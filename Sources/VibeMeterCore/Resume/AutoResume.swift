import CryptoKit
import Darwin
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
    /// 已有計畫的工作階段（例如等待每週額度重設）在重啟後仍要能重建授權。
    public static let activePlanLookback: TimeInterval = 8 * 86400
    public static let maxInspections = 5
    /// 額度用盡前這段時間內有活動的 Codex 工作階段，可能是被中止的工作（僅作建議）。
    public static let suggestionWindow: TimeInterval = 20 * 60

    /// 即使目前額度已恢復，仍確認近期的最新 turn；有本機限額訊號者優先。
    public static func codexCandidates(sessions: [CodexSessionInfo], now: Date, priority: Set<String> = [], offset: Int = 0) -> [CodexSessionInfo] {
        let recent = sessions.filter {
            let window = priority.contains($0.id.lowercased()) ? activePlanLookback : lookback
            return !$0.isSubagent && $0.cwd != nil && $0.lastActivity <= now && now.timeIntervalSince($0.lastActivity) < window
        }
        let ordered = recent.sorted { left, right in
            let lp = priority.contains(left.id.lowercased()), rp = priority.contains(right.id.lowercased())
            if lp != rp { return lp }
            if (left.lastLimitReachedType != nil) != (right.lastLimitReachedType != nil) {
                return left.lastLimitReachedType != nil
            }
            return left.lastActivity > right.lastActivity
        }
        let active = ordered.filter { priority.contains($0.id.lowercased()) }
        let recentOthers = ordered.filter { !priority.contains($0.id.lowercased()) }
        if active.count >= maxInspections {
            // Reserve one slot for discovering newly interrupted sessions.
            return Array(rotate(active, by: offset).prefix(maxInspections - 1)) + rotate(recentOthers, by: offset).prefix(1)
        }
        return active + rotate(recentOthers, by: offset).prefix(maxInspections - active.count)
    }

    private static func rotate(_ sessions: [CodexSessionInfo], by offset: Int) -> [CodexSessionInfo] {
        guard !sessions.isEmpty else { return [] }
        let start = max(0, offset) % sessions.count
        return Array(sessions[start...]) + sessions.prefix(start)
    }

    /// - Parameter evidence: 以 thread id 為 key 的中止證據（模型、建立帳戶、帳本判定）。缺少時計畫會是「待確認」。
    public static func codex(sessions: [CodexSessionInfo], latestTurns: [String: CodexTurnSummary], snapshot: UsageSnapshot?,
                             now: Date, evidence: [String: CodexBlockEvidence] = [:],
                             observations: CodexQuotaObservations = .init(), continuation: CodexContinuationSettings = .init(),
                             timedResume: Bool = false,
                             /// 工作階段層級的共享抑制（兩種自動型態共用）：已有尚未手動確認的自動嘗試時回傳 true。
                             timedSessionBlocked: (String, Date) -> Bool = { _, _ in false }) -> [BlockedSession] {
        let live = snapshot?.source == .codexAppServer ? snapshot : nil
        let full = live?.windows.filter { $0.usedPercent >= 100 && ($0.resetsAt ?? .distantFuture) > now }
            .max { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }
        let window = full ?? live?.windows.max { $0.usedPercent < $1.usedPercent }
        return sessions.compactMap { s in
            guard !s.isSubagent, let cwd = s.cwd, let turn = latestTurns[s.id], turn.isUsageLimitFailure else { return nil }
            let at = turn.completedAt ?? turn.startedAt ?? s.lastActivity
            guard at <= now, now.timeIntervalSince(at) < activePlanLookback else { return nil }
            var context = evidence[s.id]?.context(anchorTurnID: turn.id)
                ?? CodexResumeContext(accountID: nil, anchorTurnID: turn.id, verifiedLimitFailure: true,
                                      evidenceGap: L10n.token("尚未取得中止時的帳戶與模型證據"))
            context.anchorCompletedAt = turn.completedAt
            if let account = live?.accountID, !account.isEmpty { context.accountHashAtDetection = AccountHash.of(account) }
            var matchedWindow = window
            switch observations.bind(sessionID: s.id, turn: turn, model: context.modelAtBlock,
                                     snapshot: live, now: now, settings: continuation) {
            case .success(let authorization) where timedSessionBlocked(s.id, authorization.resetsAt):
                // 這個工作階段已有尚未經使用者手動確認的自動嘗試（不論型態）：無法排除新中止是自己排入的提示造成，不再自動送出。
                context.evidenceGap = L10n.token("這個工作階段已自動嘗試過；無法確認之後的工作是否由你送出，不再自動送出。按「手動繼續」後，之後新週期的中止才會再自動嘗試")
            case .success(let authorization):
                context.sessionAuthorization = authorization
                context.evidenceGap = nil
                matchedWindow = UsageWindow(kind: authorization.window, usedPercent: 100, resetsAt: authorization.resetsAt)
            case .failure(let gap):
                context.evidenceGap = gap.reason
                // 使用者選擇的一般額度定時嘗試：只在「沒有模型專屬桶」時適用，身分與時間邊界與官方路徑相同。
                // 範圍限定、缺模型、帳戶不符等其他缺口不放寬。
                if timedResume, gap.gap == .noQuotaMapping {
                    switch observations.bindTimed(sessionID: s.id, turn: turn, model: context.modelAtBlock,
                                                  snapshot: live, now: now, settings: continuation) {
                    case .success(let authorization)
                        where timedSessionBlocked(s.id, authorization.resetsAt):
                        // 自動排入的提示在同一週期又中止：可能是自己的嘗試失敗，不再自動付費重試。
                        context.evidenceGap = L10n.token("這個工作階段已自動嘗試過；無法確認之後的工作是否由你送出，不再自動送出。按「手動繼續」後，之後新週期的中止才會再自動嘗試")
                    case .success(let authorization):
                        context.sessionAuthorization = authorization
                        context.evidenceGap = nil
                        matchedWindow = UsageWindow(kind: authorization.window, usedPercent: 100, resetsAt: authorization.resetsAt)
                    case .failure(let timedGap):
                        context.evidenceGap = timedGap.reason
                    }
                }
            }
            return BlockedSession(provider: .codex, sessionID: s.id, title: s.displayTitle, cwd: cwd,
                                  blockedWindow: matchedWindow?.kind ?? .fiveHour, resetsAt: matchedWindow?.resetsAt, detectedAt: at,
                                  evidenceID: turn.id, codex: context)
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

/// 每個額度中止錨點的持久化發送記錄。跨 App 程序使用同一目錄時也只能取得一次。
public struct CodexDispatchClaims: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func file(sessionID: String, turnID: String) -> URL {
        let key = SHA256.hash(data: Data("codex|\(sessionID.lowercased())|\(turnID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key)
    }

    public func contains(sessionID: String, turnID: String) throws -> Bool {
        var info = stat()
        if lstat(file(sessionID: sessionID, turnID: turnID).path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw CocoaError(.fileReadUnknown)
    }

    public func claim(sessionID: String, turnID: String) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(file(sessionID: sessionID, turnID: turnID).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 {
            close(fd)
            return true
        }
        if errno == EEXIST { return false }
        throw CocoaError(.fileWriteUnknown)
    }
}

/// 實際送出「繼續作業」：只透過官方 CLI。
public enum ResumeExecutor {
    public enum Failure: Error, LocalizedError {
        case commandFailed(String)
        case queuedWakeUnconfirmed
        public var errorDescription: String? {
            switch self {
            case .commandFailed(let message): message
            case .queuedWakeUnconfirmed: L10n.token("已排入 Codex 佇列，CLI 回報喚醒未獲確認")
            }
        }
    }

    public static func start(_ plan: ResumePlan, via delivery: ResumePlan.Delivery, codexBinary: URL?, claudeBinary: URL?,
                             launchDir: URL) throws -> Task<Void, Error> {
        let process: Task<ProcessResult, Error>
        switch delivery {
        case .codexQueue, .codexQueueResume:
            guard let codex = codexBinary else { throw Failure.commandFailed("找不到 Codex CLI") }
            process = try ProcessRunner.start(codex, arguments: queueArguments(plan, wakeUnloaded: delivery == .codexQueueResume), timeout: 30)
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
                case .codexQueue, .codexQueueResume:
                    throw Failure.commandFailed(L10n.token("codex queue 失敗：{0}", [result.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"]))
                case .terminal:
                    throw Failure.commandFailed(L10n.token("無法開啟終端機：{0}", [result.stderr]))
                }
            }
            if delivery == .codexQueueResume, !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Failure.queuedWakeUnconfirmed
            }
        }
    }

    /// `codex queue --thread <UUID> --message <TEXT>`（不加 --resume：持有 thread 的 Codex App 會處理佇列）。
    public static func queueArguments(_ plan: ResumePlan, wakeUnloaded: Bool = false) -> [String] {
        ["queue"] + (wakeUnloaded ? ["--resume"] : []) + ["--thread", plan.sessionID, "--message", plan.prompt]
    }

    public static func supportsQueueResume(_ codex: URL) async -> Bool {
        guard let result = try? await ProcessRunner.run(codex, arguments: ["queue", "--help"], timeout: 5),
              result.status == 0 else { return false }
        return result.stdout.split(whereSeparator: \.isWhitespace).contains("--resume")
    }
}
