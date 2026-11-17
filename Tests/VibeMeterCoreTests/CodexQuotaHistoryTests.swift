import Foundation
import Testing
@testable import VibeMeterCore

@Suite struct CodexQuotaHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)
    private let model = "fixture-model"
    private let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    private func sample(_ time: Date, reset: Date, allowed: Bool?, account: String? = "account-a",
                        limitID: String = "specific-bucket", slug: String? = "fixture-model") -> UsageSnapshot {
        let windows = [UsageWindow(kind: .weekly, usedPercent: allowed == true ? 10 : 100, resetsAt: reset)]
        return UsageSnapshot(provider: .codex, windows: windows, observedAt: time, source: .codexAppServer,
                             accountID: account, usageAllowed: allowed,
                             buckets: [LimitBucket(limitID: limitID, modelSlug: slug, windows: windows, limitReachedType: nil)])
    }

    @Test func weeklyWitnessSurvivesContinuousPollingAndRestart() throws {
        let reset = start.addingTimeInterval(6 * 86400)
        let stop = start.addingTimeInterval(60)
        let turn = CodexTurnSummary(id: "failed", status: "failed", errorInfo: "usageLimitExceeded", completedAt: stop)
        var ledger = CodexQuotaObservations()
        ledger.observe(sample(start, reset: reset, allowed: true), now: start)
        for minute in 1...500 {
            let time = start.addingTimeInterval(Double(minute * 60))
            ledger.observe(sample(time, reset: reset, allowed: false), now: time)
        }
        #expect(ledger.denialCount == 1)
        let restoredAt = reset.addingTimeInterval(120)
        let recovered = sample(restoredAt, reset: reset.addingTimeInterval(7 * 86400), allowed: true)
        var reloaded = try VibeMeterJSON.decoder.decode(CodexQuotaObservations.self, from: VibeMeterJSON.encoder.encode(ledger))
        reloaded.observe(recovered, now: restoredAt)
        let result = reloaded.bind(sessionID: session, turn: turn, model: model, snapshot: recovered, now: restoredAt, settings: .init())
        let authorization = try result.get()
        #expect(reloaded.authorizes(authorization))
        let blocked = try ResumePlan(provider: .codex, sessionID: session, sessionTitle: "fixture", cwd: "/tmp",
                                     blockedWindow: .weekly, expectedResetAt: reset, codex: CodexResumeContext(
                                        accountID: nil, anchorTurnID: turn.id, verifiedLimitFailure: true, modelAtBlock: model))
        var plan = blocked
        plan.codex?.sessionAuthorization = authorization
        #expect(RestoreDetector.codexDecision(plan, snapshot: recovered, now: restoredAt) == .restored)
        var changedBucket = recovered
        changedBucket.buckets?[0].limitID = "another-meter"
        #expect(RestoreDetector.codexDecision(plan, snapshot: changedBucket, now: restoredAt) != .restored)
        var spendControl = recovered
        spendControl.buckets?[0].spendControlReached = true
        #expect(RestoreDetector.codexDecision(plan, snapshot: spendControl, now: restoredAt) == .notYet)
    }

    @Test func modelLessDefaultAndConflictingBucketsNeverAuthorize() throws {
        let data = Data(#"{"rateLimits":{"limitId":"codex","normalModelSlug":null},"rateLimitsByLimitId":null,"ordinaryUsageAllowed":true,"accountId":"fixture"}"#.utf8)
        let general = try CodexRateLimitParser.parseAppServerResult(data, observedAt: start)
        #expect(general.buckets?.first?.limitID == "codex")
        #expect(general.quotaBucket(forModel: model) == nil)
        let inconsistent = Data(#"{"rateLimits":{"limitId":"codex"},"rateLimitsByLimitId":{"alias":{"limitId":"other","normalModelSlug":"fixture-model"}}}"#.utf8)
        let parsed = try CodexRateLimitParser.parseAppServerResult(inconsistent, observedAt: start)
        #expect(parsed.quotaBucket(forModel: model) == nil)
    }

    @Test func staleOrUntrustedLedgerCannotArm() throws {
        let reset = start.addingTimeInterval(6 * 86400)
        let stopped = start.addingTimeInterval(60)
        let turn = CodexTurnSummary(id: "failed", status: "failed", errorInfo: "usageLimitExceeded",
                                    startedAt: stopped.addingTimeInterval(-20), completedAt: stopped)
        func bind(_ ledger: CodexQuotaObservations, _ snapshot: UsageSnapshot, _ turn: CodexTurnSummary) -> Bool {
            (try? ledger.bind(sessionID: session, turn: turn, model: model, snapshot: snapshot,
                              now: snapshot.observedAt, settings: .init()).get()) != nil
        }
        var ledger = CodexQuotaObservations()
        let before = sample(start, reset: reset, allowed: true)
        ledger.observe(before, now: before.observedAt)
        let late = sample(stopped.addingTimeInterval(121), reset: reset, allowed: false)
        ledger.observe(late, now: late.observedAt)
        #expect(!bind(ledger, late, turn))
        let legacy = try VibeMeterJSON.decoder.decode(CodexQuotaObservations.self, from: Data(#"{"version":2,"denials":[]}"#.utf8))
        #expect(!bind(legacy, late, turn))
        let valid = sample(stopped.addingTimeInterval(10), reset: reset, allowed: false)
        var newer = CodexQuotaObservations()
        newer.observe(before, now: before.observedAt)
        newer.observe(valid, now: valid.observedAt)
        #expect(bind(newer, valid, turn))
        let switched = sample(stopped.addingTimeInterval(20), reset: reset, allowed: nil)
        newer.observe(switched, now: switched.observedAt)
        let sameAgain = sample(stopped.addingTimeInterval(25), reset: reset, allowed: true)
        newer.observe(sameAgain, now: sameAgain.observedAt)
        #expect(!bind(newer, sameAgain, turn))
        var missingStop = turn
        missingStop.completedAt = nil
        #expect(!bind(newer, sameAgain, missingStop))
    }
}
