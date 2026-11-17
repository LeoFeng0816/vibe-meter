import Foundation

/// 時間與百分比格式，依目前介面語言（`L10n.current`）輸出。名稱沿用 v0.1.0。
public enum ZhFormat {
    /// 「2 小時 5 分」「3 天 4 小時」「不到 1 分鐘」／「2h 5m」「3d 4h」「<1 min」
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? tr("{0} 天 {1} 小時", "\(days)", "\(hours)") : tr("{0} 天", "\(days)") }
        if hours > 0 { return minutes > 0 ? tr("{0} 小時 {1} 分", "\(hours)", "\(minutes)") : tr("{0} 小時", "\(hours)") }
        if minutes > 0 { return tr("{0} 分鐘", "\(minutes)") }
        return tr("不到 1 分鐘")
    }

    public static func resetIn(_ date: Date, now: Date) -> String {
        tr("{0}後重設", duration(date.timeIntervalSince(now)))
    }

    public static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return tr("剛剛") }
        return tr("{0}前", duration(s))
    }

    /// 例：「11/9 週一 18:30」／「Mon 11/9 18:30」
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = L10n.current.locale
        f.timeZone = timeZone
        f.dateFormat = L10n.current == .en ? "EEE M/d HH:mm" : "M/d EEE HH:mm"
        return f.string(from: date)
    }

    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}
