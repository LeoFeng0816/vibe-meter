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

    /// 官方 `cost`：`total_api_duration_ms` 只在這個工作階段收到新的 API 回應後增加，用來判斷 `rate_limits` 是否真的是新的。
    public struct Cost: Decodable, Sendable {
        public var total_api_duration_ms: Double?
    }

    public var session_id: String?
    public var session_name: String?
    public var transcript_path: String?
    public var cwd: String?
    public var model: Model?
    public var version: String?
    public var rate_limits: RateLimits?
    public var cost: Cost?

    public func usageWindows() -> [UsageWindow] {
        guard let rl = rate_limits else { return [] }
        let pairs: [(WindowKind, Window?)] = [
            (.fiveHour, rl.five_hour), (.weekly, rl.seven_day), (.spend(period: rl.spend_limit?.period), rl.spend_limit),
        ]
        return pairs.compactMap { kind, w in
            guard let w, let used = w.used_percentage, (0...100).contains(used) else { return nil }
            let reset = w.resets_at.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return UsageWindow(kind: kind, usedPercent: used, resetsAt: reset)
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
    var reportedWindows: [UsageWindow]?
    /// 上次看到的 `cost.total_api_duration_ms`。
    var apiDurationMs: Double?

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
    ///
    /// statusLine 也會因權限模式切換、`refreshInterval`、重設時間到期或畫面更新而重跑，這時 `rate_limits` 仍是該工作階段
    /// 上一次 API 回應的值；Claude Code 也可能讓較舊的 script 執行晚於較新的執行結束。因此：
    /// - 每個工作階段保存 `cost.total_api_duration_ms` 的單調高水位，只有超過高水位才算「未見過的資料」；
    ///   相同或較低的計數（重播、亂序、其他工作階段的舊值）不會更新快照或時間。
    /// - 讀取、判斷、寫入在跨程序檔案鎖內完成，兩個 bridge 程序不會交錯覆蓋。
    /// - `observedAt` 只代表 bridge 收到這份新資料的時間，不是官方伺服器採樣額度的時間。
    /// - 窗口消失（重設時間已過）不寫入，也不代表額度已恢復。
    @discardableResult
    public func recordStatusLine(_ data: Data, now: Date = Date()) throws -> ClaudeStatusLineInput {
        let input = try JSONDecoder().decode(ClaudeStatusLineInput.self, from: data)
        guard let id = input.session_id, SessionID.isUUID(id) else { return input }
        try paths.ensure(paths.claudeSessionsDir)
        try BridgeLock.withLock(at: paths.claudeDir.appendingPathComponent(".bridge.lock")) {
            let sessionFile = paths.claudeSessionsDir.appendingPathComponent("\(id.lowercased()).json")
            let previous = (try? Data(contentsOf: sessionFile))
                .flatMap { try? VibeMeterJSON.decoder.decode(ClaudeSessionInfo.self, from: $0) }
            let latest = latestSnapshot(now: now)
            let windows = input.usageWindows()
            let apiDuration = input.cost?.total_api_duration_ms.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let decision = Self.freshness(windows: windows, apiDuration: apiDuration, previous: previous, latest: latest, now: now)
            switch decision {
            case .fresh:
                let snapshot = UsageSnapshot(provider: .claudeCode, windows: Self.merge(windows, keepingExpiredFrom: latest, now: now),
                                             observedAt: now, source: .claudeStatusLine)
                try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(snapshot), to: paths.claudeRateLimits)
            case .unknownTime:
                let snapshot = UsageSnapshot(provider: .claudeCode, windows: windows, observedAt: now, source: .claudeStatusLine,
                                             responseTimeUnknown: true)
                try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(snapshot), to: paths.claudeRateLimits)
            case .activityOnly:
                try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(ClaudeActivity(at: now)), to: paths.claudeActivity)
            case .replay, .olderWriter:
                break
            }
            // 較舊的 writer（計數低於高水位）不得回退版本、名稱、窗口基線；lastSeen 只前進。
            let older = decision == .olderWriter || decision == .replay
            let highWater = [apiDuration, previous?.apiDurationMs].compactMap { $0 }.max()
            let keepMetadata = older && previous != nil
            let info = ClaudeSessionInfo(id: id,
                                         name: keepMetadata ? previous?.name : (input.session_name ?? previous?.name),
                                         cwd: keepMetadata ? previous?.cwd : (input.cwd ?? previous?.cwd),
                                         transcriptPath: keepMetadata ? previous?.transcriptPath : (input.transcript_path ?? previous?.transcriptPath),
                                         model: keepMetadata ? previous?.model : (input.model?.display_name ?? input.model?.id ?? previous?.model),
                                         version: keepMetadata ? previous?.version : (input.version ?? previous?.version),
                                         lastSeen: max(now, previous?.lastSeen ?? now),
                                         reportedWindows: keepMetadata || windows.isEmpty ? previous?.reportedWindows : windows,
                                         apiDurationMs: highWater)
            try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(info), to: sessionFile)
        }
        return input
    }

    enum Freshness: Equatable {
        /// 有新回應且至少一個窗口的數值不同：以 bridge 收到的時間發布。
        case fresh
        /// 第一次看到既有工作階段且沒有任何資料：發布但標示無法確認是否為舊值。
        case unknownTime
        /// 有新回應但數值完全相同（或只有窗口消失）：只記錄活動時間，不刷新用量的時間。
        case activityOnly
        /// 重播或沒有新資訊。
        case replay
        /// 計數低於此工作階段的高水位：晚結束的舊 script。
        case olderWriter
    }

    static func freshness(windows: [UsageWindow], apiDuration: Double?, previous: ClaudeSessionInfo?,
                          latest: UsageSnapshot?, now: Date) -> Freshness {
        if let apiDuration, let highWater = previous?.apiDurationMs {
            if apiDuration < highWater { return .olderWriter }
            if apiDuration == highWater { return .replay }
        }
        guard !windows.isEmpty, latest.map({ $0.observedAt < now }) ?? true else {
            return apiDuration != nil && previous?.apiDurationMs != nil ? .activityOnly : .replay
        }
        guard previous != nil else {
            // 第一次看到這個工作階段：無法排除是很久以前的回應。只在完全沒有資料時發布，並標示無法確認。
            return latest == nil ? .unknownTime : .replay
        }
        guard apiDuration != nil else { return .replay }
        if apiDuration != nil, previous?.apiDurationMs == nil {
            // 舊紀錄沒有計數：建立高水位基線，這一次不視為新資料。
            return .replay
        }
        let changed = windows.contains { window in
            previous?.reportedWindows?.first { $0.kind == window.kind } != window &&
            latest?.window(window.kind) != window
        }
        if changed { return .fresh }
        return apiDuration != nil ? .activityOnly : .replay
    }

    /// 新資料沒有的窗口：只保留重設時間已過的舊值（介面顯示「已過重設時間」），未到期但缺少的窗口不沿用。
    static func merge(_ windows: [UsageWindow], keepingExpiredFrom latest: UsageSnapshot?, now: Date) -> [UsageWindow] {
        let kinds = Set(windows.map(\.kind))
        let expired = (latest?.windows ?? []).filter { !kinds.contains($0.kind) && ($0.resetsAt.map { $0 <= now } ?? false) }
        return windows + expired
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
        try BridgeLock.withLock(at: paths.claudeDir.appendingPathComponent(".bridge.lock")) {
            if !FileManager.default.fileExists(atPath: paths.claudeEvents.path) {
                FileManager.default.createFile(atPath: paths.claudeEvents.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: paths.claudeEvents)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    // MARK: App 端（讀取）

    /// 只使用 statusLine；較舊版本留下的主動探測快照沒有可靠的帳戶歸屬。觀察時間在未來（時鐘被調整或檔案遭竄改）的資料拒絕使用。
    public func latestSnapshot(now: Date = Date()) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: paths.claudeRateLimits),
              let snapshot = try? VibeMeterJSON.decoder.decode(UsageSnapshot.self, from: data),
              snapshot.provider == .claudeCode, snapshot.source == .claudeStatusLine,
              snapshot.observedAt <= now else { return nil }
        return snapshot
    }

    /// 最近一次「有新回應但額度數值相同」的時間。
    public func lastActivityWithoutChange(now: Date = Date()) -> Date? {
        guard let data = try? Data(contentsOf: paths.claudeActivity),
              let activity = try? VibeMeterJSON.decoder.decode(ClaudeActivity.self, from: data), activity.at <= now else { return nil }
        return activity.at
    }

    /// bridge 回報過的 Claude Code 版本中最新的一個工作階段所用版本（只取自官方 statusLine 的 `version`）。
    public func latestReportedVersion() -> (version: String, seenAt: Date)? {
        recentSessions(limit: 20).compactMap { s in s.version.map { ($0, s.lastSeen) } }.first
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
            case .fiveHour: return tr("5h 剩 {0}", "\(Int(w.remainingPercent.rounded()))%")
            case .weekly: return tr("週 剩 {0}", "\(Int(w.remainingPercent.rounded()))%")
            default: return nil
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// 跨程序互斥（flock）。多個 Claude Code 工作階段同時重跑 statusLine 時，bridge 的讀取→判斷→寫入不會交錯。
enum BridgeLock {
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileLocking) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Claude Code 有新回應但額度數值未變的時間（不代表用量資料被重新採樣）。
public struct ClaudeActivity: Codable, Sendable {
    public var at: Date
}
