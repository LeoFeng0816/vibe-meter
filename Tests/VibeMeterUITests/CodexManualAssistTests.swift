import Foundation
import Testing
@testable import VibeMeterCore
@testable import VibeMeterUI

/// 一般額度桶帳戶（官方無法授權自動送出）的協助手動續作：通知、確認與送出邊界。全部使用替身，不碰真實工作階段。
@MainActor
@Suite(.serialized) struct CodexManualAssistTests {
    let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    private func live(account: String = "acct", allowed: Bool? = true, used: Double = 3, now: Date = Date()) -> UsageSnapshot {
        let windows = [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: now.addingTimeInterval(4 * 3600))]
        return UsageSnapshot(provider: .codex, windows: windows, observedAt: now, source: .codexAppServer, accountID: account,
                             usageAllowed: allowed, buckets: [LimitBucket(limitID: "codex", modelSlug: nil, windows: windows, limitReachedType: nil)])
    }

    private func plan(now: Date = Date()) throws -> ResumePlan {
        var context = CodexResumeContext(accountID: nil, anchorTurnID: "stop", verifiedLimitFailure: true, modelAtBlock: "gpt-model",
                                         evidenceGap: L10n.token("官方額度資料無法唯一對應這個模型的額度桶"))
        context.accountHashAtDetection = AccountHash.of("acct")
        let p = try ResumePlan(provider: .codex, sessionID: sessionID, sessionTitle: "fixture", cwd: "/tmp", blockedWindow: .fiveHour,
                               expectedResetAt: now.addingTimeInterval(-600), origin: .autoDetected,
                               createdAt: now.addingTimeInterval(-3600), codex: context)
        if case .needsConfirmation = p.state {} else { Issue.record("fixture must need confirmation") }
        return p
    }

    private func model(with snapshot: UsageSnapshot) throws -> (AppModel, ResumePlan) {
        let app = AppModel(preview: ())
        let p = try plan()
        try app.planBook.add(p)
        app.reports = [ProviderReport(provider: .codex, state: .available(snapshot))]
        return (app, p)
    }

    @Test func noticeIsRecordedOnlyAfterDeliveryAndRetriesAfterDenialOrFailure() async throws {
        let (app, p) = try model(with: live())
        #expect(app.codexDiagnosis(for: p).looksReadyForManualContinue)
        var status = NotificationStatus.denied
        var failNext = false
        var delivered = 0
        let notifier = Notifier(readStatus: { status }, deliver: { _, _, _ in
            if failNext { failNext = false; throw CocoaError(.featureUnsupported) }
            delivered += 1
        })
        await app.notifyManualReadyCodexPlans(using: notifier)
        #expect(delivered == 0 && app.planBook.plan(p.id)?.manualReadyNotifiedAt == nil)   // 權限被拒：不記錄
        status = .authorized
        failNext = true
        await app.notifyManualReadyCodexPlans(using: notifier)
        #expect(delivered == 0 && app.planBook.plan(p.id)?.manualReadyNotifiedAt == nil)   // 送出失敗：不記錄
        await app.notifyManualReadyCodexPlans(using: notifier)
        #expect(delivered == 1 && app.planBook.plan(p.id)?.manualReadyNotifiedAt != nil)   // 成功後才記錄
        await app.notifyManualReadyCodexPlans(using: notifier)
        #expect(delivered == 1)
    }

    @Test func concurrentRefreshesDeliverOneNotice() async throws {
        let (app, p) = try model(with: live())
        let gate = Pause<Void>()
        var delivered = 0
        let notifier = Notifier(readStatus: { .authorized }, deliver: { _, _, _ in
            delivered += 1
            await gate.suspend()
        })
        let first = Task { await app.notifyManualReadyCodexPlans(using: notifier) }
        guard await gate.waitUntilSuspended() else { Issue.record("delivery never started"); gate.release(with: ()); return }
        await app.notifyManualReadyCodexPlans(using: notifier)
        gate.release(with: ())
        await first.value
        #expect(delivered == 1 && app.planBook.plan(p.id)?.manualReadyNotifiedAt != nil)
    }

    @Test func noticeIsDroppedWhenStateChangesBeforeDelivery() async throws {
        let (app, p) = try model(with: live())
        var delivered = 0
        let notifier = Notifier(readStatus: {
            // 讀取權限期間使用者取消計畫。
            app.cancelPlan(p.id)
            return .authorized
        }, deliver: { _, _, _ in delivered += 1 })
        await app.notifyManualReadyCodexPlans(using: notifier)
        #expect(delivered == 0)
    }

    @Test func manualSendIsBlockedAfterAccountSwitchOrRevocation() async throws {
        let (app, p) = try model(with: live(account: "other"))
        #expect(!app.codexDiagnosis(for: p).looksReadyForManualContinue)
        #expect(app.manualAccountBlocker(p) != nil)
        #expect(app.planBook.apply(.userLaunch(now: Date()), to: p.id) == [.launch])
        var deliveries = 0
        await app.execute(try #require(app.planBook.plan(p.id)), authorization: app.authorization(for: .codex, automatic: false),
                          checkPreflight: { _, _ in .unchanged }, startDelivery: { _, _ in deliveries += 1; return Task {} })
        #expect(deliveries == 0)
        if case .skipped? = app.planBook.plan(p.id)?.state {} else { Issue.record("account switch must skip") }

        // 送出前的檢查期間使用者取消：不送出。
        let (app2, p2) = try model(with: live())
        #expect(app2.planBook.apply(.userLaunch(now: Date()), to: p2.id) == [.launch])
        let pause = Pause<SessionPreflight>()
        let attempt = Task {
            await app2.execute(try #require(app2.planBook.plan(p2.id)), authorization: app2.authorization(for: .codex, automatic: false),
                               checkPreflight: { _, _ in await pause.suspend() }, startDelivery: { _, _ in deliveries += 1; return Task {} })
        }
        guard await pause.waitUntilSuspended() else { Issue.record("preflight never started"); pause.release(with: .unknown("x")); return }
        app2.cancelPlan(p2.id)
        pause.release(with: .unchanged)
        _ = await attempt.result
        #expect(deliveries == 0)
        if case .cancelled? = app2.planBook.plan(p2.id)?.state {} else { Issue.record("cancel must be preserved") }
    }

    @Test func twoAppInstancesCannotBothSendTheSameStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-manual-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = VibeMeterPaths(root: root.appendingPathComponent("meter"))
        var deliveries = 0
        var apps: [AppModel] = []
        var suites: [String] = []
        defer {
            apps.forEach { $0.stopBackgroundWork() }
            suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        }
        for _ in 0..<2 {
            let suite = "vibemeter-manual-\(UUID())"
            suites.append(suite)
            let app = AppModel(dryRun: false, defaults: try #require(UserDefaults(suiteName: suite)), paths: paths,
                               claudeSettingsURL: root.appendingPathComponent("unused.json"), startBackgroundWork: false,
                               codexBinary: .some(nil), codexHome: root.appendingPathComponent("codex"))
            app.reports = [ProviderReport(provider: .codex, state: .available(live()))]
            let p = try plan()
            try app.planBook.add(p)
            #expect(app.planBook.apply(.userLaunch(now: Date()), to: p.id) == [.launch])
            apps.append(app)
        }
        for app in apps {
            let p = try #require(app.planBook.active.first)
            await app.execute(p, authorization: app.authorization(for: .codex, automatic: false),
                              checkPreflight: { _, _ in .unchanged }, startDelivery: { _, _ in deliveries += 1; return Task {} })
        }
        #expect(deliveries == 1)
        if case .skipped? = apps[1].planBook.active.first?.state ?? apps[1].planBook.plans.first?.state {} else {
            Issue.record("second instance must skip the already dispatched stop")
        }
    }
}

/// Claude Code：原生等待在原視窗處理。重設＋30 秒時 Vibe Meter 只更新顯示，不建立計畫、不送出。
@MainActor
@Suite struct ClaudeNativeNoDoubleSendTests {
    @Test func resetPlus30OnlyUpdatesStatus() async throws {
        let model = AppModel(preview: ())
        let now = Date()
        var info = ClaudeTranscriptInfo(id: "cccccccc-1111-4222-8333-944455556666", cwd: "/tmp", transcriptPath: "/tmp/x.jsonl",
                                        lastActivity: now.addingTimeInterval(-3600))
        let hit = ClaudeTranscriptInfo.LimitHit(at: now.addingTimeInterval(-3600), resetsAt: now.addingTimeInterval(-30), window: .fiveHour,
                                                limitType: "five_hour", overageStatus: "rejected", messageUUID: "m", version: "2.1.322",
                                                entrypoint: "cli")
        info.limitHit = hit
        info.lastLimit = hit
        model.claudeSessions = [info]
        model.now = now
        var deliveries = 0
        for _ in 0..<3 {
            await model.runEngine(codexPreflight: { _, _ in .unchanged }, codexDelivery: { _, _ in deliveries += 1; return Task {} })
        }
        #expect(deliveries == 0)
        #expect(model.planBook.plans.isEmpty)
        let observation = try #require(model.claudeNativeObservations.first)
        #expect(observation.phase == .resetPassedNoNewConversation(resetsAt: hit.resetsAt!))
    }
}
