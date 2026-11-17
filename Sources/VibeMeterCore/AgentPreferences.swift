import Foundation

/// 使用者啟用的 agent。停用的 agent 不出現在主要畫面、不讀取用量、不參與自動繼續。
/// 預設全部啟用；使用者的選擇保存在 UserDefaults（`enabledAgents`）。
public struct AgentPreferences: Equatable, Sendable {
    public static let key = "enabledAgents"

    public private(set) var enabled: Set<ProviderID>

    public init(enabled: Set<ProviderID> = Set(ProviderID.allCases)) {
        self.enabled = enabled
    }

    public static func load(from defaults: UserDefaults) -> AgentPreferences {
        guard let raw = defaults.array(forKey: key) as? [String] else { return AgentPreferences() }
        // 未知的值（例如未來版本新增的 agent）忽略；空陣列代表使用者全部停用，要保留。
        return AgentPreferences(enabled: Set(raw.compactMap(ProviderID.init(rawValue:))))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(ProviderID.allCases.filter { enabled.contains($0) }.map(\.rawValue), forKey: Self.key)
    }

    public func isEnabled(_ p: ProviderID) -> Bool { enabled.contains(p) }

    public mutating func set(_ p: ProviderID, enabled on: Bool) {
        if on { enabled.insert(p) } else { enabled.remove(p) }
    }

    /// 依固定順序列出啟用的 agent。
    public var ordered: [ProviderID] { ProviderID.allCases.filter { enabled.contains($0) } }
}
