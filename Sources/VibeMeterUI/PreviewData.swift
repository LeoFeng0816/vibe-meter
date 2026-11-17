import Foundation
import VibeMeterCore

extension AppModel {
    /// 介面預覽用的範例資料（虛構工作階段與用量，不含任何使用者真實資料）。
    public static func sample(now: Date, demo: Bool = false) -> AppModel {
        let model = AppModel(preview: (), demo: demo)
        model.now = now
        model.lastRefresh = now.addingTimeInterval(-40)
        let claude = UsageSnapshot(provider: .claudeCode, windows: [
            UsageWindow(kind: .fiveHour, usedPercent: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
            UsageWindow(kind: .weekly, usedPercent: 31, resetsAt: now.addingTimeInterval(4 * 86400 + 3 * 3600)),
        ], observedAt: now.addingTimeInterval(-180), source: .claudeStatusLine, planName: "max")
        let codex = UsageSnapshot(provider: .codex, windows: [
            UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(47 * 60)),
            UsageWindow(kind: .weekly, usedPercent: 84, resetsAt: now.addingTimeInterval(2 * 86400 + 5 * 3600)),
        ], observedAt: now.addingTimeInterval(-20), source: .codexAppServer, planName: "plus",
           accountID: "demo-account", usageAllowed: false)
        model.reports = [
            ProviderReport(provider: .claudeCode, state: .available(claude)),
            ProviderReport(provider: .codex, state: .available(codex), note: "後端回報目前不可使用一般用量"),
            UsageCollector.cursorReport,
            UsageCollector.antigravityReport,
        ]
        let ids = ["0f1e2d3c-4b5a-4968-8776-655443322110", "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                   "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e", "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f"]
        var book = ResumePlanBook()
        let account = ClaudeAccountIdentity(authMethod: "claude.ai", orgID: "demo-org", subscriptionType: "max", accountKey: "demo")
        if let waiting = try? ResumePlan(provider: .codex, sessionID: ids[0], sessionTitle: "範例：結帳流程重構", cwd: "/demo/shop",
                                         blockedWindow: .fiveHour, expectedResetAt: now.addingTimeInterval(47 * 60),
                                         origin: .autoDetected, createdAt: now.addingTimeInterval(-25 * 60),
                                         codex: CodexResumeContext(accountID: "demo-account", anchorTurnID: "demo-turn", verifiedLimitFailure: true)) {
            try? book.add(waiting)
        }
        if let pending = try? ResumePlan(provider: .claudeCode, sessionID: ids[3], sessionTitle: "範例：設計稿整理", cwd: "/demo/design",
                                         blockedWindow: .named("seven_day_opus"), expectedResetAt: now.addingTimeInterval(26 * 3600),
                                         origin: .autoDetected, createdAt: now.addingTimeInterval(-40 * 60),
                                         claude: ClaudeResumeContext(model: "claude-opus-5-5", limitType: "seven_day_opus", overageStatus: nil,
                                                                     account: account, anchorMessageUUID: "demo-msg-2")) {
            try? book.add(pending)  // overage 狀態不明 → 待確認
        }
        if var resumed = try? ResumePlan(provider: .claudeCode, sessionID: ids[1], sessionTitle: "範例：API 測試補齊", cwd: "/demo/api",
                                         blockedWindow: .fiveHour, expectedResetAt: now.addingTimeInterval(-15 * 60),
                                         origin: .autoDetected, createdAt: now.addingTimeInterval(-3 * 3600),
                                         claude: ClaudeResumeContext(model: "claude-opus-5-5", limitType: "five_hour", overageStatus: "rejected",
                                                                     account: account, anchorMessageUUID: "demo-msg-1")) {
            resumed.state = .resumed(at: now.addingTimeInterval(-12 * 60))
            resumed.delivery = .terminal
            resumed.note = "以原模型 claude-opus-5-5 探測：伺服器接受、被擋住的週期為 allowed"
            try? book.add(resumed)
        }
        model.planBook = book
        model.codexSessions = [
            CodexSessionInfo(id: ids[0], threadName: "範例：結帳流程重構", cwd: "/demo/shop", startedAt: nil,
                             lastActivity: now.addingTimeInterval(-26 * 60), rolloutPath: "/demo", lastLimitReachedType: "rate_limit_reached"),
            CodexSessionInfo(id: ids[2], threadName: "範例：文件整理", cwd: "/demo/docs", startedAt: nil,
                             lastActivity: now.addingTimeInterval(-12 * 60), rolloutPath: "/demo"),
        ]
        model.codexTurns = [ids[0]: CodexTurnSummary(id: "demo-turn", status: "failed", errorInfo: "usageLimitExceeded")]
        model.codexSuggestions = [ids[2]]
        model.claudeSessions = [
            ClaudeTranscriptInfo(id: ids[1], cwd: "/demo/api", transcriptPath: "/demo", lastActivity: now.addingTimeInterval(-11 * 60),
                                 lastModel: "claude-opus-5-5"),
        ]
        model.claudeStatus = .installed
        return model
    }
}
