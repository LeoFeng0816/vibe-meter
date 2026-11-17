import CryptoKit
import Foundation
import Testing
@testable import VibeMeterCore

private let t0 = Date(timeIntervalSince1970: 1_794_190_000)

private func snap(_ provider: ProviderID, _ windows: [(WindowKind, Double, TimeInterval?)], observedAt: Date = t0,
                  source: DataSource = .codexAppServer) -> UsageSnapshot {
    UsageSnapshot(provider: provider, windows: windows.map { UsageWindow(kind: $0.0, usedPercent: $0.1, resetsAt: $0.2.map { t0.addingTimeInterval($0) }) },
                  observedAt: observedAt, source: source)
}

// MARK: - 狀態列顯示

@Suite struct MenuBarDisplayTests {
    let codex = ProviderReport(provider: .codex, state: .available(snap(.codex, [(.fiveHour, 60, 3600), (.weekly, 90, 86400)])))
    let claude = ProviderReport(provider: .claudeCode, state: .available(snap(.claudeCode, [(.fiveHour, 30, 3600)], source: .claudeStatusLine)))
    let all = Set(ProviderID.allCases)

    @Test func tightestPicksLowestFreshRemaining() {
        let d = MenuBarDisplay.resolve(.tightest, reports: [codex, claude], enabled: all, now: t0)
        #expect(d == .remaining(10, provider: .codex, window: .weekly))
        #expect(d.menuBarText == "10%")
        #expect(MenuBarDisplay.resolve(.tightest, reports: [codex, claude], enabled: [.claudeCode], now: t0) == .remaining(70, provider: .claudeCode, window: .fiveHour))
        #expect(MenuBarDisplay.resolve(.tightest, reports: [], enabled: all, now: t0) == .unavailable(.noReliableData))
    }

    @Test func fixedSelectionNeverSwitchesOrFakesZero() {
        let sel = MenuBarSelection.window(.codex, .fiveHour)
        #expect(MenuBarDisplay.resolve(sel, reports: [codex, claude], enabled: all, now: t0) == .remaining(40, provider: .codex, window: .fiveHour))
        // 停用 → 不改顯示 Claude
        #expect(MenuBarDisplay.resolve(sel, reports: [codex, claude], enabled: [.claudeCode], now: t0) == .unavailable(.agentDisabled))
        // 過期、已過重設時間、缺少週期、不支援、未連接、讀取失敗、讀取中
        let stale = t0.addingTimeInterval(DataSource.codexAppServer.staleAfter + 1)
        #expect(MenuBarDisplay.resolve(sel, reports: [codex], enabled: all, now: stale) == .unavailable(.stale))
        #expect(MenuBarDisplay.resolve(sel, reports: [codex], enabled: all, now: t0.addingTimeInterval(3601)) == .unavailable(.resetPassed))
        #expect(MenuBarDisplay.resolve(.window(.claudeCode, .weekly), reports: [claude], enabled: all, now: t0) == .unavailable(.windowMissing))
        #expect(MenuBarDisplay.resolve(.window(.cursor, .fiveHour), reports: [UsageCollector.cursorReport], enabled: all, now: t0) == .unavailable(.unsupported))
        let nc = ProviderReport(provider: .codex, state: .notConnected(reason: "x"))
        #expect(MenuBarDisplay.resolve(sel, reports: [nc], enabled: all, now: t0) == .unavailable(.notConnected))
        let err = ProviderReport(provider: .codex, state: .error(message: "x"))
        #expect(MenuBarDisplay.resolve(sel, reports: [err], enabled: all, now: t0) == .unavailable(.error))
        #expect(MenuBarDisplay.resolve(sel, reports: [], enabled: all, now: t0) == .unavailable(.loading))
        for why in [MenuBarUnavailable.stale, .agentDisabled, .unsupported] {
            #expect(MenuBarDisplay.unavailable(why).menuBarText == "—")
        }
    }

    @Test func selectionPersistsAndRejectsGarbage() throws {
        let d = try #require(UserDefaults(suiteName: "vm-test-menubar-\(UUID())"))
        #expect(MenuBarSelection.load(from: d) == .tightest)
        MenuBarSelection.window(.claudeCode, .weekly).save(to: d)
        #expect(MenuBarSelection.load(from: d) == .window(.claudeCode, .weekly))
        d.set("cursor|99h", forKey: MenuBarSelection.defaultsKey)
        #expect(MenuBarSelection.load(from: d) == .tightest)
        #expect(MenuBarSelection.choices(enabled: [.codex, .cursor]) == [.tightest, .window(.codex, .fiveHour), .window(.codex, .weekly)])
    }
}

// MARK: - 低額度提醒

@Suite struct ThresholdAlertTests {
    let policy = AlertPolicy(settings: AlertSettings(enabled: true, remainingThreshold: 20))
    let all = Set(ProviderID.allCases)

    @Test func boundaryIsStrictlyBelowAndFiresOnce() {
        var fired = Set<String>()
        // 剩 20%（等於門檻）不提醒
        #expect(policy.evaluate([snap(.codex, [(.fiveHour, 80, 3600)])], enabled: all, now: t0, fired: &fired).isEmpty)
        // 剩 19.5% 提醒一次
        let s = snap(.codex, [(.fiveHour, 80.5, 3600)])
        let first = policy.evaluate([s], enabled: all, now: t0, fired: &fired)
        #expect(first.count == 1 && first[0].window == .fiveHour)
        fired.formUnion(first.map(\.dedupeKey))
        #expect(policy.evaluate([s], enabled: all, now: t0, fired: &fired).isEmpty)
        #expect(policy.evaluate([snap(.codex, [(.fiveHour, 99, 3600)])], enabled: all, now: t0, fired: &fired).isEmpty)
    }

    @Test func windowsAreIndependentAndResetRearms() {
        var fired = Set<String>()
        let both = snap(.codex, [(.fiveHour, 90, 3600), (.weekly, 85, 86400)])
        let delivered = policy.evaluate([both], enabled: all, now: t0, fired: &fired)
        #expect(delivered.map(\.window) == [.fiveHour, .weekly])
        fired.formUnion(delivered.map(\.dedupeKey))
        // 5 小時重設（新的 resetsAt）後又低於門檻 → 再提醒；每週仍在同一週期 → 不重複
        let nextCycle = snap(.codex, [(.fiveHour, 90, 3600 + 18000), (.weekly, 86, 86400)])
        #expect(policy.evaluate([nextCycle], enabled: all, now: t0, fired: &fired).map(\.window) == [.fiveHour])
    }

    @Test func staleUnknownDisabledAndOffNeverAlert() {
        var fired = Set<String>()
        let low = snap(.codex, [(.fiveHour, 95, 3600)])
        #expect(policy.evaluate([low], enabled: all, now: t0.addingTimeInterval(DataSource.codexAppServer.staleAfter + 1), fired: &fired).isEmpty)
        #expect(policy.evaluate([low], enabled: all, now: t0.addingTimeInterval(3601), fired: &fired).isEmpty)   // 已過重設時間
        #expect(policy.evaluate([low], enabled: [.claudeCode], now: t0, fired: &fired).isEmpty)                 // agent 停用
        let off = AlertPolicy(settings: AlertSettings(enabled: false, remainingThreshold: 20))
        #expect(off.evaluate([low], enabled: all, now: t0, fired: &fired).isEmpty)
        #expect(fired.isEmpty)
    }

    @Test func noResetTimeUsesHysteresis() {
        var fired = Set<String>()
        let low = snap(.claudeCode, [(.fiveHour, 85, nil)], source: .claudeStatusLine)
        let delivered = policy.evaluate([low], enabled: all, now: t0, fired: &fired)
        #expect(delivered.count == 1)
        fired.formUnion(delivered.map(\.dedupeKey))
        // 回到 21%（< 門檻＋2）不重新允許
        _ = policy.evaluate([snap(.claudeCode, [(.fiveHour, 79, nil)], source: .claudeStatusLine)], enabled: all, now: t0, fired: &fired)
        #expect(policy.evaluate([low], enabled: all, now: t0, fired: &fired).isEmpty)
        // 回到 25% 才重新允許
        _ = policy.evaluate([snap(.claudeCode, [(.fiveHour, 75, nil)], source: .claudeStatusLine)], enabled: all, now: t0, fired: &fired)
        #expect(policy.evaluate([low], enabled: all, now: t0, fired: &fired).count == 1)
    }

    @Test func raisingThresholdAlertsAgainAndSettingsClamp() throws {
        var fired = Set<String>()
        let s = snap(.codex, [(.fiveHour, 85, 3600)])   // 剩 15%
        #expect(AlertPolicy(settings: AlertSettings(remainingThreshold: 10)).evaluate([s], enabled: all, now: t0, fired: &fired).isEmpty)
        #expect(AlertPolicy(settings: AlertSettings(remainingThreshold: 20)).evaluate([s], enabled: all, now: t0, fired: &fired).count == 1)
        #expect(AlertSettings(remainingThreshold: 0).remainingThreshold == 1)
        #expect(AlertSettings(remainingThreshold: 150).remainingThreshold == 99)
        let d = try #require(UserDefaults(suiteName: "vm-test-alert-\(UUID())"))
        AlertSettings(enabled: false, remainingThreshold: 35).save(to: d)
        #expect(AlertSettings.load(from: d) == AlertSettings(enabled: false, remainingThreshold: 35))
    }
}

// MARK: - Claude 自動更新排程

@Suite struct ClaudeRefreshPolicyTests {
    @Test func nonAlignedObservationSchedulesExactDeadline() {
        let observed = t0.addingTimeInterval(-873)
        let snapshot = UsageSnapshot(provider: .claudeCode, windows: [], observedAt: observed, source: .claudeStatusLine)
        let deadline = t0.addingTimeInterval(27)
        #expect(ClaudeRefreshPolicy.nextCheck(latest: snapshot, now: t0) == deadline)
        #expect(ClaudeRefreshPolicy.status(latest: snapshot, now: t0) == .current(observedAt: observed))
        #expect(ClaudeRefreshPolicy.status(latest: snapshot, now: deadline) == .awaitingNewReport(lastObservedAt: observed))
        #expect(ClaudeRefreshPolicy.nextCheck(latest: snapshot, now: deadline) == deadline.addingTimeInterval(60))
    }

    @Test func missingAndLegacyProbeSnapshotsDoNotCountAsNewReports() {
        let legacy = UsageSnapshot(provider: .claudeCode, windows: [], observedAt: t0, source: .claudeProbe)
        #expect(ClaudeRefreshPolicy.status(latest: nil, now: t0) == .awaitingReport)
        #expect(ClaudeRefreshPolicy.status(latest: legacy, now: t0) == .awaitingReport)
        #expect(ClaudeRefreshPolicy.nextCheck(latest: nil, now: t0) == t0.addingTimeInterval(60))
    }
}

// MARK: - 保持清醒

private final class FakePower: PowerAssertionProvider {
    var held: [UInt32: Bool] = [:]
    var refuse = false
    private var next: UInt32 = 0

    func acquire(preventDisplaySleep: Bool, reason: String) -> UInt32? {
        guard !refuse else { return nil }
        next += 1
        held[next] = preventDisplaySleep
        return next
    }

    func release(_ id: UInt32) { held.removeValue(forKey: id) }
}

@Suite struct KeepAwakeTests {
    @Test func policyHandlesTimerAgentsAndUnknown() {
        #expect(KeepAwakePolicy.evaluate(mode: .off, activity: .working(count: 1), now: t0).awake == false)
        #expect(KeepAwakePolicy.evaluate(mode: .until(t0.addingTimeInterval(60)), activity: .idle, now: t0) == (true, .timer(until: t0.addingTimeInterval(60))))
        #expect(KeepAwakePolicy.evaluate(mode: .until(t0), activity: .idle, now: t0) == (false, .expired))
        #expect(KeepAwakePolicy.evaluate(mode: .whileAgentsWork, activity: .working(count: 2), now: t0) == (true, .agentsWorking(2)))
        #expect(KeepAwakePolicy.evaluate(mode: .whileAgentsWork, activity: .idle, now: t0).awake == false)
        #expect(KeepAwakePolicy.evaluate(mode: .whileAgentsWork, activity: .unknown("x"), now: t0).awake == false)
    }

    @Test func tracksLongSilentJobsUntilAnOfficialTerminalState() {
        var tracker = CodexActivityTracker()
        let running = CodexTurnSummary(id: "turn", status: "inProgress")
        #expect(tracker.update(["long": .turn(running)], complete: true) == .working(count: 1))
        #expect(tracker.candidates(sessions: [], now: t0.addingTimeInterval(7 * 3600)).ids == ["long"])
        for result: CodexActivityTracker.Probe in [.failed, .turn(nil), .turn(CodexTurnSummary(id: "turn", status: "unrecognized"))] {
            if case .unknown = tracker.update(["long": result], complete: true) {} else { Issue.record("activity must stay unknown") }
            #expect(tracker.tracked.contains("long"))
        }
        #expect(tracker.update(["long": .turn(CodexTurnSummary(id: "turn", status: "completed"))], complete: true) == .idle)
        #expect(tracker.tracked.isEmpty)
    }

    @Test func considersMoreThanFiveThreadsAndPartialSearchDoesNotProveIdle() {
        var tracker = CodexActivityTracker()
        let sessions = (0..<25).map { i in
            CodexSessionInfo(id: "session-\(i)", threadName: nil, cwd: nil, startedAt: nil,
                             lastActivity: t0.addingTimeInterval(TimeInterval(-i * 61)), rolloutPath: "/fixture")
        }
        let first = tracker.candidates(sessions: sessions, now: t0)
        #expect(first.ids.count == 20)
        #expect(first.ids.contains("session-10"))
        #expect(!first.complete)
        let results = Dictionary(uniqueKeysWithValues: first.ids.map { ($0, CodexActivityTracker.Probe.turn(CodexTurnSummary(id: "turn", status: "completed"))) })
        if case .unknown = tracker.update(results, complete: first.complete) {} else { Issue.record("partial search cannot prove idle") }
        #expect(tracker.candidates(sessions: sessions, now: t0).ids.contains("session-24"))
    }

    @Test func controllerHoldsAtMostOneAssertionAndReleases() {
        let power = FakePower()
        let c = KeepAwakeController(provider: power)
        c.apply(awake: true, preventDisplaySleep: false, reason: "t")
        c.apply(awake: true, preventDisplaySleep: false, reason: "t")
        #expect(power.held.count == 1 && power.held.values.first == false)
        c.apply(awake: true, preventDisplaySleep: true, reason: "t")       // 改成也保持顯示器 → 換一個 assertion
        #expect(power.held.count == 1 && power.held.values.first == true)
        c.apply(awake: false, preventDisplaySleep: true, reason: "t")
        #expect(power.held.isEmpty && !c.isHolding)
        power.refuse = true
        c.apply(awake: true, preventDisplaySleep: false, reason: "t")
        #expect(!c.isHolding && c.lastError != nil)
    }

    @Test func controllerReleasesOnDeinit() {
        let power = FakePower()
        do {
            let c = KeepAwakeController(provider: power)
            c.apply(awake: true, preventDisplaySleep: false, reason: "t")
            #expect(power.held.count == 1)
        }
        #expect(power.held.isEmpty)
    }

    @Test func settingsPersistAndExpiredTimerLoadsAsOff() throws {
        let d = try #require(UserDefaults(suiteName: "vm-test-awake-\(UUID())"))
        KeepAwakeSettings(mode: .until(t0.addingTimeInterval(600)), preventDisplaySleep: true).save(to: d)
        #expect(KeepAwakeSettings.load(from: d, now: t0) == KeepAwakeSettings(mode: .until(t0.addingTimeInterval(600)), preventDisplaySleep: true))
        #expect(KeepAwakeSettings.load(from: d, now: t0.addingTimeInterval(601)).mode == .off)
        KeepAwakeSettings(mode: .whileAgentsWork).save(to: d)
        #expect(KeepAwakeSettings.load(from: d, now: t0).mode == .whileAgentsWork)
    }
}

// MARK: - 檢查更新

@Suite struct UpdateCheckerTests {
    func releaseJSON(tag: String = "v0.1.2", host: String = "github.com", owner: String = "LeoFeng0816", digest: String? = "sha256:" + String(repeating: "AB", count: 32),
                     prerelease: Bool = false) -> Data {
        let d = digest.map { #","digest":"\#($0)""# } ?? ""
        return Data("""
        {"tag_name":"\(tag)","name":"Vibe Meter \(tag)","html_url":"https://github.com/\(owner)/vibe-meter/releases/tag/\(tag)","draft":false,"prerelease":\(prerelease),
         "published_at":"2026-11-20T10:00:00Z",
         "assets":[{"name":"Vibe-Meter-0.1.2.dmg","browser_download_url":"https://\(host)/\(owner)/vibe-meter/releases/download/\(tag)/Vibe-Meter-0.1.2.dmg","size":123\(d)},
                   {"name":"Vibe-Meter-0.1.2.zip","browser_download_url":"https://\(host)/\(owner)/vibe-meter/releases/download/\(tag)/Vibe-Meter-0.1.2.zip","size":123\(d)},
                   {"name":"Vibe-Meter-0.1.2.dmg.sig","browser_download_url":"https://\(host)/\(owner)/vibe-meter/releases/download/\(tag)/Vibe-Meter-0.1.2.dmg.sig"}]}
        """.utf8)
    }

    @Test func versionsCompareNumerically() throws {
        #expect(try #require(AppVersion("v0.1.10")) > #require(AppVersion("0.1.9")))
        #expect(try #require(AppVersion("0.1")) == #require(AppVersion("0.1.0")))
        #expect(AppVersion("latest") == nil && AppVersion("1.-2.0") == nil)
    }

    @Test func parsesOnlyAllowedSource() throws {
        let info = try UpdateChecker.parse(releaseJSON())
        #expect(info.version == AppVersion("0.1.2"))
        #expect(info.dmg?.sha256 == String(repeating: "ab", count: 32))
        #expect(info.signature != nil)
        // 其他網域或其他儲存庫的附件會被忽略；release 頁面不在允許範圍 → 整筆拒絕
        #expect(try UpdateChecker.parse(releaseJSON(host: "evil.example.com")).dmg == nil)
        #expect(throws: UpdateError.self) { try UpdateChecker.parse(releaseJSON(owner: "someone-else")) }
        #expect(throws: UpdateError.self) { try UpdateChecker.parse(releaseJSON(prerelease: true)) }
        #expect(!UpdateSource.isAllowedAssetURL(URL(string: "http://github.com/LeoFeng0816/vibe-meter/releases/download/v1/a.dmg")!))
        #expect(!UpdateSource.isAllowedAssetURL(URL(string: "https://github.com/LeoFeng0816/vibe-meter/raw/main/a.dmg")!))
        #expect(UpdateSource.isAllowedRedirectHost("objects.githubusercontent.com"))
        #expect(!UpdateSource.isAllowedRedirectHost("objects.githubusercontent.com.evil.io"))
    }

    @Test func resultsForStatusCodes() throws {
        let current = try #require(AppVersion("0.1.1"))
        guard case .available = UpdateChecker.result(status: 200, body: releaseJSON(), headers: [:], current: current) else { Issue.record("available"); return }
        #expect(UpdateChecker.result(status: 200, body: releaseJSON(tag: "v0.1.1"), headers: [:], current: current)
                == .upToDate(current: current, latest: current))
        #expect(UpdateChecker.result(status: 404, body: Data(), headers: [:], current: current) == .notFound)
        #expect(UpdateChecker.result(status: 403, body: Data(), headers: ["X-RateLimit-Reset": "1794200000"], current: current)
                == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_794_200_000)))
        guard case .failed = UpdateChecker.result(status: 500, body: Data(), headers: [:], current: current) else { Issue.record("500"); return }
        guard case .failed = UpdateChecker.result(status: 200, body: Data("{}".utf8), headers: [:], current: current) else { Issue.record("bad json"); return }
    }

    @Test func publisherSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let sha = "0123abcd"
        let sig = try key.signature(for: Data(sha.utf8)).base64EncodedString()
        #expect(UpdateTrust.verify(sha256Hex: sha, signatureBase64: sig, publicKeys: [pub]))
        #expect(!UpdateTrust.verify(sha256Hex: "ffff", signatureBase64: sig, publicKeys: [pub]))
        #expect(!UpdateTrust.verify(sha256Hex: sha, signatureBase64: sig, publicKeys: [Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()]))
        #expect(!UpdateTrust.verify(sha256Hex: sha, signatureBase64: sig, publicKeys: []))
        // SwiftPM 的測試執行檔不是內嵌正式公鑰的 App bundle。
        #expect(UpdateTrust.trustedPublicKeys.isEmpty)
    }

    @Test func signedFeedItemMustMatchLatestGitHubRelease() throws {
        let info = try UpdateChecker.parse(releaseJSON())
        let asset = try #require(info.installationArchive)
        let bytes = UInt64(try #require(asset.size))
        #expect(UpdateSource.matchesInstallation(info, archive: asset.url, displayVersion: "0.1.2", bytes: bytes))
        #expect(!UpdateSource.matchesInstallation(info, archive: asset.url, displayVersion: "0.1.3", bytes: bytes))
        #expect(!UpdateSource.matchesInstallation(info, archive: asset.url, displayVersion: "0.1.2", bytes: bytes + 1))
        #expect(!UpdateSource.matchesInstallation(info, archive: asset.url.appendingPathComponent("other"), displayVersion: "0.1.2", bytes: bytes))
        #expect(!UpdateSettings().autoInstall)
    }

    @Test func fileDigestAndSchedule() throws {
        let url = TestSupport.tempDir().appendingPathComponent("f.bin")
        try Data("abc".utf8).write(to: url)
        #expect(try UpdateChecker.sha256Hex(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(UpdateSettings.isCheckDue(lastCheck: nil, now: t0))
        #expect(!UpdateSettings.isCheckDue(lastCheck: t0.addingTimeInterval(-3600), now: t0))
        #expect(UpdateSettings.isCheckDue(lastCheck: t0.addingTimeInterval(-86400), now: t0))
    }
}

// MARK: - Codex 中止證據

@Suite struct CodexEvidenceTests {
    /// 目前正式流程能取得的證據：turn 模型＋建立者＋目前帳戶，但沒有官方的中止當下帳戶。
    func productionEvidence(creator: String? = "acct-1", live: String? = "acct-1", model: String? = "gpt-test") -> CodexBlockEvidence {
        CodexBlockEvidence(turnModel: model, creatorAccountHash: creator.map(AccountHash.of), liveAccountID: live)
    }

    func isPending(_ ev: CodexBlockEvidence) -> Bool {
        let plan = try? ResumePlan(provider: .codex, sessionID: TestSupport.sessionA, sessionTitle: "x", cwd: "/tmp",
                                   blockedWindow: .fiveHour, expectedResetAt: nil, codex: ev.context(anchorTurnID: "t"))
        if case .needsConfirmation? = plan?.state { return true }
        return false
    }

    @Test func creatorAndSamplingAreNeverProofOfTheAccountAtTheStop() {
        // 建立者與目前帳戶一致、模型也有：仍然不能證明中止那一刻的帳戶（可能 A→B→A），必須待確認。
        let sameEverywhere = productionEvidence()
        #expect(!sameEverywhere.verified)
        #expect(sameEverywhere.context(anchorTurnID: "t").accountID == nil)
        #expect(sameEverywhere.context(anchorTurnID: "t").verifiedAccountAndModelAtBlock == false)
        #expect(isPending(sameEverywhere))
        // 缺少建立者
        #expect(!productionEvidence(creator: nil).verified && isPending(productionEvidence(creator: nil)))
        // A→B→A：建立者 A、中止時其實是 B、現在又是 A。官方資料無法區分，結果必須同樣是待確認。
        let abaCase = productionEvidence(creator: "acct-A", live: "acct-A")
        #expect(!abaCase.verified && isPending(abaCase))
        #expect(L10n.display(sameEverywhere.failureReason ?? "", in: .zhHant).contains("無法排除"))
    }

    @Test func onlyAnOfficialAtStopAccountCouldEverVerify() {
        // 假設未來官方提供中止 turn 的帳戶：模型、目前帳戶仍須一致。
        let official = CodexBlockEvidence(turnModel: "gpt-test", creatorAccountHash: nil, officialAccountAtBlock: "acct-1", liveAccountID: "acct-1")
        #expect(official.verified && !isPending(official))
        var switched = official; switched.liveAccountID = "acct-2"
        var noModel = official; noModel.turnModel = nil
        var noLive = official; noLive.liveAccountID = nil
        for bad in [switched, noModel, noLive] { #expect(!bad.verified && isPending(bad)) }
        #expect(!AccountHash.of("acct-1").contains("acct"))
    }

    @Test func detectorNeverArmsAutomaticSendWithProductionEvidence() throws {
        let s = CodexSessionInfo(id: TestSupport.sessionA, threadName: "A", cwd: "/tmp/a", startedAt: nil,
                                 lastActivity: t0.addingTimeInterval(-60), rolloutPath: "/r")
        let turns = [s.id: CodexTurnSummary(id: "turn-1", status: "failed", errorInfo: "usageLimitExceeded", completedAt: t0)]
        let full = UsageSnapshot(provider: .codex, windows: [UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: t0.addingTimeInterval(3600))],
                                 observedAt: t0, source: .codexAppServer, accountID: "acct-1", usageAllowed: false)
        for evidence in [[s.id: productionEvidence()], [:]] {
            let armed = try #require(BlockedSessionDetector.codex(sessions: [s], latestTurns: turns, snapshot: full,
                                                                  now: t0.addingTimeInterval(60), evidence: evidence).first)
            let plan = try ResumePlan(provider: .codex, sessionID: armed.sessionID, sessionTitle: "A", cwd: armed.cwd,
                                      blockedWindow: armed.blockedWindow, expectedResetAt: armed.resetsAt, origin: .autoDetected, codex: armed.codex)
            guard case .needsConfirmation = plan.state else { Issue.record("must stay pending"); continue }
            // 即使額度看起來已恢復，待確認的計畫也不會自動送出
            let restored = UsageSnapshot(provider: .codex, windows: [UsageWindow(kind: .fiveHour, usedPercent: 1, resetsAt: t0.addingTimeInterval(99999))],
                                         observedAt: t0.addingTimeInterval(4000), source: .codexAppServer, accountID: "acct-1", usageAllowed: true)
            #expect(ResumeReducer.reduce(plan, .observed(restored, now: t0.addingTimeInterval(4000), autoContinue: true)).1.isEmpty)
        }
    }

    @Test func decodedLegacyOrForgedProofNeverAuthorizesSending() throws {
        let encoded = Data(#"{"accountID":"acct-1","anchorTurnID":"t","verifiedLimitFailure":true,"verifiedAccountAndModelAtBlock":true,"modelAtBlock":"gpt-test","provenance":"official","officialAccountAtBlock":"acct-1"}"#.utf8)
        let context = try JSONDecoder().decode(CodexResumeContext.self, from: encoded)
        #expect(context.verifiedAccountAndModelAtBlock == nil)
        var plan = try ResumePlan(provider: .codex, sessionID: TestSupport.sessionA, sessionTitle: "fixture", cwd: "/tmp",
                                  blockedWindow: .fiveHour, expectedResetAt: nil, codex: context)
        // 已持久化 waiting 狀態本身也不能繞過發送 gate。
        plan.state = .waiting
        let current = UsageSnapshot(provider: .codex, windows: [], observedAt: t0, source: .codexAppServer,
                                    accountID: "acct-1", usageAllowed: true)
        let (_, effects) = ResumeReducer.reduce(plan, .observed(current, now: t0, autoContinue: true))
        #expect(effects == [.notifyNeedsConfirmation])
        #expect(AutoResumeGate.blocker(for: plan) != nil)
    }

    @Test func modelSpecificBucketMustAlsoRecover() throws {
        let ctx = CodexBlockEvidence(turnModel: "gpt-test", creatorAccountHash: nil,
                                      officialAccountAtBlock: "acct-1", liveAccountID: "acct-1").context(anchorTurnID: "t")
        let plan = try ResumePlan(provider: .codex, sessionID: TestSupport.sessionA, sessionTitle: "x", cwd: "/tmp", blockedWindow: .fiveHour,
                                  expectedResetAt: t0.addingTimeInterval(3600), createdAt: t0, codex: ctx)
        let at = t0.addingTimeInterval(3700)
        func live(modelBucketUsed: Double, slug: String = "gpt-test") -> UsageSnapshot {
            UsageSnapshot(provider: .codex, windows: [UsageWindow(kind: .fiveHour, usedPercent: 5, resetsAt: at.addingTimeInterval(18000))],
                          observedAt: at, source: .codexAppServer, accountID: "acct-1", usageAllowed: true,
                          buckets: [LimitBucket(limitID: "codex-model", modelSlug: slug,
                                                windows: [UsageWindow(kind: .fiveHour, usedPercent: modelBucketUsed, resetsAt: at.addingTimeInterval(9000))],
                                                limitReachedType: nil)])
        }
        #expect(RestoreDetector.codexDecision(plan, snapshot: live(modelBucketUsed: 100), now: at) == .notYet)
        #expect(RestoreDetector.codexDecision(plan, snapshot: live(modelBucketUsed: 95), now: at) == .notYet)
        #expect(RestoreDetector.codexDecision(plan, snapshot: live(modelBucketUsed: 100, slug: "other-model"), now: at) == .notYet)
        #expect(RestoreDetector.codexDecision(plan, snapshot: live(modelBucketUsed: 10), now: at) == .restored)
    }

    @Test func preflightChecksCurrentThreadModel() {
        let limited = CodexTurnSummary(id: "t", status: "failed", errorInfo: "usageLimitExceeded")
        #expect(LaunchDecision.codexPreflight(latest: limited, anchorTurnID: "t", requireLimitFailure: true,
                                              expectedModel: "gpt-test", currentModel: .some("gpt-test")) == .unchanged)
        if case .changed = LaunchDecision.codexPreflight(latest: limited, anchorTurnID: "t", requireLimitFailure: true,
                                                         expectedModel: "gpt-test", currentModel: .some("other")) {} else { Issue.record("model changed") }
        if case .unknown = LaunchDecision.codexPreflight(latest: limited, anchorTurnID: "t", requireLimitFailure: true,
                                                         expectedModel: "gpt-test", currentModel: .some(nil)) {} else { Issue.record("model unknown") }
        if case .unknown = LaunchDecision.codexPreflight(latest: limited, anchorTurnID: "t", requireLimitFailure: true,
                                                         expectedModel: "gpt-test") {} else { Issue.record("model not read") }
    }

    @Test func readsTurnModelAndCreatorFromRollout() throws {
        let home = TestSupport.tempDir()
        let day = home.appendingPathComponent("sessions/2026/11/12")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-11-12T10-00-00-\(TestSupport.sessionA).jsonl")
        try """
        {"timestamp":"2026-11-12T02:00:00.000Z","type":"session_meta","payload":{"id":"\(TestSupport.sessionA)","cwd":"/tmp/a","creator_account_id":"acct-1"}}
        {"timestamp":"2026-11-12T02:00:01.000Z","type":"turn_context","payload":{"turn_id":"turn-old","model":"old-model"}}
        {"timestamp":"2026-11-12T02:10:00.000Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-test"}}
        {"timestamp":"2026-11-12T02:10:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","error":{"codex_error_info":"usage_limit_exceeded"}}}
        """.write(to: file, atomically: true, encoding: .utf8)
        let store = CodexLocalStore(codexHome: home)
        let now = try #require(ISO8601.parse("2026-11-12T03:00:00Z"))
        #expect(store.turnModel(sessionID: TestSupport.sessionA, turnID: "turn-1", now: now) == "gpt-test")
        #expect(store.turnModel(sessionID: TestSupport.sessionA, turnID: "turn-missing", now: now) == nil)
        #expect(store.creatorAccountHash(sessionID: TestSupport.sessionA, now: now) == AccountHash.of("acct-1"))
    }

    @Test func parsesModelBucketsAndThreadModel() throws {
        let json = #"{"ordinaryUsageAllowed":true,"accountId":"a","rateLimits":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1}},"m":{"limitId":"m","normalModelSlug":"gpt-test","primary":{"usedPercent":70,"windowDurationMins":300,"resetsAt":1},"rateLimitReachedType":null}}}"#
        let s = try CodexRateLimitParser.parseAppServerResult(Data(json.utf8), observedAt: t0)
        #expect(s.buckets?.count == 2)
        #expect(s.buckets?.first { $0.limitID == "m" }?.modelSlug == "gpt-test")
        let thread = #"{"thread":{"id":"\#(TestSupport.sessionA)","model":"gpt-test","status":{"type":"notLoaded"}}}"#
        #expect(try CodexAppServerClient.parseThreadModel(Data(thread.utf8), threadID: TestSupport.sessionA) == "gpt-test")
        #expect(throws: (any Error).self) { try CodexAppServerClient.parseThreadModel(Data(thread.utf8), threadID: TestSupport.sessionB) }
        #expect(CodexAppServerClient.allowedMethods.contains("thread/read"))
        #expect(!CodexAppServerClient.allowedMethods.contains("account/rateLimitResetCredit/consume"))
    }
}

// MARK: - 在地化

@Suite(.serialized) struct LocalizationTests {
    /// 原始碼中所有 tr("...")／L10n.token("...") 的 key 都要有英文翻譯。
    @Test func everyKeyUsedInSourceHasEnglish() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let regex = try NSRegularExpression(pattern: #"(?:\btr|L10n\.token)\(\s*"((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = (text as NSString).substring(with: m.range(at: 1)).replacingOccurrences(of: "\\n", with: "\n")
                if key.range(of: "[\u{4E00}-\u{9FFF}]", options: .regularExpression) != nil, L10nTable.entries[key]?.en.isEmpty != false {
                    missing.append("\(file.lastPathComponent): \(key)")
                }
            }
        }
        #expect(missing.isEmpty, "缺少翻譯：\(missing)")
    }

    @Test func englishHasNoHanAndPlaceholdersMatch() {
        for (key, entry) in L10nTable.entries {
            #expect(entry.en.range(of: "[\u{4E00}-\u{9FFF}]", options: .regularExpression) == nil, "英文含中文：\(key)")
            for i in 0..<4 where key.contains("{\(i)}") {
                #expect(entry.en.contains("{\(i)}"), "英文缺少 {\(i)}：\(key)")
                #expect(L10n.template(key, in: .zhHans).contains("{\(i)}"), "簡體缺少 {\(i)}：\(key)")
            }
        }
    }

    @Test func simplifiedUsesMainlandVocabulary() {
        #expect(L10n.template("設定", in: .zhHans) == "设置")
        #expect(L10n.template("最近的工作階段", in: .zhHans) == "最近的会话")
        #expect(L10n.template("狀態列顯示", in: .zhHans) == "状态栏显示")
        #expect(L10n.template("{0}後重設", in: .zhHans) == "{0}后重置")
    }

    @Test func tokensReRenderInTheCurrentLanguage() {
        let stored = L10n.token("第 {0} 次探測失敗：{1}", ["2", L10n.token("查詢請求失敗")])
        #expect(L10n.display(stored, in: .zhHant) == "第 2 次探測失敗：查詢請求失敗")
        #expect(L10n.display(stored, in: .en) == "Probe #2 failed: The query request failed")
        // v0.1.0 存下的純繁中字串也能翻譯；不在表中的（例如系統錯誤訊息）原樣顯示
        #expect(L10n.display("工作目錄不存在", in: .en) == "The working directory does not exist")
        #expect(L10n.display("The operation couldn’t be completed.", in: .zhHans) == "The operation couldn’t be completed.")
        #expect(L10n.t("{0} 天 {1} 小時", ["2", "3"], in: .en) == "2d 3h")
    }

    @Test func languagePersists() throws {
        let d = try #require(UserDefaults(suiteName: "vm-test-lang-\(UUID())"))
        #expect(AppLanguage.load(from: d) == .zhHant)
        AppLanguage.en.save(to: d)
        #expect(AppLanguage.load(from: d) == .en)
        d.set("klingon", forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: d) == .zhHant)
    }
}

@Test func dispatchClaimSurvivesSeparateInstancesAndRacingCallers() async throws {
    let directory = TestSupport.tempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<4 {
            group.addTask {
                (try? CodexDispatchClaims(directory: directory).claim(sessionID: TestSupport.sessionA, turnID: "stop")) == true
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(results.filter { $0 }.count == 1)
    #expect(try !CodexDispatchClaims(directory: directory).claim(sessionID: TestSupport.sessionA, turnID: "stop"))
    #expect(try CodexDispatchClaims(directory: directory).claim(sessionID: TestSupport.sessionA, turnID: "next-stop"))
}

@Test func successfulQueueProcessWithWarningDoesNotConfirmWake() async throws {
    let dir = TestSupport.tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let executable = dir.appendingPathComponent("fake-codex")
    try """
    #!/bin/sh
    [ "$1" = queue ] && [ "$2" = --resume ] || exit 14
    printf '%s\\n' 'warning: queued but resume failed' >&2
    exit 0
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let plan = try ResumePlan(provider: .codex, sessionID: TestSupport.sessionA, sessionTitle: "fixture", cwd: "/tmp",
                              blockedWindow: .fiveHour, expectedResetAt: nil)
    let task = try ResumeExecutor.start(plan, via: .codexQueueResume, codexBinary: executable, claudeBinary: nil, launchDir: dir)
    switch await task.result {
    case .failure(ResumeExecutor.Failure.queuedWakeUnconfirmed): break
    default: Issue.record("a successful queue command with a warning must remain unconfirmed")
    }
}

@Suite struct AntigravityBridgeTests {
    @Test func readsOnlyDocumentedQuotaFractionsAndKeepsOriginalObservation() throws {
        let root = TestSupport.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AntigravityBridgeStore(paths: VibeMeterPaths(root: root))
        let raw = Data(#"""
        {"product":"antigravity","email":"fixture@example.invalid","workspace":{"project_dir":"/private/fixture"},"quota":{
            "gemini-weekly":{"remaining_fraction":0.75,"reset_time":"2026-11-20T10:00:00Z"},
            "example-bucket":{"remaining_fraction":0.5},
            "disabled":{"remaining_fraction":0,"disabled":true},
            "invalid":{"remaining_fraction":1.25},
            "credits":{"remaining_amount":100}
        }}
        """#.utf8)
        let snapshot = try #require(try store.recordStatusLine(raw, now: t0))
        #expect(snapshot.provider == .antigravity && snapshot.source == .antigravityStatusLine)
        #expect(snapshot.window(.weekly)?.remainingPercent == 75)
        #expect(snapshot.window(.weekly)?.resetsAt == ISO8601.parse("2026-11-20T10:00:00Z"))
        #expect(snapshot.window(.named("example-bucket"))?.remainingPercent == 50)
        #expect(snapshot.windows.count == 2)
        try store.recordStatusLine(raw, now: t0.addingTimeInterval(900))
        #expect(store.latestSnapshot()?.observedAt == t0)
        let persisted = try String(contentsOf: store.paths.antigravitySnapshot, encoding: .utf8)
        #expect(!persisted.contains("fixture@example.invalid") && !persisted.contains("/private/fixture"))
        #expect(try store.recordStatusLine(Data(#"{"product":"other","quota":{"gemini-weekly":{"remaining_fraction":0}}}"#.utf8)) == nil)
    }

    @Test func setupUsesOfficialStatusLineShapeAndKeepsDefaultDisplay() throws {
        let bridge = URL(fileURLWithPath: "/Applications/Vibe Meter.app/Contents/MacOS/vibemeter-bridge")
        let snippet = try #require(AntigravityBridgeStore.configurationSnippet(bridge: bridge))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: [String: Any]])
        #expect(doc["statusLine"]?["stack_with_default"] as? Bool == true)
        #expect(doc["statusLine"]?["command"] as? String == "'/Applications/Vibe Meter.app/Contents/MacOS/vibemeter-bridge' antigravity-statusline")
    }
}
