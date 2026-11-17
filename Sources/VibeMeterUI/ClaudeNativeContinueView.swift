import SwiftUI
import VibeMeterCore

/// Claude Code 官方原生自動繼續的能力、條件與最後可觀察狀態。Vibe Meter 不送出、不接管也不取消原生等待。
struct ClaudeNativeContinueView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AgentIcon(.claudeCode, size: 15)
                Text(tr("Claude Code：官方原生自動繼續")).font(.caption.weight(.semibold))
                Spacer()
                Button { model.openClaudeNativeContinueDocs() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless).help(tr("開啟官方說明"))
            }
            Text(tr("Claude Code 2.1.234 起，使用 claude.ai 訂閱的互動式 session 預設會在原視窗等待額度重設並自行接續原任務（最多連續 3 次）。Vibe Meter 不另外送出提示、不開新視窗，也不取消原生等待。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(settingText).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(tr("符合條件時，Claude Code 在原視窗等待重設並接續。Vibe Meter 只顯示從本機紀錄觀察到的中止與後續活動。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let version = model.claudeReportedVersion {
                Text(ClaudeVersion.parse(version) == nil
                     ? tr("狀態列回報的 Claude Code 版本無法辨識")
                     : ClaudeVersion.atLeast(version, ClaudeNativeContinue.minimumVersion)
                       ? tr("狀態列回報的 Claude Code 版本：{0}（支援）", version)
                       : tr("狀態列回報的 Claude Code 版本：{0}（低於 2.1.234，不支援原生自動繼續）", version))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(tr("在原 CLI 執行 /config 查看「Continue automatically at usage limit」；managed settings、--settings 或專案設定可能覆蓋，Vibe Meter 無法確認生效值或是否正在等待。等待中可執行 /rate-limit-options 選擇；查看最新用量請在 Claude Code 執行 /usage。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Text(tr("例外：-p／SDK、背景 session、API key 或按量計費沒有等待；重設超過 24 小時（例如每週額度）、Remote Control 與 teammate 不會自動開始，需在原終端用 /rate-limit-options；電腦睡眠超過約 30 分鐘且期間已重設，需在原視窗按 Enter；按 Esc、送出新提示、/login、/clear、/resume 或關閉視窗會結束等待。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            let observations = model.claudeNativeObservations
            if observations.isEmpty {
                Text(tr("最近沒有在 Claude Code 紀錄中看到額度中止。")).font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(observations.prefix(3)) { ClaudeNativeRow(observation: $0, now: model.now) }
            }
        }
    }

    private var settingText: String {
        switch model.claudeNativeUserSetting {
        case .on: tr("使用者設定（~/.claude/settings.json）：開啟")
        case .off: tr("使用者設定（~/.claude/settings.json）：關閉。若原工作階段採用此值，Claude Code 不會自行開始等待")
        case .unset: tr("使用者設定（~/.claude/settings.json）：未設定（符合條件時預設開啟）")
        case .unreadable: tr("無法讀取使用者設定檔")
        }
    }
}

struct ClaudeNativeRow: View {
    var observation: ClaudeNativeContinue.Observation
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(observation.title).font(.system(size: 11)).lineLimit(1)
                Text(observation.sessionID.prefix(8)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Text(phaseText).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(observation.caveats, id: \.self) { caveat in
                Label(caveatText(caveat), systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private var phaseText: String {
        let hit = tr("最後可觀察：{0}額度中止", ZhFormat.clock(observation.limitAt))
        switch observation.phase {
        case .blockedBeforeReset(let reset):
            return tr("{0}，官方重設時間 {1}。若原視窗仍開啟且條件符合，Claude Code 會自行繼續。", hit, ZhFormat.clock(reset))
        case .resetPassedNoNewConversation(let reset):
            return tr("{0}，重設時間 {1} 已過，紀錄尚未出現後續對話。請到原視窗確認（可能需按 Enter，或等待已被取消／達到上限）。", hit, ZhFormat.clock(reset))
        case .blockedTimeUnknown:
            return tr("Claude Code 紀錄有額度中止，確切時間未知。請到原視窗確認。")
        case .blockedUnknownReset:
            return tr("{0}，官方訊息沒有重設時間。", hit)
        case .continuedAfterLimit:
            return tr("{0}，之後紀錄已有新對話（原生續作或你送出的提示）。", hit)
        }
    }

    private func caveatText(_ caveat: ClaudeNativeContinue.Caveat) -> String {
        switch caveat {
        case .versionTooOld(let v): tr("此 session 的版本 {0} 低於 2.1.234，不支援原生自動繼續", v)
        case .versionUnknown: tr("紀錄沒有版本資訊，無法判斷是否支援")
        case .nonInteractive(let e): tr("非互動執行（{0}），官方不提供等待", e)
        case .otherInterface(let e): tr("介面為 {0}，請在該介面確認是否提供等待", e ?? tr("未知"))
        case .resetBeyond24Hours: tr("重設超過 24 小時，不會自動開始等待；可在原終端用 /rate-limit-options")
        case .userSettingOff: tr("使用者設定已關閉自動繼續")
        }
    }
}
