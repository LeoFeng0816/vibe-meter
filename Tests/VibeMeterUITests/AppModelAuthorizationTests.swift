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
                       codex: CodexResumeContext(accountID: "test", anchorTurnID: "test-turn", verifiedLimitFailure: true,
                                                verifiedAccountAndModelAtBlock: true),
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
        await preflight.waitUntilSuspended()
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
        await preflight.waitUntilSuspended()
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
        var plan = try plan(.claudeCode)
        plan.state = .needsConfirmation(reason: "fixture", at: Date())
        try model.planBook.add(plan)
        #expect(model.planBook.apply(.userLaunch(now: Date()), to: plan.id) == [.launch])
        let launching = try #require(model.planBook.plan(plan.id))
        let auth = model.authorization(for: .claudeCode, automatic: false)
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

    @Test(arguments: Revocation.allCases)
    func revocationDuringClaudeAuthenticationNeverStartsProbe(_ action: Revocation) async throws {
        let model = AppModel(preview: ())
        let plan = try plan(.claudeCode)
        try model.planBook.add(plan)
        let auth = Pause<ClaudeAccountIdentity?>()
        var probes = 0

        let engine = Task {
            await model.runEngine(readClaudeAccount: { await auth.suspend() }, startClaudeProbe: { _ in
                probes += 1
                throw CocoaError(.featureUnsupported)
            })
        }
        await auth.waitUntilSuspended()
        revoke(action, model: model, plan: plan)
        auth.release(with: account)
        await engine.value

        #expect(probes == 0)
        #expect(model.planBook.plan(plan.id)?.probeCount == 0)
    }

    @Test func overlappingEngineRunsCannotStartDuplicateClaudeProbes() async throws {
        let model = AppModel(preview: ())
        let plan = try plan(.claudeCode)
        try model.planBook.add(plan)
        let auth = Pause<ClaudeAccountIdentity?>()
        var probes = 0
        let start: AppModel.StartClaudeProbe = { _ in
            probes += 1
            throw CocoaError(.featureUnsupported)
        }
        let engine = Task { await model.runEngine(readClaudeAccount: { await auth.suspend() }, startClaudeProbe: start) }
        await auth.waitUntilSuspended()
        await model.runEngine(readClaudeAccount: { account }, startClaudeProbe: start)
        #expect(probes == 0)
        auth.release(with: account)
        await engine.value
        #expect(probes == 1)
        #expect(model.planBook.plan(plan.id)?.probeCount == 1)
    }
}

@MainActor
private final class Pause<Value: Sendable> {
    private var call: CheckedContinuation<Value, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func suspend() async -> Value {
        await withCheckedContinuation { continuation in
            call = continuation
            ready?.resume()
            ready = nil
        }
    }

    func waitUntilSuspended() async {
        if call != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func release(with value: Value) {
        call?.resume(returning: value)
        call = nil
    }
}
