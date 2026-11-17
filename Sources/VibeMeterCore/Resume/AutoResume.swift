import Foundation

/// 由官方訊號確認「因額度中止」的工作階段。
public struct BlockedSession: Hashable, Sendable {
    public var provider: ProviderID
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var blockedWindow: WindowKind
    public var resetsAt: Date?
    public var detectedAt: Date
    /// 中止點的身分（Codex turn id／Claude 訊息 uuid）。
    public var evidenceID: String
    public var codex: CodexResumeContext?
    public var claude: ClaudeResumeContext?

    /// 同一次中止（同一個 turn／訊息）只自動建立一次計畫；取消後也不會因同一次中止再建立。
    public var eventKey: String { "\(provider.rawValue)|\(sessionID)|\(evidenceID)" }
}

/// 從官方紀錄中找出「因額度中止」的工作階段。
///
/// Codex：只有 `thread/turns/list` 回報該 thread 最新 turn 為 failed／interrupted 且 `codexErrorInfo == usageLimitExceeded`
/// 才算確認；「額度滿時最近有活動」只能當作建議，不會自動加入。
public enum BlockedSessionDetector {
    public static let lookback: TimeInterval = 12 * 3600
    public static let maxInspections = 5
    /// 額度用盡前這段時間內有活動的 Codex 工作階段，可能是被中止的工作（僅作建議）。
    public static let suggestionWindow: TimeInterval = 20 * 60

    /// 額度看起來受限時，挑出值得用 `thread/turns/list` 檢查的 thread（最多 5 個）。
    public static func codexCandidates(sessions: [CodexSessionInfo], snapshot: UsageSnapshot?, now: Date) -> [CodexSessionInfo] {
        let limited = snapshot.map { s in
            s.windows.contains { $0.usedPercent >= 100 } || s.limitReachedType != nil || s.usageAllowed == false
        } ?? false
        return Array(sessions.filter { s in
            !s.isSubagent && s.cwd != nil && now.timeIntervalSince(s.lastActivity) < lookback && (limited || s.lastLimitReachedType != nil)
        }.prefix(maxInspections))
    }

    public static func codex(sessions: [CodexSessionInfo], latestTurns: [String: CodexTurnSummary], snapshot: UsageSnapshot?,
                             now: Date) -> [BlockedSession] {
        let live = snapshot?.source == .codexAppServer ? snapshot : nil
        let full = live?.windows.filter { $0.usedPercent >= 100 && ($0.resetsAt ?? .distantFuture) > now }
            .max { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }
        let window = full ?? live?.windows.max { $0.usedPercent < $1.usedPercent }
        return sessions.compactMap { s in
            guard !s.isSubagent, let cwd = s.cwd, let turn = latestTurns[s.id], turn.isUsageLimitFailure else { return nil }
            let at = turn.completedAt ?? turn.startedAt ?? s.lastActivity
            guard now.timeIntervalSince(at) < lookback else { return nil }
            return BlockedSession(provider: .codex, sessionID: s.id, title: s.displayTitle, cwd: cwd,
                                  blockedWindow: window?.kind ?? .fiveHour, resetsAt: window?.resetsAt, detectedAt: at,
                                  evidenceID: turn.id,
                                  codex: CodexResumeContext(accountID: nil, anchorTurnID: turn.id, verifiedLimitFailure: true))
        }
    }

    /// 未經驗證的建議：額度已滿、且在額度用盡前不久有活動（活動晚於快照者視為仍在工作，不列入）。
    /// 已確認最新 turn 狀態的 thread 不列入（以官方 turn 狀態為準）。
    public static func codexSuggestions(sessions: [CodexSessionInfo], snapshot: UsageSnapshot?, latestTurns: [String: CodexTurnSummary]) -> Set<String> {
        guard let snapshot, snapshot.windows.contains(where: { $0.usedPercent >= 100 }) || snapshot.limitReachedType != nil else { return [] }
        return Set(sessions.filter { s in
            !s.isSubagent && latestTurns[s.id] == nil
                && s.lastActivity <= snapshot.observedAt.addingTimeInterval(60)
                && snapshot.observedAt.timeIntervalSince(s.lastActivity) < suggestionWindow
        }.map(\.id))
    }

    public static func claude(transcripts: [ClaudeTranscriptInfo], now: Date) -> [BlockedSession] {
        transcripts.compactMap { t in
            guard let hit = t.limitHit, let cwd = t.cwd, now.timeIntervalSince(hit.at) < lookback else { return nil }
            return BlockedSession(provider: .claudeCode, sessionID: t.id, title: t.displayTitle, cwd: cwd,
                                  blockedWindow: hit.window, resetsAt: hit.resetsAt, detectedAt: hit.at,
                                  evidenceID: hit.messageUUID ?? "\(Int(hit.at.timeIntervalSince1970))",
                                  claude: ClaudeResumeContext(model: t.lastModel, limitType: hit.limitType, overageStatus: hit.overageStatus,
                                                              account: nil, anchorMessageUUID: hit.messageUUID))
        }
    }
}

/// 送出前用來檢查工作階段狀態。
public enum SessionActivity {
    /// Codex App／CLI 載入 thread 時會開啟 `thread-writer-locks/<id>.lock`。用 lsof 檢查是否有程序持有。
    public static func codexThreadLockHeld(sessionID: String, codexHome: URL) async -> Bool {
        let lock = codexHome.appendingPathComponent("thread-writer-locks/\(sessionID.lowercased()).lock")
        guard FileManager.default.fileExists(atPath: lock.path) else { return false }
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-t", "--", lock.path], timeout: 10)
        else { return false }
        return r.status == 0 && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func modificationDate(_ path: String?) -> Date? {
        guard let path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// 實際送出「繼續作業」：只透過官方 CLI。
public enum ResumeExecutor {
    public enum Failure: Error, LocalizedError {
        case commandFailed(String)
        public var errorDescription: String? {
            if case .commandFailed(let s) = self { return s }
            return nil
        }
    }

    public static func start(_ plan: ResumePlan, via delivery: ResumePlan.Delivery, codexBinary: URL?, claudeBinary: URL?,
                             launchDir: URL) throws -> Task<Void, Error> {
        let process: Task<ProcessResult, Error>
        switch delivery {
        case .codexQueue:
            guard let codex = codexBinary else { throw Failure.commandFailed("找不到 Codex CLI") }
            process = try ProcessRunner.start(codex, arguments: queueArguments(plan), timeout: 30)
        case .terminal:
            let command = ResumeCommandBuilder.command(for: plan, codexBinary: codexBinary?.path ?? "codex",
                                                       claudeBinary: claudeBinary?.path ?? "claude")
            let file = try ResumeCommandBuilder.writeCommandFile(for: plan, command: command, in: launchDir)
            process = try ProcessRunner.start(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Terminal", file.path], timeout: 20)
        }
        return Task {
            let result = try await process.value
            guard result.status == 0 else {
                switch delivery {
                case .codexQueue:
                    throw Failure.commandFailed("codex queue 失敗：\(result.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)")")
                case .terminal:
                    throw Failure.commandFailed("無法開啟終端機：\(result.stderr)")
                }
            }
        }
    }

    /// `codex queue --thread <UUID> --message <TEXT>`（不加 --resume：持有 thread 的 Codex App 會處理佇列）。
    public static func queueArguments(_ plan: ResumePlan) -> [String] {
        ["queue", "--thread", plan.sessionID, "--message", plan.prompt]
    }
}
