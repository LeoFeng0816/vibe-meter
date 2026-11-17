import Foundation

/// Claude Code 自己寫的 transcript（`~/.claude/projects/<專案>/<session-id>.jsonl`）。唯讀。
public struct ClaudeTranscriptInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var cwd: String?
    public var transcriptPath: String
    public var lastActivity: Date
    /// 最後一筆對話是官方額度中止訊息（`"error":"rate_limit"`）時的資訊。
    public var limitHit: LimitHit?
    /// 這個 session 最後一次真正回應所用的模型（排除 `<synthetic>` 錯誤訊息）。
    public var lastModel: String?

    public struct LimitHit: Hashable, Sendable {
        public var at: Date
        public var resetsAt: Date?
        public var window: WindowKind
        /// 官方 `rate_limit_info.rateLimitType` 原值（例如 five_hour、seven_day、seven_day_opus）。
        public var limitType: String?
        /// 官方 `rate_limit_info.overageStatus`；"rejected" 表示不能用額外付費用量。
        public var overageStatus: String?
        /// 該錯誤訊息的 uuid：用來確認之後沒有新的對話（去重、防止重複送出）。
        public var messageUUID: String?

        public init(at: Date, resetsAt: Date?, window: WindowKind, limitType: String? = nil,
                    overageStatus: String? = nil, messageUUID: String? = nil) {
            self.at = at
            self.resetsAt = resetsAt
            self.window = window
            self.limitType = limitType
            self.overageStatus = overageStatus
            self.messageUUID = messageUUID
        }
    }

    public var displayTitle: String { URL(fileURLWithPath: cwd ?? transcriptPath).lastPathComponent }

    public init(id: String, cwd: String?, transcriptPath: String, lastActivity: Date, limitHit: LimitHit? = nil, lastModel: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.lastActivity = lastActivity
        self.limitHit = limitHit
        self.lastModel = lastModel
    }
}

public struct ClaudeTranscriptStore: Sendable {
    public var projectsDir: URL

    public init(projectsDir: URL = ClaudeTranscriptStore.defaultProjectsDir) {
        self.projectsDir = projectsDir
    }

    public static var defaultProjectsDir: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    struct Line: Decodable {
        struct Params: Decodable {
            struct Info: Decodable { var status: String?; var resetsAt: Double?; var rateLimitType: String?; var overageStatus: String? }
            var rate_limit_info: Info?
        }
        struct Message: Decodable { var model: String? }
        var type: String?
        var uuid: String?
        var sessionId: String?
        var cwd: String?
        var timestamp: String?
        var error: String?
        var isApiErrorMessage: Bool?
        var apiErrorParams: Params?
        var message: Message?
    }

    func transcriptFiles(modifiedAfter cutoff: Date) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for project in projects {
            guard let items = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: keys,
                                                                           options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension == "jsonl" && SessionID.isUUID(url.deletingPathExtension().lastPathComponent) {
                if let m = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, m >= cutoff { files.append((url, m)) }
            }
        }
        return files.sorted { $0.1 > $1.1 }
    }

    public func recentSessions(limit: Int = 8, within: TimeInterval = 3 * 86400, now: Date = Date()) -> [ClaudeTranscriptInfo] {
        transcriptFiles(modifiedAfter: now.addingTimeInterval(-within)).prefix(limit).compactMap { Self.inspect($0.0, modified: $0.1) }
    }

    public func transcript(for sessionID: String) -> URL? {
        let name = sessionID.lowercased() + ".jsonl"
        guard let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return nil }
        return projects.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 重新讀取單一 session（送出前確認狀態用）。
    public func inspect(sessionID: String) -> ClaudeTranscriptInfo? {
        guard let url = transcript(for: sessionID),
              let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return Self.inspect(url, modified: m)
    }

    static func inspect(_ url: URL, modified: Date) -> ClaudeTranscriptInfo? {
        let id = url.deletingPathExtension().lastPathComponent.lowercased()
        var cwd: String?
        var limit: ClaudeTranscriptInfo.LimitHit?
        var lastModel: String?
        var decidedLast = false
        // 由新到舊：找出 cwd、最後的真實模型，以及「最後一筆對話」是否為額度中止。
        for raw in FileTail.lastLines(of: url, maxBytes: 512 * 1024).reversed() {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            if cwd == nil, let c = line.cwd { cwd = c }
            if lastModel == nil, line.type == "assistant", let m = line.message?.model, m != "<synthetic>", !m.isEmpty { lastModel = m }
            let isConversation = line.type == "user" || line.type == "assistant"
            if !decidedLast, isConversation {
                decidedLast = true
                if line.error == "rate_limit", line.isApiErrorMessage == true {
                    let info = line.apiErrorParams?.rate_limit_info
                    limit = .init(at: line.timestamp.flatMap(ISO8601.parse) ?? modified,
                                  resetsAt: info?.resetsAt.map { Date(timeIntervalSince1970: $0) },
                                  window: ClaudeLimitType.windowKind(info?.rateLimitType),
                                  limitType: info?.rateLimitType, overageStatus: info?.overageStatus, messageUUID: line.uuid)
                }
            }
            if cwd != nil, lastModel != nil, decidedLast { break }
        }
        return ClaudeTranscriptInfo(id: id, cwd: cwd, transcriptPath: url.path, lastActivity: modified, limitHit: limit, lastModel: lastModel)
    }
}

public enum ClaudeLimitType {
    public static func windowKind(_ type: String?) -> WindowKind {
        switch type {
        case "five_hour": return .fiveHour
        case "seven_day": return .weekly
        case let t?: return .named(t)
        case nil: return .named("unknown")
        }
    }
}
