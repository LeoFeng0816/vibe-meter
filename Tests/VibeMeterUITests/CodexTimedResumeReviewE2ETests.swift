import Foundation
import Testing
@testable import VibeMeterCore
@testable import VibeMeterUI

/// 第二輪審查的端到端情境：真實 AppModel＋假 Codex CLI，輪詢與送出前查詢都以假時鐘標記觀察時間（可跨 36 小時）。
@MainActor
@Suite(.serialized) struct CodexTimedResumeReviewE2ETests {
    enum Case: String, CaseIterable, Sendable {
        /// 原重設 R，R−60s 已核對的同帳戶回應給 R+36h：持久化，重啟後 R+40s 不送，R+36h+30s 才送一次。
        case deferralAcrossRestart
        /// 同一模型別名有兩個桶：官方對應歧義，不得落回一般桶。
        case ambiguousModelBuckets
        /// 到期時仍 100%、沒有重設：依使用者授權嘗試一次。
        case stillFullNoReset
        /// 到期時仍 100%、重設仍是原時間（已過）：嘗試一次。
        case stillFullOldReset
        /// 到期時仍 100%、有較晚的有效重設：延到新時間＋30 秒。
        case stillFullLaterReset
        /// 工作區花費上限（布林為 false）：不送。
        case workspaceCap
        /// 工作區 credits 用盡（布林為 null）：不送。
        case creditsDepleted
    }

    final class Stamp: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date?
        func set(_ date: Date?) { lock.withLock { value = date } }
        var now: Date { lock.withLock { value ?? Date() } }
    }

    @Test(arguments: Case.allCases)
    func reviewScenario(_ scenario: Case) async throws {
        let h = try CodexTimedResumeE2ETests.Harness(scenario: .success)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = realNow - 300
        // R−60s 必須晚於初次輪詢（輪詢拒絕較舊的觀察時間）。
        let reset = realNow + 180
        try h.writeRollout(stop: stop, subagent: false, model: true)
        let stamp = Stamp()
        func state(allowed: Any, five: Double, fiveReset: Any, latest: [String: Any]? = nil, reached: Any = NSNull(),
                   spend: Any = NSNull(), extra: [[String: Any]] = [], week: Double? = nil, weekReset: Int? = nil) -> [String: Any] {
            var s: [String: Any] = ["account": "A", "allowed": allowed, "bucket": "codex", "five": five, "fiveReset": fiveReset,
             "turn": latest ?? ["id": "stop-1", "status": "failed", "startedAt": stop - 20, "completedAt": stop,
                                "error": ["codexErrorInfo": "usageLimitExceeded"]],
             "model": "fixture-model", "rateError": false, "queueExit": 0, "queueStderr": "",
             "reached": reached, "spend": spend, "extraBuckets": extra]
            if let week, let weekReset { s["week"] = week; s["weekReset"] = weekReset }
            return s
        }
        let extra: [[String: Any]] = scenario == .ambiguousModelBuckets
            ? [["limitId": "m-1", "normalModelSlug": "fixture-model"], ["limitId": "m-2", "normalModelSlug": "fixture-model"]] : []
        func makeApp() -> AppModel {
            let app = h.makeApp { stamp.now }
            app.codexLivePolling = false
            let binary = h.binary
            app.codexRateReader = { try await CodexAppServerClient(binary: binary, timeout: .seconds(20)).readRateLimits(now: { stamp.now }) }
            return app
        }
        let app = makeApp()
        let client = CodexAppServerClient(binary: h.binary, timeout: .seconds(20))
        try h.set(state(allowed: true, five: 90, fiveReset: reset, extra: extra))
        app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(stop - 30)) }))
        try h.set(state(allowed: false, five: 100, fiveReset: reset, extra: extra))
        app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(stop + 10)) }))
        await app.refresh()
        let plan = try #require(app.planBook.active.first)
        if scenario == .ambiguousModelBuckets {
            #expect(plan.codex?.sessionAuthorization == nil)
            try h.set(state(allowed: true, five: 3, fiveReset: realNow + 5 * 3600, extra: extra))
            stamp.set(Date(timeIntervalSince1970: Double(reset) + 30))
            await app.refresh()
            #expect(h.queued.isEmpty)
            return
        }
        #expect(plan.codex?.sessionAuthorization?.basis == .generalBucketTimed)

        let due = Date(timeIntervalSince1970: Double(reset) + 30)
        switch scenario {
        case .deferralAcrossRestart:
            let r2 = reset + 36 * 3600
            stamp.set(Date(timeIntervalSince1970: Double(reset) - 60))
            // 36 小時的延期只可能來自週額度（超過 5 小時週期長度的重設會被排除）。
            try h.set(state(allowed: false, five: 100, fiveReset: reset, week: 100, weekReset: r2))
            await app.requestCodexPoll(reason: .refresh)
            await app.runTimedResumes()
            let deferred = try #require(app.planBook.plan(plan.id))
            #expect(deferred.codex?.timedDeferredResetAt == Date(timeIntervalSince1970: Double(r2)))
            #expect(app.codexTimedDue(for: deferred) == Date(timeIntervalSince1970: Double(r2) + 30))
            app.stopBackgroundWork()
            // 關閉後在 R+40s 重新啟動：0 送出，仍顯示 R+36h+30s。
            let restarted = makeApp()
            stamp.set(Date(timeIntervalSince1970: Double(reset) + 40))
            await restarted.refresh()
            #expect(h.queued.isEmpty)
            let rebound = try #require(restarted.planBook.active.first)
            #expect(rebound.codex?.sessionAuthorization?.basis == .generalBucketTimed)
            #expect(restarted.codexTimedDue(for: rebound) == Date(timeIntervalSince1970: Double(r2) + 30))
            // 原證據的 12 小時保留期之後仍有效；新時間＋29 秒不送，＋30 秒送一次。
            try h.set(state(allowed: true, five: 3, fiveReset: r2 + 5 * 3600, week: 40, weekReset: r2 + 6 * 86400))
            stamp.set(Date(timeIntervalSince1970: Double(r2) + 29))
            await restarted.refresh()
            #expect(h.queued.isEmpty)
            stamp.set(Date(timeIntervalSince1970: Double(r2) + 30))
            await restarted.refresh()
            #expect(h.queued.count == 1)
            let again = makeApp()
            await again.refresh()
            #expect(h.queued.count == 1, "restart after dispatch must not resend")
        case .stillFullNoReset, .stillFullOldReset:
            stamp.set(due)
            try h.set(state(allowed: false, five: 100, fiveReset: scenario == .stillFullNoReset ? NSNull() : reset))
            await app.refresh()
            #expect(h.queued.count == 1)
            let note = L10n.display(app.planBook.plan(plan.id)?.note ?? "", in: .zhHant)
            #expect(note.contains("仍回報已滿"))
            #expect(!note.contains("已確認恢復"))
            await app.refresh()
            #expect(h.queued.count == 1)
        case .stillFullLaterReset:
            let later = reset + 3600
            stamp.set(due)
            try h.set(state(allowed: true, five: 100, fiveReset: later))
            await app.refresh()
            #expect(h.queued.isEmpty)
            #expect(app.codexTimedDue(for: try #require(app.planBook.plan(plan.id))) == Date(timeIntervalSince1970: Double(later) + 30))
            try h.set(state(allowed: true, five: 3, fiveReset: later + 5 * 3600))
            stamp.set(Date(timeIntervalSince1970: Double(later) + 29))
            await app.refresh()
            #expect(h.queued.isEmpty)
            stamp.set(Date(timeIntervalSince1970: Double(later) + 30))
            await app.refresh()
            #expect(h.queued.count == 1)
        case .workspaceCap, .creditsDepleted:
            stamp.set(due)
            try h.set(state(allowed: true, five: 3, fiveReset: realNow + 5 * 3600,
                            reached: scenario == .workspaceCap ? "workspace_member_usage_limit_reached" : "workspace_owner_credits_depleted",
                            spend: scenario == .workspaceCap ? false : NSNull()))
            await app.refresh()
            stamp.set(due.addingTimeInterval(120))
            await app.refresh()
            #expect(h.queued.isEmpty)
            let note = L10n.display(app.planBook.plan(plan.id)?.note ?? "", in: .zhHant)
            #expect(note.contains("費用控制") || note.contains("工作區"))
        case .ambiguousModelBuckets:
            break
        }
        #expect(!h.methods.contains { $0.contains("rateLimitResetCredit") })
    }
}
