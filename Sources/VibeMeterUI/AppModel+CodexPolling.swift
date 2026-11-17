import AppKit
import Foundation
import Network
import VibeMeterCore

/// 以官方唯讀 `account/rateLimits/read` 取得 Codex 額度。測試以替身取代。
typealias CodexRateReader = @Sendable () async throws -> UsageSnapshot

public enum CodexPollReason: Sendable, Equatable {
    case timer, windowOpened, refresh, wake
}

/// Codex 即時額度查詢的最後狀態（顯示用）。失敗時保留上次成功的時間，數值不會被當成目前剩餘。
public enum CodexLiveStatus: Equatable, Sendable {
    case idle
    case off(String)
    case ok(at: Date)
    case failed(message: String, at: Date, lastSuccess: Date?, offline: Bool = false)

    var isOfflineFailure: Bool {
        if case .failed(_, _, _, true) = self { return true }
        return false
    }
}

extension AppModel {
    /// 開視窗後短時間內重複開關不再啟動查詢。
    static let windowOpenDebounce: TimeInterval = 5

    var codexPollingAvailable: Bool {
        live && !dryRun && !demo && !backgroundStopped && !systemAsleep && agentPrefs.isEnabled(.codex)
            && (codexRateReader != nil || collector.codexBinary != nil)
    }

    // MARK: 排程

    func startCodexPolling(initialDelay: TimeInterval = 0) {
        codexPollTask?.cancel()
        codexPollTask = nil
        guard codexLivePolling, codexPollingAvailable else {
            if !codexLivePolling { codexLiveStatus = .off(L10n.token("每 30 秒查詢已關閉")) }
            return
        }
        let sleep = codexPollSleep ?? { try await Task.sleep(for: $0) }
        codexPollTask = Task { [weak self] in
            if initialDelay > 0 {
                do { try await sleep(.seconds(initialDelay)) } catch { return }
            }
            while !Task.isCancelled {
                await self?.requestCodexPoll(reason: .timer)
                guard let delay = self?.codexPollDelay else { return }
                do { try await sleep(.seconds(delay)) } catch { return }
            }
        }
    }

    /// 30 秒；連續失敗時倍增到最多 5 分鐘。
    var codexPollDelay: TimeInterval { CodexPollPolicy.delay(consecutiveFailures: codexPollFailures) }

    /// 停用、關閉輪詢、睡眠或結束時：作廢進行中的查詢結果並停止計時器。
    func cancelCodexPolling() {
        codexPollGeneration += 1
        codexPollTask?.cancel()
        codexPollTask = nil
        codexPollOutcomeRevision += 1
        codexPollInFlight?.task.cancel()
    }

    func restartCodexPolling() {
        cancelCodexPolling()
        codexPollFailures = 0
        startCodexPolling()
    }

    public func setCodexLivePolling(_ on: Bool) { codexLivePolling = on }

    // MARK: 查詢（single-flight）

    /// 計時器、開視窗、手動刷新共用。已有查詢進行中時等待同一個結果，不另外啟動 app-server。
    func requestCodexPoll(reason: CodexPollReason) async {
        let requestedGeneration = codexPollGeneration
        while let current = codexPollInFlight {
            await current.task.value
            if codexPollInFlight?.id == current.id { codexPollInFlight = nil }
            if current.generation == requestedGeneration || requestedGeneration != codexPollGeneration { return }
        }
        guard live, !dryRun, !demo, !backgroundStopped, !systemAsleep, agentPrefs.isEnabled(.codex), !Task.isCancelled else { return }
        if reason == .timer && !codexLivePolling { return }
        guard let reader = codexRateReader ?? collector.codexBinary.map({ binary in
            { try await CodexAppServerClient(binary: binary, timeout: .seconds(10)).readRateLimits() } as CodexRateReader
        }) else {
            // 沒有 Codex CLI：只讀本機紀錄，不啟動子程序。
            replaceReport(await collector.codexReport())
            return
        }
        guard networkAvailable() else {
            if !codexLiveStatus.isOfflineFailure { await recordCodexFailure(L10n.token("目前離線"), offline: true, generation: requestedGeneration) }
            return
        }
        let generation = codexPollGeneration
        let id = UUID()
        let task = Task { [weak self] in
            let result: Result<UsageSnapshot, Error>
            if Task.isCancelled { return }
            do { result = .success(try await reader()) } catch { result = .failure(error) }
            await self?.applyCodexPoll(result, generation: generation)
        }
        codexPollInFlight = (id, generation, task)
        await task.value
        if codexPollInFlight?.id == id { codexPollInFlight = nil }
    }

    /// 每次 await 返回後重新確認：同一代、未關閉、未停用、非測試模式，才採用結果。
    func applyCodexPoll(_ result: Result<UsageSnapshot, Error>, generation: Int) async {
        guard generation == codexPollGeneration, live, !dryRun, !demo, !backgroundStopped,
              agentPrefs.isEnabled(.codex) else { return }
        let at = Date()
        lastCodexPollAt = at
        switch result {
        case .success(let snapshot):
            codexPollOutcomeRevision += 1
            codexPollFailures = 0
            codexLiveStatus = .ok(at: at)
            replaceReport(UsageCollector.codexLiveReport(snapshot))
            observeCodexQuota(snapshot)
            // 新的官方資料：到期或可延期的定時嘗試立即評估，不等完整刷新。
            scheduleTimedResumeCheck()
            now = Date()
            // Rate-limit recovery should not wait for the next five-minute discovery pass.
            if shouldCheckCodexRecoveryOnPoll, snapshot.usageAllowed == true, planBook.active.contains(where: { $0.provider == .codex && $0.state == .waiting }) {
                Task { [weak self] in await self?.runEngine() }
            }
        case .failure(let error):
            if error is CancellationError { return }
            await recordCodexFailure(CodexPollPolicy.describe(error), offline: false, generation: generation)
        }
    }

    private func recordCodexFailure(_ message: String, offline: Bool, generation: Int) async {
        codexPollOutcomeRevision += 1
        lastCodexPollAt = Date()
        codexPollFailures += offline ? 0 : 1
        let lastSuccess: Date? = if case .ok(let at) = codexLiveStatus { at }
            else if case .failed(_, _, let previous, _) = codexLiveStatus { previous } else { nil }
        codexLiveStatus = .failed(message: message, at: Date(), lastSuccess: lastSuccess, offline: offline)
        let current = reports.first { $0.provider == .codex }
        if var snapshot = current?.state.snapshot {
            // 保留上次官方值與它的觀察時間供顯示，但標成已被失敗的查詢取代：不作為目前剩餘、提醒、摘要或續作依據。
            snapshot.supersededByFailedQuery = true
            replaceReport(ProviderReport(provider: .codex, state: .available(snapshot),
                                         note: L10n.token("即時查詢失敗（{0}），顯示 {1}的值，不是目前剩餘",
                                                          [message, ZhFormat.ago(snapshot.observedAt, now: Date())])))
        } else {
            let store = collector.codexStore
            let local = await Task.detached { store.latestRateLimitSnapshot() }.value
            guard generation == codexPollGeneration, agentPrefs.isEnabled(.codex), !backgroundStopped,
                  codexLiveStatusIsFailure else { return }
            if let local {
                replaceReport(ProviderReport(provider: .codex, state: .available(local),
                                             note: L10n.token("即時查詢失敗（{0}），顯示本機紀錄；本機紀錄不作為自動繼續依據", [message])))
            } else {
                replaceReport(ProviderReport(provider: .codex, state: .error(message: L10n.token("即時查詢失敗：{0}", [message]))))
            }
        }
        now = Date()
    }

    // MARK: 視窗、睡眠與網路

    /// 使用者打開選單列視窗：立即重讀 bridge 檔案，並以同一個 single-flight 查詢 Codex 額度。
    /// 不會向 Claude Code 送出任何請求；Claude 沒有新回報時仍顯示上次資料與時間。
    public func windowOpened() {
        guard live, !dryRun, !demo, !backgroundStopped else { return }
        refreshDispatchPolicy()
        // 出現與成為 key window 兩種通知、快速開關都只處理一次。以單調時間計算，不受系統時鐘調整影響。
        let uptime = ProcessInfo.processInfo.systemUptime
        if let last = lastWindowOpenUptime, uptime - last < Self.windowOpenDebounce, uptime >= last { return }
        lastWindowOpenUptime = uptime
        if agentPrefs.isEnabled(.claudeCode) { refreshClaudeBridge() }
        if agentPrefs.isEnabled(.antigravity) { refreshAntigravityBridge() }
        now = Date()
        if codexPollInFlight != nil { return }
        if let last = lastCodexPollAt, Date().timeIntervalSince(last) < Self.windowOpenDebounce, Date() >= last { return }
        Task { await requestCodexPoll(reason: .windowOpened) }
    }

    func handleSystemWillSleep() {
        systemAsleep = true
        timedTimerTask?.cancel()
        timedTimerTask = nil
        cancelCodexPolling()
    }

    func handleSystemDidWake() {
        guard systemAsleep else { return }
        systemAsleep = false
        codexPollFailures = 0
        // 網路通常在喚醒後幾秒才恢復。
        startCodexPolling(initialDelay: 5)
        // 睡眠中錯過的定時嘗試：喚醒後立即只查官方額度並評估（不先做完整掃描），不直接補送。
        Task { await quickTimedCheck() }
    }

    func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSystemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSystemDidWake() }
            },
        ]
    }

    func startNetworkMonitor() {
        let monitor = NetworkReachability { [weak self] in self?.networkBecameAvailable() }
        reachability = monitor
        networkAvailable = { [weak monitor] in monitor?.isSatisfied ?? true }
    }

    /// 網路恢復：離線期間的失敗不累積退避，立即再查一次。
    func networkBecameAvailable() {
        guard codexLiveStatus.isOfflineFailure else { return }
        // 有等待中的定時嘗試：只查官方額度再評估到期計畫，與計時器共用同一個單一執行的檢查。
        if hasWaitingTimedPlans { startTimedCheck(poll: true) } else { Task { await requestCodexPoll(reason: .wake) } }
    }

    public var codexLiveStatusText: String? {
        switch codexLiveStatus {
        case .idle: return nil
        case .off(let reason): return L10n.display(reason)
        case .ok(let at): return tr("每 30 秒查詢官方額度 · 上次成功 {0}", ZhFormat.ago(at, now: now))
        case .failed(let message, _, let last, _):
            return last.map { tr("查詢失敗：{0}（上次成功 {1}）", L10n.display(message), ZhFormat.ago($0, now: now)) }
                ?? tr("查詢失敗：{0}", L10n.display(message))
        }
    }

    public var codexLiveStatusIsFailure: Bool {
        if case .failed = codexLiveStatus { return true }
        return false
    }
}

/// NWPathMonitor 的主執行緒包裝。只判斷有無網路路徑，不連線任何主機。
@MainActor
final class NetworkReachability {
    private let monitor = NWPathMonitor()
    private(set) var isSatisfied = true

    init(onRestored: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let restored = ok && !self.isSatisfied
                    self.isSatisfied = ok
                    if restored { onRestored() }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "vibemeter.network"))
    }

    func stop() { monitor.cancel() }
}
