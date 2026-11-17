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
        let codexWindows = [
            UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(47 * 60)),
            UsageWindow(kind: .weekly, usedPercent: 84, resetsAt: now.addingTimeInterval(2 * 86400 + 5 * 3600)),
        ]
        // 與實測帳戶相同的形狀：只有一般 `codex` 額度桶，normalModelSlug 為 null（虛構數值）。
        let codex = UsageSnapshot(provider: .codex, windows: codexWindows, observedAt: now.addingTimeInterval(-20),
                                  source: .codexAppServer, planName: "plus", accountID: "demo-account", usageAllowed: false,
                                  buckets: [LimitBucket(limitID: "codex", modelSlug: nil, windows: codexWindows, limitReachedType: nil)])
        model.reports = [
            ProviderReport(provider: .claudeCode, state: .available(claude)),
            ProviderReport(provider: .codex, state: .available(codex), note: "後端回報目前不可使用一般用量"),
            UsageCollector.cursorReport,
            UsageCollector.antigravityReport,
        ]
        let ids = ["0f1e2d3c-4b5a-4968-8776-655443322110", "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
                   "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e", "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f"]
        var book = ResumePlanBook()
        if let waiting = try? ResumePlan(provider: .codex, sessionID: ids[0], sessionTitle: "範例：結帳流程重構", cwd: "/demo/shop",
                                         blockedWindow: .fiveHour, expectedResetAt: now.addingTimeInterval(47 * 60),
                                         origin: .autoDetected, createdAt: now.addingTimeInterval(-25 * 60),
                                         codex: {
                                             var c = CodexResumeContext(accountID: nil, anchorTurnID: "demo-turn", verifiedLimitFailure: true,
                                                                        modelAtBlock: "demo-model",
                                                                        evidenceGap: L10n.token("官方額度資料無法唯一對應這個模型的額度桶"))
                                             c.accountHashAtDetection = AccountHash.of("demo-account")
                                             return c
                                         }()) {
            try? book.add(waiting)
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
        // Claude Code：只呈現官方原生自動繼續的可觀察事實（虛構）。
        var blocked = ClaudeTranscriptInfo(id: ids[1], cwd: "/demo/api", transcriptPath: "/demo", lastActivity: now.addingTimeInterval(-11 * 60),
                                           lastModel: "claude-opus-5-5")
        let hit = ClaudeTranscriptInfo.LimitHit(at: now.addingTimeInterval(-11 * 60), resetsAt: now.addingTimeInterval(38 * 60),
                                                window: .fiveHour, limitType: "five_hour", overageStatus: "rejected",
                                                messageUUID: "demo-msg-1", version: "2.1.322", entrypoint: "cli")
        blocked.limitHit = hit
        blocked.lastLimit = hit
        model.claudeSessions = [blocked]
        model.codexLiveStatus = .ok(at: now.addingTimeInterval(-20))
        model.claudeStatus = .installed
        return model
    }
}
