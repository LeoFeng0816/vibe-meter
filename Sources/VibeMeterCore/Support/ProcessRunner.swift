import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunnerError: Error, LocalizedError {
    case timeout
    case launch(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: "執行逾時"
        case .launch(let s): "無法執行：\(s)"
        }
    }
}

/// 執行外部指令（不經過 shell，參數不需跳脫）。
public enum ProcessRunner {
    public static func run(_ executable: URL, arguments: [String], cwd: URL? = nil, stdin: Data? = nil,
                           timeout: TimeInterval = 60) async throws -> ProcessResult {
        try await start(executable, arguments: arguments, cwd: cwd, stdin: stdin, timeout: timeout).value
    }

    /// 啟動子程序，並傳回等候結果的 task。呼叫端可在同一個 actor turn 檢查授權與啟動。
    public static func start(_ executable: URL, arguments: [String], cwd: URL? = nil, stdin: Data? = nil,
                             timeout: TimeInterval = 60) throws -> Task<ProcessResult, Error> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        do { try process.run() } catch {
            throw ProcessRunnerError.launch(error.localizedDescription)
        }
        return Task {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    if let stdin { input.fileHandleForWriting.write(stdin) }
                    try? input.fileHandleForWriting.close()
                    // 先讀完輸出，避免 pipe 塞滿造成死結。
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let timedOut = !timer.isCancelled && process.terminationReason == .uncaughtSignal
                    timer.cancel()
                    if timedOut {
                        continuation.resume(throwing: ProcessRunnerError.timeout)
                    } else {
                        continuation.resume(returning: ProcessResult(status: process.terminationStatus,
                                                                     stdout: String(decoding: outData, as: UTF8.self),
                                                                     stderr: String(decoding: errData, as: UTF8.self)))
                    }
                }
            }
        }
    }
}
