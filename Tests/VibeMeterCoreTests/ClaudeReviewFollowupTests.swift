import Foundation
import Testing
@testable import VibeMeterCore

/// 獨立審查（Claude 用量與原生續作顯示）後補的回歸測試。
@Suite(.serialized) struct ClaudeReviewFollowupTests {
    let session = "cccccccc-1111-4222-8333-944455556666"

    private func store() -> ClaudeBridgeStore { ClaudeBridgeStore(paths: VibeMeterPaths(root: TestSupport.tempDir())) }
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 7200 + s) }

    private func input(five: Double?, fiveReset: Date? = nil, week: Double? = nil, api: Double, version: String = "2.1.322",
                       name: String = "new") -> Data {
        var parts: [String] = []
        if let five { parts.append(#""five_hour":{"used_percentage":\#(five),"resets_at":\#(Int((fiveReset ?? Date().addingTimeInterval(3600)).timeIntervalSince1970))}"#) }
        if let week { parts.append(#""seven_day":{"used_percentage":\#(week),"resets_at":\#(Int(Date().addingTimeInterval(5 * 86400).timeIntervalSince1970))}"#) }
        return Data(#"{"session_id":"\#(session)","session_name":"\#(name)","version":"\#(version)","rate_limits":{\#(parts.joined(separator: ","))},"cost":{"total_api_duration_ms":\#(api)}}"#.utf8)
    }

    @Test func settingAcceptsOnlyJSONBooleans() throws {
        func value(_ raw: String) throws -> ClaudeNativeContinue.UserSetting {
            let url = TestSupport.tempDir().appendingPathComponent("settings.json")
            try Data(#"{"autoContinueAtUsageLimit":\#(raw)}"#.utf8).write(to: url)
            return ClaudeNativeContinue.userSetting(settingsURL: url)
        }
        #expect(try value("true") == .on)
        #expect(try value("false") == .off)
        #expect(try value("1") == .unreadable)
        #expect(try value("0") == .unreadable)
        #expect(try value("null") == .unreadable)
        #expect(try value(#""true""#) == .unreadable)
    }

    @Test func olderWriterCannotRollBackMetadataOrBaseline() throws {
        let s = store()
        try s.recordStatusLine(input(five: 5, api: 0), now: at(0))
        try s.recordStatusLine(input(five: 20, api: 200), now: at(20))
        try s.recordStatusLine(input(five: 10, api: 100, version: "2.1.100", name: "old"), now: at(30))
        let info = try #require(s.recentSessions().first { $0.id == session })
        #expect(info.version == "2.1.322" && info.name == "new" && info.apiDurationMs == 200)
        #expect(info.reportedWindows?.first?.usedPercent == 20)
        #expect(info.lastSeen >= at(20))
        #expect(s.latestSnapshot()?.window(.fiveHour)?.usedPercent == 20)
    }

    @Test func newResponseWithSameValuesIsActivityNotFreshUsage() throws {
        let s = store()
        try s.recordStatusLine(input(five: 5, week: 30, api: 0), now: at(0))
        try s.recordStatusLine(input(five: 10, week: 30, api: 100), now: at(10))
        #expect(s.latestSnapshot()?.observedAt == at(10))
        try s.recordStatusLine(input(five: 10, week: 30, api: 200), now: at(40))
        #expect(s.latestSnapshot()?.observedAt == at(10))
        #expect(s.lastActivityWithoutChange() == at(40))
        // 只有 5 小時窗口消失、數值不變：仍不是新的用量資料。
        try s.recordStatusLine(input(five: nil, week: 30, api: 300), now: at(60))
        let snap = try #require(s.latestSnapshot())
        #expect(snap.observedAt == at(10) && snap.window(.fiveHour)?.usedPercent == 10)
    }

    @Test func expiredWindowIsKeptButMissingFutureWindowIsNot() throws {
        let s = store()
        let past = at(5)
        try s.recordStatusLine(input(five: 1, fiveReset: past, week: 20, api: 0), now: at(0))
        try s.recordStatusLine(input(five: 99, fiveReset: past, week: 20, api: 50), now: at(1))
        try s.recordStatusLine(input(five: nil, week: 25, api: 100), now: at(30))
        let snap = try #require(s.latestSnapshot())
        #expect(snap.observedAt == at(30) && snap.window(.weekly)?.usedPercent == 25)
        #expect(snap.window(.fiveHour)?.resetsAt == past)   // 已過重設時間：保留並顯示待新資料
        try s.recordStatusLine(input(five: 50, week: 26, api: 150), now: at(40))
        try s.recordStatusLine(input(five: nil, week: 27, api: 200), now: at(50))
        #expect(s.latestSnapshot()?.window(.fiveHour) == nil)   // 未到期但缺少：不沿用舊值
    }

    private func transcriptInfo(timestamp: String?, reset: Double) throws -> ClaudeTranscriptInfo {
        let projects = TestSupport.tempDir()
        let dir = projects.appendingPathComponent("-tmp-p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = timestamp.map { #","timestamp":"\#($0)""# } ?? ""
        let line = #"{"type":"assistant","uuid":"m","sessionId":"\#(session)","cwd":"/tmp/p"\#(ts),"error":"rate_limit","isApiErrorMessage":true,"version":"2.1.322","entrypoint":"cli","apiErrorParams":{"rate_limit_info":{"resetsAt":\#(reset),"rateLimitType":"five_hour"}},"message":{"model":"<synthetic>"}}"#
        try Data(line.utf8).write(to: dir.appendingPathComponent("\(session).jsonl"))
        return try #require(ClaudeTranscriptStore(projectsDir: projects).inspect(sessionID: session))
    }

    @Test func untrustedLimitTimesAreNotUsedAsCountdowns() throws {
        let now = Date()
        let noTime = try transcriptInfo(timestamp: nil, reset: now.addingTimeInterval(3600).timeIntervalSince1970)
        #expect(noTime.lastLimit?.timeKnown == false)
        #expect(ClaudeNativeContinue.observations([noTime], setting: .unset, now: now).first?.phase == .blockedTimeUnknown)
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600))
        let fromFuture = try transcriptInfo(timestamp: future, reset: now.addingTimeInterval(4 * 3600).timeIntervalSince1970)
        #expect(ClaudeNativeContinue.observations([fromFuture], setting: .unset, now: now).first?.phase == .blockedTimeUnknown)
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let absurd = try transcriptInfo(timestamp: past, reset: now.addingTimeInterval(60 * 86400).timeIntervalSince1970)
        let observation = try #require(ClaudeNativeContinue.observations([absurd], setting: .unset, now: now).first)
        #expect(observation.resetsAt == nil && observation.phase == .blockedUnknownReset)
    }
}
