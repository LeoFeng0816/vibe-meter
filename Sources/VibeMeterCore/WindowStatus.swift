import Foundation

/// 某個額度週期在「現在」這個時間點應該怎麼呈現。
///
/// 核心原則：百分比只代表「觀察當下」的值。若重設時間已過，就不能再把舊百分比當成現況，
/// 也不能自行假設已歸零——要等來源回報新資料才算確認。
public enum WindowStatus: Equatable, Sendable {
    /// 仍在週期內；`stale` 表示資料觀察時間過久。
    case current(usedPercent: Double, resetsAt: Date?, stale: Bool)
    /// 重設時間已過，但尚未收到重設後的新資料。
    case resetPassedAwaitingData(lastUsedPercent: Double, resetAt: Date)

    public static func evaluate(_ window: UsageWindow, in snapshot: UsageSnapshot, now: Date) -> WindowStatus {
        if let reset = window.resetsAt, now >= reset {
            return .resetPassedAwaitingData(lastUsedPercent: window.usedPercent, resetAt: reset)
        }
        return .current(usedPercent: window.usedPercent, resetsAt: window.resetsAt, stale: snapshot.isStale(now: now))
    }

    /// 可安全用於提醒／選單列摘要的已使用百分比（過期或已過重設時間則回傳 nil）。
    public var trustworthyUsedPercent: Double? {
        if case .current(let used, _, let stale) = self, !stale { return used }
        return nil
    }
}

public enum UsageSummary {
    /// 所有服務中「最緊」的剩餘百分比，只採用新鮮、週期內的資料。沒有就回傳 nil（選單列不顯示數字）。
    public static func tightestRemainingPercent(_ snapshots: [UsageSnapshot], now: Date) -> Double? {
        var best: Double?
        for snapshot in snapshots {
            for window in snapshot.windows {
                guard let used = WindowStatus.evaluate(window, in: snapshot, now: now).trustworthyUsedPercent else { continue }
                let remaining = max(0, 100 - used)
                best = min(best ?? remaining, remaining)
            }
        }
        return best
    }
}
