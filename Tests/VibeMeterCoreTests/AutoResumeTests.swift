import Foundation
import Testing
@testable import VibeMeterCore

private let t0 = Date(timeIntervalSince1970: 1_794_190_000)
private let account = ClaudeAccountIdentity(authMethod: "claude.ai", orgID: "org-1", subscriptionType: "pro", accountKey: "k1")
private let codexCtx = CodexBlockEvidence(turnModel: "gpt-test", creatorAccountHash: nil,
                                           officialAccountAtBlock: "acct-1", liveAccountID: "acct-1")
    .context(anchorTurnID: "turn-1")
private func claudeCtx(model: String? = "claude-opus-5-5", limit: String? = "five_hour", overage: String? = "rejected",
                       account acct: ClaudeAccountIdentity? = account, verifiedAccountAtBlock: Bool? = true) -> ClaudeResumeContext {
    ClaudeResumeContext(model: model, limitType: limit, overageStatus: overage, account: acct, anchorMessageUUID: "msg-1",
                        verifiedAccountAtBlock: verifiedAccountAtBlock)
}

private func codexPlan(reset: TimeInterval? = 3600, ctx: CodexResumeContext? = codexCtx) throws -> ResumePlan {
    try ResumePlan(provider: .codex, sessionID: TestSupport.sessionA, sessionTitle: "任務", cwd: "/tmp",
                   blockedWindow: .fiveHour, expectedResetAt: reset.map { t0.addingTimeInterval($0) }, createdAt: t0, codex: ctx)
}

private func claudePlan(_ ctx: ClaudeResumeContext = claudeCtx(), reset: TimeInterval? = 3600) throws -> ResumePlan {
    try ResumePlan(provider: .claudeCode, sessionID: TestSupport.sessionA, sessionTitle: "任務", cwd: "/tmp",
                   blockedWindow: .fiveHour, expectedResetAt: reset.map { t0.addingTimeInterval($0) }, createdAt: t0, claude: ctx)
}

/// 重設後的 Codex app-server 即時資料。
private func live(_ fiveHour: Double, weekly: Double = 60, at offset: TimeInterval = 3700, allowed: Bool? = true,
                  account: String? = "acct-1", source: DataSource = .codexAppServer, reached: String? = nil) -> (UsageSnapshot, Date) {
    let at = t0.addingTimeInterval(offset)
    let windows = [
        UsageWindow(kind: .fiveHour, usedPercent: fiveHour, resetsAt: at.addingTimeInterval(18000)),
        UsageWindow(kind: .weekly, usedPercent: weekly, resetsAt: at.addingTimeInterval(86400)),
    ]
    return (UsageSnapshot(provider: .codex, windows: windows, observedAt: at, source: source,
                          limitReachedType: reached, accountID: account, usageAllowed: allowed,
                          buckets: [LimitBucket(limitID: "fixture", modelSlug: "gpt-test", windows: windows, limitReachedType: reached)]), at)
}

private func state(_ plan: ResumePlan, _ event: ResumeEvent) -> ResumePlan.State { ResumeReducer.reduce(plan, event).0.state }

private func isNeedsConfirmation(_ s: ResumePlan.State) -> Bool {
    if case .needsConfirmation = s { return true }
    return false
}

@Suite struct ResumePlanIdentityTests {
    @Test func validatesIdentity() {
        #expect(throws: ResumePlanError.invalidSessionID) {
            try ResumePlan(provider: .codex, sessionID: "thread; rm -rf ~", sessionTitle: "", cwd: "/tmp", blockedWindow: .fiveHour, expectedResetAt: nil)
        }
        #expect(throws: ResumePlanError.unsupportedProvider) {
            try ResumePlan(provider: .cursor, sessionID: TestSupport.sessionA, sessionTitle: "", cwd: "/tmp", blockedWindow: .fiveHour, expectedResetAt: nil)
        }
        #expect(throws: ResumePlanError.invalidWorkingDirectory) {
            try ResumePlan(provider: .codex, sessionID: TestSupport.sessionA, sessionTitle: "", cwd: "rel", blockedWindow: .fiveHour, expectedResetAt: nil)
        }
    }

    @Test func incompleteContextStartsAsNeedsConfirmation() throws {
        #expect(try codexPlan().state == .waiting)
        #expect(isNeedsConfirmation(try codexPlan(ctx: nil).state))
        #expect(isNeedsConfirmation(try codexPlan(ctx: CodexResumeContext(accountID: nil, anchorTurnID: "t", verifiedLimitFailure: true)).state))
        #expect(isNeedsConfirmation(try codexPlan(ctx: CodexResumeContext(accountID: "a", anchorTurnID: nil, verifiedLimitFailure: false)).state))
        #expect(isNeedsConfirmation(try codexPlan(ctx: CodexResumeContext(
            accountID: "a", anchorTurnID: "t", verifiedLimitFailure: false)).state))
        #expect(isNeedsConfirmation(try codexPlan(ctx: CodexResumeContext(
            accountID: "a", anchorTurnID: "t", verifiedLimitFailure: true)).state))
        // Claude Code 交給官方原生自動繼續：任何 Claude 計畫都不會進入自動等待。
        #expect(try claudePlan().state == .needsConfirmation(reason: ClaudeNativeContinue.handledNatively, at: t0))
        #expect(isNeedsConfirmation(try claudePlan(claudeCtx(verifiedAccountAtBlock: nil)).state))
        let apiKey = ClaudeAccountIdentity(authMethod: "api_key", orgID: nil, subscriptionType: nil, accountKey: "x")
        #expect(isNeedsConfirmation(try claudePlan(claudeCtx(account: apiKey)).state))      // API 計費帳戶
    }
}

@Suite struct CodexRestoreTests {
    @Test func resetTimeAlonePercentagesAloneOrLocalLogsNeverConfirm() throws {
        let p = try codexPlan()
        let before = UsageSnapshot(provider: .codex, windows: [UsageWindow(kind: .fiveHour, usedPercent: 5, resetsAt: t0.addingTimeInterval(3600))],
                                   observedAt: t0.addingTimeInterval(100), source: .codexAppServer, accountID: "acct-1", usageAllowed: true)
        #expect(state(p, .observed(before, now: t0.addingTimeInterval(3700), autoContinue: true)) == .waiting)
        // 本機 rollout 紀錄（即使百分比低、時間在重設後）不能作為恢復依據
        let (log, n) = live(0, source: .codexRolloutLog)
        #expect(state(p, .observed(log, now: n, autoContinue: true)) == .waiting)
        for (snap, now) in [live(95), live(0, weekly: 100), live(0, reached: "rate_limit_reached")] {
            #expect(state(p, .observed(snap, now: now, autoContinue: true)) == .waiting)
        }
        let (stale, sn) = live(3)
        #expect(state(p, .observed(stale, now: sn.addingTimeInterval(DataSource.codexAppServer.staleAfter + 1), autoContinue: true)) == .waiting)
    }

    @Test func ordinaryUsageAllowedMustBeExplicitlyTrue() throws {
        let p = try codexPlan()
        let (denied, n1) = live(0, allowed: false)
        #expect(state(p, .observed(denied, now: n1, autoContinue: true)) == .waiting)
        // null：依官方註解不可由百分比推斷恢復 → 繼續等待（不送出、不宣稱恢復），之後的明確許可仍可確認。
        let (unknown, n2) = live(0, allowed: nil)
        let (next, effects) = ResumeReducer.reduce(p, .observed(unknown, now: n2, autoContinue: true))
        #expect(next.state == .waiting)
        #expect(effects.isEmpty)
        let (ok, n3) = live(0, allowed: true)
        let (launched, e) = ResumeReducer.reduce(p, .observed(ok, now: n3, autoContinue: true))
        #expect(launched.state == .launching(startedAt: n3))
        #expect(e == [.launch])
    }

    @Test func accountMustMatch() throws {
        let p = try codexPlan()
        let (other, n) = live(0, account: "acct-2")
        #expect(isNeedsConfirmation(state(p, .observed(other, now: n, autoContinue: true))))
        // 換帳號即使還沒到重設時間也立刻停止
        let (otherEarly, ne) = live(100, at: 100, account: "acct-2")
        #expect(isNeedsConfirmation(state(p, .observed(otherEarly, now: ne, autoContinue: true))))
        let (missing, nm) = live(0, account: nil)
        #expect(isNeedsConfirmation(state(p, .observed(missing, now: nm, autoContinue: true))))
    }

    @Test func autoOffWaitsForUser() throws {
        let (ok, n) = live(0)
        let (manual, effects) = ResumeReducer.reduce(try codexPlan(), .observed(ok, now: n, autoContinue: false))
        #expect(manual.state == .ready(confirmedAt: n))
        #expect(effects == [.notifyReady])
    }

    @Test func claudePlansIgnoreSnapshots() throws {
        var snap = live(0).0
        snap.provider = .claudeCode
        let plan = try claudePlan()
        #expect(state(plan, .observed(snap, now: snap.observedAt, autoContinue: true)) == plan.state)
    }
}

@Test func codexAutomaticPreflightRequiresOfficialLimitFailure() {
    let normal = CodexTurnSummary(id: "t", status: "completed")
    let limited = CodexTurnSummary(id: "t", status: "failed", errorInfo: "usageLimitExceeded")
    #expect(LaunchDecision.codexPreflight(latest: normal, anchorTurnID: "t") == .unchanged)
    #expect(LaunchDecision.codexPreflight(latest: normal, anchorTurnID: "t", requireLimitFailure: true) != .unchanged)
    #expect(LaunchDecision.codexPreflight(latest: limited, anchorTurnID: "t", requireLimitFailure: true) == .unchanged)
}

@Suite struct ClaudeAccountTests {
    @Test func accountIdentityParsing() throws {
        let a = try #require(ClaudeAccountIdentity.parse(#"{"loggedIn":true,"authMethod":"claude.ai","email":"A@x.com","orgId":"o1","subscriptionType":"pro"}"#))
        let b = try #require(ClaudeAccountIdentity.parse(#"{"loggedIn":true,"authMethod":"claude.ai","email":"a@x.com","orgId":"o1"}"#))
        #expect(a.accountKey == b.accountKey && a.accountKey.count == 16 && !a.accountKey.contains("@"))
        #expect(a.isSubscription)
        let other = try #require(ClaudeAccountIdentity.parse(#"{"loggedIn":true,"authMethod":"claude.ai","email":"b@x.com","orgId":"o1"}"#))
        #expect(other.accountKey != a.accountKey)
        #expect(ClaudeAccountIdentity.parse(#"{"loggedIn":false}"#) == nil)
        #expect(ClaudeAccountIdentity.parse(#"{"loggedIn":true,"authMethod":"claude.ai"}"#) == nil)  // 無 email → 帳戶不明
    }
}

@Suite struct ResumeLifecycleTests {
    @Test func deliversExactlyOnceAndConfirmsActivity() throws {
        var book = ResumePlanBook()
        let p = try codexPlan()
        try book.add(p)
        #expect(throws: ResumePlanError.duplicate) { try book.add(try codexPlan()) }
        #expect(book.apply(.userLaunch(now: t0), to: p.id).isEmpty)
        let (ok, n) = live(0)
        #expect(book.observe(ok, now: n, autoContinue: true).map(\.1) == [.launch])
        #expect(book.observe(ok, now: n, autoContinue: true).isEmpty)
        #expect(book.apply(.userLaunch(now: n), to: p.id).isEmpty)
        book.apply(.delivered(.codexQueue, now: n), to: p.id)
        #expect(book.plan(p.id)?.state == .launched(at: n))
        book.apply(.activityObserved(now: n.addingTimeInterval(30)), to: p.id)
        #expect(book.plan(p.id)?.state == .resumed(at: n.addingTimeInterval(30)))
        #expect(book.active.isEmpty)
    }

    @Test func failuresNeverAutoRetryButUserCan() throws {
        var book = ResumePlanBook()
        let p = try codexPlan()
        try book.add(p)
        let (ok, n) = live(0)
        _ = book.observe(ok, now: n, autoContinue: true)
        book.apply(.launchFailed("無法開啟終端機", now: n), to: p.id)
        #expect(book.observe(ok, now: n, autoContinue: true).isEmpty)
        #expect(book.apply(.userLaunch(now: n), to: p.id) == [.launch])
        book.apply(.launchSkipped("使用中", now: n), to: p.id)
        try book.add(try codexPlan())
        #expect(book.apply(.userLaunch(now: n), to: p.id).isEmpty)
    }

    @Test func needsConfirmationOnlyLaunchesByUser() throws {
        var book = ResumePlanBook()
        let p = try codexPlan(ctx: nil)
        try book.add(p)
        let (ok, n) = live(0)
        #expect(book.observe(ok, now: n, autoContinue: true).isEmpty)          // 不會自動送出
        #expect(book.apply(.userLaunch(now: n), to: p.id) == [.launch])         // 使用者明確按下才送
        #expect(throws: ResumePlanError.duplicate) { try book.add(try codexPlan()) }
    }

    @Test func cancelAndJSON() throws {
        var book = ResumePlanBook()
        let p = try claudePlan()
        try book.add(p)
        let decoded = try VibeMeterJSON.decoder.decode(ResumePlanBook.self, from: VibeMeterJSON.encoder.encode(book))
        #expect(decoded.plans.map(\.id) == book.plans.map(\.id))
        #expect(decoded.plans.first?.claude?.verifiedAccountAtBlock == nil)
        book.apply(.userCancel(now: t0), to: p.id)
        #expect(book.plan(p.id)?.state == .cancelled(at: t0))
    }
}

@Suite struct LaunchDecisionTests {
    @Test func preflightRequiresAnchorStillLatest() {
        #expect(LaunchDecision.codexPreflight(latest: CodexTurnSummary(id: "turn-1", status: "failed", errorInfo: "usageLimitExceeded"),
                                              anchorTurnID: "turn-1") == .unchanged)
        #expect(LaunchDecision.codexPreflight(latest: CodexTurnSummary(id: "turn-2", status: "completed"), anchorTurnID: "turn-1")
                == .changed("已有新的 turn（可能已手動繼續）"))
        #expect(LaunchDecision.codexPreflight(latest: CodexTurnSummary(id: "turn-1", status: "inProgress"), anchorTurnID: "turn-1")
                == .changed("Codex 正在執行新的 turn"))
        #expect(LaunchDecision.codexPreflight(latest: nil, anchorTurnID: "turn-1") == .unknown("讀不到最新 turn"))
        #expect(LaunchDecision.codexPreflight(latest: nil, anchorTurnID: nil) == .unknown("沒有錨點 turn"))

        let hit = ClaudeTranscriptInfo.LimitHit(at: t0, resetsAt: nil, window: .fiveHour, messageUUID: "msg-1")
        let blocked = ClaudeTranscriptInfo(id: TestSupport.sessionA, cwd: "/tmp", transcriptPath: "/x", lastActivity: t0, limitHit: hit)
        #expect(LaunchDecision.claudePreflight(current: blocked, anchorMessageUUID: "msg-1") == .unchanged)
        var continued = blocked
        continued.limitHit = nil
        #expect(LaunchDecision.claudePreflight(current: continued, anchorMessageUUID: "msg-1") == .changed("已有新的對話（可能已手動繼續）"))
    }

    @Test func picksDeliveryAndSkipsBusyOrChangedSessions() throws {
        let p = try codexPlan()
        let now = t0.addingTimeInterval(4000)
        #expect(LaunchDecision.decide(p, lastActivity: now.addingTimeInterval(-30), threadLockHeld: true, cwdExists: true, preflight: .unchanged, now: now)
                == .skip("工作階段 2 分鐘內仍有活動，可能已在執行"))
        #expect(LaunchDecision.decide(p, lastActivity: t0.addingTimeInterval(-60), threadLockHeld: true, cwdExists: true, preflight: .unchanged, now: now)
                == .deliver(.codexQueue))
        #expect(LaunchDecision.decide(p, lastActivity: nil, threadLockHeld: false, cwdExists: true, preflight: .unchanged, now: now) == .deliver(.terminal))
        #expect(LaunchDecision.decide(p, lastActivity: nil, threadLockHeld: false, cwdExists: false, preflight: .unchanged, now: now) == .skip("工作目錄不存在"))
        #expect(LaunchDecision.decide(p, lastActivity: nil, threadLockHeld: true, cwdExists: true, preflight: .changed("x"), now: now) == .skip("x"))
        guard case .skip(let reason) = LaunchDecision.decide(p, lastActivity: nil, threadLockHeld: true, cwdExists: true, preflight: .unknown("y"), now: now)
        else { Issue.record("unknown preflight must skip"); return }
        #expect(L10n.display(reason, in: .zhHant) == "無法確認工作階段狀態：y")
        #expect(ResumeExecutor.queueArguments(p) == ["queue", "--thread", TestSupport.sessionA, "--message", p.prompt])
    }
}

@Suite struct CodexBlockedDetectionTests {
    let now = t0.addingTimeInterval(600)
    func session(_ id: String, _ activityOffset: TimeInterval, cwd: String? = "/tmp/x") -> CodexSessionInfo {
        CodexSessionInfo(id: id, threadName: id.prefix(4).description, cwd: cwd, startedAt: nil,
                         lastActivity: t0.addingTimeInterval(activityOffset), rolloutPath: "/r")
    }
    let full = UsageSnapshot(provider: .codex, windows: [UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: t0.addingTimeInterval(3600))],
                             observedAt: t0, source: .codexAppServer, accountID: "acct-1", usageAllowed: false)
    let ids = [TestSupport.sessionA, TestSupport.sessionB, "0c0c0c0c-1111-4222-8333-944455556666", "0d0d0d0d-1111-4222-8333-944455556666"]

    @Test func onlyVerifiedUsageLimitTurnsAreBlocked() {
        let sessions = [session(ids[0], -60), session(ids[1], -90), session(ids[2], -120), session(ids[3], -30)]
        let turns: [String: CodexTurnSummary] = [
            ids[0]: CodexTurnSummary(id: "a1", status: "failed", errorInfo: "usageLimitExceeded", completedAt: t0.addingTimeInterval(-60)),
            ids[1]: CodexTurnSummary(id: "b1", status: "completed"),                                   // 已完成
            ids[2]: CodexTurnSummary(id: "c1", status: "inProgress"),                                  // 忙碌
            ids[3]: CodexTurnSummary(id: "d1", status: "failed", errorInfo: "serverOverloaded"),       // 其他錯誤
        ]
        let blocked = BlockedSessionDetector.codex(sessions: sessions, latestTurns: turns, snapshot: full, now: now)
        #expect(blocked.map(\.sessionID) == [ids[0]])
        // 沒有中止時帳戶／模型證據 → 帳戶為空並記錄缺口（計畫會是待確認）
        #expect(blocked.first?.codex?.accountID == nil)
        #expect(blocked.first?.codex?.anchorTurnID == "a1")
        #expect(blocked.first?.codex?.verifiedLimitFailure == true)
        #expect(blocked.first?.codex?.verifiedAccountAndModelAtBlock != true)
        #expect(blocked.first?.codex?.evidenceGap != nil)
        #expect(blocked.first?.eventKey == "codex|\(ids[0])|a1")
        #expect(blocked.first?.resetsAt == t0.addingTimeInterval(3600))
        // 沒有官方 turn 資料時，額度滿＋近期活動不會被當成被擋住
        #expect(BlockedSessionDetector.codex(sessions: sessions, latestTurns: [:], snapshot: full, now: now).isEmpty)
    }

    @Test func subagentThreadsAreNeverBlockedOrCandidates() {
        var sub = session(ids[0], -60)
        sub.parentThreadID = ids[1]
        let turns = [ids[0]: CodexTurnSummary(id: "a1", status: "failed", errorInfo: "usageLimitExceeded")]
        #expect(BlockedSessionDetector.codex(sessions: [sub], latestTurns: turns, snapshot: full, now: now).isEmpty)
        #expect(BlockedSessionDetector.codexCandidates(sessions: [sub], now: now).isEmpty)
        #expect(BlockedSessionDetector.codexSuggestions(sessions: [sub], snapshot: full, latestTurns: [:]).isEmpty)
    }

    @Test func multipleVerifiedSessionsAndDedupeByTurn() {
        let sessions = [session(ids[0], -60), session(ids[1], -60)]
        var turns: [String: CodexTurnSummary] = [
            ids[0]: CodexTurnSummary(id: "a1", status: "failed", errorInfo: "usageLimitExceeded"),
            ids[1]: CodexTurnSummary(id: "b1", status: "interrupted", errorInfo: "usageLimitExceeded"),
        ]
        let first = BlockedSessionDetector.codex(sessions: sessions, latestTurns: turns, snapshot: full, now: now)
        #expect(Set(first.map(\.eventKey)).count == 2)
        // 同一個 turn 再偵測 → 同一個 eventKey（不會重複建立）；新的失敗 turn → 新的 eventKey
        #expect(BlockedSessionDetector.codex(sessions: sessions, latestTurns: turns, snapshot: full, now: now).map(\.eventKey) == first.map(\.eventKey))
        turns[ids[0]] = CodexTurnSummary(id: "a2", status: "failed", errorInfo: "usageLimitExceeded")
        let again = BlockedSessionDetector.codex(sessions: sessions, latestTurns: turns, snapshot: full, now: now)
        #expect(again.first { $0.sessionID == ids[0] }?.eventKey == "codex|\(ids[0])|a2")
    }

    @Test func rolloutSnapshotNeverProvidesAccount() {
        var log = full
        log.source = .codexRolloutLog
        let turns = [ids[0]: CodexTurnSummary(id: "a1", status: "failed", errorInfo: "usageLimitExceeded")]
        let blocked = BlockedSessionDetector.codex(sessions: [session(ids[0], -60)], latestTurns: turns, snapshot: log, now: now)
        #expect(blocked.first?.codex?.accountID == nil)  // → 計畫會是「待確認」
    }

    @Test func suggestionsRespectSnapshotTiming() {
        let sessions = [
            session(ids[0], -5 * 60),     // 快照前 5 分鐘有活動 → 建議
            session(ids[1], +10 * 60),    // 活動晚於快照 → 仍在工作，不建議
            session(ids[2], -3 * 3600),   // 很久以前 → 不建議
            session(ids[3], -2 * 60),     // 已確認最新 turn（已完成）→ 以官方為準，不建議
        ]
        let turns = [ids[3]: CodexTurnSummary(id: "d1", status: "completed")]
        #expect(BlockedSessionDetector.codexSuggestions(sessions: sessions, snapshot: full, latestTurns: turns) == [ids[0]])
        var notFull = full
        notFull.windows[0].usedPercent = 70
        #expect(BlockedSessionDetector.codexSuggestions(sessions: sessions, snapshot: notFull, latestTurns: [:]).isEmpty)
    }

    @Test func candidatesCheckRecentTurnsEvenAfterQuotaRecoveryAndAreCapped() {
        let many = (0..<8).map { i in session(String(format: "0e0e0e0%d-1111-4222-8333-944455556666", i), -Double(i) * 60) }
        #expect(BlockedSessionDetector.codexCandidates(sessions: many, now: now).count == BlockedSessionDetector.maxInspections)
        #expect(BlockedSessionDetector.codexCandidates(sessions: [session(ids[0], -60, cwd: nil)], now: now).isEmpty)
    }
}

@Suite struct ClaudeBlockedDetectionTests {
    func transcriptDir() throws -> URL {
        let root = TestSupport.tempDir()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let blocked = """
        {"type":"user","sessionId":"\(TestSupport.sessionA)","cwd":"/tmp/proj","timestamp":"2026-11-09T04:59:00.000Z","message":{"role":"user","content":"繼續"}}
        {"type":"assistant","uuid":"real-1","sessionId":"\(TestSupport.sessionA)","cwd":"/tmp/proj","timestamp":"2026-11-09T04:59:30.000Z","message":{"model":"claude-opus-5-5"}}
        {"type":"user","sessionId":"\(TestSupport.sessionA)","cwd":"/tmp/proj","timestamp":"2026-11-09T05:00:00.000Z","message":{"role":"user","content":"下一步"}}
        {"type":"assistant","uuid":"err-1","sessionId":"\(TestSupport.sessionA)","cwd":"/tmp/proj","timestamp":"2026-11-09T05:00:05.000Z","message":{"model":"<synthetic>"},"error":"rate_limit","isApiErrorMessage":true,"apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1794200000,"rateLimitType":"seven_day_opus","overageStatus":"rejected"}}}
        {"type":"system","subtype":"turn_duration","cwd":"/tmp/proj"}
        """
        try blocked.write(to: project.appendingPathComponent("\(TestSupport.sessionA).jsonl"), atomically: true, encoding: .utf8)
        let continued = blocked + "\n" + #"{"type":"user","sessionId":"\#(TestSupport.sessionB)","cwd":"/tmp/other","message":{"role":"user","content":"hi"}}"#
        try continued.write(to: project.appendingPathComponent("\(TestSupport.sessionB).jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: project.appendingPathComponent("not-a-uuid.jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func detectsModelWindowAndAnchor() throws {
        let store = ClaudeTranscriptStore(projectsDir: try transcriptDir())
        let sessions = store.recentSessions(now: Date())
        #expect(Set(sessions.map(\.id)) == [TestSupport.sessionA, TestSupport.sessionB])
        let a = try #require(sessions.first { $0.id == TestSupport.sessionA })
        #expect(a.lastModel == "claude-opus-5-5")                     // 排除 <synthetic>
        #expect(a.limitHit?.limitType == "seven_day_opus")
        #expect(a.limitHit?.window == .named("seven_day_opus"))
        #expect(a.limitHit?.messageUUID == "err-1")
        #expect(sessions.first { $0.id == TestSupport.sessionB }?.limitHit == nil)  // 之後又有對話
        let now = try #require(ISO8601.parse("2026-11-09T05:10:00Z"))
        let blocked = BlockedSessionDetector.claude(transcripts: sessions, now: now)
        #expect(blocked.map(\.sessionID) == [TestSupport.sessionA])
        #expect(blocked.first?.claude == ClaudeResumeContext(model: "claude-opus-5-5", limitType: "seven_day_opus", overageStatus: "rejected",
                                                             account: nil, anchorMessageUUID: "err-1"))
        #expect(blocked.first?.eventKey == "claudeCode|\(TestSupport.sessionA)|err-1")
        // 帳戶不明 → 計畫為待確認
        let noAccount = try #require(blocked.first)
        let plan = try ResumePlan(provider: .claudeCode, sessionID: noAccount.sessionID, sessionTitle: "", cwd: noAccount.cwd,
                                  blockedWindow: noAccount.blockedWindow, expectedResetAt: nil, claude: noAccount.claude)
        #expect(isNeedsConfirmation(plan.state))
        #expect(store.inspect(sessionID: TestSupport.sessionA.uppercased())?.limitHit?.messageUUID == "err-1")
    }
}

@Suite struct MigrationTests {
    @Test func copiesLegacyDataOnlyWhenNewIsMissingAndPreservesOldBridge() throws {
        let root = TestSupport.tempDir()
        let legacy = root.appendingPathComponent("Headroom"), current = root.appendingPathComponent("Vibe Meter")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("claude"), withIntermediateDirectories: true)
        try "{}".write(to: legacy.appendingPathComponent("resume-plans.json"), atomically: true, encoding: .utf8)
        let bridge = legacy.appendingPathComponent("bin/headroom-bridge")
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "fixture".write(to: bridge, atomically: true, encoding: .utf8)
        #expect(try LegacyMigration.migrateDataFolder(from: legacy, to: current))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("resume-plans.json").path))
        #expect(FileManager.default.fileExists(atPath: bridge.path))
        #expect(try !LegacyMigration.migrateDataFolder(from: legacy, to: current))
    }

    @Test func copiesOnlyMissingDefaults() throws {
        let legacy = try #require(UserDefaults(suiteName: "vibemeter-test-legacy-\(UUID())"))
        let current = try #require(UserDefaults(suiteName: "vibemeter-test-current-\(UUID())"))
        legacy.set(["codex|5h|1|80"], forKey: "firedAlertKeys")
        legacy.set(false, forKey: "autoContinue")
        current.set(true, forKey: "autoContinue")
        #expect(LegacyMigration.migrateDefaults(from: legacy, to: current, keys: ["firedAlertKeys", "autoContinue"]) == ["firedAlertKeys"])
        #expect(current.bool(forKey: "autoContinue"))
    }

    @Test func installerRecognizesLegacyBridge() throws {
        let root = TestSupport.tempDir()
        let settings = root.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"'/x/Headroom/bin/headroom-bridge' claude-statusline"},"hooks":{"StopFailure":[{"matcher":"rate_limit","hooks":[{"type":"command","command":"'/x/headroom-bridge' claude-stop-failure rate_limit"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        let installer = ClaudeSettingsInstaller(settingsURL: settings, paths: VibeMeterPaths(root: root.appendingPathComponent("vm")))
        let original = try Data(contentsOf: settings)
        #expect(installer.status() == .installed && installer.usesLegacyBridge())
        #expect(try Data(contentsOf: settings) == original)
        #expect(!FileManager.default.fileExists(atPath: installer.paths.backupsDir.path))
        let result = try installer.install(bridge: URL(fileURLWithPath: "/y/Vibe Meter/bin/vibemeter-bridge"))
        let backup = try #require(result)
        #expect(try Data(contentsOf: backup) == original)
        #expect(!installer.usesLegacyBridge() && installer.status() == .installed)
    }
}
