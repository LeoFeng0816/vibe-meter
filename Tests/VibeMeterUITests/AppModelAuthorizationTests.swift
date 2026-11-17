import Foundation
import Testing
import VibeMeterCore
@testable import VibeMeterUI

@MainActor
@Suite struct AppModelAuthorizationTests {
    enum Revocation: CaseIterable, Sendable {
        case autoOff, agentOff, cancel, autoOffAndBackOn
    }

    let account = ClaudeAccountIdentity(authMethod: "claude.ai", orgID: "test-org", subscriptionType: "test", accountKey: "test")

    private func plan(_ provider: ProviderID) throws -> ResumePlan {
        try ResumePlan(provider: provider, sessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                       sessionTitle: "範例", cwd: "/tmp", blockedWindow: .fiveHour,
                       expectedResetAt: Date().addingTimeInterval(-60),
                       // 模擬「未來取得官方中止時帳戶證據」的計畫（目前正式資料流程不會產生 verified=true）。
                       codex: CodexBlockEvidence(turnModel: "test-model", creatorAccountHash: nil,
                                                 officialAccountAtBlock: "test", liveAccountID: "test")
                           .context(anchorTurnID: "test-turn"),
                       claude: ClaudeResumeContext(model: "test-model", limitType: "five_hour", overageStatus: "rejected",
                                                  account: account, anchorMessageUUID: "test-msg", verifiedAccountAtBlock: true))
    }

    private func revoke(_ action: Revocation, model: AppModel, plan: ResumePlan) {
        switch action {
        case .autoOff: model.setAutoContinue(false)
        case .agentOff: model.setAgent(plan.provider, enabled: false)
        case .cancel: model.cancelPlan(plan.id)
        case .autoOffAndBackOn:
            model.setAutoContinue(false)
            model.setAutoContinue(true)
        }
    }

    @Test(arguments: Revocation.allCases)
    func revokedWhilePreflightingNeverStartsDelivery(_ action: Revocation) async throws {
        let model = AppModel(preview: ())
        var plan = try plan(.codex)
        plan.state = .launching(startedAt: Date())
        try model.planBook.add(plan)
        let auth = model.authorization(for: .codex, automatic: true)
        let preflight = Pause<SessionPreflight>()
        var deliveries = 0

        let attempt = Task {
            await model.execute(plan, authorization: auth, checkPreflight: { _, automatic in
                #expect(automatic)
                return await preflight.suspend()
            }, startDelivery: { _, _ in
                deliveries += 1
                return Task {}
            })
        }
        guard await preflight.waitUntilSuspended() else { Issue.record("preflight never started"); attempt.cancel(); preflight.release(with: .unknown("timed out")); return }
        revoke(action, model: model, plan: plan)
        preflight.release(with: .unchanged)
        await attempt.value

        #expect(deliveries == 0)
        let state = try #require(model.planBook.plan(plan.id)?.state)
        switch action {
        case .autoOff: if case .ready = state {} else { Issue.record("expected deferred ready plan") }
        case .cancel: if case .cancelled = state {} else { Issue.record("expected cancellation to be preserved") }
        case .agentOff, .autoOffAndBackOn:
            if case .skipped = state {} else { Issue.record("expected revoked attempt to be skipped") }
        }
    }

    @Test func obsoletePreflightCannotDeliverANewerAttempt() async throws {
        let model = AppModel(preview: ())
        var plan = try plan(.codex)
        let firstAttempt = Date()
        plan.state = .launching(startedAt: firstAttempt)
        try model.planBook.add(plan)
        let auth = model.authorization(for: .codex, automatic: true)
        let preflight = Pause<SessionPreflight>()
        let attempt = Task {
            await model.execute(plan, authorization: auth, checkPreflight: { _, _ in
                await preflight.suspend()
            }, startDelivery: { _, _ in
                Issue.record("stale attempt initiated delivery")
                return Task {}
            })
        }
        guard await preflight.waitUntilSuspended() else { Issue.record("preflight never started"); attempt.cancel(); preflight.release(with: .unknown("timed out")); return }
        model.planBook.apply(.launchFailed("fixture", now: firstAttempt), to: plan.id)
        let nextAttempt = firstAttempt.addingTimeInterval(1)
        model.planBook.apply(.userLaunch(now: nextAttempt), to: plan.id)
        preflight.release(with: .unchanged)
        await attempt.value
        #expect(model.planBook.plan(plan.id)?.state == .launching(startedAt: nextAttempt))
    }

    @Test func explicitlyRequestedLaunchCanStartWhenAutomationIsOff() async throws {
        let model = AppModel(preview: ())
        model.setAutoContinue(false)
        var plan = try plan(.codex)
        plan.state = .needsConfirmation(reason: "fixture", at: Date())
        try model.planBook.add(plan)
        #expect(model.planBook.apply(.userLaunch(now: Date()), to: plan.id) == [.launch])
        let launching = try #require(model.planBook.plan(plan.id))
        let auth = model.authorization(for: .codex, automatic: false)
        var deliveries = 0
        await model.execute(launching, authorization: auth, checkPreflight: { _, automatic in
            #expect(!automatic)
            return .unchanged
        }, startDelivery: { plan, via in
            #expect(plan.prompt == ResumePlan.manualPrompt)
            #expect(via == .terminal)
            deliveries += 1
            return Task {}
        })
        #expect(deliveries == 1)
        #expect(model.planBook.plan(plan.id)?.delivery == .terminal)
    }

    /// Claude Code 由官方原生自動繼續處理：即使計畫進入送出狀態，Vibe Meter 也不呼叫任何送出或探測。
    @Test func claudePlansNeverDeliverEvenWhenLaunched() async throws {
        let model = AppModel(preview: ())
        var plan = try plan(.claudeCode)
        #expect(AutoResumeGate.blocker(for: plan) == ClaudeNativeContinue.handledNatively)
        plan.state = .launching(startedAt: Date())
        try model.planBook.add(plan)
        var deliveries = 0, preflights = 0
        for automatic in [true, false] {
            await model.execute(plan, authorization: model.authorization(for: .claudeCode, automatic: automatic),
                                checkPreflight: { _, _ in preflights += 1; return .unchanged },
                                startDelivery: { _, _ in deliveries += 1; return Task {} })
        }
        await model.runEngine(codexPreflight: { _, _ in preflights += 1; return .unchanged },
                              codexDelivery: { _, _ in deliveries += 1; return Task {} })
        #expect(deliveries == 0 && preflights == 0)
        if case .skipped = model.planBook.plan(plan.id)?.state {} else { Issue.record("Claude plan should be skipped") }
    }

    @Test func claudeManualLaunchAndAddAreIgnored() throws {
        let model = AppModel(preview: ())
        var plan = try plan(.claudeCode)
        plan.state = .needsConfirmation(reason: "fixture", at: Date())
        try model.planBook.add(plan)
        model.launchNow(plan.id)
        model.addPlan(provider: .claudeCode, sessionID: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee", title: "x", cwd: "/tmp")
        #expect(model.planBook.plan(plan.id)?.state == plan.state)
        #expect(model.planBook.plans.count == 1)
    }
}

/// 讓非同步流程停在某一點的測試工具。所有等待都有時間上限，逾時回傳 false（不會讓測試永久掛起）。
@MainActor
final class Pause<Value: Sendable> {
    private var call: CheckedContinuation<Value, Never>?
    private var ready: CheckedContinuation<Bool, Never>?
    private var released: Value?

    func suspend() async -> Value {
        if let released { return released }
        return await withCheckedContinuation { continuation in
            call = continuation
            ready?.resume(returning: true)
            ready = nil
        }
    }

    /// 等到流程停在 `suspend()`；超過 `seconds` 秒回傳 false。
    func waitUntilSuspended(seconds: Double = 5) async -> Bool {
        if call != nil { return true }
        return await withCheckedContinuation { continuation in
            ready = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, let pending = self.ready else { return }
                self.ready = nil
                pending.resume(returning: false)
            }
        }
    }

    func release(with value: Value) {
        released = value
        call?.resume(returning: value)
        call = nil
    }
}
