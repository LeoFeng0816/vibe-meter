import Foundation
import Testing
@testable import VibeMeterCore
@testable import VibeMeterUI

/// 第三輪審查：雙實例競逐、自己的進行中 turn、真正的生產排程（假 CLI、假時鐘、臨時工作階段）。
@MainActor
@Suite(.serialized) struct CodexTimedResumeRaceE2ETests {
    typealias Harness = CodexTimedResumeE2ETests.Harness
    let session = CodexTimedResumeE2ETests.sessionID

    private func baseState(stop: Int, reset: Int, allowed: Any = true, five: Double = 3, fiveReset: Int? = nil,
                           latest: [String: Any]? = nil) -> [String: Any] {
        ["account": "A", "allowed": allowed, "bucket": "codex", "five": five, "fiveReset": fiveReset ?? reset,
         "turn": latest ?? ["id": "stop-1", "status": "failed", "startedAt": stop - 20, "completedAt": stop,
                            "error": ["codexErrorInfo": "usageLimitExceeded"]],
         "model": "fixture-model", "rateError": false, "queueExit": 0, "queueStderr": "", "session": session]
    }

    /// 中止前後的官方觀察（時間戳記為中止前 30 秒與後 10 秒），寫入共享的帳本。
    private func seedLedger(_ h: Harness, app: AppModel, stop: Int, reset: Int) async throws {
        let client = CodexAppServerClient(binary: h.binary, timeout: .seconds(20))
        try h.set(baseState(stop: stop, reset: reset, five: 90))
        app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(stop - 30)) }))
        try h.set(baseState(stop: stop, reset: reset, allowed: false, five: 100))
        app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(stop + 10)) }))
    }

    /// 兩個已啟動的 App 程序（各自的 UserDefaults 實例與記憶體狀態），同一工作階段、不同官方錨點、同一週期，
    /// 都停在最後的送出前檢查後同時放行：整體最多一次 queue；之後重新啟動也不追加。
    @Test func twoRunningInstancesWithDifferentAnchorsSendAtMostOnce() async throws {
        let h = try Harness(scenario: .success)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = realNow - 300, reset = realNow - 60
        try h.writeRollout(stop: stop, subagent: false, model: true)
        let seeder = h.makeApp { Date() }
        try await seedLedger(h, app: seeder, stop: stop, reset: reset)
        seeder.stopBackgroundWork()

        func makeInstance() async throws -> AppModel {
            // 新的 UserDefaults 實例（同一個 suite）：模擬另一個已啟動的 App 程序。
            let defaults = try #require(UserDefaults(suiteName: h.suite))
            let app = AppModel(dryRun: false, defaults: defaults, paths: h.paths, claudeSettingsURL: h.root.appendingPathComponent("unused.json"),
                               startBackgroundWork: false, codexBinary: .some(h.binary), codexHome: h.root)
            h.apps.append(app)
            app.codexLivePolling = false
            try h.set(baseState(stop: stop, reset: reset, allowed: false, five: 100))
            await app.requestCodexPoll(reason: .refresh)
            return app
        }
        func plan(on app: AppModel, anchor: String, completed: Int) throws -> ResumePlan {
            let turn = CodexTurnSummary(id: anchor, status: "failed", errorInfo: "usageLimitExceeded",
                                        startedAt: Date(timeIntervalSince1970: Double(completed - 20)),
                                        completedAt: Date(timeIntervalSince1970: Double(completed)))
            let info = CodexSessionInfo(id: session, threadName: "fixture", cwd: h.root.path, startedAt: nil,
                                        lastActivity: Date(timeIntervalSince1970: Double(completed)), rolloutPath: "/x")
            let item = try #require(BlockedSessionDetector.codex(
                sessions: [info], latestTurns: [session: turn], snapshot: app.liveCodexSnapshot, now: Date(),
                evidence: [session: CodexBlockEvidence(turnModel: "fixture-model", creatorAccountHash: nil, liveAccountID: "A")],
                observations: app.codexObservations, timedResume: true, timedSessionBlocked: app.timedSessionBlockedCheck()).first)
            #expect(item.codex?.sessionAuthorization?.basis == .generalBucketTimed)
            var plan = try ResumePlan(provider: .codex, sessionID: item.sessionID, sessionTitle: item.title, cwd: item.cwd,
                                      blockedWindow: item.blockedWindow, expectedResetAt: item.resetsAt, origin: .autoDetected,
                                      createdAt: Date(), codex: item.codex)
            plan.state = .launching(startedAt: Date())
            app.planBook = ResumePlanBook(plans: [plan])
            return plan
        }
        // 兩個程序都先載入相同的空狀態，才各自偵測不同錨點。
        let a = try await makeInstance()
        let b = try await makeInstance()
        let planA = try plan(on: a, anchor: "stop-1", completed: stop)
        let planB = try plan(on: b, anchor: "stop-2", completed: stop + 5)
        let gateA = Pause<SessionPreflight>(), gateB = Pause<SessionPreflight>()
        var deliveries = 0
        let delivery: AppModel.StartDelivery = { plan, _ in
            #expect(plan.prompt == ResumePlan.timedAttemptPrompt)
            deliveries += 1
            return Task {}
        }
        let runA = Task { await a.execute(planA, authorization: a.authorization(for: .codex, automatic: true),
                                          checkPreflight: { _, _ in await gateA.suspend() }, startDelivery: delivery) }
        let runB = Task { await b.execute(planB, authorization: b.authorization(for: .codex, automatic: true),
                                          checkPreflight: { _, _ in await gateB.suspend() }, startDelivery: delivery) }
        #expect(await gateA.waitUntilSuspended())
        #expect(await gateB.waitUntilSuspended())
        gateA.release(with: .unchanged)
        gateB.release(with: .unchanged)
        await runA.value
        await runB.value
        #expect(deliveries == 1)

        // 重新啟動後，同一工作階段同週期的第三個錨點也不送（偵測時已被擋下，強行送出也被原子保留拒絕）。
        let c = try await makeInstance()
        let blockedNow = c.timedSessionBlockedCheck()(session, Date(timeIntervalSince1970: Double(reset)))
        #expect(blockedNow)
        let turn3 = CodexTurnSummary(id: "stop-3", status: "failed", errorInfo: "usageLimitExceeded", completedAt: Date(timeIntervalSince1970: Double(stop + 8)))
        let info3 = CodexSessionInfo(id: session, threadName: "fixture", cwd: h.root.path, startedAt: nil,
                                     lastActivity: Date(timeIntervalSince1970: Double(stop + 8)), rolloutPath: "/x")
        let item3 = BlockedSessionDetector.codex(sessions: [info3], latestTurns: [session: turn3], snapshot: c.liveCodexSnapshot, now: Date(),
                                                 evidence: [session: CodexBlockEvidence(turnModel: "fixture-model", creatorAccountHash: nil, liveAccountID: "A")],
                                                 observations: c.codexObservations, timedResume: true,
                                                 timedSessionBlocked: c.timedSessionBlockedCheck()).first
        #expect(item3?.codex?.sessionAuthorization == nil)
        #expect(deliveries == 1)
    }

    enum OtherInstanceChange: String, CaseIterable, Sendable {
        case none, automationOff, agentOff, timedOff, scopeChanged, cancelled, offThenOn, corrupt, missing
    }

    @Test(arguments: OtherInstanceChange.allCases)
    func anotherInstanceCanRevokeBeforeSynchronousQueue(_ change: OtherInstanceChange) async throws {
        let h = try Harness(scenario: .success)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = realNow - 300, reset = realNow + 60
        try h.writeRollout(stop: stop, subagent: false, model: true)
        var fixtureNow: Date?
        let b = h.makeApp { fixtureNow ?? Date() }
        b.codexLivePolling = false
        try await seedLedger(h, app: b, stop: stop, reset: reset)
        try h.set(baseState(stop: stop, reset: reset, allowed: false, five: 100))
        await b.refresh()
        let plan = try #require(b.planBook.active.first)
        #expect(plan.codex?.sessionAuthorization?.basis == .generalBucketTimed)
        let a = AppModel(dryRun: false, defaults: try #require(UserDefaults(suiteName: h.suite)), paths: h.paths,
                         claudeSettingsURL: h.root.appendingPathComponent("unused.json"), startBackgroundWork: false,
                         codexBinary: .some(h.binary), codexHome: h.root)
        h.apps.append(a)
        a.planBook = ResumePlanBook(plans: [plan])

        fixtureNow = Date(timeIntervalSince1970: Double(reset + 31))
        var restored = try #require(b.liveCodexSnapshot)
        restored.observedAt = try #require(fixtureNow)
        b.replaceReport(UsageCollector.codexLiveReport(restored))
        try h.set(baseState(stop: stop, reset: reset, fiveReset: reset + 4 * 3600))
        let gate = h.root.appendingPathComponent("dispatch-preflight-gate")
        let paused = h.root.appendingPathComponent("dispatch-preflight-paused")
        try Data().write(to: gate)
        let run = Task { await b.runTimedResumes() }
        defer { try? FileManager.default.removeItem(at: gate) }
        for _ in 0..<240 where !FileManager.default.fileExists(atPath: paused.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: paused.path) else {
            try FileManager.default.removeItem(at: gate)
            await run.value
            Issue.record("fake CLI did not reach the last preflight RPC")
            return
        }

        switch change {
        case .none: break
        case .automationOff: a.setAutoContinue(false)
        case .agentOff: a.setAgent(.codex, enabled: false)
        case .timedOff: a.setCodexTimedResume(false)
        case .scopeChanged:
            let scope = CodexContinuationSettings.Scope(sessionID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
                                                        accountID: "A", model: "fixture-model")
            a.setCodexScope(scope)
        case .cancelled:
            a.cancelPlan(plan.id)
            if case .cancelled = a.planBook.plan(plan.id)?.state {} else { Issue.record("cancellation was not recorded") }
            #expect(b.savePlans())
            if case .cancelled = b.planBook.plan(plan.id)?.state {} else { Issue.record("stale save lost cancellation") }
        case .offThenOn:
            a.setAutoContinue(false)
            a.setAutoContinue(true)
        case .corrupt:
            try Data("{}".utf8).write(to: h.paths.root.appendingPathComponent("codex-dispatch-policy.json"))
        case .missing:
            try FileManager.default.removeItem(at: h.paths.root.appendingPathComponent("codex-dispatch-policy.json"))
        }

        try FileManager.default.removeItem(at: gate)
        await run.value
        #expect(h.queued.count == (change == .none ? 1 : 0), "shared-policy result for \(change)")
        if change == .missing {
            let restarted = h.makeApp { Date() }
            #expect(L10n.display(restarted.banner ?? "", in: .en).contains("Shared continuation settings"))
            #expect(!FileManager.default.fileExists(atPath: h.paths.root.appendingPathComponent("codex-dispatch-policy.json").path))
        }
        if change == .cancelled {
            let saved = try VibeMeterJSON.decoder.decode(ResumePlanBook.self, from: Data(contentsOf: h.paths.resumePlans))
            if case .cancelled = saved.plan(plan.id)?.state {} else { Issue.record("cancelled plan was replaced on disk") }
        }
    }

    /// 自己的續作提示先出現進行中的 turn，之後同一 turn 因額度失敗（帶較晚的重設）：不得視為新的使用者工作而再付費重試。
    @Test func ownQueuedWorkInProgressOrCompletedIsNotNewUserWork() async throws {
        let h = try Harness(scenario: .success)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = realNow - 300, reset = realNow - 60
        try h.writeRollout(stop: stop, subagent: false, model: true)
        let app = h.makeApp { Date() }
        app.codexLivePolling = false
        try await seedLedger(h, app: app, stop: stop, reset: reset)
        try h.set(baseState(stop: stop, reset: reset, allowed: true, five: 3, fiveReset: realNow + 5 * 3600))
        await app.refresh()
        #expect(h.queued.count == 1)
        // 官方回報新 turn 進行中（自己的提示）。
        let started = Int(Date().timeIntervalSince1970) + 1
        try h.set(baseState(stop: stop, reset: reset, allowed: true, five: 3, fiveReset: realNow + 5 * 3600,
                            latest: ["id": "auto-1", "status": "inProgress", "startedAt": started]))
        await app.runEngine()
        #expect(timedEntry(h)?.userConfirmedAt == nil)
        // 自己的提示順利完成（官方 turn 沒有來源標記，completed 也不能證明是使用者的新工作）。
        try h.set(baseState(stop: stop, reset: reset, allowed: true, five: 3, fiveReset: realNow + 5 * 3600,
                            latest: ["id": "auto-1", "status": "completed", "startedAt": started, "completedAt": started + 1]))
        await app.refresh()
        #expect(timedEntry(h)?.userConfirmedAt == nil)
        // 之後同工作階段的另一個 turn 因額度失敗，官方給較晚的重設 R2 > R1；中止前後都有同帳戶觀察。
        try await Task.sleep(for: .seconds(2))
        let failedAt = Int(Date().timeIntervalSince1970)
        let failed: [String: Any] = ["id": "later-1", "status": "failed", "startedAt": failedAt - 1, "completedAt": failedAt,
                                     "error": ["codexErrorInfo": "usageLimitExceeded"]]
        try h.set(baseState(stop: stop, reset: reset, allowed: true, five: 90, fiveReset: realNow + 4 * 3600, latest: failed))
        let client = CodexAppServerClient(binary: h.binary, timeout: .seconds(20))
        app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(failedAt - 5)) }))
        try h.set(baseState(stop: stop, reset: reset, allowed: false, five: 100, fiveReset: realNow + 4 * 3600, latest: failed))
        let rollout = h.root.appendingPathComponent("sessions/rollout-\(session).jsonl")
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"turn_context","payload":{"turn_id":"later-1","model":"fixture-model"}}"# + "\n").utf8))
        try handle.close()
        await app.refresh()
        await app.refresh()
        let followUp = app.planBook.plans.first { $0.codex?.anchorTurnID == "later-1" }
        #expect(followUp != nil)
        #expect(followUp?.codex?.sessionAuthorization == nil)
        let gap = L10n.display(followUp?.codex?.evidenceGap ?? "", in: .zhHant)
        #expect(gap.contains("手動繼續"))
        #expect(h.queued.count == 1)
    }

    /// 手動 A 已開始但延遲完成，期間另一個 App 程序建立自動保留 B；A 完成後不得解除 B 的防付費重試抑制。
    @Test func lateCompletingManualSendDoesNotRearmAnotherInstancesReservation() async throws {
        let h = try Harness(scenario: .success)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = realNow - 300, reset = realNow - 60
        try h.writeRollout(stop: stop, subagent: false, model: true)
        let seeder = h.makeApp { Date() }
        try await seedLedger(h, app: seeder, stop: stop, reset: reset)
        seeder.stopBackgroundWork()
        func makeInstance() async throws -> AppModel {
            let defaults = try #require(UserDefaults(suiteName: h.suite))
            let app = AppModel(dryRun: false, defaults: defaults, paths: h.paths, claudeSettingsURL: h.root.appendingPathComponent("unused.json"),
                               startBackgroundWork: false, codexBinary: .some(h.binary), codexHome: h.root)
            h.apps.append(app)
            app.codexLivePolling = false
            try h.set(baseState(stop: stop, reset: reset, allowed: false, five: 100))
            await app.requestCodexPoll(reason: .refresh)
            return app
        }
        func plan(on app: AppModel, anchor: String, completed: Int) throws -> ResumePlan {
            let turn = CodexTurnSummary(id: anchor, status: "failed", errorInfo: "usageLimitExceeded",
                                        startedAt: Date(timeIntervalSince1970: Double(completed - 20)),
                                        completedAt: Date(timeIntervalSince1970: Double(completed)))
            let info = CodexSessionInfo(id: session, threadName: "fixture", cwd: h.root.path, startedAt: nil,
                                        lastActivity: Date(timeIntervalSince1970: Double(completed)), rolloutPath: "/x")
            let item = try #require(BlockedSessionDetector.codex(
                sessions: [info], latestTurns: [session: turn], snapshot: app.liveCodexSnapshot, now: Date(),
                evidence: [session: CodexBlockEvidence(turnModel: "fixture-model", creatorAccountHash: nil, liveAccountID: "A")],
                observations: app.codexObservations, timedResume: true, timedSessionBlocked: app.timedSessionBlockedCheck()).first)
            var plan = try ResumePlan(provider: .codex, sessionID: item.sessionID, sessionTitle: item.title, cwd: item.cwd,
                                      blockedWindow: item.blockedWindow, expectedResetAt: item.resetsAt, origin: .autoDetected,
                                      createdAt: Date(), codex: item.codex)
            plan.state = .launching(startedAt: Date())
            app.planBook = ResumePlanBook(plans: [plan])
            return plan
        }
        let a = try await makeInstance()
        let b = try await makeInstance()
        let planA = try plan(on: a, anchor: "stop-1", completed: stop)
        let planB = try plan(on: b, anchor: "stop-2", completed: stop + 5)
        #expect(planB.codex?.sessionAuthorization?.basis == .generalBucketTimed)
        // 手動 A：送出已開始，完成被延遲。
        let manualDone = Pause<Void>()
        var manualSends = 0, automaticSends = 0
        let manual = Task {
            await a.execute(planA, authorization: a.authorization(for: .codex, automatic: false),
                            checkPreflight: { _, _ in .unchanged }, startDelivery: { _, _ in
                                manualSends += 1
                                return Task { await manualDone.suspend() }
                            })
        }
        #expect(await manualDone.waitUntilSuspended())
        try await Task.sleep(for: .milliseconds(1100))
        // 另一個程序在 A 開始之後建立自動保留 B 並送出。
        await b.execute(planB, authorization: b.authorization(for: .codex, automatic: true),
                        checkPreflight: { _, _ in .unchanged }, startDelivery: { _, _ in automaticSends += 1; return Task {} })
        #expect(automaticSends == 1)
        manualDone.release(with: ())
        await manual.value
        #expect(manualSends == 1)
        let entry = timedEntry(h)
        #expect(entry?.anchorTurnID == "stop-2")
        #expect(entry?.userConfirmedAt == nil, "a manual send that started earlier must not re-arm B")
        #expect(CodexTimedSessionStore(directory: h.paths.root.appendingPathComponent("Codex Timed Sessions"))
            .blocks(sessionID: session, resetsAt: Date(timeIntervalSince1970: Double(reset) + 5 * 3600)))
    }

    /// 跨型態：一般桶定時嘗試已送出（尚未手動確認），之後同工作階段新的 429 出現精確模型桶與明確拒絕、
    /// 並在重設＋30 秒後官方恢復：嚴格路徑也不得再自動送出第二次。
    @Test func timedAttemptThenExactModelBucketDoesNotSendAgain() async throws {
        let h = try Harness(scenario: .success)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = realNow - 300, reset = realNow - 60
        try h.writeRollout(stop: stop, subagent: false, model: true)
        let app = h.makeApp { Date() }
        app.codexLivePolling = false
        try await seedLedger(h, app: app, stop: stop, reset: reset)
        try h.set(baseState(stop: stop, reset: reset, allowed: true, five: 3, fiveReset: realNow + 5 * 3600))
        await app.refresh()
        try #require(h.queued.count == 1, "Initial timed attempt: \(app.planBook.plans.map { "\($0.state) \(L10n.display($0.note ?? ""))" })")

        // 新的中止 turn（官方形狀 turn_context 帶原模型），官方回報精確模型桶。
        let rollout = h.root.appendingPathComponent("sessions/rollout-\(session).jsonl")
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"turn_context","payload":{"turn_id":"strict-2","model":"fixture-model"}}"# + "\n").utf8))
        try handle.close()
        try await Task.sleep(for: .seconds(2))
        let failedAt = Int(Date().timeIntervalSince1970) - 1
        // 新週期的官方重設：在拒絕觀察時仍是未來時間。
        let r2 = failedAt + 6
        let failed: [String: Any] = ["id": "strict-2", "status": "failed", "startedAt": failedAt - 20, "completedAt": failedAt,
                                     "error": ["codexErrorInfo": "usageLimitExceeded"]]
        let modelBucket: [[String: Any]] = [["limitId": "m-meter", "normalModelSlug": "fixture-model"]]
        func state(allowed: Any, five: Double, fiveReset: Int) -> [String: Any] {
            var s = baseState(stop: stop, reset: reset, allowed: allowed, five: five, fiveReset: fiveReset, latest: failed)
            s["extraBuckets"] = modelBucket
            return s
        }
        let client = CodexAppServerClient(binary: h.binary, timeout: .seconds(20))
        try h.set(state(allowed: true, five: 90, fiveReset: r2))
        app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(failedAt - 5)) }))
        try h.set(state(allowed: false, five: 100, fiveReset: r2))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rollout.path)
        await app.refresh()
        let followUp = try #require(app.planBook.plans.first { $0.codex?.anchorTurnID == "strict-2" })
        #expect(followUp.codex?.sessionAuthorization == nil, "strict basis must honour the session reservation")
        let gap = L10n.display(followUp.codex?.evidenceGap ?? "", in: .zhHant)
        #expect(gap.contains("手動繼續"))
        let control = try #require(BlockedSessionDetector.codex(
            sessions: app.codexSessions, latestTurns: app.codexTurns, snapshot: app.liveCodexSnapshot, now: Date(),
            evidence: [session: CodexBlockEvidence(turnModel: "fixture-model", creatorAccountHash: nil, liveAccountID: "A")],
            observations: app.codexObservations).first)
        #expect(control.codex?.sessionAuthorization?.basis == .modelBucket)
        var stale = try ResumePlan(provider: .codex, sessionID: session, sessionTitle: "fixture", cwd: h.root.path,
                                   blockedWindow: control.blockedWindow, expectedResetAt: control.resetsAt, codex: control.codex)
        stale.state = .launching(startedAt: Date())
        let commit = stale
        app.planBook = ResumePlanBook(plans: [commit])
        await app.execute(commit, authorization: app.authorization(for: .codex, automatic: true),
                          checkPreflight: { _, _ in .unchanged })
        #expect(h.queued.count == 1)
    }

    private func timedEntry(_ h: Harness) -> CodexTimedDispatchLedger.Entry? {
        CodexTimedSessionStore(directory: h.paths.root.appendingPathComponent("Codex Timed Sessions")).entry(sessionID: session)
    }

    /// 真正的生產排程（睡眠計時器→額度查詢→送出前檢查），完整刷新卡在與到期計畫無關的慢查詢上：
    /// 重設＋29.x 秒不送；到＋30 秒後不需放行完整刷新就恰好送一次；放行後也不重送。
    @Test func productionSchedulerSendsOnceWhileFullRefreshIsBlocked() async throws {
        let h = try Harness(scenario: .success)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = realNow - 300, reset = realNow + 60
        try h.writeRollout(stop: stop, subagent: false, model: true)
        // 五個無關的工作階段，完整掃描會依序查它們的最新 turn。
        for i in 0..<5 {
            let other = String(format: "%08x-cccc-4ddd-8eee-ffffffffffff", 0x1000_0000 + i)
            let line = #"{"type":"session_meta","payload":{"id":"\#(other)","cwd":"\#(h.root.path)","source":"cli"}}"# + "\n"
            let file = h.root.appendingPathComponent("sessions/rollout-\(other).jsonl")
            try line.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(realNow - 600))], ofItemAtPath: file.path)
        }
        final class Offset: @unchecked Sendable { var value: TimeInterval = 0 }
        let offset = Offset()
        let app = h.makeApp { Date().addingTimeInterval(offset.value) }
        app.codexLivePolling = false
        try await seedLedger(h, app: app, stop: stop, reset: reset)
        try h.set(baseState(stop: stop, reset: reset, allowed: false, five: 100))
        await app.refresh()
        let plan = try #require(app.planBook.active.first)
        let due = try #require(app.codexTimedDue(for: plan))
        #expect(plan.state == .waiting)

        // 時鐘移到到期前 1.5 秒，額度已重設；啟用生產排程，並讓完整刷新卡住。
        offset.value = due.timeIntervalSince(Date()) - 1.5
        try h.set(baseState(stop: stop, reset: reset, allowed: true, five: 3, fiveReset: realNow + 5 * 3600))
        try Data().write(to: h.root.appendingPathComponent("gate"))
        app.schedulesTimedTimer = true
        let blocked = Task { await app.refresh() }
        try await Task.sleep(for: .milliseconds(700))
        #expect(h.queued.isEmpty, "before reset + 30 s")
        for _ in 0..<300 where h.queued.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(h.queued.count == 1, "the scheduler must send without waiting for the blocked full refresh")
        #expect(FileManager.default.fileExists(atPath: h.root.appendingPathComponent("gate").path))
        try FileManager.default.removeItem(at: h.root.appendingPathComponent("gate"))
        await blocked.value
        await app.refresh()
        #expect(h.queued.count == 1)
        #expect(h.messages == [ResumePlan.timedAttemptPrompt])
        app.schedulesTimedTimer = false
    }
}
