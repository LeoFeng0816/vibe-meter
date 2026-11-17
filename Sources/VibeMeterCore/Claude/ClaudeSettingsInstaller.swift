import Foundation

/// 在 Claude Code 使用者設定中掛上 Vibe Meter bridge。只在使用者於 App 內明確按下「連接」時執行。
///
/// - statusLine：Claude Code 每次更新狀態列時把 JSON（含 rate_limits）傳給 bridge。
///   若使用者原本已有 statusLine，會保存原指令並由 bridge 代為執行、輸出原本的內容。
/// - hooks.StopFailure（matcher `rate_limit`）：回合因額度用盡而中止時，記下是哪個工作階段。
/// 每次修改前都會備份原檔；`uninstall` 會移除 Vibe Meter 加入的項目並還原原 statusLine。
public struct ClaudeSettingsInstaller: Sendable {
    public static let marker = VibeMeterPaths.bridgeName
    /// 舊名稱也視為 Vibe Meter 的設定，以便遷移與移除。
    public static let markers = [VibeMeterPaths.bridgeName, VibeMeterPaths.legacyBridgeName]

    public var settingsURL: URL
    public var paths: VibeMeterPaths

    public init(settingsURL: URL = ClaudeSettingsInstaller.defaultSettingsURL, paths: VibeMeterPaths = .default) {
        self.settingsURL = settingsURL
        self.paths = paths
    }

    public static var defaultSettingsURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public enum Status: Equatable, Sendable {
        case claudeNotFound
        case notInstalled
        case installed
        /// statusLine 指向 Vibe Meter，但 StopFailure hook 不在（或相反）。
        case partial
    }

    public struct ChainedCommand: Codable, Equatable, Sendable {
        public var command: String
        public var padding: Int?
    }

    public func status() -> Status {
        guard FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path) else { return .claudeNotFound }
        let settings = (try? load()) ?? [:]
        let hasStatus = Self.isOurs(settings["statusLine"])
        let hasHook = Self.hookEntries(in: settings).contains { Self.isOurs($0) }
        switch (hasStatus, hasHook) {
        case (true, true): return .installed
        case (false, false): return .notInstalled
        default: return .partial
        }
    }

    /// 設定仍指向開發期名稱 headroom-bridge（需改指向 vibemeter-bridge）。
    public func usesLegacyBridge() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL) else { return false }
        return String(decoding: data, as: UTF8.self).contains(VibeMeterPaths.legacyBridgeName)
    }

    public static func statusLineCommand(bridge: URL) -> String { "\(ShellQuote.quote(bridge.path)) claude-statusline" }
    public static func stopFailureCommand(bridge: URL) -> String { "\(ShellQuote.quote(bridge.path)) claude-stop-failure rate_limit" }

    /// 安裝；回傳備份檔路徑（原本沒有設定檔則為 nil）。
    @discardableResult
    public func install(bridge: URL, now: Date = Date()) throws -> URL? {
        var settings = try load()
        let backup = try backupIfExists(now: now)

        if let existing = settings["statusLine"] as? [String: Any], !Self.isOurs(existing),
           let command = existing["command"] as? String, !command.isEmpty {
            let chained = ChainedCommand(command: command, padding: existing["padding"] as? Int)
            try VibeMeterJSON.writeAtomically(try VibeMeterJSON.encoder.encode(chained), to: paths.claudeChain)
        }
        var statusLine: [String: Any] = ["type": "command", "command": Self.statusLineCommand(bridge: bridge)]
        if let padding = (settings["statusLine"] as? [String: Any])?["padding"] { statusLine["padding"] = padding }
        settings["statusLine"] = statusLine

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var stopFailure = hooks["StopFailure"] as? [Any] ?? []
        stopFailure.removeAll { Self.isOurs($0) }
        stopFailure.append([
            "matcher": "rate_limit",
            "hooks": [["type": "command", "command": Self.stopFailureCommand(bridge: bridge)]],
        ] as [String: Any])
        hooks["StopFailure"] = stopFailure
        settings["hooks"] = hooks

        try save(settings)
        return backup
    }

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> URL? {
        var settings = try load()
        let backup = try backupIfExists(now: now)
        if Self.isOurs(settings["statusLine"]) {
            if let data = try? Data(contentsOf: paths.claudeChain),
               let chained = try? VibeMeterJSON.decoder.decode(ChainedCommand.self, from: data) {
                var restored: [String: Any] = ["type": "command", "command": chained.command]
                if let p = chained.padding { restored["padding"] = p }
                settings["statusLine"] = restored
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        }
        if var hooks = settings["hooks"] as? [String: Any], var stopFailure = hooks["StopFailure"] as? [Any] {
            stopFailure.removeAll { Self.isOurs($0) }
            if stopFailure.isEmpty { hooks.removeValue(forKey: "StopFailure") } else { hooks["StopFailure"] = stopFailure }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        try save(settings)
        try? FileManager.default.removeItem(at: paths.claudeChain)
        return backup
    }

    // MARK: helpers

    static func isOurs(_ value: Any?) -> Bool {
        guard let value else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return markers.contains { text.contains($0) }
    }

    static func hookEntries(in settings: [String: Any]) -> [Any] {
        ((settings["hooks"] as? [String: Any])?["StopFailure"] as? [Any]) ?? []
    }

    func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return obj
    }

    func save(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: [.atomic])
    }

    func backupIfExists(now: Date) throws -> URL? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        try paths.ensure(paths.backupsDir)
        let stamp = Int(now.timeIntervalSince1970 * 1000)
        let dest = paths.backupsDir.appendingPathComponent("claude-settings-\(stamp).json")
        try FileManager.default.copyItem(at: settingsURL, to: dest)
        return dest
    }
}

public enum ShellQuote {
    /// POSIX 單引號跳脫。
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
