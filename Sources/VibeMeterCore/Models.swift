import Foundation

/// 支援（或計畫支援）的 coding agent。
public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case antigravity

    public var id: String { rawValue }

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
        case .fiveHour: return "5 小時"
        case .weekly: return "每週"
        case .spend(let period):
            switch period {
            case "daily": return "每日花費上限"
            case "weekly": return "每週花費上限"
            case "monthly": return "每月花費上限"
            default: return "花費上限"
            }
        case .named(let n):
            switch n {
            case "seven_day_opus": return "每週（Opus）"
            case "seven_day_sonnet": return "每週（Sonnet）"
            case "unknown": return "未知週期"
            default: return n
            }
        case .minutes(let m):
            if m % 1440 == 0 { return "\(m / 1440) 天" }
            if m % 60 == 0 { return "\(m / 60) 小時" }
            return "\(m) 分鐘"
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
    /// `claude -p --output-format stream-json` 的官方 `rate_limit_event`（Vibe Meter 送出的極小探測請求）。
    case claudeProbe

    public var label: String {
        switch self {
        case .codexAppServer: "Codex app-server 即時查詢"
        case .codexRolloutLog: "Codex 本機工作紀錄"
        case .claudeStatusLine: "Claude Code 狀態列"
        case .claudeProbe: "Claude Code 探測請求"
        }
    }

    /// 超過這個時間就標示為過期資料。
    public var staleAfter: TimeInterval {
        switch self {
        case .codexAppServer: 15 * 60
        case .codexRolloutLog: 30 * 60
        case .claudeStatusLine: 30 * 60
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

    public init(provider: ProviderID, windows: [UsageWindow], observedAt: Date, source: DataSource,
                planName: String? = nil, limitReachedType: String? = nil, accountID: String? = nil, usageAllowed: Bool? = nil) {
        self.provider = provider
        self.windows = windows
        self.observedAt = observedAt
        self.source = source
        self.planName = planName
        self.limitReachedType = limitReachedType
        self.accountID = accountID
        self.usageAllowed = usageAllowed
    }

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(observedAt) > source.staleAfter
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
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
