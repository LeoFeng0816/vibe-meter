import Foundation
import Testing
@testable import VibeMeterCore

/// v0.1.1 安全審查後的強化：Claude statusLine 新鮮度、原生自動繼續的呈現、Codex 輪詢節奏。
@Suite(.serialized) struct ClaudeBridgeFreshnessTests {
    let sessionA = "aaaaaaaa-1111-4222-8333-944455556666"
    let sessionB = "bbbbbbbb-1111-4222-8333-944455556666"

    private func store() -> ClaudeBridgeStore { ClaudeBridgeStore(paths: VibeMeterPaths(root: TestSupport.tempDir())) }

    private func input(_ session: String, five: Double, week: Double? = nil, api: Double?) -> Data {
        var limits = #""five_hour":{"used_percentage":\#(five),"resets_at":1894220000}"#
        if let week { limits += #","seven_day":{"used_percentage":\#(week),"resets_at":1894820000}"# }
        let cost = api.map { #","cost":{"total_api_duration_ms":\#($0)}"# } ?? ""
        return Data(#"{"session_id":"\#(session)","version":"2.1.322","rate_limits":{\#(limits)}\#(cost)}"#.utf8)
    }

    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 3600 + s) }

    @Test func sameCounterReplayDoesNotRefreshTime() throws {
        let s = store()
        try s.recordStatusLine(input(sessionA, five: 10, api: 0), now: at(0))      // 第一次：時間不明
        #expect(s.latestSnapshot()?.responseTimeUnknown == true)
        try s.recordStatusLine(input(sessionA, five: 12, api: 500), now: at(10))   // 新回應
        let fresh = try #require(s.latestSnapshot())
        #expect(fresh.observedAt == at(10) && fresh.responseTimeUnknown == nil)
        // 權限模式切換、refreshInterval 等重跑：同一計數，即使時間更晚也不更新。
        try s.recordStatusLine(input(sessionA, five: 12, api: 500), now: at(600))
        #expect(s.latestSnapshot()?.observedAt == at(10))
    }

    @Test func otherSessionsOldValuesNeverOverwriteNewerData() throws {
        let s = store()
        try s.recordStatusLine(input(sessionA, five: 5, api: 0), now: at(0))
        try s.recordStatusLine(input(sessionA, five: 40, api: 900), now: at(20))   // A 新資料
        // B 是早已閒置的工作階段，第一次被看到時帶著自己很久以前的舊值。
        try s.recordStatusLine(input(sessionB, five: 7, api: 3000), now: at(30))
        #expect(s.latestSnapshot()?.window(.fiveHour)?.usedPercent == 40)
        // B 重繪（計數不變）也不覆蓋。
        try s.recordStatusLine(input(sessionB, five: 7, api: 3000), now: at(40))
        #expect(s.latestSnapshot()?.window(.fiveHour)?.usedPercent == 40)
        // B 真正收到新回應才會更新。
        try s.recordStatusLine(input(sessionB, five: 44, api: 3100), now: at(50))
        #expect(s.latestSnapshot()?.window(.fiveHour)?.usedPercent == 44)
        #expect(s.latestSnapshot()?.observedAt == at(50))
    }

    @Test func outOfOrderCounterUsesMonotonicHighWater() throws {
        let s = store()
        try s.recordStatusLine(input(sessionA, five: 1, api: 50), now: at(0))
        try s.recordStatusLine(input(sessionA, five: 20, api: 200), now: at(10))   // 新
        try s.recordStatusLine(input(sessionA, five: 10, api: 100), now: at(20))   // 晚結束的舊 script
        #expect(s.latestSnapshot()?.window(.fiveHour)?.usedPercent == 20)
        try s.recordStatusLine(input(sessionA, five: 20, api: 200), now: at(30))   // 200 再出現不是新報告
        #expect(s.latestSnapshot()?.observedAt == at(10))
        let session = try #require(s.recentSessions().first { $0.id == sessionA })
        #expect(session.apiDurationMs == 200)
    }

    @Test func droppedWindowIsNotANewReportOrReset() throws {
        let s = store()
        try s.recordStatusLine(input(sessionA, five: 1, api: 0), now: at(0))
        try s.recordStatusLine(input(sessionA, five: 99, week: 50, api: 10), now: at(10))
        // 到達 resets_at 後 Claude Code 移除窗口並重跑：rate_limits 為空。
        try s.recordStatusLine(Data(#"{"session_id":"\#(sessionA)","rate_limits":{},"cost":{"total_api_duration_ms":10}}"#.utf8), now: at(20))
        let snap = try #require(s.latestSnapshot())
        #expect(snap.observedAt == at(10) && snap.window(.fiveHour)?.usedPercent == 99)
    }

    @Test func legacyInputWithoutCostCannotMakeUsageFresh() throws {
        let s = store()
        try s.recordStatusLine(input(sessionA, five: 10, api: nil), now: at(0))
        #expect(s.latestSnapshot()?.observedAt == at(0))
        try s.recordStatusLine(input(sessionA, five: 10, api: nil), now: at(10))
        #expect(s.latestSnapshot()?.observedAt == at(0))
        try s.recordStatusLine(input(sessionA, five: 11, api: nil), now: at(20))
        #expect(s.latestSnapshot()?.observedAt == at(0))
        #expect(s.latestSnapshot()?.responseTimeUnknown == true)
    }

    /// 50 個 bridge 同時執行（亂序）：鎖確保讀取→判斷→寫入不交錯，最後一定是最大計數的資料。
    @Test func concurrentBridgesSerializeAndKeepHighestSample() throws {
        let s = store()
        try s.recordStatusLine(input(sessionA, five: 0, api: 0), now: at(0))
        let order = Array(1...50).shuffled()
        let base = at(100)
        DispatchQueue.concurrentPerform(iterations: order.count) { i in
            let n = order[i]
            _ = try? s.recordStatusLine(input(sessionA, five: Double(n), api: Double(n)), now: base.addingTimeInterval(Double(i)))
        }
        // 另一個工作階段同時重繪舊值也不影響。
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            _ = try? s.recordStatusLine(input(sessionB, five: 3, api: 7), now: base.addingTimeInterval(Double(60 + i)))
        }
        #expect(s.latestSnapshot()?.window(.fiveHour)?.usedPercent == 50)
        #expect(s.recentSessions().first { $0.id == sessionA }?.apiDurationMs == 50)
    }

    @Test func futureObservationIsRejectedAndUnknownTimeIsStale() throws {
        let s = store()
        let future = UsageSnapshot(provider: .claudeCode, windows: [UsageWindow(kind: .fiveHour, usedPercent: 1, resetsAt: nil)],
                                   observedAt: Date().addingTimeInterval(3600), source: .claudeStatusLine)
        try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(future), to: s.paths.claudeRateLimits)
        #expect(s.latestSnapshot() == nil)
        #expect(ClaudeRefreshPolicy.status(latest: future, now: Date()) == .awaitingReport)
        var unknown = future
        unknown.observedAt = Date()
        unknown.responseTimeUnknown = true
        #expect(unknown.isStale(now: Date()))
        #expect(ClaudeRefreshPolicy.status(latest: unknown, now: Date()) == .responseTimeUnknown(seenAt: unknown.observedAt))
    }
}

@Suite struct ClaudeNativeContinueTests {
    private func settings(_ json: String?) throws -> URL {
        let url = TestSupport.tempDir().appendingPathComponent("settings.json")
        if let json { try Data(json.utf8).write(to: url) }
        return url
    }

    @Test func readsOnlyTheUserSettingKey() throws {
        #expect(ClaudeNativeContinue.userSetting(settingsURL: try settings(nil)) == .unset)
        #expect(ClaudeNativeContinue.userSetting(settingsURL: try settings(#"{"theme":"dark"}"#)) == .unset)
        #expect(ClaudeNativeContinue.userSetting(settingsURL: try settings(#"{"autoContinueAtUsageLimit":true}"#)) == .on)
        #expect(ClaudeNativeContinue.userSetting(settingsURL: try settings(#"{"autoContinueAtUsageLimit":false}"#)) == .off)
        #expect(ClaudeNativeContinue.userSetting(settingsURL: try settings(#"{"autoContinueAtUsageLimit":"yes"}"#)) == .unreadable)
        #expect(ClaudeNativeContinue.userSetting(settingsURL: try settings("{oops")) == .unreadable)
        for literal in ["0", "1", "null"] {
            #expect(ClaudeNativeContinue.userSetting(settingsURL: try settings("{\"autoContinueAtUsageLimit\":\(literal)}")) == .unreadable)
        }
    }

    private func transcript(lines: [String]) throws -> ClaudeTranscriptStore {
        let projects = TestSupport.tempDir()
        let dir = projects.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: dir.appendingPathComponent("\(TestSupport.sessionA).jsonl"))
        return ClaudeTranscriptStore(projectsDir: projects)
    }

    private func limitLine(at: String = "2026-11-13T01:00:00.000Z", reset: Double, version: String = "2.1.322", entry: String = "cli") -> String {
        #"{"type":"assistant","uuid":"m-1","sessionId":"\#(TestSupport.sessionA)","cwd":"/tmp/project","timestamp":"\#(at)","error":"rate_limit","isApiErrorMessage":true,"version":"\#(version)","entrypoint":"\#(entry)","apiErrorParams":{"rate_limit_info":{"resetsAt":\#(reset),"rateLimitType":"five_hour","overageStatus":"rejected"}},"message":{"model":"<synthetic>"}}"#
    }

    @Test func phasesFromTranscriptFacts() throws {
        let hitAt = ISO8601.parse("2026-11-13T01:00:00.000Z")!
        let reset = hitAt.addingTimeInterval(3600)
        let user = #"{"type":"user","uuid":"u-1","sessionId":"\#(TestSupport.sessionA)","cwd":"/tmp/project","timestamp":"2026-11-13T00:59:00.000Z"}"#
        let blocked = try transcript(lines: [user, limitLine(reset: reset.timeIntervalSince1970)])
        let info = try #require(blocked.recentSessions(within: 10 * 86400, now: hitAt).first)
        #expect(info.limitHit?.entrypoint == "cli" && info.lastLimit?.version == "2.1.322" && !info.continuedAfterLimit)
        let before = ClaudeNativeContinue.observations([info], setting: .unset, now: hitAt.addingTimeInterval(60))
        #expect(before.first?.phase == .blockedBeforeReset(resetsAt: reset) && before.first?.caveats == [])
        let after = ClaudeNativeContinue.observations([info], setting: .unset, now: reset.addingTimeInterval(60))
        #expect(after.first?.phase == .resetPassedNoNewConversation(resetsAt: reset))

        let continued = #"{"type":"assistant","uuid":"a-2","sessionId":"\#(TestSupport.sessionA)","cwd":"/tmp/project","timestamp":"2026-11-13T02:01:00.000Z","message":{"model":"claude-opus-5-5"}}"#
        let resumed = try transcript(lines: [user, limitLine(reset: reset.timeIntervalSince1970), continued])
        let info2 = try #require(resumed.recentSessions(within: 10 * 86400, now: hitAt).first)
        #expect(info2.limitHit == nil && info2.lastLimit != nil && info2.continuedAfterLimit)
        #expect(ClaudeNativeContinue.observations([info2], setting: .on, now: reset).first?.phase == .continuedAfterLimit)
    }

    @Test func ignoresOtherSessionSidechainsAndNonAssistantErrors() throws {
        let at = ISO8601.parse("2026-11-13T01:00:00.000Z")!
        let reset = at.addingTimeInterval(3600)
        let line = limitLine(reset: reset.timeIntervalSince1970)
        let wrongSession = line.replacingOccurrences(of: TestSupport.sessionA, with: "aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff")
        let sidechain = line.replacingOccurrences(of: #"{"type":"assistant""#, with: #"{"type":"assistant","isSidechain":true"#)
        let userError = line.replacingOccurrences(of: #""type":"assistant""#, with: #""type":"user""#)
        for rejected in [wrongSession, sidechain, userError] {
            let store = try transcript(lines: [rejected])
            #expect(store.recentSessions(within: 10 * 86400, now: at).first?.lastLimit == nil)
        }
    }

    @Test func caveatsForOldVersionNonInteractiveLongResetAndSettingOff() throws {
        let hitAt = ISO8601.parse("2026-11-13T01:00:00.000Z")!
        let weekly = hitAt.addingTimeInterval(3 * 86400).timeIntervalSince1970
        let store = try transcript(lines: [limitLine(reset: weekly, version: "2.1.200", entry: "sdk-cli")])
        let info = try #require(store.recentSessions(within: 10 * 86400, now: hitAt).first)
        let caveats = Set(ClaudeNativeContinue.observations([info], setting: .off, now: hitAt).first?.caveats ?? [])
        #expect(caveats == [.versionTooOld("2.1.200"), .nonInteractive("sdk-cli"), .resetBeyond24Hours, .userSettingOff])
        #expect(ClaudeVersion.atLeast("2.1.234 (Claude Code)", "2.1.234"))
        #expect(!ClaudeVersion.atLeast("2.1.99", "2.1.234") && ClaudeVersion.atLeast("2.10.0", "2.1.234"))
        #expect(!ClaudeVersion.atLeast("garbage", "2.1.234"))
    }

    @Test func claudePlansAreNeverAutomatic() throws {
        let plan = try ResumePlan(provider: .claudeCode, sessionID: TestSupport.sessionA, sessionTitle: "x", cwd: "/tmp",
                                  blockedWindow: .fiveHour, expectedResetAt: Date().addingTimeInterval(-60))
        #expect(AutoResumeGate.blocker(for: plan) == ClaudeNativeContinue.handledNatively)
        if case .needsConfirmation = plan.state {} else { Issue.record("Claude plan must not wait for automatic delivery") }
    }
}

@Suite struct CodexPollPolicyTests {
    @Test func cadenceAndBackoff() {
        #expect(CodexPollPolicy.delay(consecutiveFailures: 0) == 30)
        #expect(CodexPollPolicy.delay(consecutiveFailures: 1) == 60)
        #expect(CodexPollPolicy.delay(consecutiveFailures: 2) == 120)
        #expect(CodexPollPolicy.delay(consecutiveFailures: 3) == 240)
        #expect(CodexPollPolicy.delay(consecutiveFailures: 4) == 300)
        #expect(CodexPollPolicy.delay(consecutiveFailures: 100) == 300)
    }

    @Test func failuresAreDescribedNotTreatedAsUsage() {
        #expect(L10n.display(CodexPollPolicy.describe(CodexAppServerError.timeout), in: .zhHant) == "Codex app-server 回應逾時")
        #expect(L10n.display(CodexPollPolicy.describe(URLError(.notConnectedToInternet)), in: .zhHant) == "目前離線")
        #expect(L10n.display(CodexPollPolicy.describe(CodexAppServerError.rpcError("x")), in: .en).contains("x"))
    }

    @Test func allowlistStillReadOnly() {
        #expect(CodexAppServerClient.allowedMethods == ["initialize", "initialized", "account/rateLimits/read", "thread/turns/list", "thread/read"])
    }
}
