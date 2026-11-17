import Foundation
import Testing
import VibeMeterCore
@testable import VibeMeterUI

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct CodexReplayIntegrationTests {
    private enum Scenario: String, CaseIterable {
        case recovery, noDenial, noPermission, noModelBucket, noStopTime, accountGap
        case weekly, multiple, newerTurn, unsupportedCLI, wakeWarning, revoked, newerPoll
        /// 實測帳戶形狀：只有一般 `codex` 桶、normalModelSlug 為 null。不自動送出，只能協助手動續作。
        case generalAssisted
        /// 精確模型桶路徑：早期樣本正常，最後的新樣本只在一般桶帶明確工作區花費上限（模型桶乾淨）。不得送出。
        case generalCapAtRecovery
    }

    @Test(arguments: Scenario.allCases)
    private func replaysOfficialResponsesThroughAppModel(_ scenario: Scenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-cli-fixture-\(UUID())")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "vibemeter-cli-fixture-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for provider in ProviderID.allCases where provider != .codex {
            var agents = AgentPreferences.load(from: defaults)
            agents.set(provider, enabled: false)
            agents.save(to: defaults)
        }
        let paths = VibeMeterPaths(root: root.appendingPathComponent("meter"))
        let binary = root.appendingPathComponent("fake-codex")
        let phaseFile = root.appendingPathComponent("phase")
        let stop = Int(Date().timeIntervalSince1970) - 300
        let reset = stop + (scenario == .weekly ? 6 * 86400 : 180)
        let ids = scenario == .multiple
            ? ["aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"]
            : ["aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"]
        try "\(stop) \(reset) \(scenario.rawValue)".write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        for (index, id) in ids.enumerated() {
            let rollout = """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"\(root.path)","source":"cli"}}
            {"type":"turn_context","payload":{"turn_id":"stop-\(index)","model":"fixture-model"}}
            {"type":"turn_context","payload":{"turn_id":"new-stop","model":"fixture-model"}}

            """
            let file = sessions.appendingPathComponent("rollout-\(id).jsonl")
            try rollout.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(stop))], ofItemAtPath: file.path)
        }
        try Self.fakeCLI.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        func setPhase(_ value: String) throws { try value.write(to: phaseFile, atomically: true, encoding: .utf8) }
        func makeApp() -> AppModel {
            let app = AppModel(dryRun: false, defaults: defaults, paths: paths, claudeSettingsURL: root.appendingPathComponent("unused.json"),
                               startBackgroundWork: false, codexBinary: .some(binary), codexHome: root)
            // generalAssisted 驗證「定時嘗試關閉時」的協助手動流程。
            if scenario == .generalAssisted { app.setCodexTimedResume(false) }
            return app
        }
        let first = makeApp()
        defer { first.stopBackgroundWork() }
        let client = CodexAppServerClient(binary: binary, timeout: .seconds(4))
        try setPhase("before")
        let beforeAt = Date(timeIntervalSince1970: Double(stop - 30))
        first.observeCodexQuota(try await client.readRateLimits(now: { beforeAt }))
        if scenario == .accountGap {
            try setPhase("gap")
            let gapAt = Date(timeIntervalSince1970: Double(stop - 10))
            first.observeCodexQuota(try await client.readRateLimits(now: { gapAt }))
        }
        try setPhase("denied")
        let deniedAt = Date(timeIntervalSince1970: Double(stop + 10))
        first.observeCodexQuota(try await client.readRateLimits(now: { deniedAt }))
        await first.refresh()
        #expect(first.planBook.active.count == ids.count)
        // noModelBucket（只有一般 codex 桶）在使用者選擇的定時嘗試下，以同帳戶明確拒絕與重設時間取得定時授權。
        let eligible: Set<Scenario> = [.recovery, .noModelBucket, .generalCapAtRecovery, .noPermission, .weekly, .multiple, .newerTurn, .unsupportedCLI, .wakeWarning, .revoked, .newerPoll]
        if scenario == .noModelBucket {
            // 夾具的重設時間已過：定時嘗試在第一次刷新就到期並送出（仍只送一次，見下方）。
            #expect(first.planBook.plans.first?.codex?.sessionAuthorization?.basis == .generalBucketTimed)
        } else if eligible.contains(scenario) {
            #expect(first.planBook.active.allSatisfy { $0.state == .waiting })
        } else {
            #expect(first.planBook.active.allSatisfy { if case .needsConfirmation = $0.state { true } else { false } })
        }

        let app = makeApp()
        defer { app.stopBackgroundWork() }
        try setPhase("recovery")
        if scenario == .revoked || scenario == .newerPoll {
            let pause = root.appendingPathComponent("pause")
            let started = root.appendingPathComponent("paused")
            let release = root.appendingPathComponent("release")
            try Data().write(to: pause)
            let poll = Task { await app.refresh() }
            // Initial discovery uses the fake latest-turn RPC too. Gate only the second RPC.
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: started.path) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(FileManager.default.fileExists(atPath: started.path))
            func record(_ line: String) throws {
                let handle = try FileHandle(forWritingTo: root.appendingPathComponent("trace"))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            }
            try record("TEST saw pause")
            if scenario == .revoked {
                app.setAutoContinue(false)
            } else {
                try setPhase("denied-again")
                await app.requestCodexPoll(reason: .refresh)
                #expect(app.liveCodexSnapshot?.usageAllowed == false)
                try record("TEST applied newer poll")
            }
            try Data().write(to: release)
            await poll.value
        } else {
            if scenario == .newerTurn { try setPhase("newer") }
            await app.refresh()
        }

        let callFile = root.appendingPathComponent("queue")
        let calls = ((try? String(contentsOf: callFile, encoding: .utf8)) ?? "").split(separator: "\n")
        let trace = (try? String(contentsOf: root.appendingPathComponent("trace"), encoding: .utf8)) ?? ""
        switch scenario {
        case .recovery, .wakeWarning, .noModelBucket: #expect(calls.count == 1, Comment(rawValue: trace))
        case .multiple: #expect(calls.count == 2 && Set(calls).count == 2, Comment(rawValue: trace))
        default: #expect(calls.isEmpty, Comment(rawValue: trace))
        }
        if scenario == .generalAssisted {
            let plan = try #require(app.planBook.active.first)
            if case .needsConfirmation = plan.state {} else { Issue.record("general bucket must not arm automation") }
            let gap = L10n.display(plan.codex?.evidenceGap ?? "", in: .zhHant)
            #expect(gap.contains("額度桶"))
            let diagnosis = app.codexDiagnosis(for: plan)
            #expect(diagnosis.looksReadyForManualContinue)
            #expect(diagnosis.items.contains { $0.check == .missing && ($0.detail ?? "").contains("normalModelSlug") })
            // 測試程序沒有可用的系統通知：未送達就不記錄，之後可重試（投遞語義見 CodexManualAssistTests）。
            #expect(plan.manualReadyNotifiedAt == nil)
            await app.refresh()   // 刷新不會自動送出
            #expect(((try? String(contentsOf: callFile, encoding: .utf8)) ?? "").isEmpty)
            // 使用者取消確認：不送出。
            var prompts = 0
            app.confirmManualCodexLaunch = { _, _, _ in prompts += 1; return false }
            app.launchNow(plan.id)
            try await Task.sleep(for: .milliseconds(300))
            #expect(prompts == 1 && ((try? String(contentsOf: callFile, encoding: .utf8)) ?? "").isEmpty)
            // 使用者確認：只排入原工作階段一次（queue --resume），之後的刷新不重送。
            app.confirmManualCodexLaunch = { _, diagnosis, live in
                prompts += 1
                #expect(diagnosis.looksReadyForManualContinue && live?.usageAllowed == true)
                return true
            }
            app.launchNow(plan.id)
            for _ in 0..<250 {
                if case .launched? = app.planBook.plan(plan.id)?.state { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let sent = ((try? String(contentsOf: callFile, encoding: .utf8)) ?? "").split(separator: "\n")
            #expect(prompts == 2 && sent.count == 1, Comment(rawValue: trace))
            #expect(app.planBook.plan(plan.id)?.delivery == .codexQueueResume)
            if case .launched? = app.planBook.plan(plan.id)?.state {} else { Issue.record("manual queue must wait for a new turn") }
            app.launchNow(plan.id)   // 已送出：不再送
            await app.refresh()
            try setPhase("activity")
            await app.runEngine()
            #expect(((try? String(contentsOf: callFile, encoding: .utf8)) ?? "").split(separator: "\n").count == 1)
            if case .resumed? = app.planBook.plan(plan.id)?.state {} else { Issue.record("new official turn should confirm continuation") }
        }
        if scenario == .newerTurn {
            #expect(app.planBook.active.first?.codex?.anchorTurnID == "new-stop")
            #expect(app.planBook.plans.count == 2)
        }
        if scenario == .weekly {
            #expect(app.planBook.active.first?.blockedWindow == .weekly)
            #expect(app.planBook.active.first?.state == .waiting)
        }
        if scenario == .wakeWarning {
            #expect(app.planBook.active.first?.note == L10n.token("已排入 Codex 佇列，CLI 回報喚醒未獲確認"))
        }
        if scenario == .recovery || scenario == .multiple || scenario == .wakeWarning {
            let third = makeApp()
            defer { third.stopBackgroundWork() }
            await third.refresh()
            #expect(((try? String(contentsOf: callFile, encoding: .utf8)) ?? "").split(separator: "\n") == calls)
            try setPhase("activity")
            await third.runEngine()
            #expect(third.planBook.active.isEmpty)
        }
    }

    private static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, pathlib, sys, time
    root = pathlib.Path(__file__).parent
    stop, reset, scenario = (root / "config").read_text().split()
    stop, reset = int(stop), int(reset)
    args = sys.argv[1:]
    if args == ["queue", "--help"]:
        print("queue --thread" if scenario == "unsupportedCLI" else "queue --resume --thread")
        sys.exit(0)
    if len(args) == 6 and args[:3] == ["queue", "--resume", "--thread"] and args[4] == "--message":
        with (root / "queue").open("a") as log:
            print(args[3], file=log)
        with (root / "trace").open("a") as trace:
            print("queued", time.monotonic(), file=trace)
        if scenario == "wakeWarning":
            print("warning: fixture cannot resume yet", file=sys.stderr)
        sys.exit(0)
    if args != ["app-server"]:
        sys.exit(2)
    for line in sys.stdin:
        req = json.loads(line)
        method = req["method"]
        phase = (root / "phase").read_text()
        with (root / "trace").open("a") as trace:
            print(method, phase, time.monotonic(), file=trace)
        if method == "initialize":
            print(json.dumps({"id": 1, "result": {}}), flush=True)
            continue
        if method == "initialized":
            continue
        if method == "account/rateLimits/read":
            assert req["params"] == {"excludeResetCreditDetails": True}
            denied = phase in ("denied", "denied-again")
            permission = not denied
            if phase == "gap" or (denied and scenario == "noDenial") or (phase == "recovery" and scenario == "noPermission"):
                permission = None
            minutes = 10080 if scenario == "weekly" else 300
            bucket = {
                "limitId": "codex" if scenario in ("noModelBucket", "generalAssisted") else "fixture-meter",
                "normalModelSlug": None if scenario in ("noModelBucket", "generalAssisted") else "fixture-model",
                "primary": {"usedPercent": 100 if denied else 8,
                            "windowDurationMins": minutes,
                            "resetsAt": reset if phase in ("before", "denied", "gap") else int(time.time()) + 3600}
            }
            result = {"accountId": "fixture-account", "ordinaryUsageAllowed": permission,
                      "rateLimits": bucket, "rateLimitsByLimitId": {bucket["limitId"]: bucket}}
            if scenario == "generalCapAtRecovery" and phase == "recovery":
                result["rateLimitsByLimitId"]["codex"] = {"limitId": "codex", "normalModelSlug": None, "primary": bucket["primary"],
                                                          "rateLimitReachedType": "workspace_member_usage_limit_reached"}
        elif method == "thread/read":
            result = {"thread": {"id": req["params"]["threadId"], "model": "fixture-model"}}
        elif method == "thread/turns/list":
            if (root / "pause").exists() and not (root / "released").exists():
                counter = root / "turn-count"
                count = int(counter.read_text()) if counter.exists() else 0
                counter.write_text(str(count + 1))
                if count == 1:
                    (root / "paused").touch()
                    deadline = time.monotonic() + 16
                    while not (root / "release").exists() and time.monotonic() < deadline:
                        time.sleep(.025)
                    with (root / "trace").open("a") as trace:
                        print("pause done", time.monotonic(), (root / "release").exists(), file=trace)
                    (root / "released").touch()
            index = 1 if req["params"]["threadId"].startswith("bbbb") else 0
            if phase == "activity":
                turn = {"id": "continued", "status": "inProgress", "startedAt": int(time.time())}
            else:
                turn = {"id": "new-stop" if phase == "newer" else f"stop-{index}",
                        "status": "failed", "startedAt": stop - 20,
                        "completedAt": None if scenario == "noStopTime" else stop + (155 if phase == "newer" else 0),
                        "error": {"codexErrorInfo": "usageLimitExceeded"}}
            result = {"data": [turn], "nextCursor": None}
        else:
            sys.exit(3)
        print(json.dumps({"id": 2, "result": result}), flush=True)
    """#
}
