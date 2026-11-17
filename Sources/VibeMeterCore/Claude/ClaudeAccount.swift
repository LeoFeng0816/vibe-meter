import CryptoKit
import Foundation

/// 舊版計畫保存的 Claude 帳戶識別（只解碼舊資料；v0.1.1 不再讀取帳戶或探測）。
public struct ClaudeAccountIdentity: Codable, Hashable, Sendable {
    public var authMethod: String
    public var orgID: String?
    public var subscriptionType: String?
    /// SHA-256(email + orgId) 的前 16 碼，用來比對「是不是同一個帳戶」。
    public var accountKey: String

    public init(authMethod: String, orgID: String?, subscriptionType: String?, accountKey: String) {
        self.authMethod = authMethod
        self.orgID = orgID
        self.subscriptionType = subscriptionType
        self.accountKey = accountKey
    }

    /// 訂閱帳號（claude.ai 登入）才有 rate_limit_event；API key 計費的帳戶不做自動探測，避免產生費用。
    public var isSubscription: Bool { authMethod == "claude.ai" }

    public static func parse(_ json: String) -> ClaudeAccountIdentity? {
        struct Status: Decodable {
            var loggedIn: Bool?
            var authMethod: String?
            var email: String?
            var orgId: String?
            var subscriptionType: String?
        }
        guard let s = try? JSONDecoder().decode(Status.self, from: Data(json.utf8)), s.loggedIn == true,
              let method = s.authMethod, let email = s.email, !email.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(email.lowercased())|\(s.orgId ?? "")".utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return ClaudeAccountIdentity(authMethod: method, orgID: s.orgId, subscriptionType: s.subscriptionType, accountKey: String(key))
    }


}

public enum ClaudeLocator {
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        var paths = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let env = ProcessInfo.processInfo.environment["PATH"] {
            paths += env.split(separator: ":").map { "\($0)/claude" }
        }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}
