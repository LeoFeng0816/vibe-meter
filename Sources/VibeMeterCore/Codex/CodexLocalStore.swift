import Foundation

/// 一個 Codex 工作階段（thread）。身分以 rollout 檔內 `session_meta.payload.id` 為準，不靠檔名猜測。
public struct CodexSessionInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var threadName: String?
    public var cwd: String?
    public var startedAt: Date?
    public var lastActivity: Date
    public var rolloutPath: String
    /// 這個工作階段最後一筆額度紀錄是否回報已達上限。
    public var lastLimitReachedType: String?
    /// 子代理（sub-agent）thread 的父 thread；一般工作階段為 nil。
    public var parentThreadID: String?

    /// Codex 內部產生的子代理 thread：不顯示、不自動繼續（`codex queue` 也不接受直接輸入）。
    public var isSubagent: Bool { parentThreadID != nil }

    public var displayTitle: String { threadName ?? URL(fileURLWithPath: cwd ?? rolloutPath).lastPathComponent }

    public init(id: String, threadName: String?, cwd: String?, startedAt: Date?, lastActivity: Date, rolloutPath: String,
                lastLimitReachedType: String? = nil, parentThreadID: String? = nil) {
        self.parentThreadID = parentThreadID
        self.id = id
        self.threadName = threadName
        self.cwd = cwd
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.rolloutPath = rolloutPath
        self.lastLimitReachedType = lastLimitReachedType
    }
}

/// 只讀取 `~/.codex` 下由 Codex 自己寫入的檔案；不修改任何東西。
public struct CodexLocalStore: Sendable {
    public var codexHome: URL

    public init(codexHome: URL = CodexLocalStore.defaultHome) {
        self.codexHome = codexHome
    }

    public static var defaultHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: codexHome.path)
    }

    var sessionsRoot: URL { codexHome.appendingPathComponent("sessions") }

    /// 依修改時間由新到舊列出 rollout 檔。
    func rolloutFiles(modifiedAfter cutoff: Date? = nil) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            if let cutoff, modified < cutoff { continue }
            result.append((url, modified))
        }
        return result.sorted { $0.1 > $1.1 }
    }

    /// 最近幾個 rollout 檔中，觀察時間最新的一筆額度資料。
    public func latestRateLimitSnapshot(scanFiles: Int = 6) -> UsageSnapshot? {
        var best: UsageSnapshot?
        for file in rolloutFiles().prefix(scanFiles) {
            if let snap = Self.lastRateLimit(in: file.url), snap.observedAt > (best?.observedAt ?? .distantPast) {
                best = snap
            }
        }
        return best
    }

    static func lastRateLimit(in url: URL) -> UsageSnapshot? {
        for line in FileTail.lastLines(of: url).reversed() {
            if let snap = CodexRateLimitParser.parseRolloutLine(line) { return snap }
        }
        return nil
    }

    /// 最近活動的工作階段。
    public func recentSessions(limit: Int = 8, within: TimeInterval = 8 * 86400, now: Date = Date(), priority: Set<String> = []) -> [CodexSessionInfo] {
        let names = threadNames()
        var sessions: [CodexSessionInfo] = []
        var prioritized: [CodexSessionInfo] = []
        var seen = Set<String>()
        for file in rolloutFiles(modifiedAfter: now.addingTimeInterval(-within)) {
            if sessions.count >= limit && prioritized.count >= priority.count { break }
            // 子代理 thread 屬於父工作階段的內部細節，不列出、不作為自動繼續對象。
            guard let meta = Self.sessionMeta(in: file.url), meta.isSubagent == false else { continue }
            let isPriority = priority.contains(meta.id.lowercased())
            guard (isPriority || sessions.count < limit), seen.insert(meta.id.lowercased()).inserted else { continue }
            let limitType = Self.lastRateLimit(in: file.url)?.limitReachedType
            let session = CodexSessionInfo(id: meta.id, threadName: names[meta.id], cwd: meta.cwd,
                                           startedAt: meta.timestamp.flatMap(ISO8601.parse),
                                           lastActivity: file.modified, rolloutPath: file.url.path,
                                           lastLimitReachedType: limitType)
            if isPriority { prioritized.append(session) } else { sessions.append(session) }
        }
        return prioritized + sessions
    }

    struct SessionMetaLine: Decodable {
        struct Payload: Decodable {
            var id: String
            var cwd: String?
            var timestamp: String?
            var parent_thread_id: String?
            var thread_source: SessionSource?
            var source: SessionSource?

            var isSubagent: Bool? {
                if parent_thread_id != nil || thread_source == .subagent || source == .subagent { return true }
                if thread_source == .unknown || source == .unknown { return nil }
                return thread_source == .topLevel || source == .topLevel ? false : nil
            }
        }
        var type: String
        var payload: Payload
    }

    enum SessionSource: Equatable, Decodable {
        case topLevel, subagent, unknown

        private enum Keys: String, CodingKey { case subagent, subAgent }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                switch value.lowercased().replacingOccurrences(of: "_", with: "") {
                case "cli", "vscode", "exec", "mcp", "appserver": self = .topLevel
                case "subagent", "subagentreview", "subagentcompact", "subagentthreadspawn", "subagentother":
                    self = .subagent
                default: self = .unknown
                }
            } else if let source = try? decoder.container(keyedBy: Keys.self),
                      source.contains(.subagent) || source.contains(.subAgent) {
                self = .subagent
            } else {
                self = .unknown
            }
        }
    }

    static func sessionMeta(in url: URL) -> SessionMetaLine.Payload? {
        guard let first = FileTail.firstLine(of: url),
              let meta = try? JSONDecoder().decode(SessionMetaLine.self, from: Data(first.utf8)),
              meta.type == "session_meta", SessionID.isUUID(meta.payload.id) else { return nil }
        return meta.payload
    }

    /// 依 session id 找 rollout 檔（檔名結尾含 id），並以 session_meta 再確認身分。
    public func rolloutFile(for sessionID: String, within: TimeInterval = 30 * 86400, now: Date = Date()) -> URL? {
        let id = sessionID.lowercased()
        return rolloutFiles(modifiedAfter: now.addingTimeInterval(-within))
            .first { $0.url.lastPathComponent.lowercased().contains(id) && Self.sessionMeta(in: $0.url)?.id.lowercased() == id }?.url
    }

    /// 是否為子代理 thread。找不到紀錄或無法確認來源時回傳 nil。
    public func isSubagent(sessionID: String, now: Date = Date()) -> Bool? {
        guard let url = rolloutFile(for: sessionID, now: now) else { return nil }
        return Self.sessionMeta(in: url)?.isSubagent
    }

    /// `session_index.jsonl`：同一 id 以最後一筆名稱為準。
    func threadNames() -> [String: String] {
        struct Entry: Decodable { var id: String; var thread_name: String? }
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        var names: [String: String] = [:]
        for line in FileTail.lastLines(of: url, maxBytes: 1024 * 1024) {
            if let e = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), let name = e.thread_name, !name.isEmpty {
                names[e.id] = name
            }
        }
        return names
    }
}
