import Foundation

/// 重讀官方 statusLine 回報。重讀本機檔案不會改變觀察時間，也不會向 Claude Code 送出請求。
///
/// Claude Code 只在自己收到 API 回應時更新 `rate_limits`；Vibe Meter 不代送查詢，因此沒有新回應就沒有新的數值。
/// `observedAt` 是 bridge 判定「這個工作階段帶來未見過的資料」並寫入的時間，不是官方伺服器採樣額度的時間。
public enum ClaudeRefreshPolicy {
    public static let interval: TimeInterval = 15 * 60
    /// 時鐘誤差容許值；超過就視為未來時間而拒絕。
    public static let futureSkew: TimeInterval = 5

    public enum Status: Equatable, Sendable {
        case awaitingReport
        case current(observedAt: Date)
        case awaitingNewReport(lastObservedAt: Date)
        /// bridge 第一次看到既有工作階段，無法排除是重播的舊值。
        case responseTimeUnknown(seenAt: Date)
    }

    public static func status(latest: UsageSnapshot?, now: Date) -> Status {
        // 與 UsageSnapshot.isStale 一致：未來時間在到達前不視為目前資料。
        guard let latest, latest.source == .claudeStatusLine, latest.observedAt <= now else { return .awaitingReport }
        if latest.responseTimeUnknown == true { return .responseTimeUnknown(seenAt: latest.observedAt) }
        return now < latest.observedAt.addingTimeInterval(interval)
            ? .current(observedAt: latest.observedAt)
            : .awaitingNewReport(lastObservedAt: latest.observedAt)
    }

    /// 提早發現新檔案，也在既有資料的 15 分鐘期限準時重讀一次。
    public static func nextCheck(latest: UsageSnapshot?, now: Date, pollingInterval: TimeInterval = 60) -> Date {
        let poll = now.addingTimeInterval(pollingInterval)
        if case .current(let observedAt) = status(latest: latest, now: now) {
            return min(poll, observedAt.addingTimeInterval(interval))
        }
        return poll
    }
}
