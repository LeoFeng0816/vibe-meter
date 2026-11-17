import Foundation

/// 狀態列要顯示的週期。
public enum MenuBarWindow: String, Codable, CaseIterable, Sendable {
    case fiveHour = "5h"
    case weekly = "7d"

    public var kind: WindowKind { self == .fiveHour ? .fiveHour : .weekly }
    public var label: String { self == .fiveHour ? tr("5 小時") : tr("每週") }
}

/// 使用者選擇的狀態列內容。保存於 UserDefaults `menuBarSelection`。
/// - `tightest`：所有啟用 agent、新鮮資料中最低的剩餘百分比（v0.1.0 的行為，也是預設值）。
/// - `window`：固定顯示某個 agent 的某個週期；資料不可用時顯示不可用狀態，**不會改顯示其他 agent 或週期**。
public enum MenuBarSelection: Hashable, Sendable {
    case tightest
    case window(ProviderID, MenuBarWindow)

    public static let defaultsKey = "menuBarSelection"

    public var storageValue: String {
        switch self {
        case .tightest: "tightest"
        case .window(let p, let w): "\(p.rawValue)|\(w.rawValue)"
        }
    }

    public init?(storageValue: String) {
        if storageValue == "tightest" { self = .tightest; return }
        let parts = storageValue.split(separator: "|").map(String.init)
        guard parts.count == 2, let p = ProviderID(rawValue: parts[0]), let w = MenuBarWindow(rawValue: parts[1]) else { return nil }
        self = .window(p, w)
    }

    public static func load(from defaults: UserDefaults) -> MenuBarSelection {
        defaults.string(forKey: defaultsKey).flatMap(MenuBarSelection.init(storageValue:)) ?? .tightest
    }

    public func save(to defaults: UserDefaults) { defaults.set(storageValue, forKey: Self.defaultsKey) }

    /// Codex、Claude Code 支援兩個週期；目前 Antigravity CLI 文件只明確標示每週 bucket。
    public static func choices(enabled: Set<ProviderID>) -> [MenuBarSelection] {
        var options = [.tightest] + [ProviderID.claudeCode, .codex].filter { enabled.contains($0) }
            .flatMap { p in MenuBarWindow.allCases.map { MenuBarSelection.window(p, $0) } }
        if enabled.contains(.antigravity) { options.append(.window(.antigravity, .weekly)) }
        return options
    }

    public var label: String {
        switch self {
        case .tightest: tr("自動：所有 agent 中最低剩餘")
        case .window(let p, let w): "\(p.displayName) · \(w.label)"
        }
    }
}

public enum MenuBarUnavailable: Equatable, Sendable {
    case agentDisabled
    case unsupported
    case notConnected
    case loading
    case error
    case windowMissing
    case stale
    case resetPassed
    /// `tightest`：沒有任何新鮮、可靠的週期。
    case noReliableData

    public var explanation: String {
        switch self {
        case .agentDisabled: tr("選擇的 agent 已停用")
        case .unsupported: tr("這個 agent 沒有可靠的官方用量來源")
        case .notConnected: tr("尚未取得這個 agent 的用量")
        case .loading: tr("讀取中…")
        case .error: tr("讀取用量失敗")
        case .windowMissing: tr("來源沒有回報這個週期")
        case .stale: tr("資料已過期，等待新資料")
        case .resetPassed: tr("已過重設時間，等待新資料確認")
        case .noReliableData: tr("沒有新鮮、可靠的用量資料")
        }
    }
}

public enum MenuBarDisplay: Equatable, Sendable {
    case remaining(Double, provider: ProviderID?, window: WindowKind?)
    case unavailable(MenuBarUnavailable)

    /// 依選擇計算狀態列內容。永遠不會把不可用狀態顯示成 0%，也不會改顯示其他 agent／週期。
    public static func resolve(_ selection: MenuBarSelection, reports: [ProviderReport], enabled: Set<ProviderID>,
                               now: Date) -> MenuBarDisplay {
        switch selection {
        case .tightest:
            let snapshots = reports.filter { enabled.contains($0.provider) }.compactMap(\.state.snapshot)
            var best: (Double, ProviderID, WindowKind)?
            for s in snapshots {
                for w in s.windows {
                    guard let used = WindowStatus.evaluate(w, in: s, now: now).trustworthyUsedPercent else { continue }
                    let remaining = max(0, 100 - used)
                    if best == nil || remaining < best!.0 { best = (remaining, s.provider, w.kind) }
                }
            }
            guard let best else { return .unavailable(.noReliableData) }
            return .remaining(best.0, provider: best.1, window: best.2)

        case .window(let provider, let window):
            guard enabled.contains(provider) else { return .unavailable(.agentDisabled) }
            guard let report = reports.first(where: { $0.provider == provider }) else { return .unavailable(.loading) }
            switch report.state {
            case .loading: return .unavailable(.loading)
            case .unsupported: return .unavailable(.unsupported)
            case .notConnected: return .unavailable(.notConnected)
            case .error: return .unavailable(.error)
            case .available(let snapshot):
                guard let w = snapshot.window(window.kind) else { return .unavailable(.windowMissing) }
                switch WindowStatus.evaluate(w, in: snapshot, now: now) {
                case .resetPassedAwaitingData: return .unavailable(.resetPassed)
                case .current(_, _, true): return .unavailable(.stale)
                case .current(let used, _, false): return .remaining(max(0, 100 - used), provider: provider, window: window.kind)
                }
            }
        }
    }

    /// 狀態列文字：可用時為百分比，不可用時為「—」。
    public var menuBarText: String {
        switch self {
        case .remaining(let r, _, _): ZhFormat.percent(r)
        case .unavailable: "—"
        }
    }
}
