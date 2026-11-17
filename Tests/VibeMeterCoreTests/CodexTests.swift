import Foundation
import Testing
@testable import VibeMeterCore

@Suite struct CodexParsingTests {
    @Test func parsesRolloutTokenCount() throws {
        let line = TestSupport.tokenCountLine(timestamp: "2026-11-09T04:02:12.391Z", primaryUsed: 83, secondaryUsed: 66)
        let snap = try #require(CodexRateLimitParser.parseRolloutLine(Substring(line)))
        #expect(snap.provider == .codex)
        #expect(snap.source == .codexRolloutLog)
        #expect(snap.planName == "plus")
        #expect(snap.windows.count == 2)
        #expect(snap.window(.fiveHour)?.usedPercent == 83)
        #expect(snap.window(.weekly)?.usedPercent == 66)
        #expect(snap.window(.fiveHour)?.resetsAt == Date(timeIntervalSince1970: 1_794_200_383))
        #expect(abs(snap.observedAt.timeIntervalSince1970 - 1_794_196_932.391) < 0.01)
    }

    @Test func ignoresOtherLines() {
        #expect(CodexRateLimitParser.parseRolloutLine(#"{"type":"response_item","payload":{"type":"message"}}"#) == nil)
        #expect(CodexRateLimitParser.parseRolloutLine(#"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#) == nil)
        #expect(CodexRateLimitParser.parseRolloutLine("not json \"token_count\" \"rate_limits\"") == nil)
    }

    @Test func parsesAppServerResult() throws {
        let json = """
        {"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":83,"windowDurationMins":300,"resetsAt":1794200383},"secondary":{"usedPercent":66,"windowDurationMins":10080,"resetsAt":1794493334},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus","rateLimitReachedType":null},"rateLimitResetCredits":{"availableCount":2,"credits":[]}}
        """
        let now = Date(timeIntervalSince1970: 1_794_197_000)
        let snap = try CodexRateLimitParser.parseAppServerResult(Data(json.utf8), observedAt: now)
        #expect(snap.source == .codexAppServer)
        #expect(snap.observedAt == now)
        #expect(snap.window(.fiveHour)?.usedPercent == 83)
        #expect(snap.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1_794_493_334))
        #expect(snap.limitReachedType == nil)
    }

    @Test func unknownWindowLengthIsKeptNotGuessed() throws {
        let json = #"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":1440,"resetsAt":1}}}"#
        let snap = try CodexRateLimitParser.parseAppServerResult(Data(json.utf8), observedAt: Date())
        #expect(snap.windows.first?.kind == .minutes(1440))
        #expect(snap.windows.first?.kind.label == "1 天")
    }

    @Test func parsesSevenDigitFractionalSeconds() throws {
        let d = try #require(ISO8601.parse("2026-09-05T17:10:06.7786027Z"))
        #expect(abs(d.timeIntervalSince1970 - 1_788_628_206.778) < 0.01)
        #expect(ISO8601.parse("2026-09-05T17:10:06Z") != nil)
    }
}

@Suite struct CodexAppServerProtocolTests {
    @Test func onlySendsReadOnlyAllowlistedMethods() throws {
        let lines = CodexAppServerClient.requestLines(method: "account/rateLimits/read")
        let methods = try lines.map { line -> String in
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(obj["method"] as? String)
        }
        #expect(methods == ["initialize", "initialized", "account/rateLimits/read"])
        #expect(CodexAppServerClient.allowedMethods == ["initialize", "initialized", "account/rateLimits/read", "thread/turns/list", "thread/read"])
        #expect(!CodexAppServerClient.allowedMethods.contains("account/rateLimitResetCredit/consume"))
        #expect(lines.allSatisfy { !$0.contains("\n") })
        let turnLines = CodexAppServerClient.requestLines(method: "thread/turns/list", params: ["threadId": TestSupport.sessionA, "limit": 1])
        #expect(turnLines[2].contains("\"limit\":1"))
    }

    @Test func extractsResultOrError() throws {
        #expect(try CodexAppServerClient.extractResult(fromLine: #"{"id":1,"result":{}}"#) == nil)
        #expect(try CodexAppServerClient.extractResult(fromLine: #"{"method":"account/updated"}"#) == nil)
        #expect(try CodexAppServerClient.extractResult(fromLine: #"{"id":2,"result":{"rateLimits":{}}}"#) != nil)
        #expect(throws: CodexAppServerError.rpcError("not logged in")) {
            try CodexAppServerClient.extractResult(fromLine: #"{"id":2,"error":{"code":-1,"message":"not logged in"}}"#)
        }
    }

    @Test func parsesOrdinaryUsageAllowedAndAccount() throws {
        func parse(_ allowed: String) throws -> UsageSnapshot {
            let json = #"{"ordinaryUsageAllowed":\#(allowed),"accountId":"acct-1","rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1}}}"#
            return try CodexRateLimitParser.parseAppServerResult(Data(json.utf8), observedAt: Date())
        }
        #expect(try parse("true").usageAllowed == true)
        #expect(try parse("false").usageAllowed == false)
        #expect(try parse("null").usageAllowed == nil)
        #expect(try parse("null").accountID == "acct-1")
        let missing = try CodexRateLimitParser.parseAppServerResult(Data(#"{"rateLimits":{}}"#.utf8), observedAt: Date())
        #expect(missing.usageAllowed == nil && missing.accountID == nil)
    }

    @Test func parsesLatestTurnSummary() throws {
        let failed = #"{"data":[{"id":"t2","status":"failed","error":{"message":"limit","codexErrorInfo":"usageLimitExceeded","additionalDetails":null},"startedAt":1794200000,"completedAt":1794200050}],"nextCursor":null}"#
        let turn = try #require(try CodexTurnSummary.parseLatest(Data(failed.utf8)))
        #expect(turn.isUsageLimitFailure)
        #expect(turn.completedAt == Date(timeIntervalSince1970: 1_794_200_050))
        let objectError = #"{"data":[{"id":"t3","status":"failed","error":{"message":"x","codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":502}}}}]}"#
        let other = try #require(try CodexTurnSummary.parseLatest(Data(objectError.utf8)))
        #expect(other.errorInfo == "httpConnectionFailed" && !other.isUsageLimitFailure)
        #expect(try CodexTurnSummary.parseLatest(Data(#"{"data":[]}"#.utf8)) == nil)
        #expect(!CodexTurnSummary(id: "a", status: "completed", errorInfo: "usageLimitExceeded").isUsageLimitFailure)
    }

    /// 實際呼叫本機 Codex（需要已登入）。預設略過：HEADROOM_LIVE_CODEX=1 swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEADROOM_LIVE_CODEX"] == "1"))
    func liveReadAgainstInstalledCodex() async throws {
        let binary = try #require(CodexLocator.find())
        let snap = try await CodexAppServerClient(binary: binary).readRateLimits()
        #expect(snap.source == .codexAppServer)
        #expect(!snap.windows.isEmpty)
        print("[live] usageAllowed=\(String(describing: snap.usageAllowed)) accountID?=\(snap.accountID != nil) windows=\(snap.windows.map { "\($0.kind.key)=\($0.usedPercent)" })")
        for s in CodexLocalStore().recentSessions(limit: 2) {
            let t = try await CodexAppServerClient(binary: binary).latestTurn(threadID: s.id)
            print("[live] thread \(s.id.prefix(8)) latest=\(t?.status ?? "nil") error=\(t?.errorInfo ?? "-") limitFailure=\(t?.isUsageLimitFailure ?? false)")
        }

    }
}

@Suite struct CodexLocalStoreTests {
    func makeHome() throws -> URL {
        let home = TestSupport.tempDir()
        let day = home.appendingPathComponent("sessions/2026/11/09")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let older = day.appendingPathComponent("rollout-2026-11-09T10-00-00-\(TestSupport.sessionB).jsonl")
        try [TestSupport.sessionMetaLine(id: TestSupport.sessionB, cwd: "/tmp/projB"),
             TestSupport.tokenCountLine(timestamp: "2026-11-09T02:00:00.000Z", primaryUsed: 10, secondaryUsed: 20)]
            .joined(separator: "\n").write(to: older, atomically: true, encoding: .utf8)
        let newer = day.appendingPathComponent("rollout-2026-11-09T11-42-52-\(TestSupport.sessionA).jsonl")
        try [TestSupport.sessionMetaLine(id: TestSupport.sessionA, cwd: "/tmp/projA"),
             TestSupport.tokenCountLine(timestamp: "2026-11-09T04:00:00.000Z", primaryUsed: 82, secondaryUsed: 66),
             #"{"timestamp":"2026-11-09T04:01:00.000Z","type":"response_item","payload":{"type":"message"}}"#,
             TestSupport.tokenCountLine(timestamp: "2026-11-09T04:02:12.391Z", primaryUsed: 100, secondaryUsed: 66,
                                        reached: "rate_limit_reached")]
            .joined(separator: "\n").write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_794_189_600)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_794_196_932)], ofItemAtPath: newer.path)
        // 無效 id 的檔案必須被忽略
        let bogus = day.appendingPathComponent("rollout-bogus.jsonl")
        try TestSupport.sessionMetaLine(id: "../../etc", cwd: "/").write(to: bogus, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_794_190_000)], ofItemAtPath: bogus.path)
        try """
        {"id":"\(TestSupport.sessionA)","thread_name":"舊名稱","updated_at":"2026-11-09T03:00:00.0000000Z"}
        {"id":"\(TestSupport.sessionA)","thread_name":"建立選單列 App","updated_at":"2026-11-09T04:00:00.0000000Z"}
        """.write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        return home
    }

    @Test func latestSnapshotUsesNewestObservation() throws {
        let store = CodexLocalStore(codexHome: try makeHome())
        let snap = try #require(store.latestRateLimitSnapshot())
        #expect(snap.window(.fiveHour)?.usedPercent == 100)
        #expect(snap.limitReachedType == "rate_limit_reached")
    }

    @Test func recentSessionsUseMetaIdentityAndLatestName() throws {
        let store = CodexLocalStore(codexHome: try makeHome())
        let sessions = store.recentSessions(limit: 5, now: Date(timeIntervalSince1970: 1_794_197_000))
        #expect(sessions.map(\.id) == [TestSupport.sessionA, TestSupport.sessionB])
        #expect(store.isSubagent(sessionID: TestSupport.sessionA, now: Date(timeIntervalSince1970: 1_794_197_000)) == false)
        #expect(sessions[0].threadName == "建立選單列 App")
        #expect(sessions[0].cwd == "/tmp/projA")
        #expect(sessions[0].lastLimitReachedType == "rate_limit_reached")
        #expect(sessions[1].lastLimitReachedType == nil)
    }

    @Test(arguments: [
        #","source":{"subagent":{"thread_spawn":{"parent_thread_id":"example","depth":1}}}"#,
        #","parent_thread_id":"0b9f8a6e-1111-4222-8333-944455556666""#,
        #","thread_source":"subagent""#,
    ])
    func excludesEachIndependentSubagentMarker(_ marker: String) throws {
        let store = try writeRollout(sourceFields: marker)
        defer { try? FileManager.default.removeItem(at: store.codexHome) }
        #expect(store.isSubagent(sessionID: TestSupport.sessionA) == true)
        #expect(store.recentSessions().isEmpty)
    }

    @Test(arguments: ["", #","source":"unknown""#, #","source":["unrecognized"]"#, #","thread_source":99"#])
    func unknownMetadataDoesNotAuthorizeDelivery(_ marker: String) throws {
        let store = try writeRollout(sourceFields: marker)
        defer { try? FileManager.default.removeItem(at: store.codexHome) }
        #expect(store.isSubagent(sessionID: TestSupport.sessionA) == nil)
        #expect(store.recentSessions().isEmpty)
    }

    private func writeRollout(sourceFields: String) throws -> CodexLocalStore {
        let home = TestSupport.tempDir()
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-fixture-\(TestSupport.sessionA).jsonl")
        let line = """
        {"type":"session_meta","payload":{"id":"\(TestSupport.sessionA)","cwd":"/tmp/project"\(sourceFields)}}
        """
        try line.write(to: rollout, atomically: true, encoding: .utf8)
        return CodexLocalStore(codexHome: home)
    }

    @Test func missingHomeIsHandled() {
        let store = CodexLocalStore(codexHome: URL(fileURLWithPath: "/nonexistent/\(UUID())"))
        #expect(!store.isInstalled)
        #expect(store.latestRateLimitSnapshot() == nil)
        #expect(store.recentSessions().isEmpty)
    }
}
