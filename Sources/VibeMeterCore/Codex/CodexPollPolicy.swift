import Foundation

/// Codex 即時額度輪詢的節奏與錯誤說明。只用於官方唯讀 `account/rateLimits/read`。
public enum CodexPollPolicy {
    public static let interval: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 300

    /// 成功或首次：30 秒。連續失敗：60、120、240，最多 300 秒。
    public static func delay(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else { return interval }
        return min(interval * pow(2, Double(min(consecutiveFailures, 8))), maxBackoff)
    }

    /// 查詢失敗的說明。失敗不代表額度用完；數值維持上次觀察並依時間標示過期。
    public static func describe(_ error: Error) -> String {
        switch error {
        case CodexAppServerError.timeout: L10n.token("Codex app-server 回應逾時")
        case CodexAppServerError.processFailed: L10n.token("無法啟動 Codex app-server")
        case CodexAppServerError.binaryNotFound: L10n.token("找不到 Codex CLI")
        case CodexAppServerError.rpcError(let message): L10n.token("Codex 回報錯誤：{0}", [String(message.prefix(120))])
        case CodexAppServerError.malformedResponse: L10n.token("Codex 回應格式無法辨識")
        case let url as URLError where url.code == .notConnectedToInternet: L10n.token("目前離線")
        default: L10n.token("查詢失敗")
        }
    }
}
