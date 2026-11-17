import Foundation
import Testing
@testable import VibeMeterCore

/// 一般額度「重設＋30 秒」定時嘗試的身分與時間邊界（使用者明確授權的最佳努力，不是官方恢復確認）。
@Suite struct CodexTimedResumeTests {
    let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let stop = Date(timeIntervalSince1970: 1_894_000_000)

    private func snap(at offset: TimeInterval, account: String? = "A", allowed: Bool?, five: Double, fiveReset: TimeInterval? = 1800,
                      week: Double? = nil, weekReset: TimeInterval? = nil, bucketID: String = "codex", slug: String? = nil,
                      extra: [LimitBucket] = [], spend: Bool? = nil) -> UsageSnapshot {
        var windows = [UsageWindow(kind: .fiveHour, usedPercent: five, resetsAt: fiveReset.map { stop.addingTimeInterval($0) })]
        if let week { windows.append(UsageWindow(kind: .weekly, usedPercent: week, resetsAt: weekReset.map { stop.addingTimeInterval($0) })) }
        return UsageSnapshot(provider: .codex, windows: windows, observedAt: stop.addingTimeInterval(offset), source: .codexAppServer,
                             accountID: account, usageAllowed: allowed,
                             buckets: [LimitBucket(limitID: bucketID, modelSlug: slug, windows: windows, limitReachedType: nil)] + extra,
                             spendControlReached: spend)
    }

    private var turn: CodexTurnSummary {
        CodexTurnSummary(id: "stop-1", status: "failed", errorInfo: "usageLimitExceeded", startedAt: stop.addingTimeInterval(-20), completedAt: stop)
    }

    private func ledger(_ snapshots: [UsageSnapshot]) -> CodexQuotaObservations {
        var l = CodexQuotaObservations()
        for s in snapshots { l.observe(s, now: s.observedAt) }
        return l
    }

    private func bind(_ l: CodexQuotaObservations, live: UsageSnapshot, model: String? = "m",
                      settings: CodexContinuationSettings = .init()) -> Result<CodexSessionAuthorization, CodexQuotaObservations.BindingGapError> {
        l.bindTimed(sessionID: sessionID, turn: turn, model: model, snapshot: live, now: live.observedAt, settings: settings)
    }

    @Test func sameAccountGeneralBucketBindsAndUsesLatestFullReset() throws {
        let before = snap(at: -30, allowed: true, five: 90)
        let exhausted = snap(at: 10, allowed: true, five: 100, week: 100, weekReset: 3 * 86400)
        let l = ledger([before, exhausted])
        let auth = try bind(l, live: exhausted).get()
        #expect(auth.basis == .generalBucketTimed && auth.window == .weekly && auth.resetsAt == stop.addingTimeInterval(3 * 86400))
        #expect(l.authorizes(auth))
        // 官方明確 false 也可作為同帳戶的用盡觀察（使用者已接受可能付費）。
        let falseLedger = ledger([before, snap(at: 10, allowed: false, five: 100)])
        #expect((try? bind(falseLedger, live: snap(at: 20, allowed: false, five: 100)).get())?.window == .fiveHour)
    }

    @Test func nullPermissionNeverRecordsOrBinds() {
        // 官方在帳戶或使用者與目前登入不符時把許可設為 null，但可能仍回舊 accountId。
        let l = ledger([snap(at: -30, allowed: true, five: 90), snap(at: 10, allowed: nil, five: 100)])
        #expect((try? bind(l, live: snap(at: 20, allowed: true, five: 100)).get()) == nil)
        let l2 = ledger([snap(at: -30, allowed: true, five: 90), snap(at: 10, allowed: true, five: 100)])
        #expect((try? bind(l2, live: snap(at: 20, allowed: nil, five: 100)).get()) == nil)
    }

    @Test func otherAccountOrLateFirstSightingNeverBinds() {
        // A 中止後一天才第一次看到已滿的 B。
        let late = snap(at: 86400, account: "B", allowed: true, five: 100, fiveReset: 86400 + 1800)
        #expect((try? bind(ledger([late]), live: late).get()) == nil)
        // A→B→A：切換清除帳本，回到 A 的第一筆觀察晚於中止。
        let switched = ledger([snap(at: -30, allowed: true, five: 90), snap(at: -10, account: "B", allowed: true, five: 40),
                               snap(at: 10, allowed: true, five: 100)])
        #expect((try? bind(switched, live: snap(at: 20, allowed: true, five: 100)).get()) == nil)
        // 只有中止後才首次觀察（沒有中止前的同帳戶確認）。
        #expect((try? bind(ledger([snap(at: 10, allowed: true, five: 100)]), live: snap(at: 20, allowed: true, five: 100)).get()) == nil)
        // 觀察與中止相距過遠（超過有界時間）。
        let far = ledger([snap(at: -30, allowed: true, five: 90), snap(at: 3600, allowed: true, five: 100)])
        #expect((try? bind(far, live: snap(at: 3610, allowed: true, five: 100)).get()) == nil)
    }

    @Test func onlyTheOfficialGeneralCodexBucketQualifies() {
        func attempt(_ bucketID: String, slug: String? = nil, extra: [LimitBucket] = [], model: String? = "m") -> Bool {
            let l = ledger([snap(at: -30, allowed: true, five: 90, bucketID: bucketID, slug: slug, extra: extra),
                            snap(at: 10, allowed: true, five: 100, bucketID: bucketID, slug: slug, extra: extra)])
            return (try? bind(l, live: snap(at: 20, allowed: true, five: 100, bucketID: bucketID, slug: slug, extra: extra), model: model).get()) != nil
        }
        #expect(attempt("codex"))
        #expect(!attempt("codex_other"))
        #expect(!attempt("codex", slug: "spark"))                       // 有別名的桶不是一般桶
        // 原模型有專屬桶時走官方路徑，不用一般桶。
        let specific = LimitBucket(limitID: "m-meter", modelSlug: "m", windows: [], limitReachedType: nil)
        #expect(!attempt("codex", extra: [specific]))
        #expect(!attempt("codex", model: nil))                          // 缺原模型
    }

    @Test func scopeAndGapsAreNotWidened() {
        let l = ledger([snap(at: -30, allowed: true, five: 90), snap(at: 10, allowed: true, five: 100)])
        let other = CodexContinuationSettings(mode: .scoped, scope: .init(sessionID: sessionID, accountID: "B", model: "m"))
        #expect((try? bind(l, live: snap(at: 20, allowed: true, five: 100), settings: other).get()) == nil)
        let otherModel = CodexContinuationSettings(mode: .scoped, scope: .init(sessionID: sessionID, accountID: "A", model: "x"))
        #expect((try? bind(l, live: snap(at: 20, allowed: true, five: 100), settings: otherModel).get()) == nil)
        let mine = CodexContinuationSettings(mode: .scoped, scope: .init(sessionID: sessionID, accountID: "A", model: "m"))
        #expect((try? bind(l, live: snap(at: 20, allowed: true, five: 100), settings: mine).get()) != nil)
        // 偵測器：官方路徑的其他缺口（範圍、模型、帳戶）不會改走定時嘗試。
        let s = CodexSessionInfo(id: sessionID, threadName: "x", cwd: "/tmp", startedAt: nil, lastActivity: stop, rolloutPath: "/x")
        let items = BlockedSessionDetector.codex(sessions: [s], latestTurns: [sessionID: turn], snapshot: snap(at: 20, allowed: true, five: 100),
                                                 now: stop.addingTimeInterval(20),
                                                 evidence: [sessionID: CodexBlockEvidence(turnModel: "m", creatorAccountHash: nil, liveAccountID: "A")],
                                                 observations: l, continuation: other, timedResume: true)
        #expect(items.first?.codex?.sessionAuthorization == nil)
        let off = BlockedSessionDetector.codex(sessions: [s], latestTurns: [sessionID: turn], snapshot: snap(at: 20, allowed: true, five: 100),
                                               now: stop.addingTimeInterval(20),
                                               evidence: [sessionID: CodexBlockEvidence(turnModel: "m", creatorAccountHash: nil, liveAccountID: "A")],
                                               observations: l, timedResume: false)
        #expect(off.first?.codex?.sessionAuthorization == nil)
    }

    @Test func evaluateWaitsUntilResetPlus30AndRespectsLaterFullWindows() throws {
        let l = ledger([snap(at: -30, allowed: true, five: 90), snap(at: 10, allowed: true, five: 100)])
        let auth = try bind(l, live: snap(at: 20, allowed: true, five: 100)).get()
        let reset = auth.resetsAt
        let recovered = UsageSnapshot(provider: .codex, windows: [UsageWindow(kind: .fiveHour, usedPercent: 3, resetsAt: reset.addingTimeInterval(5 * 3600))],
                                      observedAt: reset.addingTimeInterval(20), source: .codexAppServer, accountID: "A", usageAllowed: true,
                                      buckets: [LimitBucket(limitID: "codex", modelSlug: nil,
                                                            windows: [UsageWindow(kind: .fiveHour, usedPercent: 3, resetsAt: reset.addingTimeInterval(5 * 3600))],
                                                            limitReachedType: nil)])
        #expect(CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: recovered, now: reset.addingTimeInterval(29.999)) == .notDue(reset.addingTimeInterval(30)))
        #expect(CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: recovered, now: reset.addingTimeInterval(30)) == .due)
        var nullPermission = recovered
        nullPermission.usageAllowed = nil
        if case .wait = CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: nullPermission, now: reset.addingTimeInterval(30)) {} else { Issue.record("null must wait") }
        var otherAccount = recovered
        otherAccount.accountID = "B"
        if case .stop = CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: otherAccount, now: reset.addingTimeInterval(30)) {} else { Issue.record("switch must stop") }
        let stillFull = snap(at: 1810, allowed: true, five: 100, fiveReset: 4000)
        // 同帳戶、許可非 null 的回應提供較晚的有效重設：延期（持久化由 AppModel 處理）。
        #expect(CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: stillFull, now: reset.addingTimeInterval(30)) == .defer(stop.addingTimeInterval(4000)))
        #expect(CodexTimedResumePolicy.evaluate(auth, deferredTo: stop.addingTimeInterval(4000), live: recovered, now: reset.addingTimeInterval(30))
            == .notDue(stop.addingTimeInterval(4030)))
        // 未驗證登入（null）帶來的較晚時間不採用。
        var nullFull = stillFull
        nullFull.usageAllowed = nil
        if case .defer = CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: nullFull, now: reset.addingTimeInterval(30)) {
            Issue.record("unverified login must not move the deadline")
        }
        if case .stop = CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: nil, now: reset.addingTimeInterval(24 * 3600 + 1)) {} else { Issue.record("expired must stop") }
        if case .wait = CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: nil, now: reset.addingTimeInterval(31)) {} else { Issue.record("offline must wait") }
    }

    @Test func preflightRequiresVerifiedSameAccountAndHeadroom() throws {
        let l = ledger([snap(at: -30, allowed: true, five: 90), snap(at: 10, allowed: true, five: 100)])
        let auth = try bind(l, live: snap(at: 20, allowed: true, five: 100)).get()
        let due = auth.resetsAt.addingTimeInterval(30)
        func fresh(account: String? = "A", allowed: Bool?, used: Double = 3, spend: Bool? = nil, bucket: String = "codex") -> UsageSnapshot {
            let w = [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: due.addingTimeInterval(5 * 3600))]
            return UsageSnapshot(provider: .codex, windows: w, observedAt: due, source: .codexAppServer, accountID: account, usageAllowed: allowed,
                                 buckets: [LimitBucket(limitID: bucket, modelSlug: nil, windows: w, limitReachedType: nil)], spendControlReached: spend)
        }
        if case .send = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(allowed: true), now: due) {} else { Issue.record("true should send") }
        guard case .send(let note) = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(allowed: false), now: due) else {
            Issue.record("false is the user-authorized attempt"); return
        }
        #expect(L10n.display(note, in: .zhHant).contains("未允許"))
        if case .retry = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(allowed: nil), now: due) {} else { Issue.record("null must not send") }
        if case .retry = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(account: nil, allowed: true), now: due) {} else { Issue.record("no account") }
        if case .stop = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(account: "B", allowed: true), now: due) {} else { Issue.record("B") }
        if case .retry = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(allowed: true, spend: true), now: due) {} else { Issue.record("spend") }
        if case .defer = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(allowed: true, used: 100), now: due) {} else { Issue.record("later reset defers") }
        if case .retry = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(allowed: true, bucket: "codex_other"), now: due) {} else { Issue.record("bucket") }
        if case .retry = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: fresh(allowed: true), now: due.addingTimeInterval(-0.001)) {} else { Issue.record("early") }
    }

    @Test func sameCycleAttemptIsNotRepeatedAndForgedPlansCannotAuthorize() throws {
        let reset = stop.addingTimeInterval(1800)
        var ledger = CodexTimedDispatchLedger()
        let first = ledger.reserve(anchorTurnID: "stop-1", effectiveReset: reset, now: reset.addingTimeInterval(30))
        let sameAnchor = ledger.reserve(anchorTurnID: "stop-1", effectiveReset: reset, now: reset.addingTimeInterval(31))
        #expect(first && !sameAnchor)
        #expect(ledger.blocks(resetsAt: reset))
        // 送出後尚未確認有完成的實際工作：較晚週期的新中止也可能是自己的提示失敗，不自動重試。
        let unconfirmed = ledger.reserve(anchorTurnID: "stop-2", effectiveReset: reset.addingTimeInterval(5 * 3600), now: reset.addingTimeInterval(60))
        #expect(!unconfirmed)
        ledger.markUserConfirmed(at: reset.addingTimeInterval(-3600))   // 嘗試之前的確認不算
        #expect(ledger.blocks(resetsAt: reset.addingTimeInterval(5 * 3600)))
        ledger.markUserConfirmed(at: reset.addingTimeInterval(40))      // 使用者明確手動繼續
        #expect(!ledger.blocks(resetsAt: reset.addingTimeInterval(5 * 3600)))
        #expect(ledger.blocks(resetsAt: reset))                                      // 同週期仍擋
        let round = try JSONDecoder().decode(CodexTimedDispatchLedger.self, from: try JSONEncoder().encode(ledger))
        #expect(round == ledger)

        // 計畫檔沒有授權欄位：解碼後一律待確認，不能以自宣告欄位進入定時送出。
        let forged = """
        {"id":"\(UUID().uuidString)","provider":"codex","sessionID":"\(sessionID)","sessionTitle":"x","cwd":"/tmp","prompt":"p",
         "blockedWindow":{"fiveHour":{}},"expectedResetAt":0,"origin":"autoDetected","createdAt":0,"state":{"waiting":{}},"probeCount":0,
         "codex":{"anchorTurnID":"stop-1","verifiedLimitFailure":true,"modelAtBlock":"m","accountHashAtDetection":"\(AccountHash.of("A"))",
                  "sessionAuthorization":{"basis":"generalBucketTimed"},"verifiedAccountAndModelAtBlock":true,"timedResume":{"resetAt":0}}}
        """
        let plan = try VibeMeterJSON.decoder.decode(ResumePlan.self, from: Data(forged.utf8))
        #expect(plan.codex?.sessionAuthorization == nil && plan.codex?.verifiedAccountAndModelAtBlock == nil)
        #expect(AutoResumeGate.blocker(for: plan) != nil)
    }
}

/// 審查第二輪：歧義、新鮮度、仍滿的嘗試語義、費用障礙、延期保留與通知文字。
@Suite struct CodexTimedResumeReviewTests {
    let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let stop = Date(timeIntervalSince1970: 1_894_000_000)

    private func bucket(_ id: String, slug: String? = nil, used: Double, reset: Date?, reached: String? = nil) -> LimitBucket {
        LimitBucket(limitID: id, modelSlug: slug, windows: [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: reset)],
                    limitReachedType: reached)
    }

    private func snap(at: Date, account: String? = "A", allowed: Bool? = true, buckets: [LimitBucket], spend: Bool? = nil,
                      source: DataSource = .codexAppServer) -> UsageSnapshot {
        UsageSnapshot(provider: .codex, windows: buckets.first?.windows ?? [], observedAt: at, source: source, accountID: account,
                      usageAllowed: allowed, buckets: buckets, spendControlReached: spend)
    }

    private func authorization() throws -> (CodexQuotaObservations, CodexSessionAuthorization) {
        let reset = stop.addingTimeInterval(1800)
        var l = CodexQuotaObservations()
        let before = snap(at: stop.addingTimeInterval(-30), buckets: [bucket("codex", used: 90, reset: reset)])
        let full = snap(at: stop.addingTimeInterval(10), buckets: [bucket("codex", used: 100, reset: reset)])
        l.observe(before, now: before.observedAt)
        l.observe(full, now: full.observedAt)
        let turn = CodexTurnSummary(id: "stop-1", status: "failed", errorInfo: "usageLimitExceeded", startedAt: stop.addingTimeInterval(-20), completedAt: stop)
        return (l, try l.bindTimed(sessionID: sessionID, turn: turn, model: "m", snapshot: full, now: full.observedAt, settings: .init()).get())
    }

    @Test func duplicateModelBucketsAreAmbiguousNotGeneral() {
        let reset = stop.addingTimeInterval(1800)
        let dup = [bucket("codex", used: 100, reset: reset), bucket("x1", slug: "m", used: 100, reset: reset), bucket("x2", slug: "m", used: 100, reset: reset)]
        var l = CodexQuotaObservations()
        l.observe(snap(at: stop.addingTimeInterval(-30), buckets: dup), now: stop.addingTimeInterval(-30))
        let full = snap(at: stop.addingTimeInterval(10), buckets: dup)
        l.observe(full, now: full.observedAt)
        let turn = CodexTurnSummary(id: "stop-1", status: "failed", errorInfo: "usageLimitExceeded", completedAt: stop)
        #expect((try? l.bindTimed(sessionID: sessionID, turn: turn, model: "m", snapshot: full, now: full.observedAt, settings: .init()).get()) == nil)
    }

    @Test func preflightNeedsFreshOfficialDataAfterDueAndAllowsStillFullAttempt() throws {
        let (_, auth) = try authorization()
        let due = auth.resetsAt.addingTimeInterval(30)
        func outcome(_ s: UsageSnapshot, now: Date? = nil) -> CodexTimedResumePolicy.PreflightOutcome {
            CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: s, now: now ?? due)
        }
        // 到期前取得的回應、過期回應、本機 rollout 紀錄：都不送。
        if case .send = outcome(snap(at: due.addingTimeInterval(-1), buckets: [bucket("codex", used: 3, reset: due.addingTimeInterval(3600))])) {
            Issue.record("observation before due must not send")
        }
        if case .send = outcome(snap(at: due, buckets: [bucket("codex", used: 3, reset: due.addingTimeInterval(3600))]), now: due.addingTimeInterval(3600)) {
            Issue.record("stale observation must not send")
        }
        if case .send = outcome(snap(at: due, buckets: [bucket("codex", used: 3, reset: due.addingTimeInterval(3600))], source: .codexRolloutLog)) {
            Issue.record("local rollout must not send")
        }
        // 使用者授權的嘗試：仍 100% 但缺重設、或重設仍是過去時間 → 嘗試一次；有較晚的有效重設 → 延期。
        if case .send = outcome(snap(at: due, allowed: false, buckets: [bucket("codex", used: 100, reset: nil)])) {} else { Issue.record("100% + no reset should attempt once") }
        if case .send = outcome(snap(at: due, buckets: [bucket("codex", used: 100, reset: auth.resetsAt)])) {} else { Issue.record("100% + old reset should attempt once") }
        let later = due.addingTimeInterval(3600)
        #expect(outcome(snap(at: due, buckets: [bucket("codex", used: 100, reset: later)])) == .defer(later))
        // null 或不同帳戶帶來的較晚重設：不延期也不送。
        if case .defer = outcome(snap(at: due, allowed: nil, buckets: [bucket("codex", used: 100, reset: later)])) { Issue.record("null must not defer") }
        if case .send = outcome(snap(at: due, allowed: nil, buckets: [bucket("codex", used: 100, reset: later)])) { Issue.record("null must not send") }
        if case .stop = outcome(snap(at: due, account: "B", buckets: [bucket("codex", used: 100, reset: later)])) {} else { Issue.record("B must stop") }
    }

    @Test func workspaceCapsAndCreditsDepletionBlockEvenWithoutSpendBool() throws {
        let (_, auth) = try authorization()
        let due = auth.resetsAt.addingTimeInterval(30)
        for reached in ["workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached",
                        "workspace_owner_credits_depleted", "workspace_member_credits_depleted"] {
            for spend in [false, nil] as [Bool?] {
                let s = snap(at: due, buckets: [bucket("codex", used: 3, reset: due.addingTimeInterval(3600), reached: reached)], spend: spend)
                if case .send = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: s, now: due) { Issue.record("\(reached) must block") }
            }
        }
        // 一般的 rate_limit_reached 不是費用障礙：保留使用者選擇的嘗試。
        let ordinary = snap(at: due, buckets: [bucket("codex", used: 100, reset: nil, reached: "rate_limit_reached")])
        if case .send = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: ordinary, now: due) {} else { Issue.record("ordinary limit keeps the attempt") }
    }

    @Test func verifiedDeferralKeepsTheWitnessPastTheOriginalGrace() throws {
        var (l, auth) = try authorization()
        let r2 = auth.resetsAt.addingTimeInterval(36 * 3600)
        let probe = { (ledger: CodexQuotaObservations, at: Date) -> Bool in
            var copy = ledger
            copy.observe(self.snap(at: at, buckets: [self.bucket("codex", used: 100, reset: at.addingTimeInterval(3600))]), now: at)
            return copy.authorizes(auth)
        }
        #expect(!probe(l, auth.resetsAt.addingTimeInterval(13 * 3600)))    // 沒有延期：原 12 小時保留期後失效
        l.extendWitness(auth, until: r2.addingTimeInterval(CodexTimedResumePolicy.lateLimit))
        #expect(probe(l, auth.resetsAt.addingTimeInterval(13 * 3600)))
        #expect(probe(l, r2.addingTimeInterval(60)))
        // 延期不能提前，也不能超過上限。
        #expect(CodexTimedResumePolicy.effectiveReset(auth, deferredTo: auth.resetsAt.addingTimeInterval(-60)) == auth.resetsAt)
        #expect(CodexTimedResumePolicy.effectiveReset(auth, deferredTo: auth.resetsAt.addingTimeInterval(8 * 86400)) == auth.resetsAt)
        #expect(CodexTimedResumePolicy.effectiveReset(auth, deferredTo: r2) == r2)
    }

    @Test func timedDueWithAutoOffNeverClaimsRecovery() throws {
        let (_, auth) = try authorization()
        var plan = try ResumePlan(provider: .codex, sessionID: sessionID, sessionTitle: "x", cwd: "/tmp", blockedWindow: auth.window,
                                  expectedResetAt: auth.resetsAt, origin: .autoDetected,
                                  codex: CodexResumeContext(accountID: nil, anchorTurnID: "stop-1", verifiedLimitFailure: true, modelAtBlock: "m"))
        plan.codex?.sessionAuthorization = auth
        plan.state = .waiting
        let (ready, effects) = ResumeReducer.reduce(plan, .timedDue(now: Date(), autoContinue: false))
        #expect(effects == [.notifyTimedReady])
        if case .ready = ready.state {} else { Issue.record("auto off waits for the user") }
        let (launching, launch) = ResumeReducer.reduce(plan, .timedDue(now: Date(), autoContinue: true))
        #expect(launch == [.launch])
        if case .launching = launching.state {} else { Issue.record("auto on launches") }
    }
}

/// 第三輪審查：工作階段層級的跨程序原子保留、延期上限一致。
@Suite struct CodexTimedSessionStoreTests {
    let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @Test func concurrentInstancesWithDifferentAnchorsReserveOnce() {
        let dir = TestSupport.tempDir()
        let reset = Date(timeIntervalSince1970: 1_894_001_800)
        final class Count: @unchecked Sendable { let lock = NSLock(); var value = 0 }
        let wins = Count()
        // 多個「App 程序」各自建立 store、不同錨點、同一週期同時競逐。
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            let store = CodexTimedSessionStore(directory: dir)
            if store.reserve(sessionID: i % 2 == 0 ? session : session.uppercased(), anchorTurnID: "stop-\(i)",
                             effectiveReset: reset, now: reset.addingTimeInterval(30)) {
                wins.lock.withLock { wins.value += 1 }
            }
        }
        #expect(wins.value == 1)
        // 重新建立（重啟）後仍擋。
        let restarted = CodexTimedSessionStore(directory: dir)
        #expect(restarted.blocks(sessionID: session, resetsAt: reset))
        #expect(!restarted.reserve(sessionID: session, anchorTurnID: "stop-new", effectiveReset: reset.addingTimeInterval(5 * 3600),
                                   now: reset.addingTimeInterval(120)))
        restarted.markUserConfirmed(sessionID: session, at: reset.addingTimeInterval(200))
        #expect(restarted.reserve(sessionID: session, anchorTurnID: "stop-new", effectiveReset: reset.addingTimeInterval(5 * 3600),
                                  now: reset.addingTimeInterval(5 * 3600 + 30)))
    }

    @Test func deferralLimitIsSharedByDecisionPersistenceAndWitness() throws {
        let stop = Date(timeIntervalSince1970: 1_894_000_000)
        let reset = stop.addingTimeInterval(1800)
        func snap(at: Date, used: Double, weekReset: Date) -> UsageSnapshot {
            let w = [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: reset), UsageWindow(kind: .weekly, usedPercent: used, resetsAt: weekReset)]
            return UsageSnapshot(provider: .codex, windows: w, observedAt: at, source: .codexAppServer, accountID: "A", usageAllowed: false,
                                 buckets: [LimitBucket(limitID: "codex", modelSlug: nil, windows: w, limitReachedType: nil)])
        }
        var l = CodexQuotaObservations()
        l.observe(snap(at: stop.addingTimeInterval(-30), used: 90, weekReset: reset), now: stop.addingTimeInterval(-30))
        let full = snap(at: stop.addingTimeInterval(10), used: 100, weekReset: reset)
        l.observe(full, now: full.observedAt)
        let turn = CodexTurnSummary(id: "stop-1", status: "failed", errorInfo: "usageLimitExceeded", completedAt: stop)
        let auth = try l.bindTimed(sessionID: session, turn: turn, model: "m", snapshot: full, now: full.observedAt, settings: .init()).get()
        let exact = auth.resetsAt.addingTimeInterval(CodexTimedResumePolicy.maxDeferral)
        let over = exact.addingTimeInterval(1)
        #expect(CodexTimedResumePolicy.isValidDeferral(auth, to: exact))
        #expect(!CodexTimedResumePolicy.isValidDeferral(auth, to: over))
        // 在原重設＋30 秒觀察（週期內的重設必須距觀察時間不超過一個週期長度）。
        let now = auth.resetsAt.addingTimeInterval(30)
        // 精確 7 天：延期；多 1 秒：轉待確認（不持久化、不反覆重排）。
        #expect(CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: snap(at: now, used: 100, weekReset: exact), now: now) == .defer(exact))
        if case .stop = CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: snap(at: now, used: 100, weekReset: over), now: now) {} else {
            Issue.record("over-limit deferral must stop")
        }
        #expect(CodexTimedResumePolicy.effectiveReset(auth, deferredTo: over) == auth.resetsAt)
        // 證據可延長到「最晚合法延期＋送出期限」，再晚則不延長。
        l.extendWitness(auth, until: CodexTimedResumePolicy.witnessRetention(effectiveReset: exact))
        var probe = l
        let late = exact.addingTimeInterval(3600)
        probe.observe(snap(at: late, used: 3, weekReset: late.addingTimeInterval(86400)), now: late)
        #expect(probe.authorizes(auth))
        var refused = CodexQuotaObservations()
        refused.observe(snap(at: stop.addingTimeInterval(-30), used: 90, weekReset: reset), now: stop.addingTimeInterval(-30))
        refused.observe(full, now: full.observedAt)
        refused.extendWitness(auth, until: CodexTimedResumePolicy.witnessRetention(effectiveReset: over))
        refused.observe(snap(at: late, used: 3, weekReset: late.addingTimeInterval(86400)), now: late)
        #expect(!refused.authorizes(auth))
    }

    @Test func timedPromptNeverClaimsRecovery() {
        #expect(!ResumePlan.timedAttemptPrompt.contains("已恢復"))
        #expect(!ResumePlan.timedAttemptPrompt.contains("官方資料確認"))
        #expect(ResumePlan.defaultPrompt != ResumePlan.timedAttemptPrompt)
    }
}

/// 第四輪審查：共享去重記錄損壞或不可讀時 fail closed。
@Suite struct CodexTimedSessionStoreFailClosedTests {
    let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let reset = Date(timeIntervalSince1970: 1_894_001_800)

    private func claimed() throws -> (CodexTimedSessionStore, URL) {
        let dir = TestSupport.tempDir()
        let store = CodexTimedSessionStore(directory: dir)
        #expect(store.reserve(sessionID: session, anchorTurnID: "stop-1", effectiveReset: reset, now: reset.addingTimeInterval(30)))
        store.markUserConfirmed(sessionID: session, at: reset.addingTimeInterval(60))
        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        return (store, file)
    }

    @Test func corruptLedgerRejectsOtherAnchors() throws {
        let (store, file) = try claimed()
        let later = reset.addingTimeInterval(5 * 3600)
        #expect(!store.blocks(sessionID: session, resetsAt: later))   // 正常：已確認、新週期可評估
        try Data("{not json".utf8).write(to: file)
        #expect(store.blocks(sessionID: session, resetsAt: later))
        #expect(!store.reserve(sessionID: session, anchorTurnID: "stop-2", effectiveReset: later, now: later.addingTimeInterval(30)))
        try Data().write(to: file)
        #expect(!store.reserve(sessionID: session, anchorTurnID: "stop-2", effectiveReset: later, now: later.addingTimeInterval(30)))
    }

    @Test func unreadableLedgerRejectsOtherAnchors() throws {
        let (store, file) = try claimed()
        let later = reset.addingTimeInterval(5 * 3600)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(store.blocks(sessionID: session, resetsAt: later))
        #expect(!store.reserve(sessionID: session, anchorTurnID: "stop-2", effectiveReset: later, now: later.addingTimeInterval(30)))
        // 路徑變成目錄（本機故障）：同樣拒絕。
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(!store.reserve(sessionID: session, anchorTurnID: "stop-2", effectiveReset: later, now: later.addingTimeInterval(30)))
    }

    @Test func missingFileIsTheOnlyEmptyState() {
        let store = CodexTimedSessionStore(directory: TestSupport.tempDir().appendingPathComponent("new"))
        #expect(!store.blocks(sessionID: session, resetsAt: reset))
        #expect(store.reserve(sessionID: session, anchorTurnID: "stop-1", effectiveReset: reset, now: reset.addingTimeInterval(30)))
    }
}

/// 第五輪審查：記錄格式驗證、手動解除採開始時間、費用障礙一致排除。
@Suite struct CodexTimedReviewRound5Tests {
    let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let reset = Date(timeIntervalSince1970: 1_894_001_800)

    @Test func validJSONWithWrongShapeFailsClosed() throws {
        let shapes = [#"{}"#, #"{"entry":null}"#, #"{"surprise":true}"#, #"{"version":1}"#, #"{"version":1,"entry":null}"#,
                      #"{"version":2,"entry":{"anchorTurnID":"stop-1","effectiveReset":1894001800,"dispatchedAt":1894001830}}"#,
                      #"{"version":1,"entry":{"anchorTurnID":"","effectiveReset":1894001800,"dispatchedAt":1894001830}}"#,
                      #"{"entry":{"anchorTurnID":"stop-1","effectiveReset":1894001800,"dispatchedAt":1894001830}}"#, "[]", "null"]
        for shape in shapes {
            let dir = TestSupport.tempDir()
            let store = CodexTimedSessionStore(directory: dir)
            #expect(store.reserve(sessionID: session, anchorTurnID: "stop-1", effectiveReset: reset, now: reset.addingTimeInterval(30)))
            store.markUserConfirmed(sessionID: session, at: reset.addingTimeInterval(60))
            let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
            let later = reset.addingTimeInterval(5 * 3600)
            #expect(!store.blocks(sessionID: session, resetsAt: later), "valid ledger before tampering")
            try Data(shape.utf8).write(to: file)
            #expect(store.blocks(sessionID: session, resetsAt: later), "\(shape)")
            #expect(!store.reserve(sessionID: session, anchorTurnID: "stop-2", effectiveReset: later, now: later.addingTimeInterval(30)), "\(shape)")
        }
        // 正常寫入的格式可以往返。
        var ledger = CodexTimedDispatchLedger()
        let reserved = ledger.reserve(anchorTurnID: "stop-1", effectiveReset: reset, now: reset)
        #expect(reserved)
        let data = try VibeMeterJSON.encoder.encode(ledger)
        #expect(String(decoding: data, as: UTF8.self).contains("\"version\":1"))
        #expect(try VibeMeterJSON.decoder.decode(CodexTimedDispatchLedger.self, from: data) == ledger)
    }

    @Test func manualStartedBeforeAnotherReservationDoesNotRearmIt() {
        let store = CodexTimedSessionStore(directory: TestSupport.tempDir())
        let manualStart = reset.addingTimeInterval(10)
        // 另一個程序在手動送出開始之後才建立自動保留（錨點 B）。
        #expect(store.reserve(sessionID: session, anchorTurnID: "stop-B", effectiveReset: reset, now: reset.addingTimeInterval(30)))
        // 手動 A 較晚完成，但以開始時間記錄：不得解除 B 的抑制。
        store.markUserConfirmed(sessionID: session, at: manualStart)
        #expect(store.entry(sessionID: session)?.userConfirmedAt == nil)
        #expect(store.blocks(sessionID: session, resetsAt: reset.addingTimeInterval(5 * 3600)))
        // 保留之後才開始的手動送出才會解除。
        store.markUserConfirmed(sessionID: session, at: reset.addingTimeInterval(40))
        #expect(!store.blocks(sessionID: session, resetsAt: reset.addingTimeInterval(5 * 3600)))
    }

    private func bucket(used: Double, reset: Date?, reached: String? = nil) -> LimitBucket {
        LimitBucket(limitID: "codex", modelSlug: nil, windows: [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: reset)],
                    limitReachedType: reached)
    }

    private func snap(_ at: Date, allowed: Bool? = false, _ b: LimitBucket, spend: Bool? = nil, topReached: String? = nil) -> UsageSnapshot {
        UsageSnapshot(provider: .codex, windows: b.windows, observedAt: at, source: .codexAppServer, limitReachedType: topReached,
                      accountID: "A", usageAllowed: allowed, buckets: [b], spendControlReached: spend)
    }

    @Test func costBarrierAtTheStopNeverBecomesAWitness() {
        let stop = Date(timeIntervalSince1970: 1_894_000_000)
        let r = stop.addingTimeInterval(1800)
        let turn = CodexTurnSummary(id: "stop-1", status: "failed", errorInfo: "usageLimitExceeded", completedAt: stop)
        for (reached, top) in [("workspace_member_usage_limit_reached", false), ("workspace_owner_usage_limit_reached", true),
                               ("workspace_member_credits_depleted", false), ("workspace_owner_credits_depleted", true)] {
            var l = CodexQuotaObservations()
            l.observe(snap(stop.addingTimeInterval(-30), allowed: true, bucket(used: 90, reset: r)), now: stop.addingTimeInterval(-30))
            // 中止時：一般桶 100%，明確工作區上限／credits 用盡，花費布林缺失。
            let capped = top ? snap(stop.addingTimeInterval(10), bucket(used: 100, reset: r), topReached: reached)
                             : snap(stop.addingTimeInterval(10), bucket(used: 100, reset: r, reached: reached))
            l.observe(capped, now: capped.observedAt)
            // 之後原因欄消失：不得用中止時的資料授權。
            let cleared = snap(stop.addingTimeInterval(400), bucket(used: 100, reset: r))
            l.observe(cleared, now: cleared.observedAt)
            #expect((try? l.bindTimed(sessionID: session, turn: turn, model: "m", snapshot: cleared, now: cleared.observedAt,
                                      settings: .init()).get()) == nil, "\(reached)")
        }
        // 一般週期用盡（rate_limit_reached）仍保留使用者授權的路徑。
        var ordinary = CodexQuotaObservations()
        ordinary.observe(snap(stop.addingTimeInterval(-30), allowed: true, bucket(used: 90, reset: r)), now: stop.addingTimeInterval(-30))
        let full = snap(stop.addingTimeInterval(10), bucket(used: 100, reset: r, reached: "rate_limit_reached"))
        ordinary.observe(full, now: full.observedAt)
        #expect((try? ordinary.bindTimed(sessionID: session, turn: turn, model: "m", snapshot: full, now: full.observedAt,
                                         settings: .init()).get()) != nil)
    }

    @Test func costBarrierBlocksDeferral() throws {
        let stop = Date(timeIntervalSince1970: 1_894_000_000)
        let r = stop.addingTimeInterval(1800)
        var l = CodexQuotaObservations()
        l.observe(snap(stop.addingTimeInterval(-30), allowed: true, bucket(used: 90, reset: r)), now: stop.addingTimeInterval(-30))
        let full = snap(stop.addingTimeInterval(10), bucket(used: 100, reset: r))
        l.observe(full, now: full.observedAt)
        let turn = CodexTurnSummary(id: "stop-1", status: "failed", errorInfo: "usageLimitExceeded", completedAt: stop)
        let auth = try l.bindTimed(sessionID: session, turn: turn, model: "m", snapshot: full, now: full.observedAt, settings: .init()).get()
        let now = r.addingTimeInterval(-60)
        let later = r.addingTimeInterval(3600)
        let depleted = snap(now, bucket(used: 100, reset: later, reached: "workspace_owner_credits_depleted"))
        let result = CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: depleted, now: now)
        if case .wait = result {} else { Issue.record("cost barrier must not defer: \(result)") }
        if case .send = CodexTimedResumePolicy.preflight(auth, deferredTo: nil, snapshot: snap(r.addingTimeInterval(30), bucket(used: 3, reset: later,
            reached: "workspace_member_usage_limit_reached")), now: r.addingTimeInterval(30)) { Issue.record("cap must not send") }
        // 同一份資料沒有障礙時正常延期。
        #expect(CodexTimedResumePolicy.evaluate(auth, deferredTo: nil, live: snap(now, bucket(used: 100, reset: later)), now: now) == .defer(later))
    }
}

/// 第六輪審查：兩種自動型態共用工作階段抑制；精確模型桶也採共同費用障礙。
@Suite struct CodexCrossBasisTests {
    let session = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let stop = Date(timeIntervalSince1970: 1_894_000_000)

    private func snap(_ offset: TimeInterval, allowed: Bool?, used: Double, reset: Date, model: Bool,
                      generalReached: String? = nil) -> UsageSnapshot {
        let w = [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: reset)]
        var buckets = [LimitBucket(limitID: "codex", modelSlug: nil, windows: w, limitReachedType: generalReached)]
        if model { buckets.append(LimitBucket(limitID: "m-meter", modelSlug: "m", windows: w, limitReachedType: nil)) }
        return UsageSnapshot(provider: .codex, windows: w, observedAt: stop.addingTimeInterval(offset), source: .codexAppServer,
                             accountID: "A", usageAllowed: allowed, buckets: buckets)
    }

    private func detect(model: Bool, blocked: @escaping (String, Date) -> Bool) -> BlockedSession? {
        let reset = stop.addingTimeInterval(1800)
        var l = CodexQuotaObservations()
        l.observe(snap(-30, allowed: true, used: 90, reset: reset, model: model), now: stop.addingTimeInterval(-30))
        let denied = snap(10, allowed: false, used: 100, reset: reset, model: model)
        l.observe(denied, now: denied.observedAt)
        let turn = CodexTurnSummary(id: "stop-2", status: "failed", errorInfo: "usageLimitExceeded", completedAt: stop)
        let info = CodexSessionInfo(id: session, threadName: "x", cwd: "/tmp", startedAt: nil, lastActivity: stop, rolloutPath: "/x")
        return BlockedSessionDetector.codex(sessions: [info], latestTurns: [session: turn], snapshot: denied, now: denied.observedAt,
                                            evidence: [session: CodexBlockEvidence(turnModel: "m", creatorAccountHash: nil, liveAccountID: "A")],
                                            observations: l, timedResume: true, timedSessionBlocked: blocked).first
    }

    @Test func existingReservationBlocksBothBasesUntilManualRearm() throws {
        let store = CodexTimedSessionStore(directory: TestSupport.tempDir())
        let earlier = stop.addingTimeInterval(-6 * 3600)
        // 先前已有一次尚未經使用者手動確認的自動嘗試（不論型態）。
        #expect(store.reserve(sessionID: session, anchorTurnID: "stop-1", effectiveReset: earlier, now: earlier.addingTimeInterval(30)))
        let check: (String, Date) -> Bool = { store.blocks(sessionID: $0, resetsAt: $1) }
        // 新中止出現精確模型桶（嚴格路徑）：仍不自動送出。
        let strict = try #require(detect(model: true, blocked: check))
        #expect(strict.codex?.sessionAuthorization == nil)
        let gap = L10n.display(strict.codex?.evidenceGap ?? "", in: .zhHant)
        #expect(gap.contains("手動繼續"))
        // 反向：只有一般桶（定時路徑）也不送。
        #expect(try #require(detect(model: false, blocked: check)).codex?.sessionAuthorization == nil)
        // 沒有先前保留時兩種都能取得授權（正向控制）。
        #expect(detect(model: true, blocked: { _, _ in false })?.codex?.sessionAuthorization?.basis == .modelBucket)
        #expect(detect(model: false, blocked: { _, _ in false })?.codex?.sessionAuthorization?.basis == .generalBucketTimed)
        // 使用者手動繼續後，新週期的中止才再評估。
        store.markUserConfirmed(sessionID: session, at: earlier.addingTimeInterval(60))
        #expect(detect(model: true, blocked: check)?.codex?.sessionAuthorization?.basis == .modelBucket)
        // 同一個工作階段只能保留一次，不論型態（第二個錨點在最後原子保留被拒）。
        let fresh = CodexTimedSessionStore(directory: TestSupport.tempDir())
        let firstReserve = fresh.reserve(sessionID: session, anchorTurnID: "strict-anchor", effectiveReset: stop, now: stop.addingTimeInterval(30))
        let secondReserve = fresh.reserve(sessionID: session, anchorTurnID: "timed-anchor", effectiveReset: stop.addingTimeInterval(5 * 3600),
                                          now: stop.addingTimeInterval(5 * 3600 + 30))
        #expect(firstReserve && !secondReserve)
    }

    @Test func strictRestoreHonoursCostBarrierInAnyBucket() throws {
        let item = try #require(detect(model: true, blocked: { _, _ in false }))
        let plan = try ResumePlan(provider: .codex, sessionID: item.sessionID, sessionTitle: "x", cwd: "/tmp", blockedWindow: item.blockedWindow,
                                  expectedResetAt: item.resetsAt, origin: .autoDetected, createdAt: stop.addingTimeInterval(20), codex: item.codex)
        let reset = try #require(item.resetsAt)
        let later = reset.addingTimeInterval(60)
        func recovered(_ reached: String?) -> UsageSnapshot {
            let w = [UsageWindow(kind: .fiveHour, usedPercent: 3, resetsAt: later.addingTimeInterval(5 * 3600))]
            return UsageSnapshot(provider: .codex, windows: w, observedAt: later, source: .codexAppServer, accountID: "A", usageAllowed: true,
                                 buckets: [LimitBucket(limitID: "codex", modelSlug: nil, windows: w, limitReachedType: reached),
                                           LimitBucket(limitID: "m-meter", modelSlug: "m", windows: w, limitReachedType: nil)])
        }
        #expect(RestoreDetector.codexDecision(plan, snapshot: recovered(nil), now: later) == .restored)   // 正向控制
        for reached in ["workspace_member_usage_limit_reached", "workspace_owner_usage_limit_reached",
                        "workspace_member_credits_depleted", "workspace_owner_credits_depleted"] {
            #expect(RestoreDetector.codexDecision(plan, snapshot: recovered(reached), now: later) != .restored, "\(reached)")
        }
    }
}
