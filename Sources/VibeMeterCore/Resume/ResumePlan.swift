import Foundation

/// Codex 計畫的身分脈絡。
public struct CodexResumeContext: Codable, Hashable, Sendable {
    /// 額度中止時的帳戶；恢復確認時必須是同一個帳戶。
    public var accountID: String?
    /// 自動偵測：因額度失敗的那個 turn；手動加入：加入時的最新 turn。送出前最新 turn 必須仍是它。
    public var anchorTurnID: String?
    /// 錨點 turn 是否由官方 `thread/turns/list` 確認為 `usageLimitExceeded` 失敗。
    public var verifiedLimitFailure: Bool
    /// 官方證據能將中止 turn 綁定到帳戶與模型。舊計畫無此證據。
    public var verifiedAccountAndModelAtBlock: Bool?

    public init(accountID: String?, anchorTurnID: String?, verifiedLimitFailure: Bool,
                verifiedAccountAndModelAtBlock: Bool? = nil) {
        self.accountID = accountID
        self.anchorTurnID = anchorTurnID
        self.verifiedLimitFailure = verifiedLimitFailure
        self.verifiedAccountAndModelAtBlock = verifiedAccountAndModelAtBlock
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
    public var verifiedAccountAtBlock: Bool?
    /// 原中止訊息的 uuid；送出前 transcript 的最後一筆對話必須仍是它。
    public var anchorMessageUUID: String?

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
        /// 在「終端機」開啟 `codex resume <UUID> <prompt>` 或 `claude --resume <UUID> <prompt>`。
        case terminal

        public var label: String {
            switch self {
            case .codexQueue: "排入 Codex 佇列"
            case .terminal: "在終端機恢復"
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
            case .waiting: "等待額度恢復"
            case .needsConfirmation: "待確認・暫不自動繼續"
            case .ready: "已確認恢復・等你按繼續"
            case .launching: "正在送出…"
            case .launched: "已送出・等待 agent 回應"
            case .resumed: "已恢復作業"
            case .skipped(let r, _): "已略過：\(r)"
            case .cancelled: "已取消"
            case .failed(let r, _): "失敗：\(r)"
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
    public var note: String?
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

    public static let manualPrompt = "請先執行 git status 並回顧上次的進度，確認沒有其他程序正在修改後，從中斷處繼續未完成的任務。"
    public static let defaultPrompt = "額度已恢復（由 Vibe Meter 依官方資料確認）。請先執行 git status 並回顧上次的進度，確認沒有其他程序正在修改後，從中斷處繼續未完成的任務。"
}

public enum ResumePlanError: Error, Equatable, LocalizedError {
    case unsupportedProvider
    case invalidSessionID
    case invalidWorkingDirectory
    case duplicate

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "自動繼續目前只支援 Codex 與 Claude Code"
        case .invalidSessionID: "工作階段 id 必須是 UUID"
        case .invalidWorkingDirectory: "工作目錄必須是絕對路徑"
        case .duplicate: "這個工作階段已經在自動繼續清單中"
        }
    }
}

/// 建立計畫時就能判定「無法可靠自動繼續」的情況。
public enum AutoResumeGate {
    public static func blocker(for plan: ResumePlan) -> String? {
        switch plan.provider {
        case .codex:
            guard let c = plan.codex else { return "缺少 Codex 帳戶與工作階段資訊" }
            if c.anchorTurnID == nil { return "無法確認這個 thread 的最新 turn" }
            if !c.verifiedLimitFailure { return "未確認 Codex 工作階段因額度中止" }
            if c.accountID == nil || c.verifiedAccountAndModelAtBlock != true {
                return "官方紀錄無法確認 Codex 中止當下的帳戶與模型"
            }
            return nil
        case .claudeCode:
            guard let c = plan.claude else { return "缺少 Claude Code 工作階段資訊" }
            guard let account = c.account, c.verifiedAccountAtBlock == true else {
                return "官方紀錄無法確認 Claude Code 中止當下的帳戶"
            }
            if !account.isSubscription { return "不是訂閱帳戶（\(account.authMethod)），探測會產生 API 費用，不自動探測" }
            if c.model == nil { return "無法判定原工作階段使用的模型" }
            if c.limitType == nil { return "無法判定被擋住的額度週期" }
            if c.overageStatus != "rejected" { return "此帳戶可能使用額外付費用量（overage），不自動探測以免產生費用" }
            if c.anchorMessageUUID == nil { return "無法定位原中止訊息" }
            return nil
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
        if let reason = AutoResumeGate.blocker(for: plan) { return .stop(reason) }
        if let expected = plan.codex?.accountID, let actual = snapshot.accountID, expected != actual {
            return .stop("Codex 帳戶與中止時不同，不自動繼續")
        }
        guard !snapshot.isStale(now: now), snapshot.observedAt >= plan.createdAt else { return .notYet }
        if let reset = plan.expectedResetAt, snapshot.observedAt < reset { return .notYet }
        guard snapshot.limitReachedType == nil, let blocked = snapshot.window(plan.blockedWindow) else { return .notYet }
        if let reset = blocked.resetsAt, now >= reset { return .notYet }
        guard blocked.usedPercent < restoredBelowPercent, snapshot.windows.allSatisfy({ $0.usedPercent < 100 }) else { return .notYet }
        // 百分比看起來已恢復；接下來必須有後端明確許可與帳戶確認。
        guard snapshot.accountID != nil, plan.codex?.accountID != nil else { return .stop("後端未提供帳戶資訊，無法確認是同一帳戶") }
        switch snapshot.usageAllowed {
        case true?: return .restored
        case false?: return .notYet
        case nil: return .stop("後端未明確允許一般用量（ordinaryUsageAllowed 為 null），依官方說明不可由百分比推斷恢復")
        }
    }
}

/// Claude Code 恢復探測的節流與上限（探測使用原模型，會用到少量訂閱額度）。
public enum ProbePolicy {
    public static let minInterval: TimeInterval = 15 * 60
    public static let maxAttempts = 6
    /// 沒有已知重設時間時，建立後多久開始探測。
    public static let unknownResetDelay: TimeInterval = 30 * 60

    public static func shouldProbe(_ plan: ResumePlan, now: Date) -> Bool {
        guard plan.provider == .claudeCode, plan.state == .waiting, plan.probeCount < maxAttempts,
              AutoResumeGate.blocker(for: plan) == nil else { return false }
        let start = plan.expectedResetAt ?? plan.createdAt.addingTimeInterval(unknownResetDelay)
        guard now >= start else { return false }
        if let last = plan.lastProbeAt, now.timeIntervalSince(last) < minInterval { return false }
        return true
    }
}

public enum ResumeEvent: Sendable {
    /// 新的官方額度資料（只用於 Codex 計畫）。`autoContinue` 為使用者目前的「自動繼續」開關。
    case observed(UsageSnapshot, now: Date, autoContinue: Bool)
    /// Claude Code 以原模型探測的結果。
    case probed(ClaudeProbeOutcome, now: Date, autoContinue: Bool)
    /// 執行探測前發現帳戶與建立計畫時不同或無法讀取。
    case accountMismatch(String, now: Date)
    case userLaunch(now: Date)
    case userCancel(now: Date)
    case launchDeferred(confirmedAt: Date)
    case delivered(ResumePlan.Delivery, now: Date)
    case launchSkipped(String, now: Date)
    case launchFailed(String, now: Date)
    /// 送出後，在工作階段紀錄中偵測到新活動。
    case activityObserved(now: Date)
}

public enum ResumeEffect: Equatable, Sendable {
    case notifyReady
    case launch
    case notifyGaveUp
    case notifyNeedsConfirmation
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
                plan.note = "app-server 確認：同一帳戶、後端允許一般用量、額度有餘裕"
                return confirm(&plan, now: now, auto: auto)
            }

        case (.waiting, .probed(let outcome, let now, let auto)):
            if let reason = AutoResumeGate.blocker(for: plan) { return needsConfirmation(&plan, reason, now) }
            plan.probeCount += 1
            plan.lastProbeAt = now
            switch outcome {
            case .restored:
                plan.note = "以原模型 \(plan.claude?.model ?? "") 探測：伺服器接受、被擋住的週期為 allowed"
                return confirm(&plan, now: now, auto: auto)
            case .stillLimited(let resetsAt):
                if let resetsAt, resetsAt > now { plan.expectedResetAt = resetsAt }
                plan.note = "第 \(plan.probeCount) 次探測：仍在限制中"
            case .unconfirmed(let reason), .unsafe(let reason):
                return needsConfirmation(&plan, reason, now)
            case .failed(let reason):
                plan.note = "第 \(plan.probeCount) 次探測失敗：\(reason)"
            }
            if plan.probeCount >= ProbePolicy.maxAttempts {
                plan.state = .failed(reason: "探測 \(ProbePolicy.maxAttempts) 次仍無法確認恢復，已停止", at: now)
                return (plan, [.notifyGaveUp])
            }
            return (plan, [])

        case (.waiting, .accountMismatch(let reason, let now)):
            return needsConfirmation(&plan, reason, now)

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

        case (.launching, .launchDeferred(let confirmedAt)):
            plan.state = .ready(confirmedAt: confirmedAt)
        case (.launching, .delivered(let via, let now)):
            plan.delivery = via
            plan.state = .launched(at: now)
        case (.launching, .launchSkipped(let reason, let now)):
            plan.state = .skipped(reason: reason, at: now)
        case (.launching, .launchFailed(let reason, let now)):
            plan.state = .failed(reason: reason, at: now)

        case (.launched, .activityObserved(let now)):
            plan.state = .resumed(at: now)

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
                              preflight: SessionPreflight, now: Date) -> LaunchDecision {
        guard cwdExists else { return .skip("工作目錄不存在") }
        switch preflight {
        case .changed(let reason): return .skip(reason)
        case .unknown(let reason): return .skip("無法確認工作階段狀態：\(reason)")
        case .unchanged: break
        }
        if let last = lastActivity, now.timeIntervalSince(last) < busyWindow, last > plan.createdAt {
            return .skip("工作階段 2 分鐘內仍有活動，可能已在執行")
        }
        switch plan.provider {
        case .codex: return .deliver(threadLockHeld ? .codexQueue : .terminal)
        default: return .deliver(.terminal)
        }
    }

    public static func codexPreflight(latest: CodexTurnSummary?, anchorTurnID: String?,
                                      requireLimitFailure: Bool = false) -> SessionPreflight {
        guard let anchor = anchorTurnID else { return .unknown("沒有錨點 turn") }
        guard let latest else { return .unknown("讀不到最新 turn") }
        if latest.isInProgress { return .changed("Codex 正在執行新的 turn") }
        if latest.id != anchor { return .changed("已有新的 turn（可能已手動繼續）") }
        if requireLimitFailure && !latest.isUsageLimitFailure { return .unknown("錨點 turn 無法確認為額度中止") }
        return .unchanged
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
