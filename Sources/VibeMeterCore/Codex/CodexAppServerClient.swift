import CoreFoundation
import Darwin
import Foundation

/// 找到本機的 Codex CLI。不在 PATH 時，檢查 ChatGPT／Codex 桌面版內附的 CLI。
public enum CodexLocator {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var paths: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            paths += envPath.split(separator: ":").map { "\($0)/codex" }
        }
        paths += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        ]
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public static func find() -> URL? {
        candidates().first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}

public enum CodexAppServerError: Error, LocalizedError, Equatable {
    case binaryNotFound
    case timeout
    case processFailed(String)
    case rpcError(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound: "找不到 Codex CLI"
        case .timeout: "Codex app-server 回應逾時"
        case .processFailed(let s): L10n.token("無法啟動 Codex app-server：{0}", [s])
        case .rpcError(let s): L10n.token("Codex 回報錯誤：{0}", [s])
        case .malformedResponse: "Codex 回應格式無法辨識"
        }
    }
}

/// 透過官方 `codex app-server`（JSON-RPC over stdio）唯讀查詢。
///
/// 安全邊界：只會送出 `allowedMethods` 中的唯讀方法——
/// `account/rateLimits/read`（額度）、`thread/turns/list`（指定 thread 最新 turn 的狀態與錯誤）與 `thread/read`（thread 目前模型）。
/// 絕不呼叫 `account/rateLimitResetCredit/consume`（會用掉使用者的重設額度）或任何 thread 寫入／啟動方法。
public struct CodexAppServerClient: Sendable {
    public static let allowedMethods: Set<String> = ["initialize", "initialized", "account/rateLimits/read", "thread/turns/list", "thread/read"]

    public var binary: URL
    public var timeout: Duration

    public init(binary: URL, timeout: Duration = .seconds(20)) {
        self.binary = binary
        self.timeout = timeout
    }

    static let requestID = 2

    static func requestLines(method: String, params: [String: Any]? = nil, clientVersion: String = "0.1.1") -> [String] {
        var call: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method]
        if let params { call["params"] = params }
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "vibe-meter", "title": "Vibe Meter", "version": clientVersion]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            call,
        ]
        for m in messages { precondition(allowedMethods.contains(m["method"] as! String), "app-server method not allowed") }
        return messages.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
    }

    /// 從 app-server 的輸出行中找出 id=2 的回應。
    static func extractResult(fromLine line: String) throws -> Data? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["id"] as? Int) == requestID else { return nil }
        if let error = obj["error"] as? [String: Any] {
            throw CodexAppServerError.rpcError((error["message"] as? String) ?? "unknown")
        }
        guard let result = obj["result"] else { throw CodexAppServerError.malformedResponse }
        return try JSONSerialization.data(withJSONObject: result)
    }

    public func readRateLimits(now: @escaping @Sendable () -> Date = { Date() }) async throws -> UsageSnapshot {
        let data = try await call(method: "account/rateLimits/read", params: ["excludeResetCreditDetails": true])
        return try CodexRateLimitParser.parseAppServerResult(data, observedAt: now())
    }

    /// 指定 thread 最新的 turn（唯讀，不載入 items）。
    public func latestTurn(threadID: String) async throws -> CodexTurnSummary? {
        guard SessionID.isUUID(threadID) else { throw CodexAppServerError.rpcError("thread id 必須是 UUID") }
        let data = try await call(method: "thread/turns/list",
                                  params: ["threadId": threadID.lowercased(), "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"])
        return try CodexTurnSummary.parseLatest(data)
    }

    /// 指定 thread 目前設定的模型（唯讀 `thread/read`，不載入 turns）。官方說明：已載入時為目前設定，否則為最後保存的模型。
    public func threadModel(threadID: String) async throws -> String? {
        guard SessionID.isUUID(threadID) else { throw CodexAppServerError.rpcError("thread id 必須是 UUID") }
        let data = try await call(method: "thread/read", params: ["threadId": threadID.lowercased(), "includeTurns": false])
        return try Self.parseThreadModel(data, threadID: threadID)
    }

    static func parseThreadModel(_ data: Data, threadID: String) throws -> String? {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thread = obj["thread"] as? [String: Any], let id = thread["id"] as? String else { throw CodexAppServerError.malformedResponse }
        guard id.lowercased() == threadID.lowercased() else { throw CodexAppServerError.malformedResponse }
        return (thread["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func call(method: String, params: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let killer = ProcessBox(process)
        do { try process.run() } catch { throw CodexAppServerError.processFailed(error.localizedDescription) }

        let payload = Self.requestLines(method: method, params: params).joined(separator: "\n") + "\n"
        do {
            try stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        } catch {
            try? stdin.fileHandleForWriting.close()
            await killer.waitForTermination()
            throw CodexAppServerError.processFailed(error.localizedDescription)
        }

        let timeout = self.timeout
        let handle = stdout.fileHandleForReading
        let result: Result<Data, Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        for try await line in handle.bytes.lines {
                            if let result = try Self.extractResult(fromLine: line) { return result }
                        }
                        throw CodexAppServerError.malformedResponse
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        // 讀取端卡在 pipe 上時，結束子程序才能讓它返回。
                        killer.beginTermination()
                        throw CodexAppServerError.timeout
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else { throw CodexAppServerError.malformedResponse }
                    return first
                }
            } onCancel: {
                killer.beginTermination()
            })
        } catch {
            result = .failure(error)
        }
        try? stdin.fileHandleForWriting.close()
        // 等子程序真正結束後才回傳，呼叫端的 single-flight 才代表「最多一個 app-server」。
        await killer.waitForTermination()
        return try result.get()
    }
}

/// `thread/turns/list` 回應中的一個 turn（只取判斷需要的欄位）。
public struct CodexTurnSummary: Codable, Hashable, Sendable {
    public var id: String
    /// "completed" | "interrupted" | "failed" | "inProgress"
    public var status: String
    /// `error.codexErrorInfo`（字串形式，例如 "usageLimitExceeded"）；物件形式的錯誤記為其鍵名。
    public var errorInfo: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(id: String, status: String, errorInfo: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.status = status
        self.errorInfo = errorInfo
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// 官方訊號：這個 turn 因「用量上限」失敗。
    public var isUsageLimitFailure: Bool {
        guard status == "failed" || status == "interrupted" else { return false }
        return errorInfo == "usageLimitExceeded" || errorInfo == "usage_limit_exceeded"
    }

    public var isInProgress: Bool { status == "inProgress" }
    public var isTerminal: Bool { status == "completed" || status == "failed" || status == "interrupted" }

    static func parseLatest(_ data: Data) throws -> CodexTurnSummary? {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { throw CodexAppServerError.malformedResponse }
        guard let t = list.first, let id = t["id"] as? String, let status = t["status"] as? String else { return nil }
        var info: String?
        if let error = t["error"] as? [String: Any] {
            if let s = error["codexErrorInfo"] as? String { info = s }
            else if let o = error["codexErrorInfo"] as? [String: Any], o.count == 1 { info = o.keys.first }
        }
        func date(_ key: String) -> Date? {
            guard let raw = t[key] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
                  raw.doubleValue.isFinite, raw.doubleValue > 0 else { return nil }
            return Date(timeIntervalSince1970: raw.doubleValue)
        }
        return CodexTurnSummary(id: id, status: status, errorInfo: info, startedAt: date("startedAt"), completedAt: date("completedAt"))
    }
}

/// Process 不是 Sendable；只用來在逾時時結束子程序。
final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var termination: Task<Void, Never>?
    private let exited: AsyncStream<Void>

    init(_ process: Process) {
        self.process = process
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        exited = stream
        process.terminationHandler = { _ in continuation.finish() }
    }

    func waitForTermination() async {
        await beginTermination().value
    }

    /// Escalate independently of the pipe reader, which may be blocked until the child exits.
    @discardableResult
    func beginTermination() -> Task<Void, Never> {
        lock.withLock {
            if let termination { return termination }
            let process = self.process
            let exited = self.exited
            let task = Task.detached {
                let clock = ContinuousClock()
                if process.isRunning { process.terminate() }
                let deadline = clock.now.advanced(by: .seconds(2))
                while process.isRunning, clock.now < deadline {
                    try? await clock.sleep(for: .milliseconds(20))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                for await _ in exited {}
            }
            termination = task
            return task
        }
    }
}
