import AppKit
import Darwin
import Foundation
import UserNotifications
import VibeMeterCore

/// 預覽／示範用：不建立任何電源 assertion。
final class NoopPowerAssertions: PowerAssertionProvider {
    private var next: UInt32 = 1
    func acquire(preventDisplaySleep: Bool, reason: String) -> UInt32? { defer { next += 1 }; return next }
    func release(_ id: UInt32) {}
}

public enum NotificationStatus: Equatable, Sendable {
    case unknown, unavailable, notDetermined, denied, authorized, provisional

    public var label: String {
        switch self {
        case .unknown: tr("檢查中…")
        case .unavailable: tr("此執行方式無法使用通知")
        case .notDetermined: tr("尚未決定")
        case .denied: tr("已拒絕")
        case .authorized: tr("已允許")
        case .provisional: tr("暫時允許（安靜傳送）")
        }
    }
}

public enum UpdateDownloadState: Equatable, Sendable {
    case idle
    case downloading(version: String)
    /// 已下載。`digestVerified`：SHA-256 與 GitHub 記錄相符（只證明完整性）；`publisherVerified`：發布者簽章通過。
    case downloaded(file: URL, version: String, sha256: String, digestVerified: Bool, publisherVerified: Bool)
    case failed(String)
}

// MARK: - Claude Code 用量自動更新

extension AppModel {
    var latestClaudeSnapshot: UsageSnapshot? {
        reports.first { $0.provider == .claudeCode }?.state.snapshot
    }

    func startClaudeBridgeRefresh() {
        claudeBridgeTask?.cancel()
        claudeBridgeWatcher?.stop()
        claudeBridgeWatcher = nil
        guard persists, !backgroundStopped, claudeAutoRefresh, agentPrefs.isEnabled(.claudeCode) else { return }
        claudeBridgeWatcher = BridgeDirectoryWatcher(directory: paths.claudeDir) { [weak self] in
            self?.scheduleClaudeBridgeDeadline()
        }
        scheduleClaudeBridgeDeadline()
    }

    private func scheduleClaudeBridgeDeadline() {
        claudeBridgeTask?.cancel()
        claudeBridgeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let next = self?.refreshClaudeBridgeAndNextCheck() else { return }
                do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) }
                catch { return }
            }
        }
    }

    private func refreshClaudeBridgeAndNextCheck() -> Date? {
        guard !backgroundStopped, claudeAutoRefresh, agentPrefs.isEnabled(.claudeCode) else { return nil }
        refreshClaudeBridge()
        return ClaudeRefreshPolicy.nextCheck(latest: latestClaudeSnapshot, now: Date())
    }

    public func refreshClaudeBridge() {
        guard live, !backgroundStopped, agentPrefs.isEnabled(.claudeCode) else { return }
        updateClaudeStatus()
        replaceReport(collector.claudeReport())
        now = Date()
        handleAlerts()
    }

    public func setClaudeAutoRefresh(_ on: Bool) {
        guard claudeAutoRefresh != on else { return }
        claudeAutoRefresh = on
        startClaudeBridgeRefresh()
    }

    public var claudeRefreshStatusText: String {
        switch ClaudeRefreshPolicy.status(latest: latestClaudeSnapshot, now: now) {
        case .awaitingReport:
            tr("等待 Claude Code 狀態列回報用量")
        case .current(let observedAt):
            tr("狀態列上次帶來新資料：{0}", ZhFormat.ago(observedAt, now: now))
        case .awaitingNewReport(let observedAt):
            tr("沒有新的狀態列資料（上次 {0}）。Claude Code 下一次收到回應才會更新", ZhFormat.ago(observedAt, now: now))
        case .responseTimeUnknown(let seenAt):
            tr("讀到既有工作階段的資料（{0}），無法確認是否為舊值，等待下一次新回應", ZhFormat.ago(seenAt, now: now))
        }
    }
}

// MARK: - Claude Code 原生自動繼續（只讀、只呈現）

extension AppModel {
    /// 只讀使用者設定檔中的 `autoContinueAtUsageLimit`。不代表原視窗的生效設定。
    public var claudeNativeUserSetting: ClaudeNativeContinue.UserSetting {
        guard persists else { return .unset }
        return ClaudeNativeContinue.userSetting(settingsURL: collector.claudeInstaller.settingsURL)
    }

    /// 由 transcript 觀察到的最近額度中止與後續狀態。
    public var claudeNativeObservations: [ClaudeNativeContinue.Observation] {
        ClaudeNativeContinue.observations(visibleClaudeSessions, setting: claudeNativeUserSetting, now: now)
    }

    /// bridge 從官方 statusLine `version` 看到的最新版本。
    public var claudeReportedVersion: String? {
        guard persists else { return nil }
        return collector.claudeStore.latestReportedVersion()?.version
    }

    public func openClaudeNativeContinueDocs() {
        guard persists, !backgroundStopped else { return }
        NSWorkspace.shared.open(ClaudeNativeContinue.docsURL)
    }
}

extension AppModel {
    func startAntigravityBridgeRefresh() {
        antigravityBridgeWatcher?.stop()
        antigravityBridgeWatcher = nil
        guard persists, !backgroundStopped, agentPrefs.isEnabled(.antigravity) else { return }
        antigravityBridgeWatcher = BridgeDirectoryWatcher(directory: paths.antigravityDir) { [weak self] in
            self?.refreshAntigravityBridge()
        }
        refreshAntigravityBridge()
    }

    func refreshAntigravityBridge() {
        guard live, !backgroundStopped, agentPrefs.isEnabled(.antigravity) else { return }
        replaceReport(collector.antigravityCLIReport())
        now = Date()
        handleAlerts()
    }

    func replaceReport(_ report: ProviderReport) {
        if let i = reports.firstIndex(where: { $0.provider == report.provider }) {
            reports[i] = report
        } else {
            reports.append(report)
        }
    }

    public func copyAntigravitySetup() {
        guard persists, !backgroundStopped,
              let bridge = Bundle.main.url(forAuxiliaryExecutable: VibeMeterPaths.bridgeName),
              let snippet = AntigravityBridgeStore.configurationSnippet(bridge: bridge) else { return }
        copy(snippet, message: L10n.token("已複製 Antigravity CLI 狀態列設定"))
    }

    public func openAntigravityDesktop() {
        guard persists, !backgroundStopped,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") else { return }
        NSWorkspace.shared.open(app)
    }

    public var antigravityDesktopInstalled: Bool {
        persists && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") != nil
    }

    public func openCursorUsageHelp() {
        guard persists, !backgroundStopped, let url = URL(string: "https://cursor.com/help/models-and-usage/usage-limits") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 保持清醒

extension AppModel {
    public static let keepAwakePollInterval: TimeInterval = 60

    func startKeepAwakeLoop() {
        keepAwakeTask?.cancel()
        guard persists, !backgroundStopped, keepAwake.mode != .off else { return }
        keepAwakeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateKeepAwake()
                guard let interval = self?.keepAwakeNextInterval else { return }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    private var keepAwakeNextInterval: TimeInterval? {
        switch keepAwake.mode {
        case .off: nil
        case .until(let end): max(0, end.timeIntervalSinceNow)
        case .whileAgentsWork: Self.keepAwakePollInterval
        }
    }

    func observeTermination() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopBackgroundWork() }
        }
    }

    /// 在 await 後以 revision 排除上一個模式的查詢結果。
    func updateKeepAwake(now: Date = Date(), activityProbe: (@MainActor () async -> AgentActivity)? = nil) async {
        guard !dryRun, !backgroundStopped, persists || activityProbe != nil else { return }
        let revision = keepAwakeRevision
        if case .whileAgentsWork = keepAwake.mode {
            let activity = await (activityProbe ?? { await self.detectAgentActivity(revision: revision) })()
            guard !Task.isCancelled, !backgroundStopped, revision == keepAwakeRevision else { return }
            agentActivity = activity
        }
        applyKeepAwake(now: now)
    }

    private func applyKeepAwake(now: Date = Date()) {
        let (awake, reason) = KeepAwakePolicy.evaluate(mode: keepAwake.mode, activity: agentActivity, now: now)
        if case .expired = reason { keepAwake.mode = .off }
        keepAwakeReason = reason
        keepAwakeController.apply(awake: awake, preventDisplaySleep: keepAwake.preventDisplaySleep,
                                  reason: tr("Vibe Meter：保持清醒，避免 agent 工作或遠端連線中斷"))
        keepAwakeError = keepAwakeController.lastError.map { L10n.display($0) }
    }

    /// 最近的 rollout 只用來發現新 thread，執行狀態只採用唯讀 app-server 回覆。
    func detectAgentActivity(revision: Int) async -> AgentActivity {
        let unknown = AgentActivity.unknown(L10n.token("無法取得 Codex 執行狀態"))
        guard agentPrefs.isEnabled(.codex), let binary = collector.codexBinary else { return unknown }
        let store = collector.codexStore
        let recent = await Task.detached {
            store.recentSessions(limit: 100, within: CodexActivityTracker.discoveryWindow)
        }.value
        guard !Task.isCancelled, !backgroundStopped, revision == keepAwakeRevision else { return unknown }
        let candidates = codexActivityTracker.candidates(sessions: recent, now: Date())
        let client = CodexAppServerClient(binary: binary, timeout: .seconds(4))
        var results: [String: CodexActivityTracker.Probe] = [:]
        for offset in stride(from: 0, to: candidates.ids.count, by: 4) {
            guard !Task.isCancelled, !backgroundStopped, revision == keepAwakeRevision else { return unknown }
            let batch = candidates.ids.dropFirst(offset).prefix(4)
            await withTaskGroup(of: (String, CodexActivityTracker.Probe).self) { group in
                for id in batch {
                    group.addTask {
                        do { return (id, .turn(try await client.latestTurn(threadID: id))) }
                        catch { return (id, .failed) }
                    }
                }
                for await (id, result) in group { results[id] = result }
            }
        }
        guard !Task.isCancelled, !backgroundStopped, revision == keepAwakeRevision else { return unknown }
        return codexActivityTracker.update(results, complete: candidates.complete)
    }

    func restartKeepAwake() {
        keepAwakeRevision += 1
        codexActivityTracker = CodexActivityTracker()
        agentActivity = .unknown(L10n.token("無法取得 Codex 執行狀態"))
        applyKeepAwake()
        startKeepAwakeLoop()
    }

    public func setKeepAwake(_ mode: KeepAwakeMode) {
        guard (persists || demo || !live), !backgroundStopped else { return }
        keepAwake.mode = mode
        restartKeepAwake()
    }

    public func setKeepAwakeDisplay(_ on: Bool) {
        guard (persists || demo || !live), !backgroundStopped else { return }
        keepAwake.preventDisplaySleep = on
        applyKeepAwake()
    }

    public var keepAwakeStatusText: String {
        switch keepAwakeReason {
        case .off: return tr("關閉")
        case .timer(let until): return tr("保持清醒到 {0}（剩 {1}）", ZhFormat.clock(until), ZhFormat.duration(until.timeIntervalSince(now)))
        case .expired: return tr("時間到，已恢復正常睡眠")
        case .agentsWorking(let n): return tr("{0} 個 Codex 工作執行中，保持清醒", "\(n)")
        case .agentsIdle: return tr("已檢查的 Codex 工作階段沒有執行中的任務，允許正常睡眠")
        case .activityUnknown(let r): return tr("狀態不明（{0}），允許正常睡眠", L10n.display(r))
        }
    }

    public var isKeepingAwake: Bool { keepAwakeController.isHolding }
}

// MARK: - 檢查更新

extension AppModel {
    func scheduleUpdateChecks() {
        updateTask?.cancel()
        guard persists, !backgroundStopped else { return }
        updateTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            while !Task.isCancelled {
                await self?.checkForUpdatesIfDue()
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
            }
        }
    }

    private func checkForUpdatesIfDue() async {
        guard updateSettings.autoCheck, UpdateSettings.isCheckDue(lastCheck: lastUpdateCheck, now: Date()) else { return }
        await checkForUpdates(automatic: true)
    }

    public var currentVersion: AppVersion { AppVersion(appVersion) ?? AppVersion("0.0.0")! }

    typealias FetchRelease = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias FetchAsset = @MainActor (URL) async throws -> URL
    typealias FetchSignature = @MainActor (URL) async throws -> Data

    public func checkForUpdates() async { await checkForUpdates(automatic: false) }

    func checkForUpdates(automatic: Bool, fetch: FetchRelease? = nil) async {
        guard !dryRun, !demo, !backgroundStopped, (persists || fetch != nil), !isCheckingUpdate else { return }
        let revision = updateRevision
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        var request = URLRequest(url: UpdateSource.latestReleaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VibeMeter/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let result: UpdateCheckResult
        do {
            let (data, response) = try await (fetch ?? Self.fetchRelease)(request)
            guard response.url == UpdateSource.latestReleaseAPI, data.count <= 1024 * 1024 else { throw URLError(.badServerResponse) }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            result = UpdateChecker.result(status: response.statusCode, body: data, headers: headers, current: currentVersion)
        } catch {
            result = .failed(L10n.token("無法連線或讀取 GitHub release 資料"))
        }
        guard !Task.isCancelled, !backgroundStopped, !automatic || (revision == updateRevision && updateSettings.autoCheck) else { return }
        updateResult = result
        lastUpdateCheck = Date()
        if persists { defaults.set(lastUpdateCheck, forKey: UpdateSettings.lastCheckKey) }
        if persists, revision == updateRevision, updateSettings.autoInstall,
           case .available(let info) = result,
           startAutomaticInstall?(info, { [weak self] in
               guard let self else { return false }
               return self.persists && !self.backgroundStopped && self.updateRevision == revision
                   && self.updateSettings.autoInstall && self.updateResult == .available(info)
           }) == true { return }
        if persists, revision == updateRevision, updateSettings.autoDownload,
           case .available(let info) = result, case .idle = updateDownload {
            await downloadUpdate(info, automatic: true)
        }
    }

    private static func fetchRelease(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: anonymousSession(timeout: 20), delegate: RestrictedRedirects(assetURL: nil), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func downloadUpdate(_ info: ReleaseInfo) async { await downloadUpdate(info, automatic: false) }

    /// 先在目的地同一個目錄暫存並校驗，成功後才以 POSIX rename 原子替換。
    func downloadUpdate(_ info: ReleaseInfo, automatic: Bool, fetch: FetchAsset? = nil,
                        fetchSignature: FetchSignature? = nil, publicKeys: [String] = UpdateTrust.trustedPublicKeys) async {
        guard !dryRun, !demo, !backgroundStopped, (persists || fetch != nil), updateResult == .available(info) else { return }
        if case .downloading = updateDownload { return }
        let name = UpdateSource.expectedAssetName(for: info.version)
        guard let asset = info.dmg, UpdateSource.matches(asset, tag: info.tag, name: name) else {
            updateDownload = .failed(L10n.token("這個 release 沒有預期的 DMG 檔案"))
            return
        }
        guard let expected = asset.sha256 else {
            updateDownload = .failed(UpdateError.missingDigest.message)
            return
        }
        let revision = updateRevision
        func authorized() -> Bool {
            !Task.isCancelled && !backgroundStopped && revision == updateRevision &&
                (!automatic || updateSettings.autoDownload) && updateResult == .available(info)
        }
        guard authorized() else { return }
        let previous = updateDownload
        updateDownload = .downloading(version: info.version.description)
        do {
            let tmp = try await (fetch ?? Self.fetchDMG)(asset.url)
            defer { if fetch == nil { try? FileManager.default.removeItem(at: tmp) } }
            guard authorized() else { updateDownload = previous; return }
            let dir = paths.root.appendingPathComponent("Updates/\(info.version)")
            try paths.ensure(dir)
            let dest = dir.appendingPathComponent(name)
            let staged = dir.appendingPathComponent(".download-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            let size = try tmp.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard size.isRegularFile == true, size.isSymbolicLink != true,
                  let bytes = size.fileSize, (1...UpdateSource.maxDMGBytes).contains(bytes),
                  asset.size.map({ $0 == bytes }) ?? true else { throw UpdateError.invalidSize }
            try FileManager.default.copyItem(at: tmp, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            let sha = try await Task.detached { try UpdateChecker.sha256Hex(of: staged) }.value
            guard authorized() else { updateDownload = previous; return }
            guard expected == sha else { throw UpdateError.digestMismatch }
            if !publicKeys.isEmpty {
                guard let signature = info.signature, UpdateSource.matches(signature, tag: info.tag, name: name + ".sig") else {
                    throw UpdateError.signatureInvalid
                }
                let data = try await (fetchSignature ?? Self.fetchSignature)(signature.url)
                guard authorized() else { updateDownload = previous; return }
                guard data.count <= UpdateSource.maxSignatureBytes,
                      UpdateTrust.verify(sha256Hex: sha, signatureBase64: String(decoding: data, as: UTF8.self), publicKeys: publicKeys) else {
                    throw UpdateError.signatureInvalid
                }
            }
            guard authorized() else { updateDownload = previous; return }
            guard rename(staged.path, dest.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            updateDownload = .downloaded(file: dest, version: info.version.description, sha256: sha,
                                         digestVerified: true, publisherVerified: !publicKeys.isEmpty)
        } catch {
            updateDownload = authorized() ? .failed((error as? UpdateError)?.message ?? L10n.token("無法下載或保存更新檔")) : previous
        }
    }

    private static func fetchDMG(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: anonymousSession(timeout: 120), delegate: RestrictedRedirects(assetURL: url), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        return file
    }

    private static func fetchSignature(_ url: URL) async throws -> Data {
        let session = URLSession(configuration: anonymousSession(timeout: 20), delegate: RestrictedRedirects(assetURL: url), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func anonymousSession(timeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return config
    }

    public func revealDownloadedUpdate() {
        guard persists, !backgroundStopped, case .downloaded(let file, _, _, _, _) = updateDownload else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    public func openReleasePage() {
        guard persists, !backgroundStopped else { return }
        let url: URL
        if case .available(let info)? = updateResult, UpdateSource.isAllowedReleasePage(info.pageURL) { url = info.pageURL } else { url = UpdateSource.releasesPage }
        NSWorkspace.shared.open(url)
    }
}

/// API 固定在指定端點。只有下載可跟隨 GitHub 的正式檔案主機，並限制磁碟用量。
final class RestrictedRedirects: NSObject, URLSessionDownloadDelegate {
    let assetURL: URL?

    init(assetURL: URL?) { self.assetURL = assetURL }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let assetURL, let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              url == assetURL || UpdateSource.isAllowedRedirectHost(url.host) else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > UpdateSource.maxDMGBytes || totalBytesExpectedToWrite > UpdateSource.maxDMGBytes {
            downloadTask.cancel()
        }
    }
}

// MARK: - 權限

extension AppModel {
    public func refreshNotificationStatus() {
        guard persists, !backgroundStopped, Notifier.available else {
            notificationStatus = demo ? .notDetermined : .unavailable
            return
        }
        Task {
            let status = await notifier.status()
            guard !backgroundStopped else { return }
            notificationStatus = status
            if status == .authorized || status == .provisional {
                handleAlerts()
                await notifyManualReadyCodexPlans()
            }
        }
    }

    public func requestNotificationPermission() {
        guard persists, !backgroundStopped, Notifier.available else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            refreshNotificationStatus()
        }
    }

    /// 開啟 macOS「系統設定」中對應的頁面（只開啟，不修改任何設定）。
    public func openSystemSettings(_ pane: SystemSettingsPane) {
        guard persists, !backgroundStopped, let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }
}

public enum SystemSettingsPane: Sendable {
    case notifications, filesAndFolders

    var url: URL? {
        switch self {
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.leofeng.vibemeter")")
        case .filesAndFolders:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        }
    }
}
