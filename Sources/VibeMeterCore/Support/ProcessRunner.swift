import Darwin
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
        case .launch(let s): L10n.token("無法執行：{0}", [s])
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
        let (exit, completed) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = {
            completed.yield($0.terminationStatus)
            completed.finish()
        }
        do { try process.run() } catch {
            completed.finish()
            throw ProcessRunnerError.launch(error.localizedDescription)
        }
        return Task {
            let timer = Task {
                try await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
                try await Task.sleep(for: .seconds(2))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            defer { timer.cancel() }
            async let stdout = readPipe(out.fileHandleForReading)
            async let stderr = readPipe(err.fileHandleForReading)
            async let inputDone: Void = writeInput(input.fileHandleForWriting, data: stdin)
            var iterator = exit.makeAsyncIterator()
            guard let status = await iterator.next() else { throw ProcessRunnerError.timeout }
            await inputDone
            let (outData, errData) = await (stdout, stderr)
            if process.terminationReason == .uncaughtSignal { throw ProcessRunnerError.timeout }
            return ProcessResult(status: status, stdout: String(decoding: outData, as: UTF8.self),
                                 stderr: String(decoding: errData, as: UTF8.self))
        }
    }

    private static func readPipe(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private static func writeInput(_ handle: FileHandle, data: Data?) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                if let data { try? handle.write(contentsOf: data) }
                try? handle.close()
                continuation.resume()
            }
        }
    }
}
