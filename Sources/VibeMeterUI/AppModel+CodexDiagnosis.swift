import AppKit
import Foundation
import VibeMeterCore

extension AppModel {
    public func codexDiagnosis(for plan: ResumePlan) -> CodexAutomationDiagnosis {
        CodexAutomationDiagnosis.diagnose(plan, live: liveCodexSnapshot, now: Date())
    }

    /// 官方無法授權自動送出、但目前看起來可以繼續的計畫：系統確實接受通知後才記錄，每個計畫只成功通知一次。
    /// 通知權限被拒或送出失敗時不記錄，下次刷新或重新授權後重試；同一計畫同時只有一個投遞。
    func notifyManualReadyCodexPlans(using notifier: Notifier? = nil) async {
        guard !dryRun, !backgroundStopped, persists || notifier != nil, agentPrefs.isEnabled(.codex) else { return }
        let notifier = notifier ?? self.notifier
        for plan in planBook.active where plan.provider == .codex && plan.manualReadyNotifiedAt == nil {
            guard case .needsConfirmation = plan.state, codexDiagnosis(for: plan).looksReadyForManualContinue,
                  manualReadyInFlight.insert(plan.id).inserted else { continue }
            defer { manualReadyInFlight.remove(plan.id) }
            let id = plan.id
            let sent = await notifier.post(id: "manual-ready-\(id)", title: tr("Codex 額度看起來已恢復"),
                                           body: tr("「{0}」可以手動繼續。官方資料無法證實這個模型的額度，所以 Vibe Meter 沒有自動送出。",
                                                    L10n.display(plan.sessionTitle))) {
                guard !self.backgroundStopped, self.agentPrefs.isEnabled(.codex), let current = self.planBook.plan(id),
                      current.manualReadyNotifiedAt == nil, case .needsConfirmation = current.state else { return false }
                return self.codexDiagnosis(for: current).looksReadyForManualContinue
            }
            guard sent, !backgroundStopped, planBook.plan(id)?.manualReadyNotifiedAt == nil else { continue }
            planBook.markManualReadyNotified(id, at: Date())
            savePlans()
        }
    }

    static func presentManualCodexConfirmation(_ plan: ResumePlan, _ diagnosis: CodexAutomationDiagnosis,
                                               _ live: UsageSnapshot?) -> Bool {
        let alert = NSAlert()
        alert.messageText = tr("手動繼續這個 Codex 工作階段？")
        var lines = [tr("工作階段：{0}（{1}）", L10n.display(plan.sessionTitle), String(plan.sessionID.prefix(8)))]
        lines.append(diagnosis.looksReadyForManualContinue
                     ? tr("Codex 目前回報同一帳戶允許一般用量，但官方資料無法證實這個模型的額度已恢復。")
                     : tr("Codex 目前沒有確認一般用量已恢復。送出後可能再次因額度中止。"))
        // ordinaryUsageAllowed 只代表一般內含用量可用，不證明此模型的額度，也不排除 credits；一律提示付費風險。
        lines.append(tr("Vibe Meter 無法確認這次送出不會使用 Codex credits 或其他付費用量；一般用量許可不代表此模型的額度已恢復。"))
        if diagnosis.items.contains(where: { $0.detail == L10n.token("帳戶已變更") }) {
            lines.append(tr("目前 Codex 帳戶與偵測中止時不同，送出前會再次檢查，不同時不送出。"))
        }
        lines.append(tr("會先確認最新 turn 仍是中止點，再排入原工作階段（不開新視窗）；結果需等 Codex 開始新的 turn 才算繼續。"))
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: tr("繼續"))
        alert.addButton(withTitle: tr("取消"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
