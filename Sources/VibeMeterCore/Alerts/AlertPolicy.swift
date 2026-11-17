import Foundation

/// 一則低額度提醒。
public struct UsageAlert: Hashable, Sendable {
    public var provider: ProviderID
    public var window: WindowKind
    /// 使用者設定的「剩餘百分比」門檻。
    public var threshold: Double
    public var usedPercent: Double
    public var resetsAt: Date?

    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// 同一週期（以重設時間區分）、同一門檻只提醒一次。
    public var dedupeKey: String { AlertPolicy.key(provider: provider, window: window, resetsAt: resetsAt, threshold: threshold) }

    public var title: String {
        usedPercent >= 100
            ? tr("{0} {1}額度已用盡", provider.displayName, window.label)
            : tr("{0} {1}額度剩 {2}", provider.displayName, window.label, ZhFormat.percent(remainingPercent))
    }
}

/// 低額度提醒設定。保存於 UserDefaults。
public struct AlertSettings: Equatable, Sendable {
    public static let enabledKey = "alertsEnabled"
    public static let thresholdKey = "alertRemainingThreshold"
    public static let allowedRange: ClosedRange<Double> = 1...99

    public var enabled: Bool
    /// 剩餘百分比低於此值時提醒（預設 20%）。
    public var remainingThreshold: Double

    public init(enabled: Bool = true, remainingThreshold: Double = 20) {
        self.enabled = enabled
        self.remainingThreshold = min(max(remainingThreshold, Self.allowedRange.lowerBound), Self.allowedRange.upperBound)
    }

    public static func load(from d: UserDefaults) -> AlertSettings {
        AlertSettings(enabled: d.object(forKey: enabledKey) as? Bool ?? true,
                      remainingThreshold: d.object(forKey: thresholdKey) as? Double ?? 20)
    }

    public func save(to d: UserDefaults) {
        d.set(enabled, forKey: Self.enabledKey)
        d.set(remainingThreshold, forKey: Self.thresholdKey)
    }
}

/// 低額度提醒規則：
/// - 只看「已啟用」agent 的新鮮、週期內資料（過期、已過重設時間、未知都不提醒）。
/// - 剩餘百分比 **低於**（嚴格小於）門檻才提醒；5 小時與每週各自獨立。
/// - 同一週期同一門檻只提醒一次；重設後（新的 `resetsAt`）是新週期，會再提醒。
/// - 來源沒有提供重設時間時，剩餘量回升到「門檻 + 2」以上才重新允許提醒，避免數值在門檻附近抖動時重複通知。
public struct AlertPolicy: Sendable {
    public static let rearmMargin: Double = 2

    public var settings: AlertSettings

    public init(settings: AlertSettings = AlertSettings()) { self.settings = settings }

    static func key(provider: ProviderID, window: WindowKind, resetsAt: Date?, threshold: Double) -> String {
        let cycle = resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
        return "\(provider.rawValue)|\(window.key)|\(cycle)|\(Int(threshold.rounded()))"
    }

    /// 回傳應發送（尚未成功送達過）的提醒。**不會**把它們標為已送出——呼叫端在通知確實送達後才把 `dedupeKey` 加入 `fired`，
    /// 因此通知被拒絕或送出失敗時，之後（例如使用者開啟通知權限後）還會再嘗試。沒有重設時間的週期會在回升後重新允許提醒。
    public func evaluate(_ snapshots: [UsageSnapshot], enabled: Set<ProviderID>, now: Date, fired: inout Set<String>) -> [UsageAlert] {
        guard settings.enabled else { return [] }
        var result: [UsageAlert] = []
        for snapshot in snapshots where enabled.contains(snapshot.provider) {
            for window in snapshot.windows where window.kind == .fiveHour || window.kind == .weekly {
                guard let used = WindowStatus.evaluate(window, in: snapshot, now: now).trustworthyUsedPercent else { continue }
                let remaining = max(0, 100 - used)
                let alert = UsageAlert(provider: snapshot.provider, window: window.kind, threshold: settings.remainingThreshold,
                                       usedPercent: used, resetsAt: window.resetsAt)
                if remaining < settings.remainingThreshold {
                    if !fired.contains(alert.dedupeKey) { result.append(alert) }
                } else if window.resetsAt == nil, remaining >= settings.remainingThreshold + Self.rearmMargin {
                    fired.remove(alert.dedupeKey)
                }
            }
        }
        return result
    }
}
