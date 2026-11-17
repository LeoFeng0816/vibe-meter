import AppKit
import Foundation
import Observation
import VibeMeterCore

@MainActor
@Observable
public final class AppModel {
    public var reports: [ProviderReport] = ProviderID.allCases.map { ProviderReport(provider: $0, state: .loading) }
    public var codexSessions: [CodexSessionInfo] = []
    public var claudeSessions: [ClaudeTranscriptInfo] = []
    /// 已用官方 `thread/turns/list` 讀到的 Codex thread 最新 turn。
    public var codexTurns: [String: CodexTurnSummary] = [:]
    /// 未經驗證、只作為建議的「可能被額度中止」Codex thread。
    public var codexSuggestions: Set<String> = []
    private var turnCache: [String: CodexTurnSummary] = [:]
    public var planBook = ResumePlanBook()
    public var lastRefresh: Date?
    public var isRefreshing = false
    public var isProbingClaude = false
    public var claudeStatus: ClaudeSettingsInstaller.Status = .notInstalled
    public var claudeNeedsUpgrade = false
    public var banner: String?
    public var now = Date()

    /// 總開關：額度確認恢復後，自動告知 Codex／Claude Code 繼續作業。
    public var autoContinue: Bool {
        didSet { if live && !dryRun { defaults.set(autoContinue, forKey: Keys.autoContinue) } }
    }
    /// 自動把「被額度中止」的工作階段加入自動繼續清單。
    public var autoDetect: Bool {
        didSet { if live && !dryRun { defaults.set(autoDetect, forKey: Keys.autoDetect) } }
    }
    /// 使用者啟用的 agent（停用者不顯示、不讀取、不參與自動繼續）。
    public var agentPrefs: AgentPreferences {
        didSet { if live && !dryRun { agentPrefs.save(to: defaults) } }
    }
    /// 展開中的次要區塊（自動繼續、工作階段、設定），保存使用者上次的選擇。
    public var expandedSections: Set<String> {
        didSet { if live && !dryRun { defaults.set(Array(expandedSections).sorted(), forKey: Keys.expanded) } }
    }
    /// 測試模式（環境變數 `VIBEMETER_DRY_RUN=1`）：不探測、不自動加入、不送出任何訊息給任何工作階段。
    public let dryRun: Bool
    public let demo: Bool

    let live: Bool
    let paths: VibeMeterPaths
    let collector: UsageCollector
    let transcripts: ClaudeTranscriptStore
    let notifier = Notifier()
    let alertPolicy = AlertPolicy()
    let defaults = UserDefaults.standard
    let claudeBinary: URL?
    private var loopTask: Task<Void, Never>?
    private var engineRunning = false
    private var autoRevision = 0
    private var agentRevisions: [ProviderID: Int] = [:]
    private var deliveriesInFlight: Set<UUID> = []

    struct Authorization {
        let agentRevision: Int
        let autoRevision: Int?
    }

    typealias Preflight = @MainActor (ResumePlan, Bool) async -> SessionPreflight
    typealias StartDelivery = @MainActor (ResumePlan, ResumePlan.Delivery) throws -> Task<Void, Error>
    typealias ReadClaudeAccount = @MainActor () async -> ClaudeAccountIdentity?
    typealias StartClaudeProbe = @MainActor (String) throws -> Task<ProcessResult, Error>

    enum Keys {
        static let fired = "firedAlertKeys"
        static let autoContinue = "autoContinue"
        static let autoDetect = "autoDetect"
        static let handledEvents = "handledBlockEvents"
        static let expanded = "expandedSections"
        static let all = [fired, autoContinue, autoDetect, handledEvents]
    }

    public static let legacyBundleID = "com.leofeng.headroom"

    public init() {
        live = true
        demo = false
        dryRun = ProcessInfo.processInfo.environment["VIBEMETER_DRY_RUN"] == "1"
        paths = .default
        collector = UsageCollector()
        transcripts = ClaudeTranscriptStore()
        claudeBinary = ClaudeLocator.find()
        let migration = !dryRun && Self.migrateLegacyData(paths: paths, defaults: UserDefaults.standard)
        autoContinue = UserDefaults.standard.object(forKey: Keys.autoContinue) as? Bool ?? true
        autoDetect = UserDefaults.standard.object(forKey: Keys.autoDetect) as? Bool ?? true
        agentPrefs = AgentPreferences.load(from: UserDefaults.standard)
        expandedSections = Set(UserDefaults.standard.stringArray(forKey: Keys.expanded) ?? [])
        loadPlans()
        updateClaudeStatus()
        if migration { banner = "已從舊名稱 Headroom 遷移資料與設定" }
        if dryRun { banner = "測試模式：不探測、不送出任何訊息" }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.nextInterval ?? 300
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 預覽用：不讀寫任何使用者資料、不啟動背景工作。
    public init(preview: Void, demo: Bool = false) {
        live = false
        self.demo = demo
        let root = URL(fileURLWithPath: "/nonexistent-vibemeter-preview")
        paths = VibeMeterPaths(root: root)
        transcripts = ClaudeTranscriptStore(projectsDir: root.appendingPathComponent("projects"))
        claudeBinary = nil
        collector = UsageCollector(codexStore: CodexLocalStore(codexHome: root.appendingPathComponent("codex")),
                                   claudeStore: ClaudeBridgeStore(paths: paths),
                                   claudeInstaller: ClaudeSettingsInstaller(settingsURL: root.appendingPathComponent("settings.json"), paths: paths),
                                   codexBinary: nil)
        autoContinue = true
        autoDetect = true
        agentPrefs = AgentPreferences()
        expandedSections = []
        dryRun = demo
    }

    public var snapshots: [UsageSnapshot] { reports.filter { agentPrefs.isEnabled($0.provider) }.compactMap(\.state.snapshot) }
    public var visibleReports: [ProviderReport] { reports.filter { agentPrefs.isEnabled($0.provider) } }
    /// 主畫面顯示的計畫：只顯示啟用的 agent。
    public var visiblePlans: [ResumePlan] { planBook.plans.filter { agentPrefs.isEnabled($0.provider) } }
    public var visibleCodexSessions: [CodexSessionInfo] { agentPrefs.isEnabled(.codex) ? codexSessions : [] }
    public var visibleClaudeSessions: [ClaudeTranscriptInfo] { agentPrefs.isEnabled(.claudeCode) ? claudeSessions : [] }

    public func setAgent(_ p: ProviderID, enabled on: Bool) {
        guard agentPrefs.isEnabled(p) != on else { return }
        if !on { agentRevisions[p, default: 0] += 1 }
        agentPrefs.set(p, enabled: on)
        if on { Task { await refresh() } }
    }
    public var menuBarRemaining: Double? { UsageSummary.tightestRemainingPercent(snapshots, now: now) }

    /// 有等待中的 Codex 計畫且接近重設時間、或剛送出等待確認時，加快刷新。
    var nextInterval: TimeInterval {
        let soon = planBook.active.contains { plan in
            switch plan.state {
            case .waiting: return plan.provider == .codex && (plan.expectedResetAt ?? .distantPast) <= Date().addingTimeInterval(120)
            case .launched: return true
            default: return false
            }
        }
        return soon ? 60 : 300
    }

    // MARK: 遷移

    static func migrateLegacyData(paths: VibeMeterPaths, defaults: UserDefaults) -> Bool {
        let legacyDir = VibeMeterPaths.applicationSupport.appendingPathComponent(VibeMeterPaths.legacyFolderName)
        let standardRoot = VibeMeterPaths.applicationSupport.appendingPathComponent(VibeMeterPaths.folderName)
        guard paths.root == standardRoot else { return false }
        let migrated = (try? LegacyMigration.migrateDataFolder(from: legacyDir, to: paths.root)) ?? false
        let copied = LegacyMigration.migrateDefaults(from: UserDefaults(suiteName: legacyBundleID), to: defaults, keys: Keys.all)
        return migrated || !copied.isEmpty
    }

    /// 舊版設定仍可辨識，重新連接須由使用者在 App 內確認。
    private func updateClaudeStatus() {
        guard agentPrefs.isEnabled(.claudeCode) else { return }
        let installer = collector.claudeInstaller
        claudeStatus = installer.status()
        claudeNeedsUpgrade = installer.usesLegacyBridge()
    }

    // MARK: 刷新與自動繼續引擎

    public func refresh() async {
        guard live, !isRefreshing else { return }
        isRefreshing = true
        let enabled = agentPrefs.enabled
        defer {
            isRefreshing = false
            if !agentPrefs.enabled.isSubset(of: enabled) { Task { await refresh() } }
        }
        updateClaudeStatus()
        reports = await collector.collect(enabled)
        let codexStore = collector.codexStore
        let transcripts = self.transcripts
        codexSessions = enabled.contains(.codex) && agentPrefs.isEnabled(.codex)
            ? await Task.detached { codexStore.recentSessions(limit: 8) }.value : []
        claudeSessions = enabled.contains(.claudeCode) && agentPrefs.isEnabled(.claudeCode)
            ? await Task.detached { transcripts.recentSessions(limit: 8) }.value : []
        now = Date()
        lastRefresh = now
        await inspectCodexThreads()
        guard !dryRun else { return }
        handleAlerts()
        if autoDetect { armBlockedSessions() }
        await runEngine()
    }

    public func tick() { now = Date() }

    var liveCodexSnapshot: UsageSnapshot? {
        snapshots.first { $0.provider == .codex && $0.source == .codexAppServer }
    }

    /// 額度看起來受限時，用官方 `thread/turns/list` 逐一確認最近的 thread 是否真的因額度失敗。
    private func inspectCodexThreads() async {
        guard agentPrefs.isEnabled(.codex), let binary = collector.codexBinary else { codexTurns = [:]; return }
        let candidates = BlockedSessionDetector.codexCandidates(sessions: codexSessions, snapshot: snapshots.first { $0.provider == .codex }, now: now)
        var turns: [String: CodexTurnSummary] = [:]
        for s in candidates {
            guard agentPrefs.isEnabled(.codex) else { break }
            let cacheKey = "\(s.id)|\(Int(s.lastActivity.timeIntervalSince1970))"
            if let cached = turnCache[cacheKey] { turns[s.id] = cached; continue }
            if let turn = try? await CodexAppServerClient(binary: binary).latestTurn(threadID: s.id) {
                turns[s.id] = turn
                turnCache[cacheKey] = turn
            }
        }
        if turnCache.count > 100 { turnCache = [:] }
        codexTurns = turns
        codexSuggestions = BlockedSessionDetector.codexSuggestions(sessions: codexSessions, snapshot: snapshots.first { $0.provider == .codex },
                                                                   latestTurns: turns)
    }

    private func handleAlerts() {
        var fired = Set(defaults.stringArray(forKey: Keys.fired) ?? [])
        for alert in alertPolicy.alerts(for: snapshots, now: now, alreadyFired: fired) {
            let reset = alert.resetsAt.map { "，\(ZhFormat.resetIn($0, now: now))（\(ZhFormat.clock($0))）" } ?? ""
            notifier.post(id: alert.dedupeKey, title: alert.title,
                          body: "已使用 \(ZhFormat.percent(alert.usedPercent))\(reset)。可在 Vibe Meter 把封裝交接指令送給 Codex。")
            fired.insert(alert.dedupeKey)
        }
        defaults.set(Array(fired.suffix(200)), forKey: Keys.fired)
    }

    private func armBlockedSessions() {
        var handled = Set(defaults.stringArray(forKey: Keys.handledEvents) ?? [])
        let blocked = BlockedSessionDetector.codex(sessions: codexSessions, latestTurns: codexTurns, snapshot: liveCodexSnapshot, now: now)
            + BlockedSessionDetector.claude(transcripts: claudeSessions, now: now)
        var added = 0, pending = 0
        for b in blocked where !handled.contains(b.eventKey) && agentPrefs.isEnabled(b.provider) {
            handled.insert(b.eventKey)
            guard !planBook.hasActivePlan(provider: b.provider, sessionID: b.sessionID),
                  let plan = try? ResumePlan(provider: b.provider, sessionID: b.sessionID, sessionTitle: b.title, cwd: b.cwd,
                                             blockedWindow: b.blockedWindow, expectedResetAt: b.resetsAt, origin: .autoDetected,
                                             createdAt: now, codex: b.codex, claude: b.claude) else { continue }
            try? planBook.add(plan)
            if case .needsConfirmation = plan.state { pending += 1 } else { added += 1 }
        }
        defaults.set(Array(handled.suffix(300)), forKey: Keys.handledEvents)
        if added + pending > 0 {
            savePlans()
            let detail = pending > 0 ? "其中 \(pending) 個需要你確認。" : ""
            notifier.post(id: "armed-\(Int(now.timeIntervalSince1970))", title: "偵測到被額度中止的工作階段",
                          body: "共 \(added + pending) 個工作階段。\(detail)請在 Vibe Meter 查看。")
        }
    }

    func authorization(for provider: ProviderID, automatic: Bool) -> Authorization {
        Authorization(agentRevision: agentRevisions[provider, default: 0], autoRevision: automatic ? autoRevision : nil)
    }

    private func isAuthorized(_ auth: Authorization, for provider: ProviderID) -> Bool {
        guard !dryRun, agentPrefs.isEnabled(provider), auth.agentRevision == agentRevisions[provider, default: 0] else {
            return false
        }
        return auth.autoRevision.map { autoContinue && $0 == autoRevision } ?? true
    }

    func runEngine(readClaudeAccount: ReadClaudeAccount? = nil, startClaudeProbe: StartClaudeProbe? = nil) async {
        guard !dryRun, !engineRunning else { return }
        engineRunning = true
        defer { engineRunning = false }

        // Codex：只餵 app-server 即時資料；本機紀錄不會作為恢復依據。
        if let live = liveCodexSnapshot, agentPrefs.isEnabled(.codex) {
            let auth = authorization(for: .codex, automatic: true)
            let effects = planBook.observe(live, now: now, autoContinue: autoContinue).compactMap { id, effect in
                planBook.plan(id).map { ($0, effect) }
            }
            for (plan, effect) in effects { await handle(effect, for: plan, authorization: auth) }
        }

        // Claude Code：只在開啟自動繼續時，以原模型探測。
        if autoContinue, agentPrefs.isEnabled(.claudeCode) {
            let auth = authorization(for: .claudeCode, automatic: true)
            let readAccount = readClaudeAccount ?? claudeBinary.map { binary -> ReadClaudeAccount in
                { await ClaudeAccountIdentity.current(claudeBinary: binary) }
            }
            let startProbe = startClaudeProbe ?? claudeBinary.map { binary -> StartClaudeProbe in
                { model in try ClaudeProbe.start(claudeBinary: binary, model: model, workingDirectory: self.paths.claudeProbeDir) }
            }
            if let readAccount, let startProbe {
                for plan in planBook.active where ProbePolicy.shouldProbe(plan, now: Date()) {
                    await probe(plan, authorization: auth, readAccount: readAccount, startProbe: startProbe)
                }
            }
        }
        checkActivityAfterLaunch()
        savePlans()
    }

    private func probe(_ plan: ResumePlan, authorization auth: Authorization,
                       readAccount: ReadClaudeAccount, startProbe: StartClaudeProbe) async {
        guard isAuthorized(auth, for: .claudeCode), planBook.plan(plan.id) == plan,
              let context = plan.claude, let model = context.model, let limit = context.limitType else { return }
        let account = await readAccount()
        guard isAuthorized(auth, for: .claudeCode), planBook.plan(plan.id) == plan else { return }

        let effects: [ResumeEffect]
        if let account, account == context.account {
            let outcome: ClaudeProbeOutcome
            do {
                // startProbe 會在目前 MainActor turn 啟動程序，沒有先切換執行緒的空窗。
                let process = try startProbe(model)
                let result = try await process.value
                outcome = ClaudeProbe.evaluate(output: result.stdout, observedAt: Date(), expectedModel: model, blockedLimitType: limit)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard planBook.plan(plan.id) == plan else { return }
            let authorized = isAuthorized(auth, for: .claudeCode)
            if live, authorized, case .restored(let snapshot) = outcome, !snapshot.windows.isEmpty {
                try? collector.claudeStore.recordProbeSnapshot(snapshot)
            }
            effects = planBook.apply(.probed(outcome, now: Date(), autoContinue: authorized), to: plan.id)
        } else {
            let reason = account == nil ? "目前無法讀取 Claude Code 登入帳戶" : "Claude Code 登入帳戶與中止時不同"
            effects = planBook.apply(.accountMismatch(reason, now: Date()), to: plan.id)
        }
        guard let current = planBook.plan(plan.id) else { return }
        for effect in effects { await handle(effect, for: current, authorization: auth) }
    }

    private func handle(_ effect: ResumeEffect, for plan: ResumePlan, authorization: Authorization) async {
        guard planBook.plan(plan.id)?.state == plan.state else { return }
        let planID = plan.id
        switch effect {
        case .launch:
            await execute(plan, authorization: authorization)
        case .notifyReady:
            notifier.post(id: "ready-\(planID)", title: "\(plan.provider.displayName) 額度已恢復",
                          body: "「\(plan.sessionTitle)」可以繼續了（自動繼續已關閉，請在 Vibe Meter 按「繼續」）。")
        case .notifyGaveUp:
            notifier.post(id: "gaveup-\(planID)", title: "無法確認 \(plan.provider.displayName) 額度恢復",
                          body: "「\(plan.sessionTitle)」已停止自動嘗試，可在 Vibe Meter 手動重試。")
        case .notifyNeedsConfirmation:
            if case .needsConfirmation(let reason, _) = plan.state {
                notifier.post(id: "confirm-\(planID)", title: "\(plan.provider.displayName) 自動繼續已暫停",
                              body: "「\(plan.sessionTitle)」：\(reason)。不會自動送出，請在 Vibe Meter 確認。")
            }
        }
    }

    private func preflight(_ plan: ResumePlan, automatic: Bool) async -> SessionPreflight {
        switch plan.provider {
        case .codex:
            guard let binary = collector.codexBinary else { return .unknown("找不到 Codex CLI") }
            let store = collector.codexStore
            let id = plan.sessionID
            switch await Task.detached(operation: { store.isSubagent(sessionID: id) }).value {
            case true?: return .changed("子代理 thread 不支援自動繼續")
            case nil: return .unknown("無法確認這個 thread 的本機來源")
            case false?: break
            }
            do {
                let latest = try await CodexAppServerClient(binary: binary).latestTurn(threadID: plan.sessionID)
                return LaunchDecision.codexPreflight(latest: latest, anchorTurnID: plan.codex?.anchorTurnID,
                                                      requireLimitFailure: automatic)
            } catch {
                return .unknown(error.localizedDescription)
            }
        default:
            let transcripts = self.transcripts
            let id = plan.sessionID
            let current = await Task.detached { transcripts.inspect(sessionID: id) }.value
            return LaunchDecision.claudePreflight(current: current, anchorMessageUUID: plan.claude?.anchorMessageUUID)
        }
    }

    func execute(_ plan: ResumePlan, authorization auth: Authorization,
                 checkPreflight: Preflight? = nil, startDelivery: StartDelivery? = nil) async {
        guard case .launching = plan.state, launchStillAuthorized(plan, authorization: auth) else { return }
        let lockHeld = plan.provider == .codex
            ? await SessionActivity.codexThreadLockHeld(sessionID: plan.sessionID, codexHome: collector.codexStore.codexHome)
            : false
        guard launchStillAuthorized(plan, authorization: auth) else { return }
        let automatic = auth.autoRevision != nil
        let check = await (checkPreflight ?? preflight)(plan, automatic)
        guard launchStillAuthorized(plan, authorization: auth) else { return }

        var isDir: ObjCBool = false
        let cwdExists = FileManager.default.fileExists(atPath: plan.cwd, isDirectory: &isDir) && isDir.boolValue
        switch LaunchDecision.decide(plan, lastActivity: lastActivity(of: plan), threadLockHeld: lockHeld, cwdExists: cwdExists,
                                     preflight: check, now: Date()) {
        case .skip(let reason):
            planBook.apply(.launchSkipped(reason, now: Date()), to: plan.id)
        case .deliver(let via):
            guard savePlans() else {
                planBook.apply(.launchFailed("無法儲存送出計畫", now: Date()), to: plan.id)
                return
            }
            deliveriesInFlight.insert(plan.id)
            defer { deliveriesInFlight.remove(plan.id) }
            do {
                let delivery = try (startDelivery ?? self.startDelivery)(plan, via)
                try await delivery.value
                planBook.apply(.delivered(via, now: Date()), to: plan.id)
                if live {
                    notifier.post(id: "sent-\(plan.id)", title: "已告知 \(plan.provider.displayName) 繼續作業",
                                  body: "「\(plan.sessionTitle)」：\(via.label)。")
                }
            } catch {
                planBook.apply(.launchFailed(error.localizedDescription, now: Date()), to: plan.id)
            }
        }
        savePlans()
    }

    private func launchStillAuthorized(_ plan: ResumePlan, authorization auth: Authorization) -> Bool {
        // State equality includes startedAt, so an obsolete preflight cannot authorize a newer attempt.
        guard planBook.plan(plan.id) == plan, !deliveriesInFlight.contains(plan.id) else { return false }
        if isAuthorized(auth, for: plan.provider) {
            return auth.autoRevision == nil || AutoResumeGate.blocker(for: plan) == nil
        }
        if auth.autoRevision != nil, !autoContinue, agentPrefs.isEnabled(plan.provider),
           case .launching(let startedAt) = plan.state {
            planBook.apply(.launchDeferred(confirmedAt: startedAt), to: plan.id)
        } else {
            planBook.apply(.launchSkipped("送出前已撤銷授權", now: Date()), to: plan.id)
        }
        savePlans()
        return false
    }

    private func startDelivery(_ plan: ResumePlan, via: ResumePlan.Delivery) throws -> Task<Void, Error> {
        try ResumeExecutor.start(plan, via: via, codexBinary: collector.codexBinary, claudeBinary: claudeBinary,
                                 launchDir: paths.launchDir)
    }

    private func lastActivity(of plan: ResumePlan) -> Date? {
        switch plan.provider {
        case .codex: return SessionActivity.modificationDate(collector.codexStore.rolloutFile(for: plan.sessionID)?.path)
        default: return SessionActivity.modificationDate(transcripts.transcript(for: plan.sessionID)?.path)
        }
    }

    private func checkActivityAfterLaunch() {
        for plan in planBook.active {
            guard agentPrefs.isEnabled(plan.provider), case .launched(let at) = plan.state, let last = lastActivity(of: plan), last > at.addingTimeInterval(2) else { continue }
            planBook.apply(.activityObserved(now: last), to: plan.id)
        }
    }

    // MARK: 使用者動作

    public func setAutoContinue(_ on: Bool) {
        guard autoContinue != on else { return }
        if !on { autoRevision += 1 }
        autoContinue = on
        banner = on ? "自動繼續已開啟" : "自動繼續已關閉：確認恢復後只通知你"
        if live { Task { await runEngine() } }
    }

    /// 手動加入：仍會建立帳戶／模型／錨點脈絡；資訊不足時進入「待確認」，不會自動送出。
    public func addPlan(provider: ProviderID, sessionID: String, title: String, cwd: String?) {
        guard live, !dryRun, agentPrefs.isEnabled(provider) else { return }
        guard let cwd else { banner = "這個工作階段沒有工作目錄資訊，無法加入自動繼續"; return }
        Task {
            var codexCtx: CodexResumeContext?
            var claudeCtx: ClaudeResumeContext?
            var window: WindowKind = .fiveHour
            var resetsAt: Date?
            switch provider {
            case .codex:
                let live = liveCodexSnapshot
                let fullest = live?.windows.max { $0.usedPercent < $1.usedPercent }
                window = fullest?.kind ?? .fiveHour
                resetsAt = fullest?.resetsAt
                var anchor: CodexTurnSummary?
                if let binary = collector.codexBinary { anchor = try? await CodexAppServerClient(binary: binary).latestTurn(threadID: sessionID) }
                codexCtx = CodexResumeContext(accountID: nil, anchorTurnID: anchor?.id,
                                              verifiedLimitFailure: anchor?.isUsageLimitFailure ?? false)
            default:
                let transcripts = self.transcripts
                let info = await Task.detached { transcripts.inspect(sessionID: sessionID) }.value
                window = info?.limitHit?.window ?? .fiveHour
                resetsAt = info?.limitHit?.resetsAt
                claudeCtx = ClaudeResumeContext(model: info?.lastModel, limitType: info?.limitHit?.limitType,
                                                overageStatus: info?.limitHit?.overageStatus, account: nil,
                                                anchorMessageUUID: info?.limitHit?.messageUUID)
            }
            guard agentPrefs.isEnabled(provider) else { return }
            do {
                let plan = try ResumePlan(provider: provider, sessionID: sessionID, sessionTitle: title, cwd: cwd,
                                          blockedWindow: window, expectedResetAt: resetsAt, codex: codexCtx, claude: claudeCtx)
                try planBook.add(plan)
                savePlans()
                if case .needsConfirmation(let reason, _) = plan.state {
                    banner = "已加入，但\(reason)；不會自動送出"
                } else {
                    banner = "已加入自動繼續：\(title)"
                }
            } catch {
                banner = error.localizedDescription
            }
        }
    }

    public func canCancel(_ id: UUID) -> Bool { !deliveriesInFlight.contains(id) }

    public func cancelPlan(_ id: UUID) {
        guard canCancel(id) else { return }
        planBook.apply(.userCancel(now: Date()), to: id)
        savePlans()
    }

    public func launchNow(_ id: UUID) {
        guard live, !dryRun, let existing = planBook.plan(id), agentPrefs.isEnabled(existing.provider) else { return }
        let effects = planBook.apply(.userLaunch(now: Date()), to: id)
        guard effects.contains(.launch), let plan = planBook.plan(id) else { return }
        let auth = authorization(for: plan.provider, automatic: false)
        Task { await execute(plan, authorization: auth) }
    }

    public func clearFinished() {
        planBook = ResumePlanBook(plans: planBook.plans.filter { !$0.state.isFinished })
        savePlans()
    }

    /// 使用者手動查詢 Claude 用量（Haiku 極小請求；只用於顯示，不作為恢復依據）。
    public func probeClaudeNow() {
        guard live, !dryRun, agentPrefs.isEnabled(.claudeCode), !isProbingClaude else { return }
        guard let claude = claudeBinary else { banner = "找不到 Claude Code CLI"; return }
        let process: Task<ProcessResult, Error>
        do {
            process = try ClaudeProbe.start(claudeBinary: claude, model: ClaudeProbe.displayModel, workingDirectory: paths.claudeProbeDir)
        } catch {
            banner = "查詢失敗：\(error.localizedDescription)"
            return
        }
        isProbingClaude = true
        Task {
            let result = await process.result
            isProbingClaude = false
            guard agentPrefs.isEnabled(.claudeCode) else { return }
            let outcome: ClaudeProbeOutcome
            switch result {
            case .success(let output): outcome = ClaudeProbe.displaySnapshot(output: output.stdout, observedAt: Date())
            case .failure(let error): outcome = .failed(error.localizedDescription)
            }
            switch outcome {
            case .restored(let snap):
                try? collector.claudeStore.recordProbeSnapshot(snap)
                banner = "已更新 Claude Code 用量"
                await refresh()
            case .stillLimited(let reset):
                banner = "Claude Code 目前仍在額度限制中" + (reset.map { "，\(ZhFormat.resetIn($0, now: Date()))" } ?? "")
            case .unconfirmed(let reason), .unsafe(let reason), .failed(let reason):
                banner = "查詢失敗：\(reason)"
            }
        }
    }

    // MARK: 交接

    public func copy(_ text: String, message: String) {
        guard !demo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        banner = message
    }

    public func copyPackPrompt(provider: ProviderID, sessionID: String?, cwd: String?) {
        copy(HandoffPromptBuilder().packPrompt(agent: provider, sessionID: sessionID, cwd: cwd),
             message: "已複製封裝指令" + (sessionID.map { "（工作階段 \($0.prefix(8))…）" } ?? "，請貼到正在工作的 agent"))
    }

    public func copyTakeoverCommand(cwd: String) {
        copy(HandoffPromptBuilder().takeoverCommand(cwd: cwd, codexBinary: collector.codexBinary?.path ?? "codex"),
             message: "已複製 Codex 接手指令")
    }

    /// 透過官方 `codex queue` 把封裝指令送進「指定」的 Codex 工作階段。先顯示名稱、資料夾與 id 讓使用者確認。
    public func sendPackToCodex(_ session: CodexSessionInfo) {
        guard live, !dryRun, agentPrefs.isEnabled(.codex) else { return }
        guard let codex = collector.codexBinary else { banner = "找不到 Codex CLI"; return }
        let alert = NSAlert()
        alert.messageText = "把封裝指令送給這個 Codex 工作階段？"
        alert.informativeText = """
        名稱：\(session.displayTitle)
        資料夾：\(session.cwd ?? "未知")
        Session：\(session.id)
        最後活動：\(ZhFormat.ago(session.lastActivity, now: Date()))

        會以 codex queue 排入這個工作階段，請它停止新修改並寫好 HANDOFF.md。
        """
        alert.addButton(withTitle: "送出")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = HandoffPromptBuilder().packPrompt(agent: .codex, sessionID: session.id, cwd: session.cwd)
        let auth = authorization(for: .codex, automatic: false)
        let store = collector.codexStore
        Task {
            let isSubagent = await Task.detached { store.isSubagent(sessionID: session.id) }.value
            guard isAuthorized(auth, for: .codex) else { return }
            guard isSubagent == false else {
                banner = "無法確認這個 Codex 工作階段可接收指令"
                return
            }
            do {
                let delivery = try ProcessRunner.start(codex, arguments: ["queue", "--thread", session.id, "--message", text], timeout: 30)
                let r = try await delivery.value
                banner = r.status == 0 ? "已排入 Codex 工作階段「\(session.displayTitle)」" : "送出失敗：\(r.stderr.prefix(120))"
            } catch {
                banner = "送出失敗：\(error.localizedDescription)"
            }
        }
    }

    // MARK: Claude Code 連接

    func installBridgeBinary() throws -> URL {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: VibeMeterPaths.bridgeName) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "找不到內附的 \(VibeMeterPaths.bridgeName)，請使用 scripts/build-app.sh 建置的 App"])
        }
        try paths.ensure(paths.binDir)
        let dest = paths.installedBridge
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: bundled, to: dest)
        return dest
    }

    public func connectClaude() {
        guard live, !dryRun else { return }
        let alert = NSAlert()
        alert.messageText = "連接 Claude Code 狀態列？"
        alert.informativeText = """
        Vibe Meter 會修改 \(collector.claudeInstaller.settingsURL.path)：
        • statusLine：Claude Code 每次回應時把官方額度資料交給 Vibe Meter（原本的狀態列會保留並照常顯示）
        • StopFailure hook（rate_limit）：記錄哪個工作階段因額度中止

        修改前會先備份，可隨時「中斷連接」還原。
        """
        alert.addButton(withTitle: "連接")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let backup = try collector.claudeInstaller.install(bridge: try installBridgeBinary())
            banner = "已連接 Claude Code" + (backup.map { "（備份：\($0.lastPathComponent)）" } ?? "")
        } catch {
            banner = "連接失敗：\(error.localizedDescription)"
        }
        updateClaudeStatus()
        Task { await refresh() }
    }

    public func disconnectClaude() {
        guard live, !dryRun else { return }
        let alert = NSAlert()
        alert.messageText = "中斷 Claude Code 狀態列連接？"
        alert.informativeText = "Vibe Meter 會先備份 Claude Code 設定，再移除自己的連接並還原原本的狀態列。"
        alert.addButton(withTitle: "中斷連接")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try collector.claudeInstaller.uninstall()
            banner = "已中斷連接並還原 Claude Code 設定"
        } catch {
            banner = "中斷連接失敗：\(error.localizedDescription)"
        }
        updateClaudeStatus()
        Task { await refresh() }
    }

    // MARK: 持久化

    private func loadPlans() {
        guard let data = try? Data(contentsOf: paths.resumePlans),
              let book = try? VibeMeterJSON.decoder.decode(ResumePlanBook.self, from: data) else { return }
        let plans = book.plans.map { saved in
            var plan = saved
            switch plan.state {
            case .launching:
                plan.state = .needsConfirmation(reason: "上次的送出結果無法確認", at: Date())
            case .waiting, .ready:
                if let reason = AutoResumeGate.blocker(for: plan) {
                    plan.state = .needsConfirmation(reason: reason, at: Date())
                }
            default: break
            }
            return plan
        }
        planBook = ResumePlanBook(plans: plans)
    }

    @discardableResult
    func savePlans() -> Bool {
        guard live, !dryRun else { return true }
        planBook.prune()
        do {
            let data = try VibeMeterJSON.encoder.encode(planBook)
            try VibeMeterJSON.writeAtomically(data, to: paths.resumePlans)
            return true
        } catch {
            return false
        }
    }
}
