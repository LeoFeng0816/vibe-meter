import Foundation

/// 產生恢復／接手用的終端機指令。所有參數都經過 POSIX 單引號跳脫。
public enum ResumeCommandBuilder {
    /// - codex：`codex resume <SESSION_ID> [PROMPT]`（官方 CLI，UUID 優先於名稱解析）。
    /// - Claude Code：`claude --resume <session-id> [prompt]`。
    public static func command(for plan: ResumePlan, codexBinary: String = "codex", claudeBinary: String = "claude") -> String {
        let q = ShellQuote.quote
        let tool: String
        switch plan.provider {
        case .codex: tool = "\(q(codexBinary)) resume \(q(plan.sessionID)) \(q(plan.prompt))"
        case .claudeCode: tool = "\(q(claudeBinary)) --resume \(q(plan.sessionID)) \(q(plan.prompt))"
        case .cursor, .antigravity: preconditionFailure("ResumePlan 不允許此服務")
        }
        return "cd \(q(plan.cwd)) && \(tool)"
    }

    /// 寫出可由 Terminal 開啟的 `.command` 檔（權限 0700）。開啟動作由 App 端在使用者按下按鈕後執行。
    public static func writeCommandFile(for plan: ResumePlan, command: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("resume-\(plan.id.uuidString.lowercased()).command")
        let script = """
        #!/bin/zsh -l
        # Vibe Meter 產生：恢復 \(plan.provider.displayName) 工作階段 \(plan.sessionID)
        \(command)

        """
        try Data(script.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// 用量快耗盡時的交接指令。
public struct HandoffPromptBuilder: Sendable {
    public var handoffRelativePath: String

    public init(handoffRelativePath: String = "HANDOFF.md") {
        self.handoffRelativePath = handoffRelativePath
    }

    /// 貼給「目前正在工作、額度快用盡」的 agent：請它把狀態封裝成交接檔。
    public func packPrompt(agent: ProviderID, sessionID: String?, cwd: String?) -> String {
        let place = cwd.map { "\($0)/\(handoffRelativePath)" } ?? handoffRelativePath
        return """
        我的 \(agent.displayName) 額度快用完了。請立即停止開始新的修改，把目前的工作封裝成交接檔，讓 Codex 能無縫接手。

        請寫入（已存在就更新，不要刪除既有內容）：\(place)
        內容依序包含：
        1. 目標：這次任務要達成什麼、驗收條件。
        2. 進度：已完成、進行中、尚未開始的項目。
        3. 已修改檔案：請實際執行 `git status --short` 與 `git diff --stat`，貼上結果並說明每個檔案的用途。
        4. 測試：已執行的測試指令與結果；沒有執行的要明寫「未執行」。
        5. 已知問題、風險與做過但放棄的嘗試。
        6. 下一步：可直接照做的具體步驟（含指令）。
        7. 工作階段資訊：工具 \(agent.displayName)、session id \(sessionID ?? "（未知）")、工作目錄 \(cwd ?? "（未知）")。

        不要 commit、push、部署或刪除檔案。完成後只回覆交接檔路徑與一句摘要。
        """
    }

    /// 給 Codex 的接手指令。
    public func takeoverPrompt(cwd: String?) -> String {
        """
        請先完整閱讀 \(handoffRelativePath) 交接檔，再執行 `git status --short` 確認實際狀態與交接檔一致；不一致時先回報差異，不要猜測。確認後從「下一步」繼續，並在交接檔追加你的進度。
        """
    }

    public func takeoverCommand(cwd: String, codexBinary: String = "codex") -> String {
        "cd \(ShellQuote.quote(cwd)) && \(ShellQuote.quote(codexBinary)) \(ShellQuote.quote(takeoverPrompt(cwd: cwd)))"
    }
}
