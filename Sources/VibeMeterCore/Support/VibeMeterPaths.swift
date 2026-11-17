import Foundation

/// Vibe Meter 自己的資料夾。預設 `~/Library/Application Support/Vibe Meter`，可用 `VIBEMETER_HOME` 覆寫（測試用）。
public struct VibeMeterPaths: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static let folderName = "Vibe Meter"
    /// v0.1 開發期間的舊名稱；啟動時會遷移。
    public static let legacyFolderName = "Headroom"

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static var `default`: VibeMeterPaths {
        let env = ProcessInfo.processInfo.environment
        if let path = env["VIBEMETER_HOME"] ?? env["HEADROOM_HOME"], !path.isEmpty {
            return VibeMeterPaths(root: URL(fileURLWithPath: path))
        }
        return VibeMeterPaths(root: applicationSupport.appendingPathComponent(folderName))
    }

    public var antigravityDir: URL { root.appendingPathComponent("antigravity") }
    public var antigravitySnapshot: URL { antigravityDir.appendingPathComponent("quota.json") }

    public var claudeDir: URL { root.appendingPathComponent("claude") }
    public var claudeRateLimits: URL { claudeDir.appendingPathComponent("rate-limits.json") }
    public var claudeActivity: URL { claudeDir.appendingPathComponent("activity.json") }
    public var claudeSessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    public var claudeEvents: URL { claudeDir.appendingPathComponent("events.jsonl") }
    public var claudeChain: URL { claudeDir.appendingPathComponent("statusline-chain.json") }
    public var claudeProbeDir: URL { claudeDir.appendingPathComponent("probe") }
    public var binDir: URL { root.appendingPathComponent("bin") }
    public var installedBridge: URL { binDir.appendingPathComponent(VibeMeterPaths.bridgeName) }
    public var backupsDir: URL { root.appendingPathComponent("backups") }
    public var resumePlans: URL { root.appendingPathComponent("resume-plans.json") }
    public var launchDir: URL { root.appendingPathComponent("launch") }

    public static let bridgeName = "vibemeter-bridge"
    public static let legacyBridgeName = "headroom-bridge"

    public func ensure(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

/// 從開發期名稱 Headroom 遷移到 Vibe Meter，保留舊 bridge 仍在使用的路徑。
public enum LegacyMigration {
    public struct Result: Equatable, Sendable {
        public var movedDataFolder = false
        public var copiedDefaultsKeys: [String] = []
    }

    /// 舊資料夾存在且新資料夾不存在時複製。先放到暫存位置，再原子移到新路徑。
    public static func migrateDataFolder(from legacy: URL, to current: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return false }
        let parent = current.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".vibemeter-migration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: legacy, to: staging)
        try fm.moveItem(at: staging, to: current)
        return true
    }

    /// 舊 bundle id 的偏好設定，只補上新設定中不存在的鍵。
    public static func migrateDefaults(from legacy: UserDefaults?, to current: UserDefaults, keys: [String]) -> [String] {
        guard let legacy else { return [] }
        var copied: [String] = []
        for key in keys where current.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                current.set(value, forKey: key)
                copied.append(key)
            }
        }
        return copied
    }
}

public enum VibeMeterJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// 原子寫入，權限 0600（內容含本機路徑與工作階段 id）。
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum SessionID {
    /// 只接受標準 UUID，避免把名稱、路徑或指令片段當成工作階段身分。
    public static func isUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil && s.count == 36
    }
}
