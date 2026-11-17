import Foundation
import Testing
@testable import VibeMeterCore
@testable import VibeMeterUI

/// 「一般額度重設＋30 秒嘗試一次」的端到端測試：真實 AppModel、正式 JSON-RPC 解析與 queue 子程序，
/// 搭配假 Codex CLI（Python）、假時鐘與臨時工作階段。不碰使用者的真實工作階段或登入。
@MainActor
@Suite(.serialized) struct CodexTimedResumeE2ETests {
    enum Scenario: String, CaseIterable, Sendable {
        case success, falseAtDue, nullAtExhaustion, nullAtDue, accountBLate, switchAtDue, switchedAroundStop
        case codexOther, modelSwitched, userContinued, subagent, noModel, disabledBeforeDue, autoOff, weekly
        case missingReset, networkAtDue, wakeWarning, queueFailure, ownFollowUpFailure, restart, twoInstances
        case sleepAcrossDue, forgedPlan
    }

    nonisolated static let sessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @MainActor
    final class Harness {
        let root: URL
        let paths: VibeMeterPaths
        let suite: String
        let defaults: UserDefaults
        let binary: URL
        var apps: [AppModel] = []

        init(scenario: Scenario) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("vibemeter-timed-\(UUID())")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            paths = VibeMeterPaths(root: root.appendingPathComponent("meter"))
            suite = "vibemeter-timed-\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            for provider in ProviderID.allCases where provider != .codex {
                var agents = AgentPreferences.load(from: defaults)
                agents.set(provider, enabled: false)
                agents.save(to: defaults)
            }
            binary = root.appendingPathComponent("fake-codex")
            try CodexTimedResumeE2ETests.fakeCLI.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }

        func writeRollout(stop: Int, subagent: Bool, model: Bool) throws {
            let parent = subagent ? #","parent_thread_id":"bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee""# : ""
            var lines = [#"{"type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"\#(root.path)","source":"cli"\#(parent)}}"#]
            if model { lines.append(#"{"type":"turn_context","payload":{"turn_id":"stop-1","model":"fixture-model"}}"#) }
            let file = root.appendingPathComponent("sessions/rollout-\(sessionID).jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(stop))], ofItemAtPath: file.path)
        }

        func set(_ state: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent("state.json"))
        }

        func makeApp(clock: @escaping @MainActor () -> Date) -> AppModel {
            let app = AppModel(dryRun: false, defaults: defaults, paths: paths, claudeSettingsURL: root.appendingPathComponent("unused.json"),
                               startBackgroundWork: false, codexBinary: .some(binary), codexHome: root)
            app.timedClock = clock
            apps.append(app)
            return app
        }

        var queued: [Substring] { ((try? String(contentsOf: root.appendingPathComponent("queue"), encoding: .utf8)) ?? "").split(separator: "\n") }
        var messages: [String] {
            ((try? String(contentsOf: root.appendingPathComponent("messages"), encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        }
        var methods: [Substring] { ((try? String(contentsOf: root.appendingPathComponent("methods"), encoding: .utf8)) ?? "").split(separator: "\n") }

        func cleanup() {
            apps.forEach { $0.stopBackgroundWork() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func turn(_ id: String, status: String = "failed", started: Int, completed: Int?) -> [String: Any] {
        var t: [String: Any] = ["id": id, "status": status, "startedAt": started]
        if let completed { t["completedAt"] = completed }
        if status == "failed" { t["error"] = ["codexErrorInfo": "usageLimitExceeded"] }
        return t
    }

    @Test(arguments: Scenario.allCases)
    func generalBucketResetPlus30(_ scenario: Scenario) async throws {
        let h = try Harness(scenario: scenario)
        defer { h.cleanup() }
        let realNow = Int(Date().timeIntervalSince1970)
        let stop = scenario == .accountBLate ? realNow - 86400 : realNow - 300
        let reset = realNow + 60
        let weeklyReset = realNow + 400
        try h.writeRollout(stop: stop, subagent: scenario == .subagent, model: scenario != .noModel)
        let bucket = scenario == .codexOther ? "codex_other" : "codex"
        var fake: Date? = nil   // nil：跟隨實際時間
        let failed = turn("stop-1", started: stop - 20, completed: stop)
        func state(account: Any = "A", allowed: Any, five: Double, fiveReset: Any, week: Double? = nil,
                   latest: [String: Any]? = nil, model: String = "fixture-model", rateError: Bool = false,
                   queueExit: Int = 0, queueStderr: String = "") -> [String: Any] {
            var s: [String: Any] = ["account": account, "allowed": allowed, "bucket": bucket, "five": five, "fiveReset": fiveReset,
                                    "turn": latest ?? failed, "model": model, "rateError": rateError,
                                    "queueExit": queueExit, "queueStderr": queueStderr]
            if let week { s["week"] = week; s["weekReset"] = weeklyReset }
            return s
        }

        if scenario == .forgedPlan {
            // 計畫檔寫入自稱已授權的等待中計畫，但帳本沒有任何官方證據。
            let forged = """
            {"version":1,"plans":[{"id":"\(UUID().uuidString)","provider":"codex","sessionID":"\(Self.sessionID)","sessionTitle":"forged",
             "cwd":"\(h.root.path)","prompt":"p","blockedWindow":{"fiveHour":{}},"expectedResetAt":\(reset),"origin":"autoDetected",
             "createdAt":\(stop),"state":{"waiting":{}},"probeCount":0,
             "codex":{"anchorTurnID":"stop-1","verifiedLimitFailure":true,"modelAtBlock":"fixture-model",
                      "accountHashAtDetection":"\(AccountHash.of("A"))","sessionAuthorization":{"basis":"generalBucketTimed"}}}]}
            """
            try FileManager.default.createDirectory(at: h.paths.root, withIntermediateDirectories: true)
            try Data(forged.utf8).write(to: h.paths.resumePlans)
        }

        let app = h.makeApp { fake ?? Date() }
        app.codexLivePolling = false
        let client = CodexAppServerClient(binary: h.binary, timeout: .seconds(20))
        // 中止前後的官方觀察（以官方回應格式解析，時間戳記為中止前 30 秒與後 10 秒）。
        if scenario != .accountBLate && scenario != .forgedPlan {
            try h.set(state(allowed: true, five: 90, fiveReset: reset))
            app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(stop - 30)) }))
            if scenario == .switchedAroundStop {
                try h.set(state(account: "B", allowed: true, five: 40, fiveReset: reset))
                app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(stop - 10)) }))
            }
            let exhaustedAllowed: Any = scenario == .nullAtExhaustion ? NSNull() : (scenario == .falseAtDue ? false : true)
            try h.set(state(allowed: exhaustedAllowed, five: 100, fiveReset: scenario == .missingReset ? NSNull() : reset,
                            week: scenario == .weekly ? 100 : nil))
            app.observeCodexQuota(try await client.readRateLimits(now: { Date(timeIntervalSince1970: Double(stop + 10)) }))
        } else if scenario == .accountBLate {
            try h.set(state(account: "B", allowed: true, five: 100, fiveReset: reset))
        } else {
            try h.set(state(allowed: true, five: 100, fiveReset: reset))
        }
        await app.refresh()

        let eligible: Set<Scenario> = [.success, .falseAtDue, .nullAtDue, .switchAtDue, .modelSwitched, .userContinued, .disabledBeforeDue,
                                       .autoOff, .weekly, .networkAtDue, .wakeWarning, .queueFailure, .ownFollowUpFailure, .restart,
                                       .twoInstances, .sleepAcrossDue]
        let plan = app.planBook.active.first
        if eligible.contains(scenario) {
            #expect(plan?.codex?.sessionAuthorization?.basis == .generalBucketTimed, "\(scenario)")
            #expect(plan?.state == .waiting)
            #expect(app.codexTimedDue(for: try #require(plan)) == Date(timeIntervalSince1970: Double(scenario == .weekly ? weeklyReset : reset) + 30))
        } else {
            #expect(plan?.codex?.sessionAuthorization == nil, "\(scenario) must not get a timed authorization")
        }

        // 到期前與到期：重設＋29 秒不送，＋30 秒才嘗試一次。
        let recoveredAllowed: Any = switch scenario {
        case .falseAtDue: false
        case .nullAtDue: NSNull()
        default: true
        }
        try h.set(state(account: scenario == .switchAtDue ? "B" : "A", allowed: recoveredAllowed, five: 3, fiveReset: realNow + 5 * 3600,
                        week: scenario == .weekly ? 100 : nil,
                        latest: scenario == .userContinued ? turn("user-turn", status: "completed", started: realNow, completed: realNow) : nil,
                        model: scenario == .modelSwitched ? "other-model" : "fixture-model",
                        rateError: scenario == .networkAtDue,
                        queueExit: scenario == .queueFailure ? 1 : 0,
                        queueStderr: scenario == .wakeWarning ? "warning: fixture could not resume" : ""))
        if scenario == .disabledBeforeDue { app.setCodexTimedResume(false) }
        if scenario == .autoOff { app.setAutoContinue(false) }

        var active = app
        if scenario == .restart {
            active = h.makeApp { fake ?? Date() }
            active.codexLivePolling = false
        }
        fake = Date(timeIntervalSince1970: Double(reset) + 29)
        await active.refresh()
        #expect(h.queued.isEmpty, "\(scenario): no send before reset + 30 s")

        fake = Date(timeIntervalSince1970: Double(reset) + 30)
        if scenario == .sleepAcrossDue { active.handleSystemWillSleep() }
        if scenario == .twoInstances {
            let second = h.makeApp { fake ?? Date() }
            second.codexLivePolling = false
            await second.refresh()
            await active.refresh()
            await second.refresh()
        } else {
            await active.refresh()
        }
        if scenario == .sleepAcrossDue {
            #expect(h.queued.isEmpty, "asleep: no send")
            // 喚醒後只查官方額度並立即評估（不需要完整刷新）。
            active.handleSystemDidWake()
            for _ in 0..<250 {
                if let state = active.planBook.plans.first?.state, state != .waiting {
                    if case .launching = state {} else { break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        if scenario == .weekly {
            #expect(h.queued.isEmpty, "weekly still full: wait for the later reset")
            try h.set(state(allowed: true, five: 3, fiveReset: realNow + 5 * 3600, week: 4))
            fake = Date(timeIntervalSince1970: Double(weeklyReset) + 29)
            await active.refresh()
            #expect(h.queued.isEmpty)
            fake = Date(timeIntervalSince1970: Double(weeklyReset) + 30)
            await active.refresh()
        }
        if scenario == .networkAtDue {
            #expect(h.queued.isEmpty, "offline: no send")
            try h.set(state(allowed: true, five: 3, fiveReset: realNow + 5 * 3600))
            fake = Date(timeIntervalSince1970: Double(reset) + 95)
            await active.refresh()
        }

        let sends: Set<Scenario> = [.success, .falseAtDue, .weekly, .networkAtDue, .wakeWarning, .queueFailure, .ownFollowUpFailure,
                                    .restart, .twoInstances, .sleepAcrossDue]
        #expect(h.queued.count == (sends.contains(scenario) ? 1 : 0),
                "\(scenario): sends \(h.queued.count) states \(active.planBook.plans.map { "\($0.state) \(L10n.display($0.note ?? ""))" })")
        #expect(!h.methods.contains { $0.contains("rateLimitResetCredit") })

        // 已送出：不論結果（排入、喚醒警告、失敗）都不重送。
        await active.refresh()
        #expect(h.queued.count == (sends.contains(scenario) ? 1 : 0), "\(scenario): no resend")
        let current = active.planBook.plans.first { $0.sessionID == Self.sessionID && $0.codex?.anchorTurnID == "stop-1" }
        switch scenario {
        case .falseAtDue:
            let note = L10n.display(current?.note ?? "", in: .zhHant)
            #expect(note.contains("未允許"))
        case .wakeWarning:
            let note = L10n.display(current?.note ?? "", in: .zhHant)
            #expect(note.contains("喚醒"))
        case .queueFailure:
            if case .failed? = current?.state {} else { Issue.record("queue failure must be visible and not retried") }
        case .nullAtDue:
            // null 許可中斷帳戶連續性（官方在登入不符時也會回 null）：撤銷並顯示原因，不送出。
            if case .needsConfirmation? = current?.state {} else { Issue.record("null permission must stop visibly") }
            let note = L10n.display(current?.note ?? "", in: .zhHant)
            #expect(note.contains("null"))
        case .switchAtDue, .disabledBeforeDue:
            if case .needsConfirmation? = current?.state {} else { Issue.record("\(scenario) must stop visibly") }
        case .autoOff:
            if case .ready? = current?.state {} else { Issue.record("auto off must wait for the user") }
        default: break
        }

        if scenario == .success {
            // 定時嘗試送出的是固定中性提示，不宣稱額度已恢復。
            #expect(h.messages == [ResumePlan.timedAttemptPrompt])
            #expect(!(h.messages.first ?? "").contains("已恢復"))
            if case .launched? = current?.state {} else { Issue.record("queue acceptance must not claim continuation") }
            try h.set(state(allowed: true, five: 3, fiveReset: realNow + 5 * 3600,
                            latest: turn("continued", status: "inProgress", started: Int(Date().timeIntervalSince1970) + 1, completed: nil)))
            await active.runEngine()
            if case .resumed? = active.planBook.plan(try #require(current).id)?.state {} else { Issue.record("new official turn confirms continuation") }
        }
        if scenario == .ownFollowUpFailure {
            // 自動排入的提示又中止（同一週期、沒有新的同時段用盡觀察）：不再自動付費重試。
            let now = Int(Date().timeIntervalSince1970)
            try h.set(state(allowed: true, five: 3, fiveReset: realNow + 5 * 3600, latest: turn("stop-2", started: now, completed: now)))
            fake = Date(timeIntervalSince1970: Double(reset) + 600)
            await active.refresh()
            await active.refresh()
            #expect(h.queued.count == 1)
            let followUp = active.planBook.active.first { $0.codex?.anchorTurnID == "stop-2" }
            #expect(followUp?.codex?.sessionAuthorization == nil)
        }
    }

    nonisolated static let fakeCLI = #"""
    #!/usr/bin/env python3
    import json, pathlib, sys, time
    root = pathlib.Path(__file__).parent
    state = json.loads((root / "state.json").read_text())
    args = sys.argv[1:]
    if args == ["queue", "--help"]:
        print("queue --resume --thread")
        sys.exit(0)
    if len(args) == 6 and args[:3] == ["queue", "--resume", "--thread"] and args[4] == "--message":
        with (root / "queue").open("a") as log:
            print(args[3], file=log)
        with (root / "messages").open("a") as log:
            print(json.dumps(args[5], ensure_ascii=False), file=log)
        if state.get("queueStderr"):
            print(state["queueStderr"], file=sys.stderr)
        sys.exit(state.get("queueExit", 0))
    if args != ["app-server"]:
        sys.exit(2)
    for line in sys.stdin:
        req = json.loads(line)
        method = req["method"]
        with (root / "methods").open("a") as log:
            print(method, file=log)
        if method == "initialize":
            print(json.dumps({"id": 1, "result": {}}), flush=True)
            continue
        if method == "initialized":
            continue
        if method == "account/rateLimits/read":
            if state.get("rateError"):
                print(json.dumps({"id": 2, "error": {"message": "fixture network failure"}}), flush=True)
                continue
            primary = {"usedPercent": state["five"], "windowDurationMins": 300, "resetsAt": state["fiveReset"]}
            secondary = None
            if "week" in state:
                secondary = {"usedPercent": state["week"], "windowDurationMins": 10080, "resetsAt": state["weekReset"]}
            bucket = {"limitId": state["bucket"], "normalModelSlug": None, "primary": primary, "secondary": secondary,
                      "rateLimitReachedType": state.get("reached"), "spendControlReached": state.get("spend")}
            byId = {state["bucket"]: bucket}
            for extra in state.get("extraBuckets", []):
                byId[extra["limitId"]] = dict(extra, primary=primary, secondary=None)
            result = {"accountId": state["account"], "ordinaryUsageAllowed": state["allowed"],
                      "rateLimits": bucket, "rateLimitsByLimitId": byId}
        elif method == "thread/read":
            result = {"thread": {"id": req["params"]["threadId"], "model": state["model"]}}
        elif method == "thread/turns/list":
            tid = req["params"]["threadId"]
            gate = root / "gate"
            if tid != state.get("session", tid):
                # 模擬完整掃描中與到期計畫無關的慢查詢（測試以 gate 檔控制）。
                deadline = time.monotonic() + 20
                while gate.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                result = {"data": [{"id": "other-" + tid[:4], "status": "completed", "startedAt": 1, "completedAt": 2}], "nextCursor": None}
            else:
                dispatch_gate = root / "dispatch-preflight-gate"
                if dispatch_gate.exists():
                    (root / "dispatch-preflight-paused").touch()
                    deadline = time.monotonic() + 12
                    while dispatch_gate.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                result = {"data": [state["turn"]], "nextCursor": None}
        else:
            sys.exit(3)
        print(json.dumps({"id": 2, "result": result}), flush=True)
    """#
}
