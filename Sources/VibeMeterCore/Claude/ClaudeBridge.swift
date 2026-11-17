import Foundation

/// Claude Code statusLine 會從 stdin 傳入的 JSON（只取需要的欄位）。
/// 官方欄位說明：rate_limits.five_hour / seven_day 的 used_percentage（0–100）與 resets_at（Unix 秒）。
public struct ClaudeStatusLineInput: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public var id: String?
        public var display_name: String?
    }

    public struct Window: Decodable, Sendable {
        public var used_percentage: Double?
        public var resets_at: Double?
        public var period: String?
    }

    public struct RateLimits: Decodable, Sendable {
        public var five_hour: Window?
        public var seven_day: Window?
        public var spend_limit: Window?
    }

    public var session_id: String?
    public var session_name: String?
    public var transcript_path: String?
    public var cwd: String?
    public var model: Model?
    public var version: String?
    public var rate_limits: RateLimits?

    public func usageWindows() -> [UsageWindow] {
        guard let rl = rate_limits else { return [] }
        let pairs: [(WindowKind, Window?)] = [
            (.fiveHour, rl.five_hour), (.weekly, rl.seven_day), (.spend(period: rl.spend_limit?.period), rl.spend_limit),
        ]
        return pairs.compactMap { kind, w in
            guard let w, let used = w.used_percentage else { return nil }
            return UsageWindow(kind: kind, usedPercent: used, resetsAt: w.resets_at.map { Date(timeIntervalSince1970: $0) })
        }
    }
}

public struct ClaudeSessionInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var model: String?
    public var version: String?
    public var lastSeen: Date

    public var displayTitle: String { name ?? URL(fileURLWithPath: cwd ?? id).lastPathComponent }
}

/// StopFailure hook 紀錄（matcher = rate_limit）。
public struct ClaudeLimitEvent: Codable, Hashable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var transcriptPath: String?
    public var reason: String
    public var at: Date
}

/// bridge 寫入、App 讀取的檔案格式。
public struct ClaudeBridgeStore: Sendable {
    public var paths: VibeMeterPaths

    public init(paths: VibeMeterPaths = .default) { self.paths = paths }

    // MARK: bridge 端（寫入）

    /// 處理一次 statusLine 輸入。回傳解析結果以便輸出狀態列文字。
    @discardableResult
    public func recordStatusLine(_ data: Data, now: Date = Date()) throws -> ClaudeStatusLineInput {
        let input = try JSONDecoder().decode(ClaudeStatusLineInput.self, from: data)
        // 沒有 rate_limits 不代表用量為 0（例如非訂閱帳號或尚未有回應），因此保留上一筆，不覆寫。
        let windows = input.usageWindows()
        if !windows.isEmpty {
            let snapshot = UsageSnapshot(provider: .claudeCode, windows: windows, observedAt: now, source: .claudeStatusLine)
            try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(snapshot), to: paths.claudeRateLimits)
        }
        if let id = input.session_id, SessionID.isUUID(id) {
            let info = ClaudeSessionInfo(id: id, name: input.session_name, cwd: input.cwd,
                                         transcriptPath: input.transcript_path, model: input.model?.display_name ?? input.model?.id,
                                         version: input.version, lastSeen: now)
            try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(info),
                                             to: paths.claudeSessionsDir.appendingPathComponent("\(id.lowercased()).json"))
        }
        return input
    }

    public func recordStopFailure(_ data: Data, reason: String, now: Date = Date()) throws {
        struct HookInput: Decodable { var session_id: String?; var cwd: String?; var transcript_path: String? }
        let input = try JSONDecoder().decode(HookInput.self, from: data)
        guard let id = input.session_id, SessionID.isUUID(id) else { return }
        let event = ClaudeLimitEvent(sessionID: id, cwd: input.cwd, transcriptPath: input.transcript_path,
                                     reason: reason, at: now)
        var line = try VibeMeterJSON.encoder.encode(event)
        line.append(0x0A)
        try paths.ensure(paths.claudeDir)
        if !FileManager.default.fileExists(atPath: paths.claudeEvents.path) {
            FileManager.default.createFile(atPath: paths.claudeEvents.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: paths.claudeEvents)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    // MARK: App 端（讀取）

    /// 狀態列資料與探測資料中較新的一筆。
    public func latestSnapshot() -> UsageSnapshot? {
        [paths.claudeRateLimits, probeSnapshotURL].compactMap { url -> UsageSnapshot? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? VibeMeterJSON.decoder.decode(UsageSnapshot.self, from: data)
        }.max { $0.observedAt < $1.observedAt }
    }

    var probeSnapshotURL: URL { paths.claudeDir.appendingPathComponent("probe-snapshot.json") }

    public func recordProbeSnapshot(_ snapshot: UsageSnapshot) throws {
        try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(snapshot), to: probeSnapshotURL)
    }

    public func recentSessions(limit: Int = 8) -> [ClaudeSessionInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: paths.claudeSessionsDir, includingPropertiesForKeys: nil)
        else { return [] }
        let sessions = files.filter { $0.pathExtension == "json" }.compactMap { url -> ClaudeSessionInfo? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? VibeMeterJSON.decoder.decode(ClaudeSessionInfo.self, from: data)
        }
        return Array(sessions.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
    }

    public func limitEvents(since: Date) -> [ClaudeLimitEvent] {
        FileTail.lastLines(of: paths.claudeEvents, maxBytes: 256 * 1024).compactMap {
            try? VibeMeterJSON.decoder.decode(ClaudeLimitEvent.self, from: Data($0.utf8))
        }.filter { $0.at >= since }
    }
}

public enum StatusLineText {
    /// statusLine 本身的輸出：簡短顯示剩餘額度。
    public static func compact(_ windows: [UsageWindow]) -> String {
        let parts = windows.compactMap { w -> String? in
            switch w.kind {
            case .fiveHour: return "5h 剩 \(Int(w.remainingPercent.rounded()))%"
            case .weekly: return "週 剩 \(Int(w.remainingPercent.rounded()))%"
            default: return nil
            }
        }
        return parts.joined(separator: " · ")
    }
}
