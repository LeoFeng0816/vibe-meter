import Foundation
import Testing
@testable import VibeMeterCore

private let t0 = Date(timeIntervalSince1970: 1_794_190_000)
private func w(_ kind: WindowKind, _ used: Double, resetIn: TimeInterval?) -> UsageWindow {
    UsageWindow(kind: kind, usedPercent: used, resetsAt: resetIn.map { t0.addingTimeInterval($0) })
}

@Suite struct WindowStatusTests {
    @Test func resetPassedIsNotShownAsCurrent() {
        let snap = TestSupport.snapshot(observedAt: t0, windows: [w(.fiveHour, 97, resetIn: 600)])
        let status = WindowStatus.evaluate(snap.windows[0], in: snap, now: t0.addingTimeInterval(601))
        #expect(status == .resetPassedAwaitingData(lastUsedPercent: 97, resetAt: t0.addingTimeInterval(600)))
        #expect(status.trustworthyUsedPercent == nil)
    }

    @Test func staleDataIsFlaggedAndExcludedFromSummary() {
        let snap = TestSupport.snapshot(observedAt: t0, windows: [w(.weekly, 40, resetIn: 86400)])
        let later = t0.addingTimeInterval(DataSource.codexAppServer.staleAfter + 1)
        #expect(WindowStatus.evaluate(snap.windows[0], in: snap, now: later) == .current(usedPercent: 40, resetsAt: t0.addingTimeInterval(86400), stale: true))
        #expect(UsageSummary.tightestRemainingPercent([snap], now: later) == nil)
        #expect(UsageSummary.tightestRemainingPercent([snap], now: t0) == 60)
    }

    @Test func summaryPicksTightestWindow() {
        let a = TestSupport.snapshot(observedAt: t0, windows: [w(.fiveHour, 83, resetIn: 3600), w(.weekly, 66, resetIn: 86400)])
        let b = TestSupport.snapshot(.claudeCode, observedAt: t0, source: .claudeStatusLine, windows: [w(.fiveHour, 20, resetIn: 3600)])
        #expect(UsageSummary.tightestRemainingPercent([a, b], now: t0) == 17)
    }
}

@Suite struct ClaudeBridgeTests {
    let statusJSON = """
    {"session_id":"\(TestSupport.sessionA)","session_name":"usage app","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/proj","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"version":"2.1.319","rate_limits":{"five_hour":{"used_percentage":92.5,"resets_at":1794200000},"seven_day":{"used_percentage":40,"resets_at":1794600000}}}
    """

    @Test func recordsSnapshotAndSession() throws {
        let store = ClaudeBridgeStore(paths: VibeMeterPaths(root: TestSupport.tempDir()))
        let input = try store.recordStatusLine(Data(statusJSON.utf8), now: t0)
        #expect(StatusLineText.compact(input.usageWindows()) == "5h 剩 8% · 週 剩 60%")
        let snap = try #require(store.latestSnapshot())
        #expect(snap.source == .claudeStatusLine)
        #expect(snap.window(.fiveHour)?.usedPercent == 92.5)
        #expect(snap.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1_794_600_000))
        #expect(snap.observedAt == t0)
        let sessions = store.recentSessions()
        #expect(sessions.map(\.id) == [TestSupport.sessionA])
        #expect(sessions[0].cwd == "/tmp/proj")
        let perms = try FileManager.default.attributesOfItem(atPath: store.paths.claudeRateLimits.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func missingRateLimitsKeepsPreviousSnapshot() throws {
        let store = ClaudeBridgeStore(paths: VibeMeterPaths(root: TestSupport.tempDir()))
        try store.recordStatusLine(Data(statusJSON.utf8), now: t0)
        try store.recordStatusLine(Data(#"{"session_id":"\#(TestSupport.sessionA)","cwd":"/tmp/proj"}"#.utf8), now: t0.addingTimeInterval(60))
        #expect(store.latestSnapshot()?.observedAt == t0)
    }

    @Test func rejectsNonUUIDSessionIDs() throws {
        let store = ClaudeBridgeStore(paths: VibeMeterPaths(root: TestSupport.tempDir()))
        try store.recordStatusLine(Data(#"{"session_id":"../../evil","cwd":"/"}"#.utf8), now: t0)
        try store.recordStopFailure(Data(#"{"session_id":"../../evil"}"#.utf8), reason: "rate_limit", now: t0)
        #expect(store.recentSessions().isEmpty)
        #expect(store.limitEvents(since: .distantPast).isEmpty)
    }

    @Test func recordsStopFailureEvents() throws {
        let store = ClaudeBridgeStore(paths: VibeMeterPaths(root: TestSupport.tempDir()))
        let hook = #"{"session_id":"\#(TestSupport.sessionA)","cwd":"/tmp/proj","hook_event_name":"StopFailure"}"#
        try store.recordStopFailure(Data(hook.utf8), reason: "rate_limit", now: t0)
        try store.recordStopFailure(Data(hook.utf8), reason: "rate_limit", now: t0.addingTimeInterval(10))
        #expect(store.limitEvents(since: .distantPast).count == 2)
        #expect(store.limitEvents(since: t0.addingTimeInterval(5)).count == 1)
    }
}

@Suite struct ClaudeSettingsInstallerTests {
    func setup(_ initial: String?) throws -> (ClaudeSettingsInstaller, URL) {
        let root = TestSupport.tempDir()
        let settings = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let initial { try initial.write(to: settings, atomically: true, encoding: .utf8) }
        return (ClaudeSettingsInstaller(settingsURL: settings, paths: VibeMeterPaths(root: root.appendingPathComponent("hr"))), settings)
    }

    func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func installPreservesSettingsAndChainsExistingStatusLine() throws {
        let initial = #"{"theme":"dark","permissions":{"allow":["Bash(ls)"]},"statusLine":{"type":"command","command":"~/my-status.sh","padding":1},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let (installer, url) = try setup(initial)
        #expect(installer.status() == .notInstalled)
        let bridge = URL(fileURLWithPath: "/Users/x/Library/Application Support/Vibe Meter/bin/vibemeter-bridge")
        let backup = try #require(try installer.install(bridge: bridge, now: t0))
        #expect(try String(contentsOf: backup, encoding: .utf8) == initial)
        #expect(installer.status() == .installed)

        let s = try json(url)
        #expect(s["theme"] as? String == "dark")
        #expect((s["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
        let status = try #require(s["statusLine"] as? [String: Any])
        #expect(status["command"] as? String == "'/Users/x/Library/Application Support/Vibe Meter/bin/vibemeter-bridge' claude-statusline")
        #expect(status["padding"] as? Int == 1)
        let hooks = try #require(s["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [Any])?.count == 1)
        #expect((hooks["StopFailure"] as? [[String: Any]])?.first?["matcher"] as? String == "rate_limit")

        // 重複安裝不會重複加入 hook，也不會把自己當成要串接的原指令
        try installer.install(bridge: bridge, now: t0.addingTimeInterval(1))
        #expect(((try json(url)["hooks"] as? [String: Any])?["StopFailure"] as? [Any])?.count == 1)

        try installer.uninstall(now: t0.addingTimeInterval(2))
        let restored = try json(url)
        #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "~/my-status.sh")
        #expect((restored["hooks"] as? [String: Any])?["StopFailure"] == nil)
        #expect(((restored["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1)
        #expect(installer.status() == .notInstalled)
    }

    @Test func installWithoutExistingFileAndUninstallCleansUp() throws {
        let (installer, url) = try setup(nil)
        #expect(try installer.install(bridge: URL(fileURLWithPath: "/b/vibemeter-bridge"), now: t0) == nil)
        #expect(installer.status() == .installed)
        try installer.uninstall(now: t0)
        let s = try json(url)
        #expect(s["statusLine"] == nil && s["hooks"] == nil)
    }

    @Test func corruptSettingsAreNotOverwritten() throws {
        let (installer, url) = try setup("{ not json")
        #expect(throws: (any Error).self) { try installer.install(bridge: URL(fileURLWithPath: "/b/vibemeter-bridge"), now: t0) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }
}

@Suite struct AlertPolicyTests {
    let policy = AlertPolicy(thresholds: [80, 95])

    @Test func firesHighestCrossedThresholdOnce() {
        let s85 = TestSupport.snapshot(observedAt: t0, windows: [w(.fiveHour, 85, resetIn: 3600), w(.weekly, 50, resetIn: 86400)])
        let first = policy.alerts(for: [s85], now: t0, alreadyFired: [])
        #expect(first.map(\.threshold) == [80])
        let fired = Set(first.map(\.dedupeKey))
        #expect(policy.alerts(for: [s85], now: t0, alreadyFired: fired).isEmpty)

        let s96 = TestSupport.snapshot(observedAt: t0, windows: [w(.fiveHour, 96, resetIn: 3600)])
        let second = policy.alerts(for: [s96], now: t0, alreadyFired: fired)
        #expect(second.map(\.threshold) == [95])
        #expect(second.first?.title == "Codex 5 小時額度剩 4%")
    }

    @Test func newCycleAlertsAgainAndStaleDataIsIgnored() {
        let old = TestSupport.snapshot(observedAt: t0, windows: [w(.fiveHour, 90, resetIn: 3600)])
        let fired = Set(policy.alerts(for: [old], now: t0, alreadyFired: []).map(\.dedupeKey))
        let nextCycle = TestSupport.snapshot(observedAt: t0, windows: [w(.fiveHour, 90, resetIn: 3600 + 18000)])
        #expect(policy.alerts(for: [nextCycle], now: t0, alreadyFired: fired).count == 1)
        #expect(policy.alerts(for: [old], now: t0.addingTimeInterval(DataSource.codexAppServer.staleAfter + 1), alreadyFired: []).isEmpty)
    }
}

@Suite struct CommandTests {
    @Test func resumeCommandQuotesEverything() throws {
        let p = try ResumePlan(provider: .codex, sessionID: TestSupport.sessionA.uppercased(), sessionTitle: "x",
                               cwd: "/Users/me/it's here", prompt: "繼續；別 $(rm) `x`", blockedWindow: .fiveHour, expectedResetAt: nil)
        let cmd = ResumeCommandBuilder.command(for: p, codexBinary: "/Apps/codex")
        #expect(cmd == "cd '/Users/me/it'\\''s here' && '/Apps/codex' resume '\(TestSupport.sessionA)' '繼續；別 $(rm) `x`'")

        var c = p
        c.provider = .claudeCode
        #expect(ResumeCommandBuilder.command(for: c, claudeBinary: "claude").contains("'claude' --resume '\(TestSupport.sessionA)'"))
    }

    @Test func commandFileIsExecutableOnlyByOwner() throws {
        let p = try ResumePlan(provider: .codex, sessionID: TestSupport.sessionA, sessionTitle: "x", cwd: "/tmp",
                               blockedWindow: .fiveHour, expectedResetAt: nil)
        let url = try ResumeCommandBuilder.writeCommandFile(for: p, command: "echo hi", in: TestSupport.tempDir())
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.posixPermissions] as? Int == 0o700)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("#!/bin/zsh -l\n"))
    }

    @Test func handoffPromptsCarryIdentity() {
        let b = HandoffPromptBuilder()
        let pack = b.packPrompt(agent: .codex, sessionID: TestSupport.sessionA, cwd: "/tmp/proj")
        #expect(pack.contains("/tmp/proj/HANDOFF.md"))
        #expect(pack.contains(TestSupport.sessionA))
        #expect(pack.contains("git status --short"))
        #expect(pack.contains("不要 commit"))
        #expect(b.takeoverCommand(cwd: "/tmp/proj").hasPrefix("cd '/tmp/proj' && 'codex' '"))
    }

    @Test func zhFormatting() {
        #expect(ZhFormat.duration(30) == "不到 1 分鐘")
        #expect(ZhFormat.duration(3 * 3600 + 12 * 60) == "3 小時 12 分")
        #expect(ZhFormat.duration(2 * 86400 + 5 * 3600) == "2 天 5 小時")
        #expect(ZhFormat.resetIn(t0.addingTimeInterval(300), now: t0) == "5 分鐘後重設")
        #expect(ZhFormat.ago(t0, now: t0.addingTimeInterval(10)) == "剛剛")
    }
}
