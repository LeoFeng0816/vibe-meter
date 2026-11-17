import Foundation

/// 解析 Codex 兩種官方產生的額度資料格式。
public enum CodexRateLimitParser {
    // MARK: app-server `account/rateLimits/read` 回應（camelCase）

    struct AppServerWindow: Decodable {
        var usedPercent: Double
        var windowDurationMins: Int?
        var resetsAt: Int64?
    }

    struct AppServerSnapshot: Decodable {
        var limitId: String?
        var primary: AppServerWindow?
        var secondary: AppServerWindow?
        var planType: String?
        var rateLimitReachedType: String?
    }

    struct AppServerResult: Decodable {
        var rateLimits: AppServerSnapshot
        /// 官方註解：後端對一般內含用量的許可；null 表示不可用，不可由百分比或重設時間推斷恢復。
        var ordinaryUsageAllowed: Bool?
        var accountId: String?
    }

    /// `result` 物件（JSON-RPC 回應的 result 欄位）→ 快照。
    public static func parseAppServerResult(_ data: Data, observedAt: Date) throws -> UsageSnapshot {
        let result = try JSONDecoder().decode(AppServerResult.self, from: data)
        let rl = result.rateLimits
        let windows = [rl.primary, rl.secondary].compactMap { w -> UsageWindow? in
            guard let w, let kind = WindowKind.fromMinutes(w.windowDurationMins) else { return nil }
            return UsageWindow(kind: kind, usedPercent: w.usedPercent, resetsAt: w.resetsAt.map(Self.date))
        }
        return UsageSnapshot(provider: .codex, windows: windows, observedAt: observedAt,
                             source: .codexAppServer, planName: rl.planType,
                             limitReachedType: rl.rateLimitReachedType, accountID: result.accountId,
                             usageAllowed: result.ordinaryUsageAllowed)
    }

    // MARK: rollout JSONL `event_msg` / `token_count`（snake_case）

    struct RolloutWindow: Decodable {
        var used_percent: Double
        var window_minutes: Int?
        var resets_at: Int64?
    }

    struct RolloutRateLimits: Decodable {
        var primary: RolloutWindow?
        var secondary: RolloutWindow?
        var plan_type: String?
        var rate_limit_reached_type: String?
    }

    struct RolloutPayload: Decodable {
        var type: String
        var rate_limits: RolloutRateLimits?
    }

    struct RolloutLine: Decodable {
        var timestamp: String?
        var type: String
        var payload: RolloutPayload?
    }

    /// 解析單行 rollout 紀錄；不是含 rate_limits 的 token_count 就回傳 nil。
    public static func parseRolloutLine(_ line: Substring) -> UsageSnapshot? {
        guard line.contains("\"token_count\""), line.contains("\"rate_limits\"") else { return nil }
        guard let decoded = try? JSONDecoder().decode(RolloutLine.self, from: Data(line.utf8)),
              decoded.type == "event_msg",
              let payload = decoded.payload, payload.type == "token_count",
              let rl = payload.rate_limits,
              let ts = decoded.timestamp, let observedAt = ISO8601.parse(ts)
        else { return nil }
        let windows = [rl.primary, rl.secondary].compactMap { w -> UsageWindow? in
            guard let w, let kind = WindowKind.fromMinutes(w.window_minutes) else { return nil }
            return UsageWindow(kind: kind, usedPercent: w.used_percent, resetsAt: w.resets_at.map(Self.date))
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(provider: .codex, windows: windows, observedAt: observedAt,
                             source: .codexRolloutLog, planName: rl.plan_type,
                             limitReachedType: rl.rate_limit_reached_type)
    }

    static func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
}

enum ISO8601 {
    /// 支援 0–9 位小數秒（Codex 的 session_index 使用 7 位）。
    static func parse(_ raw: String) -> Date? {
        var string = raw
        if let dot = string.firstIndex(of: "."),
           let end = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = string[string.index(after: dot)..<end]
            let fixed = String((digits + "000").prefix(3))
            string.replaceSubrange(string.index(after: dot)..<end, with: fixed)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
