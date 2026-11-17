import Foundation

/// Codex 計畫的身分脈絡。
public struct CodexResumeContext: Codable, Hashable, Sendable {
    /// 額度中止時的帳戶；恢復確認時必須是同一個帳戶。
    public var accountID: String?
    /// 自動偵測：因額度失敗的那個 turn；手動加入：加入時的最新 turn。送出前最新 turn 必須仍是它。
    public var anchorTurnID: String?
    public var anchorCompletedAt: Date?
    /// 錨點 turn 是否由官方 `thread/turns/list` 確認為 `usageLimitExceeded` 失敗。
    public var verifiedLimitFailure: Bool
    /// 只在本次執行讀到官方中止證據時建立。舊計畫的同名欄位不參與解碼。
    public internal(set) var verifiedAccountAndModelAtBlock: Bool? = nil
    /// 使用者的當次執行授權。和官方中止證據分開保存，兩者均不序列化。
    public internal(set) var sessionAuthorization: CodexSessionAuthorization? = nil
    /// 中止 turn 的模型（rollout `turn_context`）。恢復時模型專屬額度與 thread 目前模型都要對得上。
    public var modelAtBlock: String?
    /// 證據不足時的原因（顯示用）。
    public var evidenceGap: String?
    /// 偵測到中止時 app-server 回報的帳戶雜湊。只是 Vibe Meter 的觀察，不是中止 turn 的官方帳戶證據，
    /// 只用於「協助手動續作」提示判斷帳戶是否改變，絕不作為自動送出的授權。
    public var accountHashAtDetection: String?

    /// 一般額度定時嘗試：已核對的同帳戶官方回應提供的較晚重設。只能把送出時間延後，不能授權或提前。
    public var timedDeferredResetAt: Date?

    private enum CodingKeys: String, CodingKey {
        case accountID, anchorTurnID, anchorCompletedAt, verifiedLimitFailure, modelAtBlock, evidenceGap, accountHashAtDetection
        case timedDeferredResetAt
    }

    /// 本次執行由帳本重建的「一般額度重設後 30 秒嘗試一次」授權（不序列化，計畫檔無法自行授權）。
    public var isTimedAttempt: Bool { sessionAuthorization?.basis == .generalBucketTimed }

    public init(accountID: String?, anchorTurnID: String?, verifiedLimitFailure: Bool,
                modelAtBlock: String? = nil, evidenceGap: String? = nil) {
        self.accountID = accountID
        self.anchorTurnID = anchorTurnID
        self.verifiedLimitFailure = verifiedLimitFailure
        self.modelAtBlock = modelAtBlock
        self.evidenceGap = evidenceGap
    }
}

/// Claude Code 計畫的身分脈絡（皆取自官方 transcript 與 `claude auth status`）。
public struct ClaudeResumeContext: Codable, Hashable, Sendable {
    /// 原 session 最後一次真正回應所用的模型；探測只會用這個模型。
    public var model: String?
    /// 原中止訊息的 `rateLimitType`（five_hour、seven_day、seven_day_opus…）。
    public var limitType: String?
    /// 原中止訊息的 `overageStatus`；只有 "rejected"（不能用額外付費用量）才會自動探測。
    public var overageStatus: String?
    public var account: ClaudeAccountIdentity?
    /// 官方證據能將中止訊息綁定到帳戶。舊計畫無此證據。
    public private(set) var verifiedAccountAtBlock: Bool? = nil
    /// 原中止訊息的 uuid；送出前 transcript 的最後一筆對話必須仍是它。
    public var anchorMessageUUID: String?

    private enum CodingKeys: String, CodingKey {
        case model, limitType, overageStatus, account, anchorMessageUUID
    }

    public init(model: String?, limitType: String?, overageStatus: String?, account: ClaudeAccountIdentity?,
                anchorMessageUUID: String?, verifiedAccountAtBlock: Bool? = nil) {
        self.model = model
        self.limitType = limitType
        self.overageStatus = overageStatus
        self.account = account
        self.anchorMessageUUID = anchorMessageUUID
        self.verifiedAccountAtBlock = verifiedAccountAtBlock
    }
}

/// 「額度恢復後自動告知 agent 繼續作業」的計畫。
///
/// 安全原則：
/// - 身分：只接受 UUID session id，綁定工作目錄、帳戶、以及中止當下的 turn／訊息（錨點）。
/// - 恢復判斷：絕不只靠重設時間或百分比。Codex 需要 app-server 即時資料、`ordinaryUsageAllowed == true`、同一帳戶；
///   Claude Code 需要以「原模型」探測成功、未使用額外付費用量、且被擋住的週期在官方回應中為 allowed。
/// - 無法確認時進入「待確認」，不自動送出、不宣稱恢復。
/// - 防重複：每個計畫只自動送一次；送出前再確認錨點仍是最新狀態。失敗或略過不自動重試。
public struct ResumePlan: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        case manual
        /// 由官方訊號確認該工作階段因額度中止（Codex turn `usageLimitExceeded`、Claude transcript `rate_limit`）。
        case autoDetected
    }

    public enum Delivery: String, Codable, Sendable {
        /// `codex queue --thread <UUID> --message`：排入目前持有該 thread 的 Codex（例如 Codex App）。
        case codexQueue
        /// 請官方 CLI 排入並喚醒指定的已卸載工作階段。
        case codexQueueResume
        /// 在「終端機」開啟 `codex resume <UUID> <prompt>` 或 `claude --resume <UUID> <prompt>`。
        case terminal

        public var label: String {
            switch self {
            case .codexQueue, .codexQueueResume: tr("排入 Codex 佇列")
            case .terminal: tr("在終端機恢復")
            }
        }
    }

    public enum State: Codable, Hashable, Sendable {
        case waiting
        /// 無法可靠確認（帳戶、模型、週期、後端許可不明）：暫不自動繼續，等使用者決定。
        case needsConfirmation(reason: String, at: Date)
        /// 已確認恢復，但自動繼續關閉，等使用者按「繼續」。
        case ready(confirmedAt: Date)
        case launching(startedAt: Date)
        /// 已送出指令，等待偵測到工作階段有新活動。
        case launched(at: Date)
        /// 送出後偵測到工作階段有新活動。
        case resumed(at: Date)
        case skipped(reason: String, at: Date)
        case cancelled(at: Date)
        case failed(reason: String, at: Date)

        /// 不再有任何自動動作。
        public var isFinished: Bool {
            switch self {
            case .resumed, .skipped, .cancelled, .failed: true
            default: false
            }
        }

        public var canRetry: Bool {
            switch self {
            case .skipped, .failed: true
            default: false
            }
        }

        public var label: String {
            switch self {
            case .waiting: tr("等待額度恢復")
            case .needsConfirmation: tr("待確認・暫不自動繼續")
            case .ready: tr("已確認恢復・等你按繼續")
            case .launching: tr("正在送出…")
            case .launched: tr("已送出・等待 agent 回應")
            case .resumed: tr("已偵測到新作業")
            case .skipped(let r, _): tr("已略過：{0}", L10n.display(r))
            case .cancelled: tr("已取消")
            case .failed(let r, _): tr("失敗：{0}", L10n.display(r))
            }
        }
    }

    public var id: UUID
    public var provider: ProviderID
    public var sessionID: String
    public var sessionTitle: String
    public var cwd: String
    public var prompt: String
    public var blockedWindow: WindowKind
    public var expectedResetAt: Date?
    public var origin: Origin
    public var createdAt: Date
    public var state: State
    public var probeCount: Int = 0
    public var lastProbeAt: Date?
    public var delivery: Delivery?
    public var deliveryStartedAt: Date?
    public var automaticRetryBlocked: Bool?
    public var note: String?
    /// 已通知過「看起來可手動續作」的時間（每個計畫只通知一次）。
    public var manualReadyNotifiedAt: Date?
    public var codex: CodexResumeContext?
    public var claude: ClaudeResumeContext?

    public init(id: UUID = UUID(), provider: ProviderID, sessionID: String, sessionTitle: String, cwd: String,
                prompt: String = ResumePlan.defaultPrompt, blockedWindow: WindowKind, expectedResetAt: Date?,
                origin: Origin = .manual, createdAt: Date = Date(),
                codex: CodexResumeContext? = nil, claude: ClaudeResumeContext? = nil) throws {
        guard provider == .codex || provider == .claudeCode else { throw ResumePlanError.unsupportedProvider }
        guard SessionID.isUUID(sessionID) else { throw ResumePlanError.invalidSessionID }
        guard cwd.hasPrefix("/") else { throw ResumePlanError.invalidWorkingDirectory }
        self.id = id
        self.provider = provider
        self.sessionID = sessionID.lowercased()
        self.sessionTitle = sessionTitle
        self.cwd = cwd
        self.prompt = prompt
        self.blockedWindow = blockedWindow
        self.expectedResetAt = expectedResetAt
        self.origin = origin
        self.createdAt = createdAt
        self.codex = codex
        self.claude = claude
        self.state = .waiting
        if let reason = AutoResumeGate.blocker(for: self) {
            self.state = .needsConfirmation(reason: reason, at: createdAt)
        } else {
            self.state = .waiting
        }
    }

    // l10n-ignore：以下是送給 agent 的指令，不是介面文字。
    public static let manualPrompt = "請先執行 git status 並回顧上次的進度，確認沒有其他程序正在修改後，從中斷處繼續未完成的任務。"
    /// 一般額度定時嘗試送出的固定中性提示：送出當下由程式產生，不使用計畫檔內可編輯的文字，也不宣稱額度已恢復。
    public static let timedAttemptPrompt = "請從中斷處繼續未完成的任務。先執行 git status 並回顧上次的進度，確認沒有其他程序正在修改後再繼續。"  // l10n-ignore
    public static let defaultPrompt = "額度已恢復（由 Vibe Meter 依官方資料確認）。請先執行 git status 並回顧上次的進度，確認沒有其他程序正在修改後，從中斷處繼續未完成的任務。"  // l10n-ignore
}

public enum ResumePlanError: Error, Equatable, LocalizedError {
    case unsupportedProvider
    case invalidSessionID
    case invalidWorkingDirectory
    case duplicate

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: tr("自動繼續目前只支援 Codex 與 Claude Code")
        case .invalidSessionID: tr("工作階段 id 必須是 UUID")
        case .invalidWorkingDirectory: tr("工作目錄必須是絕對路徑")
        case .duplicate: tr("這個工作階段已經在自動繼續清單中")
        }
    }
}

/// 建立計畫時就能判定「無法可靠自動繼續」的情況。
public enum AutoResumeGate {
    public static func blocker(for plan: ResumePlan) -> String? {
        switch plan.provider {
        case .codex:
            if plan.automaticRetryBlocked == true {
                return L10n.token("此中止事件已有送出記錄或無法保存，請確認後手動處理")
            }
            guard let c = plan.codex else { return "缺少 Codex 帳戶與工作階段資訊" }
            if c.anchorTurnID == nil { return "無法確認這個 thread 的最新 turn" }
            if !c.verifiedLimitFailure { return "未確認 Codex 工作階段因額度中止" }
            if let authorization = c.sessionAuthorization, authorization.sessionID == plan.sessionID,
               authorization.turnID == c.anchorTurnID, authorization.model == c.modelAtBlock,
               authorization.window == plan.blockedWindow, authorization.resetsAt == plan.expectedResetAt,
               plan.automaticRetryBlocked != true { return nil }
            if c.accountID == nil || c.verifiedAccountAndModelAtBlock != true || c.modelAtBlock == nil {
                return c.evidenceGap ?? "官方紀錄無法確認 Codex 中止當下的帳戶與模型"
            }
            return nil
        case .claudeCode:
            // 官方原生續作在原視窗處理；Vibe Meter 不探測也不送出。
            return ClaudeNativeContinue.handledNatively
        default:
            return "不支援的服務"
        }
    }
}

public enum RestoreDecision: Equatable, Sendable {
    case notYet
    case restored
    /// 無法可靠確認，停止自動繼續（帳戶不明或變更、後端未明確允許）。
    case stop(String)
}

public enum RestoreDetector {
    /// 被擋住的週期，已使用量低於此值才算「有餘裕」。
    public static let restoredBelowPercent: Double = 90

    /// Codex：只接受 app-server 即時資料；本機 rollout 紀錄永遠不能作為恢復依據。
    public static func codexDecision(_ plan: ResumePlan, snapshot: UsageSnapshot, now: Date) -> RestoreDecision {
        guard plan.provider == .codex, snapshot.provider == .codex, snapshot.source == .codexAppServer else { return .notYet }
        // 一般額度定時嘗試由 CodexTimedResumePolicy 處理，不以百分比或許可判斷「已恢復」。
        if plan.codex?.isTimedAttempt == true { return .notYet }
        if let reason = AutoResumeGate.blocker(for: plan) { return .stop(reason) }
        if let authorization = plan.codex?.sessionAuthorization {
            guard authorization.matches(accountID: snapshot.accountID) else {
                return .stop(L10n.token("無法確認目前使用已授權的 Codex 帳戶"))
            }
        } else if let expected = plan.codex?.accountID, let actual = snapshot.accountID, expected != actual {
            return .stop("Codex 帳戶與中止時不同，不自動繼續")
        }
        let requiredObservation = plan.codex?.sessionAuthorization?.observedAt ?? plan.createdAt
        guard !snapshot.isStale(now: now), snapshot.observedAt > requiredObservation else { return .notYet }
        // 使用者指定：重設時間後保留 30 秒緩衝再送出。
        if let reset = plan.expectedResetAt, snapshot.observedAt < reset.addingTimeInterval(CodexTimedResumePolicy.buffer) { return .notYet }
        // 與定時路徑共用費用障礙：任何桶明確的工作區花費上限、credits 用盡或 spend control 都不算恢復（即使模型桶正常）。
        if CodexTimedResumePolicy.costBarrier(snapshot) { return .notYet }
        guard snapshot.spendControlReached != true, snapshot.limitReachedType == nil, let blocked = snapshot.window(plan.blockedWindow) else { return .notYet }
        if let reset = blocked.resetsAt, now >= reset { return .notYet }
        guard blocked.usedPercent < restoredBelowPercent, snapshot.windows.allSatisfy({ $0.usedPercent < 100 }) else { return .notYet }
        // 中止模型唯一匹配的官方額度桶也必須未滿。
        guard let model = plan.codex?.modelAtBlock else { return .notYet }
        guard let bucket = snapshot.quotaBucket(forModel: model) else { return .notYet }
        if let expected = plan.codex?.sessionAuthorization?.quotaKey, expected != bucket.quotaKey {
            return .stop(L10n.token("官方額度桶的對應與中止時不同，不自動繼續"))
        }
        guard bucket.spendControlReached != true, bucket.limitReachedType == nil, bucket.windows.allSatisfy({ $0.usedPercent < 100 }),
              let window = bucket.windows.first(where: { $0.kind == plan.blockedWindow }),
              window.usedPercent < restoredBelowPercent,
              window.resetsAt.map({ $0 > now }) == true else { return .notYet }
        // 百分比看起來已恢復；接下來必須有後端明確許可與帳戶確認。
        guard snapshot.accountID != nil, plan.codex?.accountID != nil || plan.codex?.sessionAuthorization != nil else { return .stop("後端未提供帳戶資訊，無法確認是同一帳戶") }
        switch snapshot.usageAllowed {
        case true?: return .restored
        // 後端未明確允許（false 或 null）：繼續等待，依官方說明不可由百分比推斷恢復，也不宣稱恢復。
        case false?, nil: return .notYet
        }
    }
}

public enum ResumeEvent: Sendable {
    /// 新的官方額度資料（只用於 Codex 計畫）。`autoContinue` 為使用者目前的「自動繼續」開關。
    case observed(UsageSnapshot, now: Date, autoContinue: Bool)
    case userLaunch(now: Date)
    case userCancel(now: Date)
    case sharedCancellation(now: Date)
    case supersededByNewTurn(now: Date)
    case launchDeferred(confirmedAt: Date)
    case retryAfterPreflight(String)
    /// 定時續作：已到官方重設時間＋30 秒。
    case timedDue(now: Date, autoContinue: Bool)
    /// 定時續作：不送出，轉為待確認（帳戶變更、過期等）。
    case timedStopped(String, now: Date)
    case delivered(ResumePlan.Delivery, now: Date)
    case launchSkipped(String, now: Date)
    case launchFailed(String, now: Date)
    /// 送出後，在工作階段紀錄中偵測到新活動。
    case activityObserved(now: Date)
    case authorizationRevoked(now: Date)
    case queuedWithWakeWarning(ResumePlan.Delivery, now: Date)
}

public enum ResumeEffect: Equatable, Sendable {
    case notifyReady
    case launch
    case notifyGaveUp
    case notifyNeedsConfirmation
    /// 一般額度定時嘗試到期但自動繼續關閉：只提醒「已過一般重設，可確認後手動繼續」。
    case notifyTimedReady
}

public enum ResumeReducer {
    public static func reduce(_ plan: ResumePlan, _ event: ResumeEvent) -> (ResumePlan, [ResumeEffect]) {
        var plan = plan
        switch (plan.state, event) {
        case (.waiting, .observed(let snapshot, let now, let auto)):
            guard plan.provider == .codex else { return (plan, []) }  // Claude 只接受同模型探測
            switch RestoreDetector.codexDecision(plan, snapshot: snapshot, now: now) {
            case .notYet: return (plan, [])
            case .stop(let reason): return needsConfirmation(&plan, reason, now)
            case .restored:
                plan.note = plan.codex?.sessionAuthorization == nil
                    ? "app-server 確認：同一帳戶、後端允許一般用量、額度有餘裕"
                    : L10n.token("目前帳戶符合用量觀察，官方確認模型週期已恢復")
                return confirm(&plan, now: now, auto: auto)
            }

        case (.ready, .userLaunch(let now)), (.needsConfirmation, .userLaunch(let now)):
            if case .needsConfirmation = plan.state {
                plan.note = "使用者在未確認狀態下手動繼續"
                if plan.prompt == ResumePlan.defaultPrompt { plan.prompt = ResumePlan.manualPrompt }
            }
            plan.state = .launching(startedAt: now)
            return (plan, [.launch])
        case (let s, .userLaunch(let now)) where s.canRetry:
            plan.state = .launching(startedAt: now)
            plan.note = "使用者手動重試"
            if plan.prompt == ResumePlan.defaultPrompt { plan.prompt = ResumePlan.manualPrompt }
            return (plan, [.launch])

        case (.waiting, .timedDue(let now, let auto)):
            guard plan.codex?.isTimedAttempt == true else { return (plan, []) }
            plan.note = L10n.token("已到一般額度重設時間＋30 秒（依時間嘗試，非官方確認原模型恢復）")
            if auto {
                plan.state = .launching(startedAt: now)
                return (plan, [.launch])
            }
            // 自動繼續關閉：不宣稱已恢復，只提醒可確認後手動繼續。
            plan.state = .ready(confirmedAt: now)
            return (plan, [.notifyTimedReady])
        case (.waiting, .timedStopped(let reason, let now)), (.ready, .timedStopped(let reason, let now)):
            return needsConfirmation(&plan, reason, now)
        case (.launching, .retryAfterPreflight(let reason)):
            plan.note = reason
            plan.state = .waiting
        case (.launching, .launchDeferred(let confirmedAt)):
            plan.state = .ready(confirmedAt: confirmedAt)
        case (.launching(let startedAt), .delivered(let via, let now)):
            plan.delivery = via
            plan.deliveryStartedAt = startedAt
            plan.state = .launched(at: now)
        case (.launching(let startedAt), .queuedWithWakeWarning(let via, let now)):
            plan.delivery = via
            plan.deliveryStartedAt = startedAt
            plan.note = L10n.token("已排入 Codex 佇列，CLI 回報喚醒未獲確認")
            plan.state = .launched(at: now)
        case (.launching, .launchSkipped(let reason, let now)):
            plan.state = .skipped(reason: reason, at: now)
        case (.launching, .launchFailed(let reason, let now)):
            plan.state = .failed(reason: reason, at: now)

        case (.launched, .activityObserved(let now)):
            plan.state = .resumed(at: now)

        case (.waiting, .authorizationRevoked(let now)), (.ready, .authorizationRevoked(let now)),
             (.launching, .authorizationRevoked(let now)):
            plan.codex?.sessionAuthorization = nil
            plan.state = .needsConfirmation(reason: L10n.token("此 Codex 工作階段的自動續作授權已撤銷"), at: now)
        case (let s, .supersededByNewTurn(let now)) where !s.isFinished:
            plan.automaticRetryBlocked = true
            plan.state = .skipped(reason: L10n.token("Codex 已有更新的額度中止 turn"), at: now)
        case (_, .sharedCancellation(let now)):
            plan.state = .cancelled(at: now)
        case (let s, .userCancel(let now)) where !s.isFinished:
            plan.state = .cancelled(at: now)
        default:
            break
        }
        return (plan, [])
    }

    private static func confirm(_ plan: inout ResumePlan, now: Date, auto: Bool) -> (ResumePlan, [ResumeEffect]) {
        if auto {
            plan.state = .launching(startedAt: now)
            return (plan, [.launch])
        }
        plan.state = .ready(confirmedAt: now)
        return (plan, [.notifyReady])
    }

    private static func needsConfirmation(_ plan: inout ResumePlan, _ reason: String, _ now: Date) -> (ResumePlan, [ResumeEffect]) {
        plan.state = .needsConfirmation(reason: reason, at: now)
        return (plan, [.notifyNeedsConfirmation])
    }
}

/// 送出前重新讀取工作階段的結果。
public enum SessionPreflight: Equatable, Sendable {
    /// 錨點（中止的 turn／訊息）仍是最新狀態。
    case unchanged
    case changed(String)
    case unknown(String)
    case retry(String)
}

/// 送出前的最後檢查：決定用哪種方式送、或是否該略過。
public enum LaunchDecision: Equatable, Sendable {
    case deliver(ResumePlan.Delivery)
    case skip(String)

    /// 工作階段在這段時間內有活動，就視為可能仍在執行。
    public static let busyWindow: TimeInterval = 120

    /// - Parameters:
    ///   - lastActivity: 工作階段紀錄（Codex rollout／Claude transcript）最後修改時間。
    ///   - threadLockHeld: Codex `thread-writer-locks/<id>.lock` 是否被某個程序開啟（例如 Codex App 已載入該 thread）。
    ///   - preflight: 重新讀取的工作階段狀態；必須仍停在原中止點。
    public static func decide(_ plan: ResumePlan, lastActivity: Date?, threadLockHeld: Bool, cwdExists: Bool,
                              preflight: SessionPreflight, now: Date, wakeUnloaded: Bool = false) -> LaunchDecision {
        guard cwdExists else { return .skip("工作目錄不存在") }
        switch preflight {
        case .changed(let reason): return .skip(reason)
        case .unknown(let reason), .retry(let reason): return .skip(L10n.token("無法確認工作階段狀態：{0}", [reason]))
        case .unchanged: break
        }
        if let last = lastActivity, now.timeIntervalSince(last) < busyWindow, last > plan.createdAt {
            return .skip("工作階段 2 分鐘內仍有活動，可能已在執行")
        }
        switch plan.provider {
        case .codex:
            if wakeUnloaded { return .deliver(.codexQueueResume) }
            return .deliver(threadLockHeld ? .codexQueue : .terminal)
        default: return .deliver(.terminal)
        }
    }

    /// - Parameters:
    ///   - currentModel: `thread/read` 回報的 thread 目前模型；自動送出時必須等於中止時模型（`expectedModel`）。
    public static func codexPreflight(latest: CodexTurnSummary?, anchorTurnID: String?,
                                      requireLimitFailure: Bool = false,
                                      expectedModel: String? = nil, currentModel: String?? = .none) -> SessionPreflight {
        guard let anchor = anchorTurnID else { return .unknown("沒有錨點 turn") }
        guard let latest else { return .unknown("讀不到最新 turn") }
        if latest.isInProgress { return .changed("Codex 正在執行新的 turn") }
        if latest.id != anchor { return .changed("已有新的 turn（可能已手動繼續）") }
        if requireLimitFailure && !latest.isUsageLimitFailure { return .unknown("錨點 turn 無法確認為額度中止") }
        if requireLimitFailure, let expected = expectedModel {
            switch currentModel {
            case .none, .some(.none): return .unknown("讀不到這個 thread 目前的模型")
            case .some(.some(let m)) where m != expected: return .changed(L10n.token("thread 目前模型（{0}）與中止時（{1}）不同", [m, expected]))
            default: break
            }
        }
        return .unchanged
    }

    public static func hasNewCodexActivity(_ plan: ResumePlan, latest: CodexTurnSummary) -> Bool {
        guard let anchor = plan.codex?.anchorTurnID, latest.id != anchor,
              let started = latest.startedAt, let dispatched = plan.deliveryStartedAt else { return false }
        return started >= Date(timeIntervalSince1970: floor(dispatched.timeIntervalSince1970)) &&
            (latest.isInProgress || latest.status == "completed")
    }

    public static func claudePreflight(current: ClaudeTranscriptInfo?, anchorMessageUUID: String?) -> SessionPreflight {
        guard let anchor = anchorMessageUUID else { return .unknown("沒有錨點訊息") }
        guard let current else { return .unknown("讀不到 transcript") }
        guard let hit = current.limitHit, hit.messageUUID == anchor else { return .changed("已有新的對話（可能已手動繼續）") }
        return .unchanged
    }
}

/// 一組計畫，保證每個工作階段最多一個進行中的計畫。
public struct ResumePlanBook: Codable, Sendable {
    public private(set) var plans: [ResumePlan] = []

    public init(plans: [ResumePlan] = []) { self.plans = plans }

    public var active: [ResumePlan] { plans.filter { !$0.state.isFinished } }

    public func plan(_ id: UUID) -> ResumePlan? { plans.first { $0.id == id } }

    public func hasActivePlan(provider: ProviderID, sessionID: String) -> Bool {
        active.contains { $0.provider == provider && $0.sessionID == sessionID.lowercased() }
    }

    public mutating func add(_ plan: ResumePlan) throws {
        if hasActivePlan(provider: plan.provider, sessionID: plan.sessionID) { throw ResumePlanError.duplicate }
        plans.append(plan)
    }

    @discardableResult
    public mutating func apply(_ event: ResumeEvent, to id: UUID) -> [ResumeEffect] {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { return [] }
        // 重試前確認沒有同一工作階段的其他進行中計畫。
        if case .userLaunch = event, plans[i].state.canRetry,
           hasActivePlan(provider: plans[i].provider, sessionID: plans[i].sessionID) { return [] }
        let (next, effects) = ResumeReducer.reduce(plans[i], event)
        plans[i] = next
        return effects
    }

    /// 只有同一個尚待確認的自動計畫可用新證據更新；已送出或取消的計畫不可重建。
    public mutating func setNote(_ id: UUID, _ note: String?) {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[i].note = note
    }

    public mutating func markManualReadyNotified(_ id: UUID, at date: Date) {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[i].manualReadyNotifiedAt = date
    }

    public mutating func bindPendingPlan(_ replacement: ResumePlan) -> Bool {
        guard let i = plans.firstIndex(where: { $0.id == replacement.id }),
              case .needsConfirmation = plans[i].state, plans[i].origin == .autoDetected,
              plans[i].automaticRetryBlocked != true, plans[i].codex?.anchorTurnID == replacement.codex?.anchorTurnID,
              replacement.state == .waiting,
              replacement.codex?.sessionAuthorization != nil else { return false }
        var merged = replacement
        // 已核對的延期跟著同一錨點保留（只會延後送出）。
        if merged.codex?.timedDeferredResetAt == nil { merged.codex?.timedDeferredResetAt = plans[i].codex?.timedDeferredResetAt }
        plans[i] = merged
        return true
    }

    /// 已核對的延期：保存較晚的有效重設（只接受晚於目前的值）。
    public mutating func deferTimedResume(_ id: UUID, to reset: Date) {
        guard let i = plans.firstIndex(where: { $0.id == id }), plans[i].state == .waiting,
              let auth = plans[i].codex?.sessionAuthorization, auth.basis == .generalBucketTimed else { return }
        let current = CodexTimedResumePolicy.effectiveReset(auth, deferredTo: plans[i].codex?.timedDeferredResetAt)
        guard reset > current, CodexTimedResumePolicy.isValidDeferral(auth, to: reset) else { return }
        plans[i].codex?.timedDeferredResetAt = reset
        plans[i].note = L10n.token("Codex 回報較晚的重設時間，改在新時間＋30 秒嘗試")
    }

    /// 把新觀察到的快照餵給所有等待中的計畫。
    public mutating func observe(_ snapshot: UsageSnapshot, now: Date, autoContinue: Bool) -> [(UUID, ResumeEffect)] {
        var out: [(UUID, ResumeEffect)] = []
        for plan in active where plan.provider == snapshot.provider && plan.state == .waiting {
            for effect in apply(.observed(snapshot, now: now, autoContinue: autoContinue), to: plan.id) {
                out.append((plan.id, effect))
            }
        }
        return out
    }

    public mutating func prune(keepFinished: Int = 20) {
        let finished = plans.filter { $0.state.isFinished }
        if finished.count > keepFinished {
            let drop = Set(finished.sorted { $0.createdAt < $1.createdAt }.prefix(finished.count - keepFinished).map(\.id))
            plans.removeAll { drop.contains($0.id) }
        }
    }
}
