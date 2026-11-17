import Foundation
import IOKit.pwr_mgt

/// 保持電腦清醒的模式。
public enum KeepAwakeMode: Equatable, Sendable {
    case off
    /// 保持到指定時間。
    case until(Date)
    /// 只在能可靠確認 agent 正在執行任務時保持清醒；狀態不明時不保持。
    case whileAgentsWork
}

/// agent 是否正在執行任務。只接受官方可驗證的訊號（目前為 Codex app-server 的 turn 狀態 `inProgress`）。
public enum AgentActivity: Equatable, Sendable {
    case working(count: Int)
    case idle
    /// 查詢失敗或無法判斷。
    case unknown(String)

}

/// 依官方 `thread/turns/list` 的 turn 狀態判斷 Codex 是否有工作在執行。
///
/// - 曾經看到 `inProgress` 的 thread 會持續追蹤，直到官方回報該 turn 已結束——長時間沒有新輸出的任務不會被當成 idle。
/// - 新任務的探索範圍：最近 `discoveryWindow` 內有活動的主 thread（排除子代理）。每次最多查詢 `maxChecksPerPoll` 個；
///   範圍內的 thread 超過上限時，若沒有確認執行中的工作，結果是「不明」而不是 idle。
/// - 查詢失敗或不認得的 turn 狀態會標為不明並釋放 assertion，但保留追蹤 id 供下次再查。
/// - 只支援 Codex。Claude Code、Cursor、Antigravity 沒有可靠的官方執行中訊號，不納入。
public struct CodexActivityTracker: Sendable {
    public static let discoveryWindow: TimeInterval = 6 * 3600
    public static let maxChecksPerPoll = 20

    public enum Probe: Sendable { case turn(CodexTurnSummary?), failed }

    public private(set) var tracked: Set<String> = []
    private var nextDiscoveryOffset = 0

    public init() {}

    public mutating func candidates(sessions: [CodexSessionInfo], now: Date) -> (ids: [String], complete: Bool) {
        let recent = sessions.filter { !$0.isSubagent && now.timeIntervalSince($0.lastActivity) < Self.discoveryWindow }
            .sorted { $0.lastActivity > $1.lastActivity }.map(\.id)
        let fresh = recent.filter { !tracked.contains($0) }
        let all = tracked.sorted() + fresh
        guard all.count > Self.maxChecksPerPoll else { return (all, !all.isEmpty) }
        // 每輪優先複查已知執行中的工作，留一半查詢額度給其餘工作輪替。
        let preferred = Array(tracked.sorted().prefix(Self.maxChecksPerPoll / 2))
        let rest = all.filter { !preferred.contains($0) }
        let start = nextDiscoveryOffset % rest.count
        let count = Self.maxChecksPerPoll - preferred.count
        let ids = preferred + (0..<count).map { rest[(start + $0) % rest.count] }
        nextDiscoveryOffset = (start + count) % rest.count
        return (ids, false)
    }

    public mutating func update(_ results: [String: Probe], complete: Bool) -> AgentActivity {
        var working = 0
        var unknown = false
        for (id, probe) in results {
            switch probe {
            case .turn(let turn?) where turn.isInProgress:
                tracked.insert(id)
                working += 1
            case .turn(let turn?) where turn.isTerminal:
                tracked.remove(id)
            case .turn, .failed:
                unknown = true
            }
        }
        if working > 0 { return .working(count: working) }
        if unknown || results.isEmpty { return .unknown(L10n.token("無法取得 Codex 執行狀態")) }
        if !complete { return .unknown(L10n.token("最近的 Codex 工作階段太多，無法全部確認")) }
        return .idle
    }
}

public enum KeepAwakeReason: Equatable, Sendable {
    case off
    case timer(until: Date)
    case expired
    case agentsWorking(Int)
    case agentsIdle
    case activityUnknown(String)
}

/// 純規則：在某個時間點是否應保持清醒。
public enum KeepAwakePolicy {
    public static func evaluate(mode: KeepAwakeMode, activity: AgentActivity, now: Date) -> (awake: Bool, reason: KeepAwakeReason) {
        switch mode {
        case .off:
            return (false, .off)
        case .until(let date):
            return now < date ? (true, .timer(until: date)) : (false, .expired)
        case .whileAgentsWork:
            switch activity {
            case .working(let n): return (true, .agentsWorking(n))
            case .idle: return (false, .agentsIdle)
            case .unknown(let r): return (false, .activityUnknown(r))
            }
        }
    }
}

/// 電源 assertion 的抽象，方便以替身測試。
public protocol PowerAssertionProvider: AnyObject {
    /// 取得 assertion，回傳識別碼；失敗回傳 nil。
    func acquire(preventDisplaySleep: Bool, reason: String) -> UInt32?
    func release(_ id: UInt32)
}

/// 使用 macOS 公開的 IOKit 電源管理 API。只建立本程序的 assertion，不修改系統的全域休眠設定；
/// 程序結束時系統也會自動釋放。注意：assertion 不會阻止「闔上筆電」造成的睡眠。
public final class IOKitPowerAssertions: PowerAssertionProvider {
    public init() {}

    public func acquire(preventDisplaySleep: Bool, reason: String) -> UInt32? {
        // 防止顯示器睡眠時，系統也不會因閒置而睡眠；否則只防止系統閒置睡眠（螢幕仍可關閉）。
        let type = preventDisplaySleep ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    public func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

/// 管理目前持有的 assertion：需要時取得、不需要或設定改變時釋放；同時只持有一個。
public final class KeepAwakeController {
    private let provider: PowerAssertionProvider
    public private(set) var assertionID: UInt32?
    public private(set) var holdsDisplayAssertion = false
    public private(set) var lastError: String?

    public init(provider: PowerAssertionProvider) { self.provider = provider }

    public var isHolding: Bool { assertionID != nil }

    /// 依期望狀態調整 assertion。
    public func apply(awake: Bool, preventDisplaySleep: Bool, reason: String) {
        if !awake {
            releaseAll()
            lastError = nil
            return
        }
        if let id = assertionID, holdsDisplayAssertion == preventDisplaySleep { _ = id; return }
        releaseAll()
        if let id = provider.acquire(preventDisplaySleep: preventDisplaySleep, reason: reason) {
            assertionID = id
            holdsDisplayAssertion = preventDisplaySleep
            lastError = nil
        } else {
            lastError = L10n.token("系統拒絕建立防止睡眠的設定")
        }
    }

    public func releaseAll() {
        if let id = assertionID { provider.release(id) }
        assertionID = nil
        holdsDisplayAssertion = false
    }

    deinit { releaseAll() }
}

/// 保持清醒的設定（保存於 UserDefaults）。逾時模式的結束時間也保存，以便重新開啟 App 時正確判斷是否已過期。
public struct KeepAwakeSettings: Equatable, Sendable {
    public static let modeKey = "keepAwakeMode"
    public static let untilKey = "keepAwakeUntil"
    public static let displayKey = "keepAwakeDisplay"

    public var mode: KeepAwakeMode
    public var preventDisplaySleep: Bool

    public init(mode: KeepAwakeMode = .off, preventDisplaySleep: Bool = false) {
        self.mode = mode
        self.preventDisplaySleep = preventDisplaySleep
    }

    public static func load(from d: UserDefaults, now: Date) -> KeepAwakeSettings {
        let display = d.bool(forKey: displayKey)
        switch d.string(forKey: modeKey) {
        case "until":
            let until = d.object(forKey: untilKey) as? Date
            if let until, until > now { return KeepAwakeSettings(mode: .until(until), preventDisplaySleep: display) }
            return KeepAwakeSettings(mode: .off, preventDisplaySleep: display)
        case "agents":
            return KeepAwakeSettings(mode: .whileAgentsWork, preventDisplaySleep: display)
        default:
            return KeepAwakeSettings(mode: .off, preventDisplaySleep: display)
        }
    }

    public func save(to d: UserDefaults) {
        d.set(preventDisplaySleep, forKey: Self.displayKey)
        switch mode {
        case .off: d.set("off", forKey: Self.modeKey); d.removeObject(forKey: Self.untilKey)
        case .until(let date): d.set("until", forKey: Self.modeKey); d.set(date, forKey: Self.untilKey)
        case .whileAgentsWork: d.set("agents", forKey: Self.modeKey); d.removeObject(forKey: Self.untilKey)
        }
    }

    /// 可選的時長（分鐘）。
    public static let durationChoices: [Int] = [30, 60, 120, 240, 480]
}
