import Foundation

public enum ZhFormat {
    /// 「2 小時 5 分」「3 天 4 小時」「不到 1 分鐘」
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小時" : "\(days) 天" }
        if hours > 0 { return minutes > 0 ? "\(hours) 小時 \(minutes) 分" : "\(hours) 小時" }
        if minutes > 0 { return "\(minutes) 分鐘" }
        return "不到 1 分鐘"
    }

    public static func resetIn(_ date: Date, now: Date) -> String {
        "\(duration(date.timeIntervalSince(now)))後重設"
    }

    public static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "剛剛" }
        return "\(duration(s))前"
    }

    /// 例：「11/9 週一 18:30」
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.timeZone = timeZone
        f.dateFormat = "M/d EEE HH:mm"
        return f.string(from: date)
    }

    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}
