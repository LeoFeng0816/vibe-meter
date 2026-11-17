import Foundation

public struct UsageAlert: Hashable, Sendable {
    public var provider: ProviderID
    public var window: WindowKind
    public var threshold: Double
    public var usedPercent: Double
    public var resetsAt: Date?

    /// 同一週期（以重設時間區分）同一門檻只提醒一次。
    public var dedupeKey: String {
        let reset = resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
        return "\(provider.rawValue)|\(window.key)|\(reset)|\(Int(threshold))"
    }

    public var title: String {
        usedPercent >= 100 ? "\(provider.displayName) \(window.label)額度已用盡" : "\(provider.displayName) \(window.label)額度剩 \(Int(max(0, 100 - usedPercent).rounded()))%"
    }
}

public struct AlertPolicy: Sendable {
    /// 已使用百分比門檻（遞增）。
    public var thresholds: [Double]

    public init(thresholds: [Double] = [80, 95]) {
        self.thresholds = thresholds.sorted()
    }

    /// 只用新鮮、週期內的資料；每個週期只回報「目前跨過的最高門檻」，且尚未提醒過的。
    public func alerts(for snapshots: [UsageSnapshot], now: Date, alreadyFired: Set<String>) -> [UsageAlert] {
        var result: [UsageAlert] = []
        for snapshot in snapshots {
            for window in snapshot.windows {
                guard let used = WindowStatus.evaluate(window, in: snapshot, now: now).trustworthyUsedPercent,
                      let threshold = thresholds.last(where: { used >= $0 }) else { continue }
                let alert = UsageAlert(provider: snapshot.provider, window: window.kind, threshold: threshold,
                                       usedPercent: used, resetsAt: window.resetsAt)
                // 已經提醒過更高門檻時，不要再補發較低門檻。
                let higherOrEqualFired = thresholds.filter { $0 >= threshold }.contains {
                    alreadyFired.contains(UsageAlert(provider: alert.provider, window: alert.window, threshold: $0,
                                                     usedPercent: used, resetsAt: alert.resetsAt).dedupeKey)
                }
                if !higherOrEqualFired { result.append(alert) }
            }
        }
        return result
    }
}
