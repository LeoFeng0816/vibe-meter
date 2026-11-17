import CryptoKit
import Foundation

/// 用官方 `claude -p --output-format stream-json --verbose` 送出一個極小請求，讀取 `rate_limit_event`。
///
/// - 恢復確認：只用「原 session 的模型」探測；並驗證 init／assistant／modelUsage 回報的模型確實是該模型，
///   不會改用其他模型代替。伺服器接受、未使用額外付費用量、且被擋住的週期在官方回應中明確為 allowed，才算恢復。
/// - 使用者手動「查詢」用量：用 Haiku，只用於顯示，絕不作為恢復依據。
public enum ClaudeProbeOutcome: Equatable, Sendable {
    /// 已確認：同一模型可用，被擋住的週期為 allowed。附上官方回報的週期用量。
    case restored(UsageSnapshot)
    /// 伺服器拒絕（仍在限制中）；附上官方回報的重設時間。
    case stillLimited(resetsAt: Date?)
    /// 請求有回應，但無法確認（例如缺少被擋住的週期）；應暫停，不可宣稱恢復。
    case unconfirmed(String)
    /// 繼續探測可能造成錯誤或額外費用，必須停止自動流程（例如模型不符、使用了額外付費用量）。
    case unsafe(String)
    case failed(String)
}

public enum ClaudeProbe {
    public static let prompt = "只回覆 OK"
    public static let displayModel = "haiku"

    public static func arguments(model: String) -> [String] {
        ["-p", prompt, "--output-format", "stream-json", "--verbose", "--model", model, "--max-turns", "1",
         "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands", "--tools", ""]
    }

    struct Window: Decodable { var utilization: Double?; var resetsAt: Double?; var status: String? }
    struct Info: Decodable {
        var status: String?
        var resetsAt: Double?
        var rateLimitType: String?
        var isUsingOverage: Bool?
        var unifiedWindows: [String: Window]?
    }
    struct Message: Decodable { var model: String? }
    struct Line: Decodable {
        var type: String
        var subtype: String?
        var is_error: Bool?
        var model: String?
        var message: Message?
        var modelUsage: [String: AnyDecodable]?
        var rate_limit_info: Info?
    }
    struct AnyDecodable: Decodable { init(from decoder: Decoder) throws {} }

    struct Parsed {
        var info: Info?
        var resultOK: Bool?
        var models: Set<String> = []
    }

    static func parseLines(_ output: String) -> Parsed {
        var p = Parsed()
        for raw in output.split(separator: "\n") {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
            switch line.type {
            case "system": if let m = line.model { p.models.insert(m) }
            case "assistant": if let m = line.message?.model, m != "<synthetic>" { p.models.insert(m) }
            case "rate_limit_event": p.info = line.rate_limit_info ?? p.info
            case "result":
                p.resultOK = (line.subtype == "success" && line.is_error == false)
                if let keys = line.modelUsage?.keys { p.models.formUnion(keys) }
            default: break
            }
        }
        return p
    }

    static func windows(_ info: Info?) -> [UsageWindow] {
        guard let unified = info?.unifiedWindows else { return [] }
        return unified.keys.sorted().compactMap { key in
            guard let w = unified[key], let u = w.utilization else { return nil }
            return UsageWindow(kind: ClaudeLimitType.windowKind(key), usedPercent: u * 100,
                               resetsAt: w.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// 恢復確認用的判斷（純函式，可測試）。
    /// - Parameters:
    ///   - expectedModel: 原 session 的模型 id（例如 claude-opus-5-5）。
    ///   - blockedLimitType: 原中止訊息的 `rateLimitType`（例如 five_hour、seven_day_opus）。
    public static func evaluate(output: String, observedAt: Date, expectedModel: String, blockedLimitType: String) -> ClaudeProbeOutcome {
        let p = parseLines(output)
        if p.info?.isUsingOverage == true { return .unsafe("探測使用了額外付費用量，已停止自動探測") }
        if p.info?.status == "rejected" || (p.resultOK == false && p.info?.status != "allowed" && p.info != nil) {
            return .stillLimited(resetsAt: p.info?.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
        guard let ok = p.resultOK else { return .failed("探測沒有回傳結果") }
        guard ok else { return .failed("探測請求失敗（非額度原因）") }
        // 模型必須確實是原 session 的模型；不接受其他模型的成功。
        guard !p.models.isEmpty else { return .unconfirmed("探測回應沒有回報模型，無法確認") }
        guard p.models == [expectedModel] else {
            return .unsafe("探測實際使用的模型（\(p.models.sorted().joined(separator: ", "))）與原工作階段（\(expectedModel)）不同")
        }
        guard let info = p.info, info.status == "allowed" else { return .unconfirmed("官方回應沒有額度狀態，無法確認") }
        guard info.isUsingOverage == false else { return .unconfirmed("官方回應未確認未使用額外付費用量") }
        let unified = info.unifiedWindows ?? [:]
        if unified.values.contains(where: { $0.status == "rejected" }) {
            return .stillLimited(resetsAt: info.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
        // 被擋住的週期必須出現在官方 unifiedWindows 中且明確為 allowed；沒有就不能宣稱恢復。
        guard let w = unified[blockedLimitType] else {
            return .unconfirmed(unified.isEmpty ? "官方回應沒有額度週期，無法確認"
                                                : "官方回應未包含被擋住的週期（\(blockedLimitType)），無法確認")
        }
        guard w.status == "allowed" else {
            return .unconfirmed("被擋住的週期（\(blockedLimitType)）狀態不明")
        }
        let ws = windows(info)
        return .restored(UsageSnapshot(provider: .claudeCode, windows: ws, observedAt: observedAt, source: .claudeProbe))
    }

    /// 手動查詢用量（只顯示，不作為恢復依據）。
    public static func displaySnapshot(output: String, observedAt: Date) -> ClaudeProbeOutcome {
        let p = parseLines(output)
        if p.info?.status == "rejected" { return .stillLimited(resetsAt: p.info?.resetsAt.map { Date(timeIntervalSince1970: $0) }) }
        guard p.resultOK == true else { return .failed(p.resultOK == nil ? "探測沒有回傳結果" : "探測請求失敗") }
        let ws = windows(p.info)
        guard !ws.isEmpty else { return .unconfirmed("官方回應沒有額度週期") }
        return .restored(UsageSnapshot(provider: .claudeCode, windows: ws, observedAt: observedAt, source: .claudeProbe))
    }

    public static func start(claudeBinary: URL, model: String, workingDirectory: URL,
                             timeout: TimeInterval = 90) throws -> Task<ProcessResult, Error> {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return try ProcessRunner.start(claudeBinary, arguments: arguments(model: model), cwd: workingDirectory, timeout: timeout)
    }
}

/// Claude Code 目前登入的帳戶（`claude auth status --json`）。不讀 token；email 只保留雜湊。
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

    public static func current(claudeBinary: URL) async -> ClaudeAccountIdentity? {
        guard let r = try? await ProcessRunner.run(claudeBinary, arguments: ["auth", "status", "--json"], timeout: 20), r.status == 0
        else { return nil }
        return parse(r.stdout)
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
