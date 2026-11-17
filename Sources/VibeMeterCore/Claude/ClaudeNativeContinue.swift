import Foundation

/// Claude Code 官方原生「Continue automatically at usage limit」（`autoContinueAtUsageLimit`，v2.1.234 起）。
///
/// 符合條件的 claude.ai 訂閱互動式 session 在額度中止後會留在原視窗等待，重設後由 Claude Code 自行接續原任務。
/// Vibe Meter 只呈現能力、條件與最後可觀察的事實，不送出提示、不開新視窗、不取消或接管原生等待，
/// 也不修改 Claude 設定。生效設定可能被 managed settings、`--settings` 或 project／local 檔覆蓋，Vibe Meter 無法確認。
/// 官方說明：https://code.claude.com/docs/en/interactive-mode#wait-for-a-usage-limit-to-reset
public enum ClaudeNativeContinue {
    public static let minimumVersion = "2.1.234"
    public static let maxAutomaticContinuations = 3
    public static let docsURL = URL(string: "https://code.claude.com/docs/en/interactive-mode#wait-for-a-usage-limit-to-reset")!

    public static var handledNatively: String {
        L10n.token("Claude Code 由官方原生自動繼續處理，Vibe Meter 不送出")
    }

    /// 只讀使用者設定檔中的 `autoContinueAtUsageLimit` 一個鍵。不代表實際生效值。
    public enum UserSetting: Equatable, Sendable {
        case on, off, unset
        /// 設定檔不存在或無法解析。
        case unreadable
    }

    public static func userSetting(settingsURL: URL) -> UserSetting {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return FileManager.default.fileExists(atPath: settingsURL.path) ? .unreadable : .unset
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        guard let value = object["autoContinueAtUsageLimit"] else { return .unset }
        // 只接受 JSON 布林；Foundation 會把數字 1／0 也橋接成 Bool，需以 CFBoolean 型別區分。
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return .unreadable }
        return number.boolValue ? .on : .off
    }

    public enum Interface: Equatable, Sendable {
        case interactiveTerminal
        /// `-p`、Agent SDK 等非互動執行：官方不提供等待。
        case nonInteractive(String)
        /// 其他介面（IDE、Desktop 等）或紀錄未提供：請在該介面確認。
        case other(String?)

        public static func from(entrypoint: String?) -> Interface {
            switch entrypoint {
            case "cli": .interactiveTerminal
            case let e? where e.hasPrefix("sdk"): .nonInteractive(e)
            default: .other(entrypoint)
            }
        }
    }

    /// 由 transcript 可觀察的事實推得的狀態。不代表原視窗目前真的在等待。
    public enum Phase: Equatable, Sendable {
        /// 中止仍是最後一筆對話，重設時間未到。
        case blockedBeforeReset(resetsAt: Date)
        /// 重設時間已過，紀錄尚未出現後續對話（可能仍在處理、電腦睡眠後需按 Enter、等待被取消或已達三次上限）。
        case resetPassedNoNewConversation(resetsAt: Date)
        /// 中止仍是最後一筆對話，但官方訊息沒有合理的重設時間。
        case blockedUnknownReset
        /// 紀錄存在，但沒有可信的中止時間（缺時間戳或在未來）。
        case blockedTimeUnknown
        /// 中止之後已有新的對話（原生續作或使用者送出提示，無法分辨）。
        case continuedAfterLimit
    }

    /// 為什麼官方原生等待可能不會自動開始。
    public enum Caveat: Equatable, Sendable, Hashable {
        case versionTooOld(String)
        case versionUnknown
        case nonInteractive(String)
        case otherInterface(String?)
        case resetBeyond24Hours
        case userSettingOff
    }

    public struct Observation: Equatable, Sendable, Identifiable {
        public var sessionID: String
        public var title: String
        public var limitAt: Date
        public var resetsAt: Date?
        public var limitType: String?
        public var version: String?
        public var interface: Interface
        public var phase: Phase
        public var caveats: [Caveat]
        public var id: String { sessionID }
    }

    public static let lookback: TimeInterval = 8 * 86400

    public static func observations(_ transcripts: [ClaudeTranscriptInfo], setting: UserSetting, now: Date) -> [Observation] {
        transcripts.compactMap { t in
            guard let hit = t.lastLimit, now.timeIntervalSince(hit.at) < lookback else { return nil }
            let timeTrusted = hit.timeKnown && hit.at <= now.addingTimeInterval(60)
            // 重設時間須在中止前後的合理範圍內（不早於中止前 1 小時、不晚於 31 天），否則視為未知。
            let reset = hit.resetsAt.flatMap { r -> Date? in
                guard timeTrusted, r >= hit.at.addingTimeInterval(-3600), r <= hit.at.addingTimeInterval(31 * 86400) else { return nil }
                return r
            }
            let phase: Phase
            if t.continuedAfterLimit {
                phase = .continuedAfterLimit
            } else if !timeTrusted {
                phase = .blockedTimeUnknown
            } else if let reset {
                phase = now < reset ? .blockedBeforeReset(resetsAt: reset) : .resetPassedNoNewConversation(resetsAt: reset)
            } else {
                phase = .blockedUnknownReset
            }
            let interface = Interface.from(entrypoint: hit.entrypoint)
            var caveats: [Caveat] = []
            switch hit.version {
            case let v? where ClaudeVersion.parse(v) != nil:
                if !ClaudeVersion.atLeast(v, minimumVersion) { caveats.append(.versionTooOld(v)) }
            default: caveats.append(.versionUnknown)
            }
            switch interface {
            case .interactiveTerminal: break
            case .nonInteractive(let e): caveats.append(.nonInteractive(e))
            case .other(let e): caveats.append(.otherInterface(e))
            }
            if let reset, reset.timeIntervalSince(hit.at) > 24 * 3600 { caveats.append(.resetBeyond24Hours) }
            if setting == .off { caveats.append(.userSettingOff) }
            return Observation(sessionID: t.id, title: t.displayTitle, limitAt: hit.at, resetsAt: reset,
                               limitType: hit.limitType, version: hit.version, interface: interface, phase: phase, caveats: caveats)
        }.sorted { $0.limitAt > $1.limitAt }
    }
}

/// 版本字串比較（只看數字段）。
public enum ClaudeVersion {
    public static func parse(_ text: String) -> [Int]? {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first(where: { $0.first?.isNumber == true }) else { return nil }
        let parts = token.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard parts.count >= 3, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    public static func atLeast(_ text: String, _ minimum: String) -> Bool {
        guard let a = parse(text), let b = parse(minimum) else { return false }
        for (x, y) in zip(a, b) where x != y { return x > y }
        return a.count >= b.count
    }
}
