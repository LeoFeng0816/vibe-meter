import Foundation

/// 支援（或計畫支援）的 coding agent。
public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case antigravity

    public var id: String { rawValue }

    /// 狀態列等空間有限處使用的短名稱。
    public var shortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "AG"
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }
}

/// 額度週期。只用來源實際回報的週期，不自行推算。
public enum WindowKind: Codable, Hashable, Sendable {
    case fiveHour
    case weekly
    case spend(period: String?)
    /// 來源回報了非標準長度的週期（分鐘）。
    case minutes(Int)
    /// 來源以名稱回報、沒有固定長度的週期（例如 Claude 的 seven_day_opus 模型專屬週期）。
    case named(String)

    public static func fromMinutes(_ minutes: Int?) -> WindowKind? {
        guard let minutes, minutes > 0 else { return nil }
        switch minutes {
        case 300: return .fiveHour
        case 10080: return .weekly
        default: return .minutes(minutes)
        }
    }

    public var label: String {
        switch self {
        case .fiveHour: return tr("5 小時")
        case .weekly: return tr("每週")
        case .spend(let period):
            switch period {
            case "daily": return tr("每日花費上限")
            case "weekly": return tr("每週花費上限")
            case "monthly": return tr("每月花費上限")
            default: return tr("花費上限")
            }
        case .named(let n):
            switch n {
            case "seven_day_opus": return tr("每週（Opus）")
            case "seven_day_sonnet": return tr("每週（Sonnet）")
            case "unknown": return tr("未知週期")
            default: return n
            }
        case .minutes(let m):
            if m % 1440 == 0 { return tr("{0} 天", "\(m / 1440)") }
            if m % 60 == 0 { return tr("{0} 小時", "\(m / 60)") }
            return tr("{0} 分鐘", "\(m)")
        }
    }

    /// 穩定字串鍵（提醒去重、持久化用）。
    public var key: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "7d"
        case .spend(let p): "spend-\(p ?? "unknown")"
        case .minutes(let m): "\(m)m"
        case .named(let n): "n-\(n)"
        }
    }
}

public struct UsageWindow: Codable, Hashable, Sendable {
    public var kind: WindowKind
    /// 已使用百分比（0–100，超額時可能 > 100）。這是來源原值，不做推估。
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(kind: WindowKind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

/// 資料是從哪裡來的；決定可信度與「多久算過期」。
public enum DataSource: String, Codable, Sendable {
    /// `codex app-server` 的 `account/rateLimits/read`（向伺服器即時查詢）。
    case codexAppServer
    /// `~/.codex/sessions/**/rollout-*.jsonl` 中最後一筆 `token_count.rate_limits`（Codex 上次回應時的值）。
    case codexRolloutLog
    /// Claude Code statusLine 輸入 JSON 的 `rate_limits`（Claude Code 上次回應時的值）。
    case claudeStatusLine
    case antigravityStatusLine
    /// `claude -p --output-format stream-json` 的官方 `rate_limit_event`（Vibe Meter 送出的極小探測請求）。
    case claudeProbe

    public var label: String {
        switch self {
        case .codexAppServer: tr("Codex app-server 即時查詢")
        case .codexRolloutLog: tr("Codex 本機工作紀錄")
        case .claudeStatusLine: tr("Claude Code 狀態列")
        case .antigravityStatusLine: tr("Antigravity CLI 狀態列")
        case .claudeProbe: tr("Claude Code 探測請求")
        }
    }

    /// 超過這個時間就標示為過期資料。
    public var staleAfter: TimeInterval {
        switch self {
        case .codexAppServer: 15 * 60
        case .codexRolloutLog: 30 * 60
        case .claudeStatusLine, .antigravityStatusLine: ClaudeRefreshPolicy.interval
        case .claudeProbe: 30 * 60
        }
    }
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public var provider: ProviderID
    public var windows: [UsageWindow]
    public var observedAt: Date
    public var source: DataSource
    public var planName: String?
    /// 來源明確回報「已達上限」時的類型字串（例如 Codex `rate_limit_reached`）。
    public var limitReachedType: String?
    /// 這筆資料所屬的帳戶（Codex app-server `accountId`）。nil 表示來源未提供。
    public var accountID: String?
    /// 後端對「一般內含用量」的明確許可（Codex `ordinaryUsageAllowed`）。nil 表示後端未提供，
    /// 依官方註解不可由百分比或重設時間推斷已恢復。
    public var usageAllowed: Bool?
    public var spendControlReached: Bool?
    /// Codex `rateLimitsByLimitId` 的各額度桶（含模型專屬額度）。舊資料為 nil。
    public var buckets: [LimitBucket]?
    /// bridge 第一次看到某個既有工作階段，無法判斷這份資料是否為重播的舊值。
    /// 這類資料一律視為過期：顯示但不參與狀態列摘要、提醒與續作判斷。
    public var responseTimeUnknown: Bool?
    /// 之後的即時查詢失敗：保留這份官方值供顯示，但不再作為目前剩餘、提醒、摘要或續作依據。
    public var supersededByFailedQuery: Bool?

    public init(provider: ProviderID, windows: [UsageWindow], observedAt: Date, source: DataSource,
                planName: String? = nil, limitReachedType: String? = nil, accountID: String? = nil, usageAllowed: Bool? = nil,
                buckets: [LimitBucket]? = nil, responseTimeUnknown: Bool? = nil, spendControlReached: Bool? = nil) {
        self.buckets = buckets
        self.responseTimeUnknown = responseTimeUnknown
        self.provider = provider
        self.windows = windows
        self.observedAt = observedAt
        self.source = source
        self.planName = planName
        self.limitReachedType = limitReachedType
        self.accountID = accountID
        self.usageAllowed = usageAllowed
        self.spendControlReached = spendControlReached
    }

    public func isStale(now: Date) -> Bool {
        responseTimeUnknown == true || supersededByFailedQuery == true || observedAt > now || now.timeIntervalSince(observedAt) >= source.staleAfter
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }
}

/// Codex 的 metered limit ID 與官方模型別名。缺少別名本身不代表共用。
public struct LimitBucket: Codable, Hashable, Sendable {
    public var limitID: String
    public var modelSlug: String?
    public var windows: [UsageWindow]
    public var limitReachedType: String?
    public var spendControlReached: Bool?

    public init(limitID: String, modelSlug: String?, windows: [UsageWindow], limitReachedType: String?,
                spendControlReached: Bool? = nil) {
        self.limitID = limitID
        self.modelSlug = modelSlug
        self.windows = windows
        self.limitReachedType = limitReachedType
        self.spendControlReached = spendControlReached
    }

    public var quotaKey: String {
        if let modelSlug, !modelSlug.isEmpty { return "model:\(limitID.count):\(limitID):\(modelSlug)" }
        return "general:\(limitID)"
    }
}

extension UsageSnapshot {
    /// 官方一般 Codex 額度的 `limit_id`（實測 codex-cli 0.167 只回報這一個桶，`normalModelSlug` 為 null）。
    public static let generalCodexLimitID = "codex"

    /// A model-less default bucket is useful for display, but cannot identify a failed turn's effective bucket.
    public func quotaBucket(forModel model: String) -> LimitBucket? {
        let matching = (buckets ?? []).filter { $0.modelSlug == model }
        return matching.count == 1 ? matching.first : nil
    }
}

/// 每個服務在 UI 上的狀態。不可用時一定附上原因，不顯示假的百分比。
public enum ProviderState: Sendable, Equatable {
    case loading
    case available(UsageSnapshot)
    /// 已知如何讀取，但使用者尚未啟用／尚無資料。
    case notConnected(reason: String)
    /// 目前沒有可靠的資料來源。
    case unsupported(reason: String)
    case error(message: String)

    public var snapshot: UsageSnapshot? {
        if case .available(let s) = self { return s }
        return nil
    }
}
