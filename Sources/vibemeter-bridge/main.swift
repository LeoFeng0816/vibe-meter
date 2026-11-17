import CoreFoundation
import Foundation
import VibeMeterCore

// Claude Code 呼叫的小工具。任何錯誤都不能讓 Claude Code 的狀態列或 hook 失敗，所以一律吞掉錯誤、exit 0。
//
//   vibemeter-bridge claude-statusline               ← settings.json statusLine.command
//   vibemeter-bridge claude-stop-failure rate_limit  ← settings.json hooks.StopFailure (matcher: rate_limit)

let args = CommandLine.arguments.dropFirst()
let input = FileHandle.standardInput.readDataToEndOfFile()
let store = ClaudeBridgeStore()
// 狀態列文字使用 Vibe Meter 設定的語言（只讀取語言設定）。
if let raw = CFPreferencesCopyAppValue(AppLanguage.defaultsKey as CFString, "com.leofeng.vibemeter" as CFString) as? String,
   let language = AppLanguage(rawValue: raw) {
    L10n.current = language
}

func runChained(_ command: String, stdin: Data) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let inPipe = Pipe(), outPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    inPipe.fileHandleForWriting.write(stdin)
    try? inPipe.fileHandleForWriting.close()
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: out, as: UTF8.self)
}

switch args.first {
case "claude-statusline":
    let parsed = try? store.recordStatusLine(input)
    if let data = try? Data(contentsOf: store.paths.claudeChain),
       let chained = try? VibeMeterJSON.decoder.decode(ClaudeSettingsInstaller.ChainedCommand.self, from: data),
       let output = runChained(chained.command, stdin: input) {
        // 使用者原本的狀態列優先，維持原樣。
        FileHandle.standardOutput.write(Data(output.utf8))
    } else if let parsed {
        print(StatusLineText.compact(parsed.usageWindows()))
    }
case "antigravity-statusline":
    _ = try? AntigravityBridgeStore().recordStatusLine(input)
case "claude-stop-failure":
    let reason = args.dropFirst().first ?? "unknown"
    try? store.recordStopFailure(input, reason: reason)
default:
    FileHandle.standardError.write(Data("usage: vibemeter-bridge claude-statusline | claude-stop-failure <reason> | antigravity-statusline\n".utf8))
}
exit(0)
