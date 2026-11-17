import Darwin
import Foundation
import Testing
import VibeMeterCore
@testable import VibeMeterUI

/// 跨執行緒計數（讀取替身在主執行緒以外執行）。
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _offMain: [Bool] = []
    private var _sleeps: [Duration] = []
    func call(offMain: Bool) { lock.withLock { _calls += 1; _offMain.append(offMain) } }
    func sleep(_ d: Duration) { lock.withLock { _sleeps.append(d) } }
    var calls: Int { lock.withLock { _calls } }
    var offMain: [Bool] { lock.withLock { _offMain } }
    var sleeps: [Duration] { lock.withLock { _sleeps } }
}

@MainActor
@Suite(.serialized) struct CodexPollingTests {
    private func makeModel() throws -> (AppModel, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-poll-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "vibemeter-poll-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = AppModel(dryRun: false, defaults: defaults, paths: VibeMeterPaths(root: root),
                             claudeSettingsURL: root.appendingPathComponent("settings.json"),
                             startBackgroundWork: false, codexBinary: .some(nil),
                             codexHome: root.appendingPathComponent("codex"))
        return (model, {
            model.stopBackgroundWork()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        })
    }

    private func snapshot(_ used: Double) -> UsageSnapshot {
        UsageSnapshot(provider: .codex, windows: [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: Date().addingTimeInterval(3600))],
                      observedAt: Date(), source: .codexAppServer, accountID: "acct", usageAllowed: true)
    }

    @Test func overlappingTriggersShareOneQueryAndReadOffMain() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let log = CallLog()
        let gate = Pause<Void>()
        model.codexRateReader = { [snapshot = snapshot(42)] in
            log.call(offMain: pthread_main_np() == 0)
            await gate.suspend()
            return snapshot
        }
        let first = Task { await model.requestCodexPoll(reason: .timer) }
        guard await gate.waitUntilSuspended() else { Issue.record("reader never started"); gate.release(with: ()); return }
        // 視窗開關、手動刷新、計時器同時要求。
        model.windowOpened()
        model.windowOpened()
        let second = Task { await model.requestCodexPoll(reason: .refresh) }
        let third = Task { await model.requestCodexPoll(reason: .windowOpened) }
        try await Task.sleep(for: .milliseconds(50))
        gate.release(with: ())
        await first.value; await second.value; await third.value
        #expect(log.calls == 1)
        #expect(log.offMain == [true])
        #expect(model.reports.first { $0.provider == .codex }?.state.snapshot?.window(.fiveHour)?.usedPercent == 42)
        if case .ok = model.codexLiveStatus {} else { Issue.record("expected ok status") }
        // 剛查過：再次開視窗不會立刻再查。
        model.windowOpened()
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.calls == 1)
    }

    @Test func disablingCodexWhileInFlightDiscardsTheResult() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let gate = Pause<Void>()
        model.codexRateReader = { [snapshot = snapshot(77)] in
            await gate.suspend()
            return snapshot
        }
        let poll = Task { await model.requestCodexPoll(reason: .timer) }
        guard await gate.waitUntilSuspended() else { Issue.record("reader never started"); gate.release(with: ()); return }
        model.setAgent(.codex, enabled: false)
        gate.release(with: ())
        await poll.value
        #expect(model.reports.first { $0.provider == .codex }?.state.snapshot == nil)
        #expect(model.lastCodexPollAt == nil)
    }

    @Test func multipleRequestsDrainOneCancelledReaderBeforeStartingReplacement() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let log = CallLog()
        let gate = Pause<Void>()
        model.codexRateReader = { [first = snapshot(80), second = snapshot(15)] in
            log.call(offMain: true)
            if log.calls == 1 {
                await gate.suspend()
                return first
            }
            try await Task.sleep(for: .milliseconds(100))
            return second
        }
        let first = Task { await model.requestCodexPoll(reason: .refresh) }
        guard await gate.waitUntilSuspended() else { gate.release(with: ()); Issue.record("reader did not start"); return }
        model.cancelCodexPolling()
        let second = Task { await model.requestCodexPoll(reason: .refresh) }
        let third = Task { await model.requestCodexPoll(reason: .windowOpened) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.calls == 1)
        gate.release(with: ())
        await first.value
        await second.value
        await third.value
        #expect(log.calls == 2)
        #expect(model.liveCodexSnapshot?.window(.fiveHour)?.usedPercent == 15)
    }

    @Test func failureKeepsLastOfficialValueAndBacksOff() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let fail = CallLog()
        model.codexRateReader = { [snapshot = snapshot(30)] in
            if fail.calls > 0 { fail.call(offMain: true); throw CodexAppServerError.timeout }
            fail.call(offMain: true)
            return snapshot
        }
        await model.requestCodexPoll(reason: .timer)
        #expect(model.codexPollDelay == 30)
        await model.requestCodexPoll(reason: .timer)
        await model.requestCodexPoll(reason: .timer)
        let report = try #require(model.reports.first { $0.provider == .codex })
        #expect(report.state.snapshot?.window(.fiveHour)?.usedPercent == 30)   // 上次官方值保留
        #expect(L10n.display(report.note ?? "", in: .zhHant).contains("不是目前剩餘"))
        #expect(model.codexLiveStatusIsFailure)
        #expect(model.codexPollDelay == 120)
        if case .failed(_, _, let lastSuccess, _) = model.codexLiveStatus { #expect(lastSuccess != nil) }
    }

    @Test func offlineWindowOpensAreDebouncedAndNetworkRestoreQueriesOnce() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let log = CallLog()
        model.codexRateReader = { [snapshot = snapshot(4)] in log.call(offMain: true); return snapshot }
        var online = false
        model.networkAvailable = { online }
        for _ in 0..<6 { model.windowOpened() }   // 出現與 key window 通知、快速開關
        try await Task.sleep(for: .milliseconds(80))
        #expect(log.calls == 0)
        #expect(model.codexLiveStatus.isOfflineFailure)
        let firstFailure = model.codexLiveStatus
        model.lastWindowOpenUptime = nil
        model.windowOpened()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.codexLiveStatus == firstFailure)   // 離線期間不重複記錄失敗
        online = true
        model.networkBecameAvailable()
        for _ in 0..<40 where log.calls == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(log.calls == 1)
        if case .ok = model.codexLiveStatus {} else { Issue.record("network restore should query again") }
        model.networkBecameAvailable()   // 已恢復：不再重查
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.calls == 1)
    }

    @Test func offlineSkipsTheQuery() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let log = CallLog()
        model.codexRateReader = { [snapshot = snapshot(1)] in log.call(offMain: true); return snapshot }
        model.networkAvailable = { false }
        await model.requestCodexPoll(reason: .timer)
        #expect(log.calls == 0)
        #expect(model.codexLiveStatusIsFailure)
        #expect(model.codexPollDelay == 30)   // 離線不累積退避
    }

    @Test func timerCadenceSleepWakeAndToggle() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let log = CallLog()
        let ticker = Ticker()
        defer { ticker.releaseAll() }
        model.codexRateReader = { [snapshot = snapshot(5)] in log.call(offMain: true); return snapshot }
        model.codexPollSleep = { duration in
            log.sleep(duration)
            await ticker.sleep()
            try Task.checkCancellation()
        }
        model.startCodexPolling()
        #expect(await ticker.waitForSleeper())
        #expect(log.calls == 1 && log.sleeps == [.seconds(30)])
        ticker.advance()
        #expect(await ticker.waitForSleeper())
        #expect(log.calls == 2 && log.sleeps == [.seconds(30), .seconds(30)])

        // 睡眠：取消計時器、作廢查詢；睡眠中不查詢。
        model.handleSystemWillSleep()
        ticker.advance()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.codexPollTask == nil && log.calls == 2)
        await model.requestCodexPoll(reason: .timer)
        model.windowOpened()
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.calls == 2)

        // 喚醒：先等 5 秒再查，之後回到 30 秒。
        model.handleSystemDidWake()
        #expect(await ticker.waitForSleeper())
        #expect(log.sleeps.last == .seconds(5) && log.calls == 2)
        ticker.advance()
        #expect(await ticker.waitForSleeper())
        #expect(log.calls == 3 && log.sleeps.last == .seconds(30))

        // 關閉 30 秒查詢：停止計時器並顯示已關閉。
        model.setCodexLivePolling(false)
        ticker.releaseAll()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.codexPollTask == nil && log.calls == 3)
        if case .off = model.codexLiveStatus {} else { Issue.record("expected off status") }
    }

    @Test func nonLiveModelsHaveNoSideEffects() async throws {
        let log = CallLog()
        let reader: CodexRateReader = { log.call(offMain: true); throw CodexAppServerError.timeout }
        for model in [AppModel(preview: ()), AppModel.sample(now: Date(), demo: true)] {
            model.codexRateReader = reader
            model.windowOpened()
            await model.requestCodexPoll(reason: .timer)
            model.startCodexPolling()
            #expect(model.codexPollTask == nil)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-dry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "vibemeter-dry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dry = AppModel(dryRun: true, defaults: defaults, paths: VibeMeterPaths(root: root),
                           claudeSettingsURL: root.appendingPathComponent("settings.json"), startBackgroundWork: false)
        dry.codexRateReader = reader
        dry.windowOpened()
        await dry.requestCodexPoll(reason: .timer)
        dry.startCodexPolling()
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.calls == 0)
        #expect(dry.codexPollTask == nil)
    }

    @Test func refreshRequestsCoalesceIntoOneFollowUp() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let log = CallLog()
        let gate = Pause<Void>()
        model.setAgent(.claudeCode, enabled: false)
        model.setAgent(.antigravity, enabled: false)
        model.setAgent(.cursor, enabled: false)
        model.codexRateReader = { [snapshot = snapshot(9)] in
            log.call(offMain: true)
            if log.calls == 1 { await gate.suspend() }
            return snapshot
        }
        let first = Task { await model.refresh() }
        guard await gate.waitUntilSuspended() else { Issue.record("refresh never queried"); gate.release(with: ()); return }
        for _ in 0..<5 { await model.refresh() }   // 執行中的重複要求只記一次
        #expect(model.refreshPending)
        gate.release(with: ())
        await first.value
        for _ in 0..<40 where model.isRefreshing || model.refreshPending { try await Task.sleep(for: .milliseconds(25)) }
        #expect(log.calls == 2)
    }
}

/// 假時鐘：每次 sleep 都停住，直到測試呼叫 advance。
@MainActor
final class Ticker {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep() async { await withCheckedContinuation { waiting.append($0) } }

    func advance() { if !waiting.isEmpty { waiting.removeFirst().resume() } }

    func releaseAll() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }

    func waitForSleeper() async -> Bool {
        for _ in 0..<80 {
            if !waiting.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

@MainActor
@Suite struct ClaudeNativeIsolationTests {
    @Test func dryRunNeverReadsClaudeSettingsOrBridgeSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-native-dry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try Data(#"{"autoContinueAtUsageLimit":false}"#.utf8).write(to: settings)
        let paths = VibeMeterPaths(root: root.appendingPathComponent("meter"))
        try ClaudeBridgeStore(paths: paths).recordStatusLine(Data(#"{"session_id":"dddddddd-1111-4222-8333-944455556666","version":"2.1.100"}"#.utf8))
        let suite = "vibemeter-native-dry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dry = AppModel(dryRun: true, defaults: defaults, paths: paths, claudeSettingsURL: settings, startBackgroundWork: false)
        #expect(dry.claudeNativeUserSetting == .unset)
        #expect(dry.claudeReportedVersion == nil)
        let live = AppModel(dryRun: false, defaults: defaults, paths: paths, claudeSettingsURL: settings,
                            startBackgroundWork: false, codexBinary: .some(nil), codexHome: root.appendingPathComponent("codex"))
        defer { live.stopBackgroundWork() }
        #expect(live.claudeNativeUserSetting == .off)
        #expect(live.claudeReportedVersion == "2.1.100")
    }
}
