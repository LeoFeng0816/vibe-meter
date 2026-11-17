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
    private var codexInspectionOffset = 0
    private var codexActivityOffset = 0
    private var codexInspectionRevision = 0
    private var turnCache: [String: (turn: CodexTurnSummary, readAt: Date)] = [:]
    var codexObservations = CodexQuotaObservations()
    public private(set) var codexContinuation = CodexContinuationSettings()
    var scopeRequestInProgress = false
    public var planBook = ResumePlanBook()
    public var lastRefresh: Date?
    public var isRefreshing = false
    public var claudeStatus: ClaudeSettingsInstaller.Status = .notInstalled
    public var claudeNeedsUpgrade = false
    public var banner: String?
    public var now = Date()

    /// Codex 自動續作總開關。
    public private(set) var autoContinue: Bool
    /// 自動把「被額度中止」的工作階段加入自動繼續清單。
    public var autoDetect: Bool {
        didSet { if live && !dryRun { defaults.set(autoDetect, forKey: Keys.autoDetect) } }
    }
    public private(set) var agentPrefs: AgentPreferences
    /// 展開中的次要區塊（自動繼續、工作階段、設定），保存使用者上次的選擇。
    public var expandedSections: Set<String> {
        didSet { if live && !dryRun { defaults.set(Array(expandedSections).sorted(), forKey: Keys.expanded) } }
    }
    /// 測試模式（環境變數 `VIBEMETER_DRY_RUN=1`）：不探測、不自動加入、不送出任何訊息給任何工作階段。
    public let dryRun: Bool
    public let demo: Bool

    // MARK: v0.1.1 設定與狀態
    /// 介面語言（繁體中文／簡體中文／英文）。
    public var language: AppLanguage {
        didSet {
            L10n.current = language
            if persists { language.save(to: defaults) }
        }
    }
    /// 狀態列顯示哪個 agent 的哪個週期。
    public var menuBarSelection: MenuBarSelection {
        didSet { if persists { menuBarSelection.save(to: defaults) } }
    }
    public var alertSettings: AlertSettings {
        didSet { if persists { alertSettings.save(to: defaults) } }
    }
    /// Claude Code 用量自動更新（每 15 分鐘）。
    public var claudeAutoRefresh: Bool {
        didSet { if persists { defaults.set(claudeAutoRefresh, forKey: Keys.claudeAutoRefresh) } }
    }
    public var keepAwake: KeepAwakeSettings {
        didSet { if persists { keepAwake.save(to: defaults) } }
    }
    public var keepAwakeReason: KeepAwakeReason = .off
    public var agentActivity: AgentActivity = .idle
    public var keepAwakeError: String?
    public var updateSettings: UpdateSettings {
        didSet {
            if oldValue != updateSettings { updateRevision += 1 }
            if persists { updateSettings.save(to: defaults) }
            if oldValue != updateSettings { cancelAutomaticInstall?() }
        }
    }
    public var startAutomaticInstall: ((ReleaseInfo, @escaping () -> Bool) -> Bool)?
    public var cancelAutomaticInstall: (() -> Void)?
    public var updateInstallStatus: String?
    public var updateInstallCommitted = false
    public var updateResult: UpdateCheckResult?
    public var lastUpdateCheck: Date?
    public var isCheckingUpdate = false
    public var updateDownload: UpdateDownloadState = .idle
    public var notificationStatus: NotificationStatus = .unknown
    var keepAwakeController: KeepAwakeController
    var keepAwakeTask: Task<Void, Never>?
    var keepAwakeRevision = 0
    var codexActivityTracker = CodexActivityTracker()
    var claudeBridgeTask: Task<Void, Never>?
    var claudeBridgeWatcher: BridgeDirectoryWatcher?
    var antigravityBridgeWatcher: BridgeDirectoryWatcher?
    var backgroundStopped = false
    var updateTask: Task<Void, Never>?
    var updateRevision = 0
    var firedAlerts: Set<String> = []
    var pendingAlerts: Set<String> = []

    // MARK: Codex 即時額度輪詢（只呼叫官方唯讀 account/rateLimits/read）
    /// 每 30 秒查詢 Codex 官方額度。關閉時仍保留一般刷新（約 5 分鐘）。
    public var codexLivePolling: Bool {
        didSet {
            guard oldValue != codexLivePolling else { return }
            if persists { defaults.set(codexLivePolling, forKey: Keys.codexLivePolling) }
            restartCodexPolling()
        }
    }
    public var codexLiveStatus: CodexLiveStatus = .idle
    var codexPollTask: Task<Void, Never>?
    var codexPollInFlight: (id: UUID, generation: Int, task: Task<Void, Never>)?
    var codexPollOutcomeRevision = 0
    var lastWindowOpenUptime: TimeInterval?
    var manualReadyInFlight: Set<UUID> = []

    // MARK: 一般額度重設後 30 秒嘗試一次（使用者明確選擇）
    /// 官方沒有模型專屬額度桶時，以唯一一般 `codex` 桶的用盡觀察與重設時間，於重設＋30 秒嘗試一次。
    public private(set) var codexTimedResume: Bool
    var timedRunInFlight = false
    var timedTimerID: UUID?
    var timedCheckTask: Task<Void, Never>?
    var timedCheckPending = false
    var timedRetryAfter: [UUID: Date] = [:]
    var pendingTimedDeferrals: [UUID: Date] = [:]
    /// 測試替身：取代牆上時鐘。
    var timedClock: @MainActor () -> Date = { Date() }
    var timedTimerTask: Task<Void, Never>?
    var schedulesTimedTimer = false
    var timedDispatchNotes: [UUID: String] = [:]
    var codexPollGeneration = 0
    var codexPollFailures = 0
    public internal(set) var lastCodexPollAt: Date?
    var systemAsleep = false
    var refreshPending = false
    /// 測試替身：取代實際啟動 `codex app-server`。
    var codexRateReader: CodexRateReader?
    /// 測試替身：取代 Task.sleep，用來驗證輪詢節奏。
    var codexPollSleep: (@Sendable (Duration) async throws -> Void)?
    var networkAvailable: @MainActor () -> Bool = { true }
    var reachability: NetworkReachability?
    var sleepObservers: [NSObjectProtocol] = []

    /// 只有正式執行（非預覽、非示範、非測試模式）才寫入 UserDefaults 與檔案。
    var persists: Bool { live && !dryRun }

    let live: Bool
    let paths: VibeMeterPaths
    let collector: UsageCollector
    let transcripts: ClaudeTranscriptStore
    let notifier = Notifier()
    let defaults: UserDefaults
    let claudeBinary: URL?
    private var loopTask: Task<Void, Never>?
    private var engineRunning = false
    private var enginePending = false
    private let canScheduleBackgroundWork: Bool
    private var autoRevision = 0
    private var sharedPolicy: CodexDispatchPolicy?
    private var dispatchPolicyWatcher: BridgeDirectoryWatcher?
    private var agentRevisions: [ProviderID: Int] = [:]
    private var deliveriesInFlight: Set<UUID> = []

    struct Authorization {
        let agentRevision: Int
        let autoRevision: Int?
        let sharedRevision: UUID?
        let sharedAgentRevision: UUID?
    }

    private var dispatchPolicyStore: CodexDispatchPolicyStore { CodexDispatchPolicyStore(directory: paths.root) }

    private enum DispatchRejection: Error {
        case revoked, cancelled(Date), reservation, claim
    }

    typealias Preflight = @MainActor (ResumePlan, Bool) async -> SessionPreflight
    typealias StartDelivery = @MainActor (ResumePlan, ResumePlan.Delivery) throws -> Task<Void, Error>

    enum Keys {
        static let fired = "firedAlertKeys"
        static let autoContinue = "autoContinue"
        static let autoDetect = "autoDetect"
        static let handledEvents = "handledBlockEvents"
        static let expanded = "expandedSections"
        static let claudeAutoRefresh = "claudeAutoRefresh"
        static let codexContinuation = "codexContinuationSettingsV1"
        static let codexObservations = "codexQuotaObservationsV1"
        static let codexLivePolling = "codexLivePolling30s"
        static let codexTimedResume = "codexTimedResumeGeneralBucketV1"
        static let codexTimedDispatches = "codexTimedDispatchesV1"
        static let all = [fired, autoContinue, autoDetect, handledEvents]
    }

    public static let legacyBundleID = "com.leofeng.headroom"

    public convenience init() {
        self.init(dryRun: ProcessInfo.processInfo.environment["VIBEMETER_DRY_RUN"] == "1",
                  defaults: .standard, paths: .default)
    }

    /// - Parameters:
    ///   - startBackgroundWork: 測試傳 false，不啟動任何計時器、檔案監看或網路檢查。
    ///   - codexBinary: 測試可傳 `.some(nil)` 避免啟動真正的 Codex CLI。
    init(dryRun: Bool, defaults: UserDefaults, paths: VibeMeterPaths,
         claudeSettingsURL: URL = ClaudeSettingsInstaller.defaultSettingsURL,
         startBackgroundWork: Bool = true, codexBinary: URL?? = .none, codexHome: URL? = nil) {
        live = true
        canScheduleBackgroundWork = startBackgroundWork
        demo = false
        self.dryRun = dryRun
        self.defaults = defaults
        self.paths = paths
        collector = UsageCollector(codexStore: codexHome.map { CodexLocalStore(codexHome: $0) } ?? CodexLocalStore(),
                                   claudeStore: ClaudeBridgeStore(paths: paths),
                                   claudeInstaller: ClaudeSettingsInstaller(settingsURL: claudeSettingsURL, paths: paths),
                                   codexBinary: dryRun ? nil : (codexBinary ?? CodexLocator.find()))
        transcripts = ClaudeTranscriptStore()
        claudeBinary = dryRun ? nil : ClaudeLocator.find()
        let migration = !dryRun && Self.migrateLegacyData(paths: paths, defaults: defaults)
        autoContinue = defaults.object(forKey: Keys.autoContinue) as? Bool ?? true
        autoDetect = defaults.object(forKey: Keys.autoDetect) as? Bool ?? true
        agentPrefs = AgentPreferences.load(from: defaults)
        expandedSections = Set(defaults.stringArray(forKey: Keys.expanded) ?? [])
        language = AppLanguage.load(from: defaults)
        menuBarSelection = MenuBarSelection.load(from: defaults)
        alertSettings = AlertSettings.load(from: defaults)
        claudeAutoRefresh = defaults.object(forKey: Keys.claudeAutoRefresh) as? Bool ?? true
        codexLivePolling = defaults.object(forKey: Keys.codexLivePolling) as? Bool ?? true
        codexTimedResume = defaults.object(forKey: Keys.codexTimedResume) as? Bool ?? true
        keepAwake = dryRun ? KeepAwakeSettings() : KeepAwakeSettings.load(from: defaults, now: Date())
        updateSettings = dryRun ? UpdateSettings(autoCheck: false) : UpdateSettings.load(from: defaults)
        keepAwakeController = KeepAwakeController(provider: dryRun ? NoopPowerAssertions() : IOKitPowerAssertions())
        L10n.current = language
        firedAlerts = Set(defaults.stringArray(forKey: Keys.fired) ?? [])
        lastUpdateCheck = dryRun ? nil : defaults.object(forKey: UpdateSettings.lastCheckKey) as? Date
        if dryRun {
            banner = "測試模式：不探測、不送出任何訊息"
            return
        }
        if let data = defaults.data(forKey: Keys.codexContinuation),
           let saved = try? VibeMeterJSON.decoder.decode(CodexContinuationSettings.self, from: data) {
            codexContinuation = saved
        }
        if let data = defaults.data(forKey: Keys.codexObservations),
           let saved = try? VibeMeterJSON.decoder.decode(CodexQuotaObservations.self, from: data) {
            codexObservations = saved
        }
        let fallback = CodexDispatchPolicy(autoContinue: autoContinue, codexEnabled: agentPrefs.isEnabled(.codex),
                                           timedResume: codexTimedResume, continuation: codexContinuation)
        do { adoptDispatchPolicy(try dispatchPolicyStore.initialize(fallback)) }
        catch { showDispatchPolicyError() }
        loadPlans()
        updateClaudeStatus()
        if migration { banner = "已從舊名稱 Headroom 遷移資料與設定" }
        guard startBackgroundWork else { return }
        dispatchPolicyWatcher = BridgeDirectoryWatcher(directory: paths.root) { [weak self] in
            self?.refreshDispatchPolicy()
        }
        schedulesTimedTimer = true
        startNetworkMonitor()
        observeSleepAndWake()
        startCodexPolling()
        startClaudeBridgeRefresh()
        startAntigravityBridgeRefresh()
        startKeepAwakeLoop()
        observeTermination()
        scheduleUpdateChecks()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.nextInterval ?? 300
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    func stopBackgroundWork() {
        backgroundStopped = true
        loopTask?.cancel()
        claudeBridgeTask?.cancel()
        claudeBridgeWatcher?.stop()
        antigravityBridgeWatcher?.stop()
        dispatchPolicyWatcher?.stop()
        keepAwakeTask?.cancel()
        updateTask?.cancel()
        cancelCodexPolling()
        reachability?.stop()
        cancelAutomaticInstall?()
        keepAwakeController.releaseAll()
    }

    /// 預覽用：不讀寫任何使用者資料、不啟動背景工作。
    public init(preview: Void, demo: Bool = false, fixturePaths: VibeMeterPaths? = nil) {
        live = false
        canScheduleBackgroundWork = false
        defaults = .standard
        self.demo = demo
        let root = fixturePaths?.root ?? URL(fileURLWithPath: "/nonexistent-vibemeter-preview")
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
        language = L10n.current
        menuBarSelection = .tightest
        alertSettings = AlertSettings()
        claudeAutoRefresh = true
        codexLivePolling = true
        codexTimedResume = true
        keepAwake = KeepAwakeSettings()
        updateSettings = UpdateSettings()
        // 預覽／示範不建立真正的電源 assertion。
        keepAwakeController = KeepAwakeController(provider: NoopPowerAssertions())
    }

    public var snapshots: [UsageSnapshot] { reports.filter { agentPrefs.isEnabled($0.provider) }.compactMap(\.state.snapshot) }
    public var visibleReports: [ProviderReport] {
        ProviderID.allCases.filter { agentPrefs.isEnabled($0) }.compactMap { provider in
            reports.first { $0.provider == provider }
        }
    }
    /// 主畫面顯示的計畫：只顯示啟用的 agent。
    public var visiblePlans: [ResumePlan] { planBook.plans.filter { agentPrefs.isEnabled($0.provider) } }
    public var visibleCodexSessions: [CodexSessionInfo] { agentPrefs.isEnabled(.codex) ? codexSessions : [] }
    public var visibleClaudeSessions: [ClaudeTranscriptInfo] { agentPrefs.isEnabled(.claudeCode) ? claudeSessions : [] }

    public func setAgent(_ p: ProviderID, enabled on: Bool) {
        if p == .codex {
            changeDispatchPolicy { $0.codexEnabled = on }
            return
        }
        guard agentPrefs.isEnabled(p) != on else { return }
        if !on { agentRevisions[p, default: 0] += 1 }
        agentPrefs.set(p, enabled: on)
        if persists { agentPrefs.save(to: defaults) }
        if p == .claudeCode { startClaudeBridgeRefresh() }
        if p == .antigravity { startAntigravityBridgeRefresh() }
        if on { Task { await refresh() } }
    }
    public var menuBarRemaining: Double? { UsageSummary.tightestRemainingPercent(snapshots, now: now) }
    public var menuBarDisplay: MenuBarDisplay {
        MenuBarDisplay.resolve(menuBarSelection, reports: reports, enabled: agentPrefs.enabled, now: now)
    }
    public var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1-dev"
    }

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
    func updateClaudeStatus() {
        guard agentPrefs.isEnabled(.claudeCode) else { return }
        let installer = collector.claudeInstaller
        claudeStatus = installer.status()
        claudeNeedsUpgrade = installer.usesLegacyBridge()
    }

    // MARK: 刷新與自動繼續引擎

    /// 完整刷新（工作階段掃描、提醒、續作引擎）。同時只有一個；執行中再要求只會在結束後補跑一次。
    public func refresh() async {
        guard live, !backgroundStopped else { return }
        refreshDispatchPolicy()
        guard !isRefreshing else { refreshPending = true; return }
        isRefreshing = true
        let enabled = agentPrefs.enabled
        defer {
            isRefreshing = false
            if refreshPending || !agentPrefs.enabled.isSubset(of: enabled) {
                refreshPending = false
                Task { await refresh() }
            }
        }
        if enabled.contains(.claudeCode) {
            refreshClaudeBridge()
        }
        if enabled.contains(.antigravity) { refreshAntigravityBridge() }
        // Codex 額度與 30 秒輪詢共用同一個 single-flight 查詢，不另外啟動 app-server。
        let separate: Set<ProviderID> = [.claudeCode, .antigravity, .codex]
        let collected = await collector.collect(enabled.subtracting(separate))
        guard !backgroundStopped else { return }
        reports = reports.filter { separate.contains($0.provider) } + collected
        if enabled.contains(.codex) {
            if dryRun { replaceReport(await collector.codexReport()) } else { await requestCodexPoll(reason: .refresh) }
        }
        guard !backgroundStopped else { return }
        now = Date()
        lastRefresh = now
        guard !dryRun else { return }
        let codexStore = collector.codexStore
        let transcripts = self.transcripts
        let plannedCodex = Set(planBook.active.filter { $0.provider == .codex }.map(\.sessionID))
        let currentCodexSessions = enabled.contains(.codex) && agentPrefs.isEnabled(.codex)
            ? await Task.detached { codexStore.recentSessions(limit: 16, priority: plannedCodex) }.value : []
        codexSessions = agentPrefs.isEnabled(.codex) ? currentCodexSessions : []
        claudeSessions = enabled.contains(.claudeCode) && agentPrefs.isEnabled(.claudeCode)
            ? await Task.detached { transcripts.recentSessions(limit: 8) }.value : []
        now = Date()
        lastRefresh = now
        guard !dryRun, !backgroundStopped else { return }
        observeCodexQuota()
        await inspectCodexThreads()
        guard !backgroundStopped else { return }
        handleAlerts()
        if autoDetect { await armBlockedSessions() }
        await runEngine()
    }

    public func tick() { now = Date() }

    /// 最近一次 Codex 官方回應（可能已過期），只用於說明撤銷原因。
    var liveCodexSnapshotIncludingStale: UsageSnapshot? {
        reports.first { $0.provider == .codex }?.state.snapshot.flatMap { $0.source == .codexAppServer ? $0 : nil }
    }

    /// 目前可作為即時依據的 Codex 官方資料。查詢失敗後保留的舊值、過期資料都不算。
    var liveCodexSnapshot: UsageSnapshot? {
        snapshots.first { $0.provider == .codex && $0.source == .codexAppServer && !$0.isStale(now: timedClock()) }
    }

    var shouldCheckCodexRecoveryOnPoll: Bool { canScheduleBackgroundWork }

    func codexWaitingReason(_ plan: ResumePlan) -> String? {
        guard let snapshot = liveCodexSnapshot else { return tr("等待新的 Codex 官方用量回報") }
        if snapshot.spendControlReached == true { return tr("Codex 回報已達花費上限") }
        if snapshot.usageAllowed == nil { return tr("Codex 未提供一般用量許可，暫不送出") }
        if snapshot.usageAllowed == false { return tr("Codex 尚未允許一般用量") }
        if let model = plan.codex?.modelAtBlock {
            guard let bucket = snapshot.quotaBucket(forModel: model) else { return tr("官方額度資料無法唯一對應這個模型的額度桶") }
            if bucket.spendControlReached == true { return tr("Codex 回報已達花費上限") }
        }
        return nil
    }

    func observeCodexQuota(_ updated: UsageSnapshot? = nil) {
        guard persists, !backgroundStopped, let snapshot = updated ?? liveCodexSnapshot else { return }
        codexObservations.observe(snapshot, now: timedClock())
        if let data = try? VibeMeterJSON.encoder.encode(codexObservations) {
            defaults.set(data, forKey: Keys.codexObservations)
        }
        revokeInvalidCodexPlans()
    }

    func inspectCodexThreads(readTurn: (@MainActor (String) async -> CodexTurnSummary?)? = nil) async {
        guard !dryRun, agentPrefs.isEnabled(.codex), readTurn != nil || collector.codexBinary != nil else {
            codexTurns = [:]
            return
        }
        codexInspectionRevision += 1
        let revision = codexInspectionRevision
        let agentRevision = agentRevisions[.codex, default: 0]
        let planned = Set(planBook.active.filter { $0.provider == .codex }.map(\.sessionID))
        let candidates = BlockedSessionDetector.codexCandidates(sessions: codexSessions, now: now, priority: planned, offset: codexInspectionOffset)
        codexInspectionOffset = (codexInspectionOffset + 1) % 1_000_000
        var turns: [String: CodexTurnSummary] = [:]
        for session in candidates {
            guard !backgroundStopped, agentPrefs.isEnabled(.codex) else { break }
            let key = "\(session.id)|\(session.lastActivity.timeIntervalSince1970)"
            if let cached = turnCache[key], Date().timeIntervalSince(cached.readAt) < 60 {
                turns[session.id] = cached.turn
                continue
            }
            let latest: CodexTurnSummary?
            if let readTurn {
                latest = await readTurn(session.id)
            } else if let binary = collector.codexBinary {
                latest = try? await CodexAppServerClient(binary: binary, timeout: .seconds(5)).latestTurn(threadID: session.id)
            } else {
                latest = nil
            }
            guard revision == codexInspectionRevision, agentRevision == agentRevisions[.codex, default: 0],
                  !backgroundStopped, agentPrefs.isEnabled(.codex) else { return }
            if let latest {
                turns[session.id] = latest
                if latest.isTerminal { turnCache[key] = (latest, Date()) }
            }
        }
        if turnCache.count > 100 { turnCache = [:] }
        codexTurns = turns
        codexSuggestions = BlockedSessionDetector.codexSuggestions(sessions: codexSessions,
            snapshot: snapshots.first { $0.provider == .codex }, latestTurns: turns)
    }

    func handleAlerts() {
        guard persists, !backgroundStopped else { return }
        Task { await deliverAlerts() }
    }

    func deliverAlerts(using notifier: Notifier? = nil, now: Date = Date()) async {
        guard !dryRun, !backgroundStopped, live || notifier != nil else { return }
        let notifier = notifier ?? self.notifier
        let policy = AlertPolicy(settings: alertSettings)
        for alert in policy.evaluate(snapshots, enabled: agentPrefs.enabled, now: now, fired: &firedAlerts) {
            let key = alert.dedupeKey
            guard pendingAlerts.insert(key).inserted else { continue }
            defer { pendingAlerts.remove(key) }
            let reset = alert.resetsAt.map { tr("{0}（{1}）", ZhFormat.resetIn($0, now: now), ZhFormat.clock($0)) } ?? tr("來源未提供重設時間")
            let sent = await notifier.post(id: key, title: alert.title,
                                          body: tr("剩餘 {0}，低於你設定的 {1}。{2}。可在 Vibe Meter 複製封裝交接指令給 Codex。",
                                                   ZhFormat.percent(alert.remainingPercent), ZhFormat.percent(alert.threshold), reset)) {
                guard !self.backgroundStopped, self.alertSettings == policy.settings else { return false }
                return policy.evaluate(self.snapshots, enabled: self.agentPrefs.enabled, now: max(now, self.now),
                                       fired: &self.firedAlerts).contains { $0.dedupeKey == key }
            }
            if sent { firedAlerts.insert(key) }
        }
        if persists, !backgroundStopped { defaults.set(Array(Array(firedAlerts).sorted().suffix(300)), forKey: Keys.fired) }
    }

    private func postNotice(id: String, title: String, body: String) {
        guard persists, !backgroundStopped else { return }
        Task { _ = await notifier.post(id: id, title: title, body: body) { !self.backgroundStopped } }
    }

    /// 為每個官方確認的額度中止 turn 收集證據：turn 模型（rollout `turn_context`）與 thread 建立帳戶（僅供參考）。
    /// 官方資料沒有中止當下的帳戶，因此證據一律不足、計畫保持待確認（見 CodexBlockEvidence）。
    func codexEvidence(for turns: [String: CodexTurnSummary]) async -> [String: CodexBlockEvidence] {
        let store = collector.codexStore
        let live = liveCodexSnapshot?.accountID
        var out: [String: CodexBlockEvidence] = [:]
        for (id, turn) in turns where turn.isUsageLimitFailure {
            guard !backgroundStopped, agentPrefs.isEnabled(.codex) else { break }
            let model = await Task.detached { store.turnModel(sessionID: id, turnID: turn.id) }.value
            out[id] = CodexBlockEvidence(turnModel: model, creatorAccountHash: nil, liveAccountID: live)
        }
        return out
    }

    private func armBlockedSessions() async {
        var handled = Set(defaults.stringArray(forKey: Keys.handledEvents) ?? [])
        let detectedTurns = codexTurns
        let revision = codexInspectionRevision
        let evidence = await codexEvidence(for: detectedTurns)
        guard persists, !backgroundStopped, autoDetect, revision == codexInspectionRevision,
              agentPrefs.isEnabled(.codex) else { return }
        let blocked = BlockedSessionDetector.codex(sessions: codexSessions, latestTurns: detectedTurns, snapshot: liveCodexSnapshot,
                                                   now: timedClock(), evidence: evidence, observations: codexObservations,
                                                   continuation: codexContinuation,
                                                   timedResume: codexTimedResume, timedSessionBlocked: timedSessionBlockedCheck())
        var added = 0, pending = 0, rebound = false
        for item in blocked where agentPrefs.isEnabled(item.provider) {
            var existing = planBook.active.first { $0.provider == item.provider && $0.sessionID == item.sessionID.lowercased() }
            if let previous = existing, previous.codex?.anchorTurnID != item.evidenceID {
                // Keep an unresolved dispatch visible; a later, separate failed turn can be evaluated on its own.
                guard !deliveriesInFlight.contains(previous.id),
                      let newer = item.codex?.anchorCompletedAt,
                      newer >= (previous.codex?.anchorCompletedAt ?? previous.createdAt),
                      previous.deliveryStartedAt.map({ newer >= $0 }) ?? true else { continue }
                if case .launching = previous.state { continue }
                planBook.apply(.supersededByNewTurn(now: now), to: previous.id)
                existing = nil
                rebound = true
            }
            guard existing != nil || !handled.contains(item.eventKey),
                  let plan = try? ResumePlan(id: existing?.id ?? UUID(), provider: item.provider, sessionID: item.sessionID,
                                             sessionTitle: item.title, cwd: item.cwd, blockedWindow: item.blockedWindow,
                                             expectedResetAt: item.resetsAt, origin: .autoDetected, createdAt: now,
                                             codex: item.codex, claude: item.claude) else { continue }
            if existing != nil {
                if planBook.bindPendingPlan(plan) { rebound = true }
                continue
            }
            do { try planBook.add(plan) } catch { continue }
            handled.insert(item.eventKey)
            if case .needsConfirmation = plan.state { pending += 1 } else { added += 1 }
        }
        if added + pending > 0 || rebound {
            if savePlans() { defaults.set(Array(Array(handled).sorted().suffix(300)), forKey: Keys.handledEvents) }
        }
        if added + pending > 0 {
            let detail = pending > 0 ? tr("其中 {0} 個需要你確認。", "\(pending)") : ""
            postNotice(id: "armed-\(Int(now.timeIntervalSince1970))", title: tr("偵測到被額度中止的工作階段"),
                       body: tr("共 {0} 個工作階段。{1}請在 Vibe Meter 查看。", "\(added + pending)", detail))
        }
    }

    private func revokeInvalidCodexPlans() {
        for plan in planBook.active {
            guard let authorization = plan.codex?.sessionAuthorization, !deliveriesInFlight.contains(plan.id) else { continue }
            if !autoContinue || !agentPrefs.isEnabled(.codex) ||
               (authorization.basis == .generalBucketTimed && !codexTimedResume) ||
               !codexContinuation.permits(authorization) || !codexObservations.authorizes(authorization) {
                planBook.apply(.authorizationRevoked(now: Date()), to: plan.id)
                if codexObservations.authorizes(authorization) == false, liveCodexSnapshotIncludingStale?.usageAllowed == nil {
                    planBook.setNote(plan.id, L10n.token("Codex 未驗證目前登入（一般用量許可為 null），帳戶連續性中斷，未自動送出；可手動繼續"))
                } else if let live = liveCodexSnapshotIncludingStale?.accountID, !authorization.matches(accountID: live) {
                    planBook.setNote(plan.id, L10n.token("目前 Codex 帳戶與中止時不同，不送出"))
                }
            }
        }
    }

    func authorization(for provider: ProviderID, automatic: Bool) -> Authorization {
        Authorization(agentRevision: agentRevisions[provider, default: 0], autoRevision: automatic ? autoRevision : nil,
                      sharedRevision: sharedPolicy?.revision, sharedAgentRevision: sharedPolicy?.agentRevision)
    }

    private func isAuthorized(_ auth: Authorization, for provider: ProviderID) -> Bool {
        guard !dryRun, !backgroundStopped, agentPrefs.isEnabled(provider), auth.agentRevision == agentRevisions[provider, default: 0],
              provider != .codex || !persists || (sharedPolicy != nil && sharedPolicy?.agentRevision == auth.sharedAgentRevision) else {
            return false
        }
        return auth.autoRevision.map { revision in
            autoContinue && revision == autoRevision &&
                (provider != .codex || !persists || sharedPolicy?.revision == auth.sharedRevision)
        } ?? true
    }

    func runEngine(codexPreflight: Preflight? = nil, codexDelivery: StartDelivery? = nil) async {
        guard !dryRun, !backgroundStopped, !systemAsleep else { return }
        refreshDispatchPolicy()
        guard !engineRunning else { enginePending = true; return }
        engineRunning = true
        defer {
            engineRunning = false
            if enginePending {
                enginePending = false
                Task { await self.runEngine(codexPreflight: codexPreflight, codexDelivery: codexDelivery) }
            }
        }

        // Codex：只餵 app-server 即時資料；本機紀錄不會作為恢復依據。
        if let live = liveCodexSnapshot, agentPrefs.isEnabled(.codex) {
            let auth = authorization(for: .codex, automatic: true)
            let recoveryRevision = codexPollOutcomeRevision
            let effects = planBook.observe(live, now: now, autoContinue: autoContinue).compactMap { id, effect in
                planBook.plan(id).map { ($0, effect) }
            }
            for (plan, effect) in effects {
                await handle(effect, for: plan, authorization: auth, recoveryRevision: recoveryRevision,
                             checkPreflight: codexPreflight, startDelivery: codexDelivery)
            }
        }

        await runTimedResumes(codexPreflight: codexPreflight, codexDelivery: codexDelivery)
        await notifyManualReadyCodexPlans()

        // Claude Code：由官方原生「Continue automatically at usage limit」在原視窗等待並繼續。
        // Vibe Meter 不探測、不送出提示、不開新視窗，也不取消原生等待。
        await checkActivityAfterLaunch()
        savePlans()
    }

    func handle(_ effect: ResumeEffect, for plan: ResumePlan, authorization: Authorization,
                        recoveryRevision: Int, checkPreflight: Preflight? = nil, startDelivery: StartDelivery? = nil) async {
        guard planBook.plan(plan.id)?.state == plan.state else { return }
        let planID = plan.id
        switch effect {
        case .launch:
            await execute(plan, authorization: authorization, recoveryRevision: recoveryRevision, checkPreflight: checkPreflight, startDelivery: startDelivery)
        case .notifyReady:
            postNotice(id: "ready-\(planID)", title: tr("{0} 額度已恢復", plan.provider.displayName),
                          body: tr("「{0}」可以繼續了（自動繼續已關閉，請在 Vibe Meter 按「繼續」）。", L10n.display(plan.sessionTitle)))
        case .notifyGaveUp:
            postNotice(id: "gaveup-\(planID)", title: tr("無法確認 {0} 額度恢復", plan.provider.displayName),
                          body: tr("「{0}」已停止自動嘗試，可在 Vibe Meter 手動重試。", L10n.display(plan.sessionTitle)))
        case .notifyTimedReady:
            postTimedReadyNotice(plan)
        case .notifyNeedsConfirmation:
            if case .needsConfirmation(let reason, _) = plan.state {
                postNotice(id: "confirm-\(planID)", title: tr("{0} 自動繼續已暫停", plan.provider.displayName),
                              body: tr("「{0}」：{1}。不會自動送出，請在 Vibe Meter 確認。", L10n.display(plan.sessionTitle), L10n.display(reason)))
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
                let client = CodexAppServerClient(binary: binary, timeout: .seconds(8))
                var currentModel: String?? = .none
                let pollRevision = codexPollOutcomeRevision
                if automatic, let timed = plan.codex?.sessionAuthorization, timed.basis == .generalBucketTimed {
                    return await timedPreflight(plan, timed, client: client, binary: binary, pollRevision: pollRevision)
                }
                if automatic {
                    guard await ResumeExecutor.supportsQueueResume(binary) else {
                        return .unknown(L10n.token("目前的 Codex CLI 不支援喚醒未載入的工作階段"))
                    }
                    currentModel = .some(try await client.threadModel(threadID: plan.sessionID))
                    let refreshed = try await client.readRateLimits()
                    // A switch noticed during preflight also invalidates observations for other pending plans.
                    guard acceptsConcurrentPoll(for: plan, after: pollRevision) else {
                        return .retry(L10n.token("較新的 Codex 查詢未確認一般用量許可，等待下次檢查"))
                    }
                    observeCodexQuota(refreshed)
                    guard RestoreDetector.codexDecision(plan, snapshot: refreshed, now: Date()) == .restored else {
                        return .retry(L10n.token("送出前無法再次確認 Codex 帳戶與用量許可"))
                    }
                }
                // 最新 turn 放在最後一次官方查詢。CLI 不提供帶錨點條件的原子 queue。
                let latest = try await client.latestTurn(threadID: plan.sessionID)
                if automatic, !acceptsConcurrentPoll(for: plan, after: pollRevision) {
                    return .retry(L10n.token("較新的 Codex 查詢未確認一般用量許可，等待下次檢查"))
                }
                return LaunchDecision.codexPreflight(latest: latest, anchorTurnID: plan.codex?.anchorTurnID,
                                                      requireLimitFailure: automatic, expectedModel: plan.codex?.modelAtBlock,
                                                      currentModel: currentModel)
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

    func acceptsConcurrentPollPublic(for plan: ResumePlan, after revision: Int) -> Bool {
        acceptsConcurrentPoll(for: plan, after: revision)
    }

    private func acceptsConcurrentPoll(for plan: ResumePlan, after revision: Int) -> Bool {
        guard !systemAsleep else { return false }
        guard codexPollOutcomeRevision != revision else { return true }
        guard let latest = liveCodexSnapshot else { return false }
        if let timed = plan.codex?.sessionAuthorization, timed.basis == .generalBucketTimed {
            if case .send = CodexTimedResumePolicy.preflight(timed, deferredTo: plan.codex?.timedDeferredResetAt,
                                                             snapshot: latest, now: timedClock()) { return true }
            return false
        }
        return RestoreDetector.codexDecision(plan, snapshot: latest, now: Date()) == .restored
    }

    func execute(_ plan: ResumePlan, authorization auth: Authorization,
                 recoveryRevision: Int? = nil, checkPreflight: Preflight? = nil, startDelivery: StartDelivery? = nil) async {
        // Claude Code 交給官方原生續作；另開 `claude --resume` 可能與原視窗的等待重複送出。
        guard plan.provider == .codex else {
            if case .launching = plan.state { planBook.apply(.launchSkipped(ClaudeNativeContinue.handledNatively, now: Date()), to: plan.id) }
            return
        }
        guard case .launching = plan.state, launchStillAuthorized(plan, authorization: auth) else { return }
        let lockHeld = plan.provider == .codex
            ? await SessionActivity.codexThreadLockHeld(sessionID: plan.sessionID, codexHome: collector.codexStore.codexHome)
            : false
        guard launchStillAuthorized(plan, authorization: auth) else { return }
        let automatic = auth.autoRevision != nil
        // 使用者明確按下手動續作時，也優先排入原工作階段（queue --resume），不另開新視窗。
        var manualWake = false
        if !automatic, plan.provider == .codex, startDelivery == nil, let binary = collector.codexBinary {
            manualWake = await ResumeExecutor.supportsQueueResume(binary)
            guard launchStillAuthorized(plan, authorization: auth) else { return }
        }
        let pollRevision = recoveryRevision ?? codexPollOutcomeRevision
        let check = await (checkPreflight ?? preflight)(plan, automatic)
        guard launchStillAuthorized(plan, authorization: auth) else { return }
        if automatic {
            if !acceptsConcurrentPoll(for: plan, after: pollRevision) {
                planBook.apply(.retryAfterPreflight(L10n.token("較新的 Codex 查詢未確認一般用量許可，等待下次檢查")), to: plan.id)
                savePlans()
                return
            }
            if case .retry(let reason) = check {
                planBook.apply(.retryAfterPreflight(reason), to: plan.id)
                if plan.codex?.isTimedAttempt == true { timedPreflightRetried(plan.id) }
                savePlans()
                return
            }
        }

        var isDir: ObjCBool = false
        let cwdExists = FileManager.default.fileExists(atPath: plan.cwd, isDirectory: &isDir) && isDir.boolValue
        switch LaunchDecision.decide(plan, lastActivity: lastActivity(of: plan), threadLockHeld: lockHeld, cwdExists: cwdExists,
                                     preflight: check, now: Date(),
                                     wakeUnloaded: plan.provider == .codex && (automatic || manualWake)) {
        case .skip(let reason):
            planBook.apply(.launchSkipped(reason, now: Date()), to: plan.id)
        case .deliver(let via):
            if !automatic, let reason = manualAccountBlocker(plan) {
                planBook.apply(.launchSkipped(reason, now: Date()), to: plan.id)
                savePlans()
                return
            }
            do {
                var outgoing = plan
                if automatic, plan.codex?.isTimedAttempt == true { outgoing.prompt = ResumePlan.timedAttemptPrompt }
                let start = startDelivery ?? self.startDelivery
                let dispatchStartedAt = Date()
                let delivery: Task<Void, Error>
                if live {
                    delivery = try dispatchPolicyStore.withPolicy { policy in
                        if let cancelled = policy.cancelledAt(plan) { throw DispatchRejection.cancelled(cancelled) }
                        guard policy.codexEnabled, policy.agentRevision == auth.sharedAgentRevision else { throw DispatchRejection.revoked }
                        if automatic {
                            guard policy.revision == auth.sharedRevision, let binding = plan.codex?.sessionAuthorization,
                                  policy.permits(binding) else { throw DispatchRejection.revoked }
                        }
                        try savePlans(under: policy)
                        guard let anchor = plan.codex?.anchorTurnID,
                              try !dispatchPolicyStore.claims.contains(sessionID: plan.sessionID, turnID: anchor) else {
                            throw DispatchRejection.claim
                        }
                        if automatic, let binding = plan.codex?.sessionAuthorization {
                            let reset = binding.basis == .generalBucketTimed
                                ? CodexTimedResumePolicy.effectiveReset(binding, deferredTo: plan.codex?.timedDeferredResetAt) : binding.resetsAt
                            guard timedSessionStore.reserve(sessionID: plan.sessionID, anchorTurnID: anchor, effectiveReset: reset, now: dispatchStartedAt) else {
                                throw DispatchRejection.reservation
                            }
                        }
                        guard try dispatchPolicyStore.claims.claim(sessionID: plan.sessionID, turnID: anchor) else { throw DispatchRejection.claim }
                        return try start(outgoing, via)
                    }
                } else {
                    delivery = try start(outgoing, via)
                }
                deliveriesInFlight.insert(plan.id)
                defer { deliveriesInFlight.remove(plan.id) }
                try await delivery.value
                planBook.apply(.delivered(via, now: Date()), to: plan.id)
                if !automatic, plan.provider == .codex, live {
                    // 使用者明確手動繼續：之後新週期的中止才會再評估自動嘗試。
                    timedSessionStore.markUserConfirmed(sessionID: plan.sessionID, at: dispatchStartedAt)
                }
                if let note = timedDispatchNotes.removeValue(forKey: plan.id) { planBook.setNote(plan.id, note) }
                if live {
                    postNotice(id: "sent-\(plan.id)", title: tr("已將 {0} 續作請求送出", plan.provider.displayName),
                                  body: tr("「{0}」：{1}。", L10n.display(plan.sessionTitle), via.label))
                }
            } catch DispatchRejection.cancelled(let at) {
                planBook.apply(.sharedCancellation(now: at), to: plan.id)
            } catch DispatchRejection.revoked {
                if automatic {
                    planBook.apply(.authorizationRevoked(now: Date()), to: plan.id)
                } else {
                    planBook.apply(.launchSkipped("送出前已撤銷授權", now: Date()), to: plan.id)
                }
                refreshDispatchPolicy()
            } catch DispatchRejection.reservation {
                planBook.apply(.launchSkipped(L10n.token("這個工作階段已自動嘗試過；無法確認之後的工作是否由你送出，不再自動送出。按「手動繼續」後，之後新週期的中止才會再自動嘗試"), now: Date()), to: plan.id)
            } catch DispatchRejection.claim {
                planBook.apply(.launchSkipped(L10n.token("此中止事件已有送出記錄或無法保存，請確認後手動處理"), now: Date()), to: plan.id)
            } catch ResumeExecutor.Failure.queuedWakeUnconfirmed {
                planBook.apply(.queuedWithWakeWarning(via, now: Date()), to: plan.id)
                if let note = timedDispatchNotes.removeValue(forKey: plan.id) {
                    planBook.setNote(plan.id, L10n.token("{0}；{1}", [L10n.token("已排入 Codex 佇列，CLI 回報喚醒未獲確認"), note]))
                }
            } catch {
                planBook.apply(.launchFailed(error.localizedDescription, now: Date()), to: plan.id)
            }
        }
        savePlans()
    }

    /// 手動續作：偵測中止時已觀察到帳戶，而目前即時帳戶不同時不送出。帳戶不明時由使用者已確認的風險自行決定。
    func manualAccountBlocker(_ plan: ResumePlan) -> String? {
        guard let atDetection = plan.codex?.accountHashAtDetection,
              let current = liveCodexSnapshot?.accountID, !current.isEmpty,
              AccountHash.of(current) != atDetection else { return nil }
        return L10n.token("目前 Codex 帳戶與偵測中止時不同，未送出")
    }

    private func launchStillAuthorized(_ plan: ResumePlan, authorization auth: Authorization) -> Bool {
        // State equality includes startedAt, so an obsolete preflight cannot authorize a newer attempt.
        guard planBook.plan(plan.id) == plan, !deliveriesInFlight.contains(plan.id) else { return false }
        if isAuthorized(auth, for: plan.provider) {
            if auth.autoRevision == nil { return true }
            if plan.provider == .codex {
                let bindingAllowed = plan.codex?.sessionAuthorization.map {
                    codexContinuation.permits($0) && codexObservations.authorizes($0)
                        && ($0.basis != .generalBucketTimed || codexTimedResume)
                } ?? (!live && codexContinuation.mode == .automatic && plan.codex?.verifiedAccountAndModelAtBlock == true)
                guard bindingAllowed else {
                    planBook.apply(.authorizationRevoked(now: Date()), to: plan.id)
                    savePlans()
                    return false
                }
            }
            return AutoResumeGate.blocker(for: plan) == nil
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

    private func checkActivityAfterLaunch() async {
        guard persists, !backgroundStopped else { return }
        let launched = planBook.active.filter {
            if case .launched = $0.state { return agentPrefs.isEnabled($0.provider) }
            return false
        }
        guard !launched.isEmpty else { return }
        let offset = codexActivityOffset % launched.count
        codexActivityOffset = (offset + 1) % launched.count
        let batch = (Array(launched[offset...]) + launched.prefix(offset)).prefix(5)
        for plan in batch {
            guard !backgroundStopped, agentPrefs.isEnabled(plan.provider), case .launched(let at) = plan.state else { continue }
            if plan.provider == .codex, let binary = collector.codexBinary {
                let latest = try? await CodexAppServerClient(binary: binary, timeout: .seconds(5)).latestTurn(threadID: plan.sessionID)
                guard !backgroundStopped, agentPrefs.isEnabled(.codex), planBook.plan(plan.id) == plan,
                      let latest, LaunchDecision.hasNewCodexActivity(plan, latest: latest) else { continue }
                planBook.apply(.activityObserved(now: latest.startedAt ?? at), to: plan.id)
                // 只更新顯示的活動狀態。官方 turn 沒有可信的來源標記，進行中或完成都不解除防付費重試。
            } else if plan.provider == .claudeCode, let last = lastActivity(of: plan), last > at.addingTimeInterval(2) {
                planBook.apply(.activityObserved(now: last), to: plan.id)
            }
        }
    }

    // MARK: 使用者動作

    public func setAutoContinue(_ on: Bool) {
        guard changeDispatchPolicy({ $0.autoContinue = on }) else { return }
        banner = on ? "自動繼續已開啟" : "自動繼續已關閉：確認恢復後只通知你"
        if canScheduleBackgroundWork { Task { await runEngine() } }
    }

    public func setCodexContinuationMode(_ mode: CodexContinuationSettings.Mode) {
        changeDispatchPolicy { $0.continuation.mode = mode }
    }

    @discardableResult
    func setCodexScope(_ scope: CodexContinuationSettings.Scope, expecting revision: UUID? = nil) -> Bool {
        changeDispatchPolicy(expecting: revision) {
            $0.continuation = CodexContinuationSettings(mode: .scoped, scope: scope)
        }
    }

    public func clearCodexScope() {
        changeDispatchPolicy { $0.continuation.scope = nil }
    }

    public func setCodexTimedResume(_ on: Bool) {
        changeDispatchPolicy { $0.timedResume = on }
    }

    @discardableResult
    private func changeDispatchPolicy(expecting revision: UUID? = nil, _ change: (inout CodexDispatchPolicy) -> Void) -> Bool {
        guard !dryRun, !backgroundStopped else { return false }
        if persists {
            do {
                let policy = try dispatchPolicyStore.update { policy in
                    if let revision, revision != policy.revision { throw DispatchRejection.revoked }
                    change(&policy)
                }
                adoptDispatchPolicy(policy)
                defaults.set(autoContinue, forKey: Keys.autoContinue)
                defaults.set(codexTimedResume, forKey: Keys.codexTimedResume)
                defaults.set(try? VibeMeterJSON.encoder.encode(codexContinuation), forKey: Keys.codexContinuation)
                agentPrefs.save(to: defaults)
            } catch DispatchRejection.revoked {
                refreshDispatchPolicy()
                banner = L10n.token("另一個 Vibe Meter 已變更續作設定，請重新確認")
                return false
            } catch { showDispatchPolicyError(); return false }
        } else {
            var policy = CodexDispatchPolicy(autoContinue: autoContinue, codexEnabled: agentPrefs.isEnabled(.codex),
                                            timedResume: codexTimedResume, continuation: codexContinuation)
            change(&policy)
            adoptDispatchPolicy(policy)
        }
        return true
    }

    func refreshDispatchPolicy() {
        guard persists, !backgroundStopped else { return }
        do { adoptDispatchPolicy(try dispatchPolicyStore.withPolicy { $0 }) }
        catch {
            sharedPolicy = nil
            showDispatchPolicyError()
        }
    }

    private func adoptDispatchPolicy(_ policy: CodexDispatchPolicy) {
        guard sharedPolicy != policy else { return }
        let hadPolicy = sharedPolicy != nil
        let oldEnabled = agentPrefs.isEnabled(.codex)
        let changed = sharedPolicy?.revision != policy.revision || autoContinue != policy.autoContinue ||
            codexTimedResume != policy.timedResume || codexContinuation != policy.continuation
        if persists { sharedPolicy = policy }
        autoContinue = policy.autoContinue
        codexTimedResume = policy.timedResume
        codexContinuation = policy.continuation
        agentPrefs.set(.codex, enabled: policy.codexEnabled)
        if changed { autoRevision += 1 }
        if oldEnabled != policy.codexEnabled {
            agentRevisions[.codex, default: 0] += 1
            if hadPolicy {
                if !policy.codexEnabled { cancelCodexPolling() }
                if canScheduleBackgroundWork {
                    if policy.codexEnabled {
                        restartCodexPolling()
                        Task { await refresh() }
                    }
                    if keepAwake.mode == .whileAgentsWork { restartKeepAwake() }
                }
            }
            if !policy.codexEnabled {
                replaceReport(ProviderReport(provider: .codex, state: .loading))
                codexLiveStatus = .idle
            }
        }
        reconcileCancelledPlans(policy)
        if changed, hadPolicy || !persists {
            revokeInvalidCodexPlans()
            scheduleTimedResumeCheck()
        }
    }

    private func showDispatchPolicyError() {
        banner = L10n.token("無法讀寫共用續作設定，未變更設定或送出")
    }

    public func configureCodexScope(_ session: CodexSessionInfo) {
        refreshDispatchPolicy()
        guard persists, !backgroundStopped, !scopeRequestInProgress, agentPrefs.isEnabled(.codex),
              let sharedRevision = sharedPolicy?.revision,
              let binary = collector.codexBinary, SessionID.isUUID(session.id) else { return }
        scopeRequestInProgress = true
        let auth = authorization(for: .codex, automatic: false)
        let revision = autoRevision
        let pollRevision = codexPollOutcomeRevision
        func accountStillConfirmed(_ account: String) -> Bool {
            if pollRevision == codexPollOutcomeRevision { return true }
            return liveCodexSnapshot?.accountID == account && liveCodexSnapshot?.usageAllowed != nil
        }
        Task {
            defer { scopeRequestInProgress = false }
            let store = collector.codexStore
            let root = await Task.detached { store.isSubagent(sessionID: session.id) }.value
            guard root == false, isAuthorized(auth, for: .codex), revision == autoRevision else { return }
            let client = CodexAppServerClient(binary: binary, timeout: .seconds(8))
            guard let model = try? await client.threadModel(threadID: session.id), !model.isEmpty,
                  let snapshot = try? await client.readRateLimits(), snapshot.usageAllowed != nil,
                  let account = snapshot.accountID, !account.isEmpty, accountStillConfirmed(account),
                  isAuthorized(auth, for: .codex), revision == autoRevision else {
                banner = L10n.token("無法確認 Codex 的目前帳戶與模型，未設定範圍")
                return
            }
            let scope = CodexContinuationSettings.Scope(sessionID: session.id, accountID: account, model: model)
            let alert = NSAlert()
            alert.messageText = tr("將自動續作限制為這個 Codex 工作階段？")
            alert.informativeText = tr("工作階段：{0}（{1}）\n帳戶識別碼：{2}\n模型：{3}\n只有此組合符合官方用量恢復條件時才會自動送出。",
                                       session.displayTitle, String(session.id.prefix(8)), String(scope.accountHash.suffix(8)), model)
            alert.addButton(withTitle: tr("套用範圍"))
            alert.addButton(withTitle: tr("取消"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, isAuthorized(auth, for: .codex),
                  revision == autoRevision, accountStillConfirmed(account) else { return }
            setCodexScope(scope, expecting: sharedRevision)
        }
    }

    /// 手動加入：仍會建立帳戶／模型／錨點脈絡；資訊不足時進入「待確認」，不會自動送出。
    public func addPlan(provider: ProviderID, sessionID: String, title: String, cwd: String?) {
        guard live, !dryRun, provider == .codex, agentPrefs.isEnabled(provider) else { return }
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
                    banner = L10n.token("已加入，但{0}；不會自動送出", [reason])
                } else {
                    banner = L10n.token("已加入自動繼續：{0}", [title])
                }
            } catch {
                banner = error.localizedDescription
            }
        }
    }

    public func canCancel(_ id: UUID) -> Bool { !deliveriesInFlight.contains(id) }

    public func cancelPlan(_ id: UUID) {
        guard canCancel(id), let plan = planBook.plan(id), !plan.state.isFinished else { return }
        if persists, plan.provider == .codex {
            do { adoptDispatchPolicy(try dispatchPolicyStore.cancel(plan, at: Date())) }
            catch CodexDispatchPolicyStore.CancellationError.alreadySubmitted {
                banner = L10n.token("續作已提交給 Codex，無法取消")
                return
            } catch { showDispatchPolicyError(); return }
        } else {
            planBook.apply(.userCancel(now: Date()), to: id)
        }
        savePlans()
    }

    /// 手動續作前的確認。官方未能授權自動送出時，說明目前狀態與可能使用付費 credits 的風險。測試可注入替身。
    var confirmManualCodexLaunch: (@MainActor (ResumePlan, CodexAutomationDiagnosis, UsageSnapshot?) -> Bool)?

    public func launchNow(_ id: UUID) {
        refreshDispatchPolicy()
        guard live, !dryRun, let existing = planBook.plan(id), existing.provider == .codex,
              agentPrefs.isEnabled(existing.provider) else { return }
        guard sharedPolicy?.cancelledAt(existing) == nil else { return }
        if case .ready = existing.state {} else {
            let diagnosis = codexDiagnosis(for: existing)
            guard (confirmManualCodexLaunch ?? Self.presentManualCodexConfirmation)(existing, diagnosis, liveCodexSnapshot) else { return }
        }
        let effects = planBook.apply(.userLaunch(now: Date()), to: id)
        guard effects.contains(.launch), let plan = planBook.plan(id) else { return }
        let auth = authorization(for: plan.provider, automatic: false)
        Task { await execute(plan, authorization: auth) }
    }

    public func clearFinished() {
        planBook = ResumePlanBook(plans: planBook.plans.filter { !$0.state.isFinished })
        savePlans(keepStoredCancellations: false)
    }

    // MARK: 交接

    public func copy(_ text: String, message: String) {
        guard persists, !backgroundStopped else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        banner = message
    }

    public func copyPackPrompt(provider: ProviderID, sessionID: String?, cwd: String?) {
        copy(HandoffPromptBuilder().packPrompt(agent: provider, sessionID: sessionID, cwd: cwd),
             message: sessionID.map { L10n.token("已複製封裝指令（工作階段 {0}…）", [String($0.prefix(8))]) } ?? "已複製封裝指令，請貼到正在工作的 agent")
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
        alert.messageText = tr("把封裝指令送給這個 Codex 工作階段？")
        alert.informativeText = tr("名稱：{0}\n資料夾：{1}\nSession：{2}\n最後活動：{3}\n\n會以 codex queue 排入這個工作階段，請它停止新修改並寫好 HANDOFF.md。",
                                   L10n.display(session.displayTitle), session.cwd ?? tr("未知"), session.id,
                                   ZhFormat.ago(session.lastActivity, now: Date()))
        alert.addButton(withTitle: tr("送出"))
        alert.addButton(withTitle: tr("取消"))
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
                banner = r.status == 0 ? L10n.token("已排入 Codex 工作階段「{0}」", [session.displayTitle]) : L10n.token("送出失敗：{0}", [String(r.stderr.prefix(120))])
            } catch {
                banner = L10n.token("送出失敗：{0}", [error.localizedDescription])
            }
        }
    }

    // MARK: Claude Code 連接

    func installBridgeBinary() throws -> URL {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: VibeMeterPaths.bridgeName) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: L10n.token("找不到內附的 {0}，請使用 scripts/build-app.sh 建置的 App", [VibeMeterPaths.bridgeName])])
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
        alert.messageText = tr("連接 Claude Code 狀態列？")
        alert.informativeText = tr("Vibe Meter 會修改 {0}：\n• statusLine：Claude Code 每次回應時把官方額度資料交給 Vibe Meter（原本的狀態列會保留並照常顯示）\n• StopFailure hook（rate_limit）：記錄哪個工作階段因額度中止\n\n修改前會先備份，可隨時「中斷連接」還原。",
                                   collector.claudeInstaller.settingsURL.path)
        alert.addButton(withTitle: tr("連接"))
        alert.addButton(withTitle: tr("取消"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let backup = try collector.claudeInstaller.install(bridge: try installBridgeBinary())
            banner = backup.map { L10n.token("已連接 Claude Code（備份：{0}）", [$0.lastPathComponent]) } ?? "已連接 Claude Code"
        } catch {
            banner = L10n.token("連接失敗：{0}", [error.localizedDescription])
        }
        refreshClaudeBridge()
        startClaudeBridgeRefresh()
    }

    public func disconnectClaude() {
        guard live, !dryRun else { return }
        let alert = NSAlert()
        alert.messageText = tr("中斷 Claude Code 狀態列連接？")
        alert.informativeText = tr("Vibe Meter 會先備份 Claude Code 設定，再移除自己的連接並還原原本的狀態列。")
        alert.addButton(withTitle: tr("中斷連接"))
        alert.addButton(withTitle: tr("取消"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try collector.claudeInstaller.uninstall()
            banner = "已中斷連接並還原 Claude Code 設定"
        } catch {
            banner = L10n.token("中斷連接失敗：{0}", [error.localizedDescription])
        }
        refreshClaudeBridge()
        startClaudeBridgeRefresh()
    }

    // MARK: 持久化

    private func loadPlans() {
        guard let data = try? Data(contentsOf: paths.resumePlans),
              let book = try? VibeMeterJSON.decoder.decode(ResumePlanBook.self, from: data) else { return }
        let plans = book.plans.map { saved in
            var plan = saved
            if plan.provider == .claudeCode, !plan.state.isFinished {
                plan.state = .skipped(reason: ClaudeNativeContinue.handledNatively, at: Date())
                return plan
            }
            switch plan.state {
            case .launching:
                plan.automaticRetryBlocked = true
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
        if let sharedPolicy { reconcileCancelledPlans(sharedPolicy) }
    }

    private func reconcileCancelledPlans(_ policy: CodexDispatchPolicy) {
        for plan in planBook.plans where plan.provider == .codex && !deliveriesInFlight.contains(plan.id) {
            if let cancelledAt = policy.cancelledAt(plan) {
                planBook.apply(.sharedCancellation(now: cancelledAt), to: plan.id)
            }
        }
    }

    @discardableResult
    func savePlans(keepStoredCancellations: Bool = true) -> Bool {
        guard persists, !backgroundStopped else { return !backgroundStopped }
        return (try? dispatchPolicyStore.withPolicy { policy in
            try savePlans(under: policy, keepStoredCancellations: keepStoredCancellations)
            return true
        }) ?? false
    }

    private func savePlans(under policy: CodexDispatchPolicy, keepStoredCancellations: Bool = true) throws {
        reconcileCancelledPlans(policy)
        // Another instance may not have loaded the cancelled plan. Preserve it when writing its own list.
        if keepStoredCancellations, let data = try? Data(contentsOf: paths.resumePlans),
           let existing = try? VibeMeterJSON.decoder.decode(ResumePlanBook.self, from: data) {
            let missing = existing.plans.filter { $0.provider == .codex && policy.cancelledAt($0) != nil && planBook.plan($0.id) == nil }
            if !missing.isEmpty {
                planBook = ResumePlanBook(plans: planBook.plans + missing)
                reconcileCancelledPlans(policy)
            }
        }
        planBook.prune()
        try VibeMeterJSON.writeAtomically(VibeMeterJSON.encoder.encode(planBook), to: paths.resumePlans)
    }
}
