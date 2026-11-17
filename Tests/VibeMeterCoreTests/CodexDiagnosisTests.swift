import Foundation
import Testing
@testable import VibeMeterCore

/// 實測帳戶形狀（只有一般 `codex` 桶、normalModelSlug 為 null）的診斷與「協助手動續作」提示。
@Suite struct CodexDiagnosisTests {
    let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let t0 = Date(timeIntervalSince1970: 1_894_000_000)

    private func generalSnapshot(at: Date, account: String? = "acct", allowed: Bool?, used: Double, reset: Date) -> UsageSnapshot {
        let windows = [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: reset)]
        return UsageSnapshot(provider: .codex, windows: windows, observedAt: at, source: .codexAppServer, accountID: account,
                             usageAllowed: allowed, buckets: [LimitBucket(limitID: "codex", modelSlug: nil, windows: windows, limitReachedType: nil)])
    }

    private func plan(detectedWith snapshot: UsageSnapshot) throws -> ResumePlan {
        let stop = t0
        let s = CodexSessionInfo(id: session, threadName: "x", cwd: "/tmp", startedAt: nil, lastActivity: stop, rolloutPath: "/x")
        let turn = CodexTurnSummary(id: "stop", status: "failed", errorInfo: "usageLimitExceeded", startedAt: stop.addingTimeInterval(-20), completedAt: stop)
        var observations = CodexQuotaObservations()
        observations.observe(generalSnapshot(at: stop.addingTimeInterval(-60), allowed: true, used: 90, reset: stop.addingTimeInterval(1800)),
                             now: stop.addingTimeInterval(-60))
        observations.observe(snapshot, now: snapshot.observedAt)
        let item = try #require(BlockedSessionDetector.codex(
            sessions: [s], latestTurns: [session: turn], snapshot: snapshot, now: snapshot.observedAt,
            evidence: [session: CodexBlockEvidence(turnModel: "gpt-model", creatorAccountHash: nil, liveAccountID: "acct")],
            observations: observations).first)
        return try ResumePlan(provider: .codex, sessionID: item.sessionID, sessionTitle: item.title, cwd: item.cwd,
                              blockedWindow: item.blockedWindow, expectedResetAt: item.resetsAt, origin: .autoDetected,
                              createdAt: snapshot.observedAt, codex: item.codex)
    }

    @Test func generalBucketOnlyNeverAuthorizesButExplainsAndSuggestsManual() throws {
        let reset = t0.addingTimeInterval(1800)
        let denied = generalSnapshot(at: t0.addingTimeInterval(10), allowed: false, used: 100, reset: reset)
        let p = try plan(detectedWith: denied)
        if case .needsConfirmation = p.state {} else { Issue.record("general bucket must not arm automation") }
        #expect(p.codex?.sessionAuthorization == nil)
        #expect(p.codex?.accountHashAtDetection == AccountHash.of("acct"))
        let blocked = CodexAutomationDiagnosis.diagnose(p, live: denied, now: denied.observedAt)
        #expect(!blocked.looksReadyForManualContinue)
        #expect(blocked.items.contains { ($0.detail ?? "").contains("normalModelSlug") })

        let after = reset.addingTimeInterval(60)
        let recovered = generalSnapshot(at: after, allowed: true, used: 2, reset: after.addingTimeInterval(5 * 3600))
        #expect(CodexAutomationDiagnosis.diagnose(p, live: recovered, now: after).looksReadyForManualContinue)
        // 官方恢復判斷仍不成立：沒有能對應模型的額度桶。
        #expect(RestoreDetector.codexDecision(p, snapshot: recovered, now: after) != .restored)
    }

    @Test func manualHintRequiresSameAccountExplicitPermissionAndHeadroom() throws {
        let reset = t0.addingTimeInterval(1800)
        let p = try plan(detectedWith: generalSnapshot(at: t0.addingTimeInterval(10), allowed: false, used: 100, reset: reset))
        let after = reset.addingTimeInterval(60)
        let next = after.addingTimeInterval(5 * 3600)
        func ready(_ s: UsageSnapshot) -> Bool { CodexAutomationDiagnosis.diagnose(p, live: s, now: s.observedAt).looksReadyForManualContinue }
        #expect(!ready(generalSnapshot(at: after, account: "other", allowed: true, used: 2, reset: next)))   // 帳戶改變
        #expect(!ready(generalSnapshot(at: after, allowed: nil, used: 2, reset: next)))                       // 許可未提供
        #expect(!ready(generalSnapshot(at: after, allowed: false, used: 2, reset: next)))                     // 明確拒絕
        #expect(!ready(generalSnapshot(at: after, allowed: true, used: 100, reset: next)))                    // 仍滿額
        #expect(!ready(generalSnapshot(at: reset.addingTimeInterval(-60), allowed: true, used: 2, reset: next))) // 尚未到預計重設
        var stale = generalSnapshot(at: after, allowed: true, used: 2, reset: next)
        stale.supersededByFailedQuery = true
        #expect(!ready(stale))                                                                                 // 查詢失敗後的舊值
        #expect(CodexAutomationDiagnosis.diagnose(p, live: nil, now: after).looksReadyForManualContinue == false)
        // 偵測時沒有記錄帳戶的舊計畫：帳戶不明，不提示。
        var legacy = p
        legacy.codex?.accountHashAtDetection = nil
        #expect(!CodexAutomationDiagnosis.diagnose(legacy, live: generalSnapshot(at: after, allowed: true, used: 2, reset: next), now: after)
            .looksReadyForManualContinue)
    }
}

@Suite struct CodexDiagnosisWindowTests {
    private func plan(now: Date) throws -> ResumePlan {
        var context = CodexResumeContext(accountID: nil, anchorTurnID: "stop", verifiedLimitFailure: true, modelAtBlock: "gpt-model")
        context.accountHashAtDetection = AccountHash.of("acct")
        return try ResumePlan(provider: .codex, sessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", sessionTitle: "x", cwd: "/tmp",
                              blockedWindow: .fiveHour, expectedResetAt: now.addingTimeInterval(-600), createdAt: now.addingTimeInterval(-3600),
                              codex: context)
    }

    private func snapshot(_ buckets: [LimitBucket], now: Date, spend: Bool? = nil) -> UsageSnapshot {
        UsageSnapshot(provider: .codex, windows: buckets.first?.windows ?? [], observedAt: now, source: .codexAppServer,
                      accountID: "acct", usageAllowed: true, buckets: buckets, spendControlReached: spend)
    }

    @Test func missingOrIrrelevantWindowsNeverLookRecovered() throws {
        let now = Date()
        let p = try plan(now: now)
        let ok = UsageWindow(kind: .fiveHour, usedPercent: 3, resetsAt: now.addingTimeInterval(3600))
        func ready(_ s: UsageSnapshot) -> Bool { CodexAutomationDiagnosis.diagnose(p, live: s, now: now).looksReadyForManualContinue }
        #expect(ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [ok], limitReachedType: nil)], now: now)))
        #expect(!ready(snapshot([], now: now)))                                                                    // 沒有任何桶
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [], limitReachedType: nil)], now: now)))  // 空窗口
        let weeklyOnly = UsageWindow(kind: .weekly, usedPercent: 3, resetsAt: now.addingTimeInterval(86400))
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [weeklyOnly], limitReachedType: nil)], now: now)))  // 缺中止週期
        let noReset = UsageWindow(kind: .fiveHour, usedPercent: 3, resetsAt: nil)
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [noReset], limitReachedType: nil)], now: now)))
        let pastReset = UsageWindow(kind: .fiveHour, usedPercent: 3, resetsAt: now.addingTimeInterval(-10))
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [pastReset], limitReachedType: nil)], now: now)))
        #expect(!ready(snapshot([LimitBucket(limitID: "codex_other", modelSlug: nil, windows: [ok], limitReachedType: nil)], now: now)))  // 非官方一般桶
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [ok], limitReachedType: nil),
                                 LimitBucket(limitID: "codex", modelSlug: nil, windows: [ok], limitReachedType: nil)], now: now)))      // 不唯一
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [ok], limitReachedType: "rate_limit_reached")], now: now)))
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [ok], limitReachedType: nil, spendControlReached: true)], now: now)))
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [ok], limitReachedType: nil)], now: now, spend: true)))
        let weeklyFull = UsageWindow(kind: .weekly, usedPercent: 100, resetsAt: now.addingTimeInterval(86400))
        #expect(!ready(snapshot([LimitBucket(limitID: "codex", modelSlug: nil, windows: [ok, weeklyFull], limitReachedType: nil)], now: now)))
        // 其他模型的專屬桶有餘裕，不代表此模型。
        #expect(!ready(snapshot([LimitBucket(limitID: "spark", modelSlug: "other-model", windows: [ok], limitReachedType: nil)], now: now)))
    }
}
