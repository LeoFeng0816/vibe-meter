import CryptoKit
import Foundation

/// 版本號（major.minor.patch），比較時忽略前置的 "v"。
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.count <= 4, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = nums.map { $0! }
        while parts.count < 3 { parts.append(0) }
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for (x, y) in zip(a.parts, b.parts) where x != y { return x < y }
        return a.parts.count < b.parts.count
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// 更新來源：只允許使用者既有的 GitHub 儲存庫 `LeoFeng0816/vibe-meter` 的正式 release。
public enum UpdateSource {
    public static let owner = "LeoFeng0816"
    public static let repo = "vibe-meter"
    public static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")! }
    public static var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(repo)/releases")! }

    /// 下載網址必須是這個儲存庫 release 的附件：`https://github.com/LeoFeng0816/vibe-meter/releases/download/<tag>/<file>`。
    public static func isAllowedAssetURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let c = url.pathComponents  // ["/", owner, repo, "releases", "download", tag, file]
        return c.count == 7 && c[1] == owner && c[2] == repo && c[3] == "releases" && c[4] == "download"
            && c[5].range(of: #"^v?[0-9]+(?:\.[0-9]+){2,3}$"#, options: .regularExpression) != nil
            && c[6].range(of: #"^Vibe-Meter-[0-9.]+\.(?:zip|dmg(?:\.sig)?)$"#, options: .regularExpression) != nil
            && url.path(percentEncoded: true) == c.dropFirst().reduce("") { $0 + "/" + $1 }
    }

    /// GitHub 下載會轉址到它自己的檔案主機；只接受這些主機。
    public static func isAllowedRedirectHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "objects.githubusercontent.com" || h == "release-assets.githubusercontent.com"
    }

    /// 只有 release 頁面（不是任意網址）可以在瀏覽器中開啟。
    public static func isAllowedReleasePage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let c = url.pathComponents
        return c.count == 6 && c[1] == owner && c[2] == repo && c[3] == "releases" && c[4] == "tag"
            && c[5].range(of: #"^v?[0-9]+(?:\.[0-9]+){2,3}$"#, options: .regularExpression) != nil
            && url.path(percentEncoded: true) == c.dropFirst().reduce("") { $0 + "/" + $1 }
    }

    public static var signedAppcast: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/appcast.xml")!
    }

    public static func matchesInstallation(_ info: ReleaseInfo, archive: URL?, displayVersion: String, bytes: UInt64) -> Bool {
        guard let asset = info.installationArchive, let size = asset.size, (1...maxDMGBytes).contains(size), asset.sha256 != nil,
              bytes == UInt64(size), archive == asset.url, displayVersion == info.version.description else { return false }
        return matches(asset, tag: info.tag, name: expectedArchiveName(for: info.version))
    }

    public static let maxDMGBytes = 128 * 1024 * 1024
    public static let maxSignatureBytes = 8192

    public static func matches(_ asset: ReleaseAsset, tag: String, name: String) -> Bool {
        asset.name == name && isAllowedAssetURL(asset.url) && asset.url.pathComponents.suffix(2).elementsEqual([tag, name])
    }

    public static func expectedArchiveName(for version: AppVersion) -> String { "Vibe-Meter-\(version).zip" }
    public static func expectedAssetName(for version: AppVersion) -> String { "Vibe-Meter-\(version).dmg" }
}

public struct ReleaseAsset: Equatable, Sendable {
    public var name: String
    public var url: URL
    public var size: Int?
    /// GitHub 回報的 SHA-256（`digest: "sha256:..."`）。只能驗證下載完整性，**不能**證明發布者身分。
    public var sha256: String?
}

public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var version: AppVersion
    public var name: String?
    public var pageURL: URL
    public var publishedAt: Date?
    public var dmg: ReleaseAsset?
    public var installationArchive: ReleaseAsset?
    /// 同一 release 中的發布者簽章檔（`<dmg>.sig`）。
    public var signature: ReleaseAsset?
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: AppVersion, latest: AppVersion)
    case available(ReleaseInfo)
    /// 404：儲存庫目前是私人的或沒有正式 release（匿名查詢看不到）。**不代表**已是最新版本。
    case notFound
    case rateLimited(resetAt: Date?)
    case failed(String)
}

public enum UpdateChecker {
    struct APIRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
            var size: Int?
            var digest: String?
        }
        var tag_name: String
        var name: String?
        var html_url: String
        var draft: Bool?
        var prerelease: Bool?
        var published_at: String?
        var assets: [Asset]
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        let r = try JSONDecoder().decode(APIRelease.self, from: data)
        guard r.draft == false, r.prerelease == false else { throw UpdateError.notOfficial }
        guard let version = AppVersion(r.tag_name) else { throw UpdateError.badVersion }
        guard let page = URL(string: r.html_url), UpdateSource.isAllowedReleasePage(page), page.lastPathComponent == r.tag_name else { throw UpdateError.untrustedURL }
        func asset(_ name: String) -> ReleaseAsset? {
            guard let a = r.assets.first(where: { $0.name == name }), let url = URL(string: a.browser_download_url),
                  UpdateSource.isAllowedAssetURL(url) else { return nil }
            let sha = a.digest.flatMap { digest -> String? in
                guard digest.range(of: #"^sha256:[0-9A-Fa-f]{64}$"#, options: .regularExpression) != nil else { return nil }
                return String(digest.dropFirst(7)).lowercased()
            }
            let asset = ReleaseAsset(name: a.name, url: url, size: a.size, sha256: sha)
            return UpdateSource.matches(asset, tag: r.tag_name, name: name) ? asset : nil
        }
        let dmgName = UpdateSource.expectedAssetName(for: version)
        return ReleaseInfo(tag: r.tag_name, version: version, name: r.name, pageURL: page,
                           publishedAt: r.published_at.flatMap(ISO8601.parse), dmg: asset(dmgName),
                           installationArchive: asset(UpdateSource.expectedArchiveName(for: version)), signature: asset(dmgName + ".sig"))
    }

    /// 依 HTTP 狀態與內容判斷結果。
    public static func result(status: Int, body: Data, headers: [String: String], current: AppVersion) -> UpdateCheckResult {
        switch status {
        case 200:
            do {
                let info = try parse(body)
                return info.version > current ? .available(info) : .upToDate(current: current, latest: info.version)
            } catch {
                return .failed((error as? UpdateError)?.message ?? L10n.token("無法解析 release 資料"))
            }
        case 404:
            return .notFound
        case 403, 429:
            let reset = headers.first { $0.key.lowercased() == "x-ratelimit-reset" }.flatMap { Double($0.value) }
            return .rateLimited(resetAt: reset.map { Date(timeIntervalSince1970: $0) })
        default:
            return .failed(L10n.token("GitHub 回應 HTTP {0}", ["\(status)"]))
        }
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum UpdateError: Error, Equatable {
    case notOfficial, badVersion, untrustedURL, digestMismatch, missingDigest, signatureInvalid, invalidSize

    public var message: String {
        switch self {
        case .notOfficial: L10n.token("最新 release 不是正式版本")
        case .badVersion: L10n.token("release 版本號無法辨識")
        case .untrustedURL: L10n.token("release 網址不在允許的來源內")
        case .digestMismatch: L10n.token("下載檔的 SHA-256 與 GitHub 記錄不符")
        case .missingDigest: L10n.token("GitHub 沒有提供這個檔案的 SHA-256")
        case .signatureInvalid: L10n.token("發布者簽章缺失或無法驗證")
        case .invalidSize: L10n.token("下載檔的大小不符或超出上限")
        }
    }
}

/// App 在建置時嵌入公開金鑰；私鑰由發布者離線保管。
public enum UpdateTrust {
    public static var trustedPublicKeys: [String] {
        guard let encoded = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let raw = Data(base64Encoded: encoded), (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else { return [] }
        return [encoded]
    }

    /// 驗證簽章：簽署內容為 DMG 的 SHA-256 十六進位字串（UTF-8）。
    public static func verify(sha256Hex: String, signatureBase64: String, publicKeys: [String] = trustedPublicKeys) -> Bool {
        guard let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let message = Data(sha256Hex.lowercased().utf8)
        return publicKeys.contains { keyB64 in
            guard let raw = Data(base64Encoded: keyB64), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: message)
        }
    }
}

/// 自動檢查／下載設定（保存於 UserDefaults）。
public struct UpdateSettings: Equatable, Sendable {
    public static let autoCheckKey = "updateAutoCheck"
    public static let autoDownloadKey = "updateAutoDownload"
    public static let autoInstallKey = "updateAutoInstall"
    public static let lastCheckKey = "updateLastCheck"
    public static let checkInterval: TimeInterval = 24 * 3600

    public var autoCheck: Bool
    public var autoDownload: Bool
    public var autoInstall: Bool

    public init(autoCheck: Bool = true, autoDownload: Bool = false, autoInstall: Bool = false) {
        self.autoCheck = autoCheck
        self.autoDownload = autoDownload
        self.autoInstall = autoInstall
    }

    public static func load(from d: UserDefaults) -> UpdateSettings {
        UpdateSettings(autoCheck: d.object(forKey: autoCheckKey) as? Bool ?? true, autoDownload: d.bool(forKey: autoDownloadKey), autoInstall: d.bool(forKey: autoInstallKey))
    }

    public func save(to d: UserDefaults) {
        d.set(autoCheck, forKey: Self.autoCheckKey)
        d.set(autoDownload, forKey: Self.autoDownloadKey)
        d.set(autoInstall, forKey: Self.autoInstallKey)
    }

    public static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }
}
