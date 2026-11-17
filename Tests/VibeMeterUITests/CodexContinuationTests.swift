import Foundation
import Testing
import VibeMeterCore
@testable import VibeMeterUI

@MainActor
@Suite struct CodexContinuationTests {
    private let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let modelID = "fixture-model"
    private let anchor = "fixture-stop"

    private func snapshot(_ now: Date, account: String = "account-a", allowed: Bool, reset: Date) -> UsageSnapshot {
        let windows = [UsageWindow(kind: .fiveHour, usedPercent: allowed ? 12 : 100, resetsAt: reset)]
        return UsageSnapshot(provider: .codex, windows: windows, observedAt: now, source: .codexAppServer,
                             accountID: account, usageAllowed: allowed,
                             buckets: [LimitBucket(limitID: "fixture", modelSlug: modelID, windows: windows, limitReachedType: nil)])
    }

    private func fixture(at now: Date) -> (session: CodexSessionInfo, turn: CodexTurnSummary, before: UsageSnapshot,
                                            denied: UsageSnapshot, recovered: UsageSnapshot, evidence: [String: CodexBlockEvidence]) {
        let stop = now.addingTimeInterval(-1500)
        let session = CodexSessionInfo(id: sessionID, threadName: "fixture", cwd: "/tmp", startedAt: nil,
                                       lastActivity: stop, rolloutPath: "/fixture")
        let turn = CodexTurnSummary(id: anchor, status: "failed", errorInfo: "usageLimitExceeded", completedAt: stop)
        let oldReset = now.addingTimeInterval(-600)
        return (session, turn, snapshot(stop.addingTimeInterval(-60), allowed: true, reset: oldReset),
                snapshot(stop.addingTimeInterval(60), allowed: false, reset: oldReset),
                snapshot(now, allowed: true, reset: now.addingTimeInterval(5 * 3600)),
                [sessionID: CodexBlockEvidence(turnModel: modelID, creatorAccountHash: nil, liveAccountID: "account-a")])
    }

    private func makePlan(_ item: BlockedSession, now: Date) throws -> ResumePlan {
        try ResumePlan(provider: .codex, sessionID: item.sessionID, sessionTitle: item.title, cwd: item.cwd,
                       blockedWindow: item.blockedWindow, expectedResetAt: item.resetsAt,
                       origin: .autoDetected, createdAt: now, codex: item.codex)
    }

    @Test func defaultAutomationWakesAfterObservedDenialAndRestartEvenWhenDiscoveredAfterRecovery() async throws {
        let now = Date()
        let fixture = fixture(at: now)
        var observations = CodexQuotaObservations()
        observations.observe(fixture.before, now: fixture.before.observedAt)
        observations.observe(fixture.denied, now: fixture.denied.observedAt)
        let bytes = try VibeMeterJSON.encoder.encode(observations)
        let app = AppModel(preview: ())
        app.codexObservations = try VibeMeterJSON.decoder.decode(CodexQuotaObservations.self, from: bytes)
        app.codexObservations.observe(fixture.recovered, now: now)
        app.now = now
        app.codexSessions = [fixture.session]
        app.reports = [ProviderReport(provider: .codex, state: .available(fixture.recovered))]
        var checks = 0
        await app.inspectCodexThreads(readTurn: { id in
            checks += 1
            #expect(id == fixture.session.id)
            return fixture.turn
        })
        #expect(checks == 1)
        let items = BlockedSessionDetector.codex(sessions: app.codexSessions, latestTurns: app.codexTurns,
                                                  snapshot: fixture.recovered, now: now, evidence: fixture.evidence,
                                                  observations: app.codexObservations, continuation: app.codexContinuation)
        let item = try #require(items.first)
        let plan = try makePlan(item, now: now)
        #expect(plan.codex?.verifiedAccountAndModelAtBlock != true)
        #expect(plan.state == .waiting)
        try app.planBook.add(plan)
        var deliveries = 0
        let delivery: AppModel.StartDelivery = { p, via in
            deliveries += 1
            #expect(p.codex?.anchorTurnID == self.anchor)
            #expect(via == .codexQueueResume)
            #expect(ResumeExecutor.queueArguments(p, wakeUnloaded: true).prefix(2).elementsEqual(["queue", "--resume"]))
            return Task { throw ResumeExecutor.Failure.queuedWakeUnconfirmed }
        }
        await app.runEngine(codexPreflight: { _, _ in .unchanged }, codexDelivery: delivery)
        await app.runEngine(codexPreflight: { _, _ in .unchanged }, codexDelivery: delivery)
        #expect(deliveries == 1)
        let queued = try #require(app.planBook.plan(plan.id))
        if case .launched = queued.state {} else { Issue.record("queue acceptance must not claim resumption") }
        #expect(queued.note == L10n.token("已排入 Codex 佇列，CLI 回報喚醒未獲確認"))
        #expect(!LaunchDecision.hasNewCodexActivity(queued, latest: fixture.turn))
        let newTurn = CodexTurnSummary(id: "new", status: "inProgress", startedAt: Date())
        #expect(LaunchDecision.hasNewCodexActivity(queued, latest: newTurn))
    }

    @Test func noWitnessWrongScopeAndObservedAccountSwitchCannotArm() throws {
        let now = Date()
        let fixture = fixture(at: now)
        var observations = CodexQuotaObservations()
        observations.observe(fixture.before, now: fixture.before.observedAt)
        let scope = CodexContinuationSettings.Scope(sessionID: sessionID, accountID: "account-a", model: modelID)
        func arm(_ settings: CodexContinuationSettings, snapshot: UsageSnapshot? = nil) throws -> ResumePlan {
            let blocked = BlockedSessionDetector.codex(sessions: [fixture.session], latestTurns: [sessionID: fixture.turn],
                                                        snapshot: snapshot ?? fixture.recovered, now: now, evidence: fixture.evidence,
                                                        observations: observations, continuation: settings)
            return try makePlan(#require(blocked.first), now: now)
        }
        #expect(try arm(.init()).codex?.sessionAuthorization == nil)
        observations.observe(fixture.denied, now: fixture.denied.observedAt)
        #expect(try arm(.init(mode: .scoped)).codex?.sessionAuthorization == nil)
        let otherScope = CodexContinuationSettings.Scope(sessionID: sessionID, accountID: "account-b", model: modelID)
        #expect(try arm(.init(mode: .scoped, scope: otherScope)).codex?.sessionAuthorization == nil)
        let validSettings = CodexContinuationSettings(mode: .scoped, scope: scope)
        let persisted = try VibeMeterJSON.encoder.encode(validSettings)
        #expect(try VibeMeterJSON.decoder.decode(CodexContinuationSettings.self, from: persisted) == validSettings)
        #expect(try arm(validSettings).codex?.sessionAuthorization != nil)

        let other = snapshot(now.addingTimeInterval(-120), account: "account-b", allowed: true, reset: now.addingTimeInterval(6000))
        observations.observe(other, now: other.observedAt)
        observations.observe(fixture.recovered, now: now)
        #expect(try arm(.init()).codex?.sessionAuthorization == nil)
    }

    @Test func optionalSchemaFieldsCannotAuthorizeWake() throws {
        let now = Date()
        let f = fixture(at: now)
        var observations = CodexQuotaObservations()
        observations.observe(f.before, now: f.before.observedAt)
        var deniedWithoutModel = f.denied
        deniedWithoutModel.buckets?[0].modelSlug = nil
        observations.observe(deniedWithoutModel, now: deniedWithoutModel.observedAt)
        func planFor(_ snapshot: UsageSnapshot) throws -> ResumePlan {
            let item = try #require(BlockedSessionDetector.codex(
                sessions: [f.session], latestTurns: [sessionID: f.turn], snapshot: snapshot, now: now,
                evidence: f.evidence, observations: observations).first)
            return try makePlan(item, now: now)
        }
        #expect(try planFor(f.recovered).codex?.sessionAuthorization == nil)
        observations = CodexQuotaObservations()
        observations.observe(f.before, now: f.before.observedAt)
        observations.observe(f.denied, now: f.denied.observedAt)
        var noAccount = f.recovered
        noAccount.accountID = nil
        #expect(try planFor(noAccount).codex?.sessionAuthorization == nil)
        let plan = try planFor(f.recovered)
        var noPermission = f.recovered
        noPermission.usageAllowed = nil
        #expect(RestoreDetector.codexDecision(plan, snapshot: noPermission, now: now) == .notYet)
        var noCurrentModel = f.recovered
        noCurrentModel.buckets?[0].modelSlug = nil
        #expect(RestoreDetector.codexDecision(plan, snapshot: noCurrentModel, now: now) == .notYet)
    }

    @Test func scopeRevocationDuringPreflightCannotSend() async throws {
        let now = Date()
        let f = fixture(at: now)
        let app = AppModel(preview: ())
        app.now = now
        app.codexObservations.observe(f.before, now: f.before.observedAt)
        app.codexObservations.observe(f.denied, now: f.denied.observedAt)
        let scope = CodexContinuationSettings.Scope(sessionID: sessionID, accountID: "account-a", model: modelID)
        app.setCodexScope(scope)
        let item = try #require(BlockedSessionDetector.codex(
            sessions: [f.session], latestTurns: [sessionID: f.turn], snapshot: f.recovered, now: now,
            evidence: f.evidence, observations: app.codexObservations, continuation: app.codexContinuation).first)
        try app.planBook.add(makePlan(item, now: now))
        app.reports = [ProviderReport(provider: .codex, state: .available(f.recovered))]
        let pause = Pause<SessionPreflight>()
        let execution = Task {
            await app.runEngine(codexPreflight: { _, _ in await pause.suspend() }, codexDelivery: { _, _ in
                Issue.record("revoked scoped send was started")
                return Task {}
            })
        }
        guard await pause.waitUntilSuspended() else {
            Issue.record("preflight did not start")
            pause.release(with: .unknown("fixture timeout"))
            return
        }
        app.clearCodexScope()
        pause.release(with: .unchanged)
        await execution.value
        if case .needsConfirmation? = app.planBook.active.first?.state {} else { Issue.record("revocation must be visible") }
    }
}
