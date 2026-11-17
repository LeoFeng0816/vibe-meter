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
    /// 讀取範圍內最近一次額度中止（不論之後是否還有對話）。
    public var lastLimit: LimitHit?
    /// 最近一次額度中止之後，transcript 已有新的對話（原生自動繼續、使用者送出提示等，無法分辨）。
    public var continuedAfterLimit: Bool = false

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
        /// 寫入該行的 Claude Code 版本與進入點（例如 `cli` 為互動終端機、`sdk-cli` 為 `-p`／SDK）。
        public var version: String?
        public var entrypoint: String?
        /// 紀錄有可解析的時間戳。false 時 `at` 只是檔案修改時間，不能當作中止時間或倒數起點。
        public var timeKnown: Bool = true

        public init(at: Date, resetsAt: Date?, window: WindowKind, limitType: String? = nil,
                    overageStatus: String? = nil, messageUUID: String? = nil, version: String? = nil, entrypoint: String? = nil) {
            self.at = at
            self.resetsAt = resetsAt
            self.window = window
            self.limitType = limitType
            self.overageStatus = overageStatus
            self.messageUUID = messageUUID
            self.version = version
            self.entrypoint = entrypoint
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
        var version: String?
        var entrypoint: String?
        var isSidechain: Bool?
        var isMeta: Bool?
    }

    func transcriptFiles(modifiedAfter cutoff: Date) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                          options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for project in projects {
            guard let attributes = try? project.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  attributes.isDirectory == true, attributes.isSymbolicLink != true,
                  let items = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: keys,
                                                                           options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension == "jsonl" && SessionID.isUUID(url.deletingPathExtension().lastPathComponent) {
                if let attributes = try? url.resourceValues(forKeys: Set(keys)),
                   attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                   let m = attributes.contentModificationDate, m >= cutoff { files.append((url, m)) }
            }
        }
        return files.sorted { $0.1 > $1.1 }
    }

    public func recentSessions(limit: Int = 8, within: TimeInterval = 3 * 86400, now: Date = Date()) -> [ClaudeTranscriptInfo] {
        transcriptFiles(modifiedAfter: now.addingTimeInterval(-within)).prefix(limit).compactMap { Self.inspect($0.0, modified: $0.1) }
    }

    public func transcript(for sessionID: String) -> URL? {
        guard SessionID.isUUID(sessionID) else { return nil }
        let name = sessionID.lowercased() + ".jsonl"
        return transcriptFiles(modifiedAfter: .distantPast).first { $0.0.lastPathComponent.lowercased() == name }?.0
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
        var lastLimit: ClaudeTranscriptInfo.LimitHit?
        var lastModel: String?
        var decidedLast = false
        var conversationAfter = false
        var continuedAfterLimit = false
        // 由新到舊。只採用同一主工作階段（行內 sessionId 等於檔名、非 sidechain）的紀錄；
        // 額度中止只認 assistant 的官方 API 錯誤；「新對話」只算真正的回應或使用者提示（排除工具結果、meta、合成訊息）。
        for raw in FileTail.lastLines(of: url, maxBytes: 512 * 1024).reversed() {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)),
                  line.sessionId?.lowercased() == id, line.isSidechain != true else { continue }
            if cwd == nil, let c = line.cwd { cwd = c }
            let realModel = line.message?.model.flatMap { $0 != "<synthetic>" && !$0.isEmpty ? $0 : nil }
            let isLimit = line.type == "assistant" && line.error == "rate_limit" && line.isApiErrorMessage == true
            if lastModel == nil, line.type == "assistant", !isLimit, let m = realModel { lastModel = m }
            let isReply = line.type == "assistant" && !isLimit && line.error == nil && realModel != nil
            let isPrompt = line.type == "user" && line.isMeta != true
                && !raw.contains("\"tool_result\"") && !raw.contains("\"toolUseResult\"")
            guard isLimit || isReply || isPrompt else { continue }
            if isLimit, lastLimit == nil {
                let info = line.apiErrorParams?.rate_limit_info
                let parsed = line.timestamp.flatMap(ISO8601.parse)
                var hit = ClaudeTranscriptInfo.LimitHit(at: parsed ?? modified,
                                                         resetsAt: info?.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                                                         window: ClaudeLimitType.windowKind(info?.rateLimitType),
                                                         limitType: info?.rateLimitType, overageStatus: info?.overageStatus,
                                                         messageUUID: line.uuid, version: line.version, entrypoint: line.entrypoint)
                hit.timeKnown = parsed != nil
                lastLimit = hit
                continuedAfterLimit = conversationAfter
                if !decidedLast { limit = hit }
            }
            decidedLast = true
            if !isLimit { conversationAfter = true }
            if cwd != nil, lastModel != nil, lastLimit != nil { break }
        }
        var info = ClaudeTranscriptInfo(id: id, cwd: cwd, transcriptPath: url.path, lastActivity: modified, limitHit: limit, lastModel: lastModel)
        info.lastLimit = lastLimit
        info.continuedAfterLimit = continuedAfterLimit
        return info
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
