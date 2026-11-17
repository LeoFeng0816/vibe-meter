import AppKit
import Combine
import SwiftUI
import VibeMeterCore

/// 選單列彈出視窗。頂部與底部固定；中間內容在螢幕高度不足時可捲動，因此重新整理與結束永遠點得到。
public struct MenuContentView: View {
    @Bindable var model: AppModel
    /// 中間可捲動區域的最大高度；nil 時依目前螢幕的可用高度計算。
    var maxScrollHeight: CGFloat?
    var statusMenu: Bool
    @State private var screenHeight: CGFloat?
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    public static let width: CGFloat = 344

    public init(model: AppModel, maxScrollHeight: CGFloat? = nil, statusMenu: Bool = false) {
        self.model = model
        self.maxScrollHeight = maxScrollHeight
        self.statusMenu = statusMenu
    }

    /// 預留固定頂部、頁尾和視窗邊框。短螢幕也不強制最小捲動高度。
    private var availableScrollHeight: CGFloat {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let height = screenHeight ?? screen?.visibleFrame.height ?? 600
        return max(0, min(maxScrollHeight ?? 540, height - 130))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            Divider()
            AdaptiveScroll(maxHeight: availableScrollHeight) {
                VStack(alignment: .leading, spacing: 7) {
                    if let banner = model.banner {
                        Label(L10n.display(banner), systemImage: "info.circle.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.info.opacity(0.09)))
                    }
                    if model.visibleReports.isEmpty {
                        EmptyAgentsView(model: model)
                    }
                    ForEach(model.visibleReports) { report in
                        AgentCard(report: report, model: model)
                    }
                    DisclosureSection(id: "auto", title: tr("自動繼續"), symbol: "arrow.triangle.2.circlepath",
                                      tint: model.autoContinue ? Theme.ok : .secondary, model: model) {
                        AutoContinueSummary(model: model)
                    } content: {
                        AutoContinueContent(model: model)
                    }
                    DisclosureSection(id: "awake", title: tr("保持清醒"), symbol: "cup.and.saucer",
                                      tint: model.isKeepingAwake ? Theme.warn : .secondary, model: model) {
                        KeepAwakeSummary(model: model)
                    } content: {
                        KeepAwakeContent(model: model)
                    }
                    if !model.visibleCodexSessions.isEmpty || !model.visibleClaudeSessions.isEmpty {
                        DisclosureSection(id: "sessions", title: tr("最近的工作階段"), symbol: "clock.arrow.circlepath",
                                          tint: Theme.info, model: model) {
                            Text("\(min(model.visibleCodexSessions.count, 3) + min(model.visibleClaudeSessions.count, 3))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        } content: {
                            SessionsContent(model: model)
                        }
                    }
                    DisclosureSection(id: "settings", title: tr("設定"), symbol: "gearshape", tint: .secondary, model: model) {
                        Text(tr("{0}/{1} 個 agent", "\(model.agentPrefs.enabled.count)", "\(ProviderID.allCases.count)"))
                            .font(.caption2).foregroundStyle(.secondary)
                    } content: {
                        SettingsContent(model: model)
                    }
                }
                .padding(10)
            }
            Divider()
            FooterView(model: model)
                .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: statusMenu ? 12 : 0))
        // 語言切換時重建整個畫面，確保所有文字都換成新語言。
        .id(model.language)
        .environment(\.locale, model.language.locale)
        .background {
            MenuWindowScreen(keepOnScreen: model.demo && !statusMenu, clearWindowBackground: statusMenu,
                             onOpen: statusMenu ? { model.windowOpened() } : nil) { screenHeight = $0 }
        }
        .onReceive(clock) { _ in model.tick() }
        .onAppear { if statusMenu { model.windowOpened() } }
    }
}

/// 選單列在不同螢幕打開時，使用實際容器所在的螢幕。
private struct MenuWindowScreen: NSViewRepresentable {
    var keepOnScreen: Bool
    var clearWindowBackground: Bool
    /// 選單列視窗每次成為 key window（使用者打開）時呼叫。
    var onOpen: (() -> Void)?
    var updateHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.updateHeight = updateHeight
        view.onOpen = onOpen
        view.keepOnScreen = keepOnScreen
        view.clearWindowBackground = clearWindowBackground
        view.scheduleUpdate()
    }

    final class ObserverView: NSView {
        var keepOnScreen = false
        var clearWindowBackground = false
        private weak var configuredWindow: NSWindow?
        var updateHeight: ((CGFloat) -> Void)?
        var onOpen: (() -> Void)?
        private var lastHeight: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                center.addObserver(self, selector: #selector(scheduleUpdate), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(scheduleUpdate),
                               name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            center.addObserver(self, selector: #selector(windowOpened), name: NSWindow.didBecomeKeyNotification, object: window)
            scheduleUpdate()
        }

        @objc func windowOpened() { onOpen?() }

        @objc func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in self?.updateScreen() }
        }

        private func updateScreen() {
            guard let window, let visible = window.screen?.visibleFrame else { return }
            if clearWindowBackground, configuredWindow !== window {
                window.isOpaque = false
                window.backgroundColor = .clear
                configuredWindow = window
            }
            if visible.height != lastHeight {
                lastHeight = visible.height
                updateHeight?(visible.height)
            }
            // 獨立示範視窗在展開內容後可能向螢幕下方延伸。選單列視窗由系統錨定。
            if keepOnScreen, window.frame.height <= visible.height {
                var origin = window.frame.origin
                origin.y = min(max(origin.y, visible.minY), visible.maxY - window.frame.height)
                if origin != window.frame.origin { window.setFrameOrigin(origin) }
            }
        }
    }
}

/// 內容不高時就照內容高度；超過上限時固定高度並可捲動。
struct AdaptiveScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content.background {
                GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 60), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Header / Footer

struct HeaderView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().interpolation(.high).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("Vibe Meter").font(.system(size: 13, weight: .bold))
                Text(model.lastRefresh.map { tr("更新於 {0}", ZhFormat.ago($0, now: model.now)) } ?? tr("讀取中…"))
                    .font(.caption2).foregroundStyle(.secondary)
                if model.codexLiveStatusIsFailure, model.agentPrefs.isEnabled(.codex) {
                    Text(tr("Codex 即時查詢失敗，顯示上次資料")).font(.caption2).foregroundStyle(Theme.warn)
                }
            }
            Spacer()
            MenuBarPill(model: model)
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help(tr("重新整理"))
            .disabled(model.isRefreshing)
        }
    }
}

/// 與狀態列相同的內容：使用者選擇的 agent／週期；不可用時顯示「—」並說明原因。
struct MenuBarPill: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.menuBarDisplay {
        case .remaining(let r, let p, let w):
            let color = Theme.level(100 - r)
            Text(pillText(r, p, w))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.13)))
                .help(tr("狀態列顯示：{0}", model.menuBarSelection.label))
        case .unavailable(let why):
            Text("—")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .help(tr("狀態列顯示：{0}。{1}", model.menuBarSelection.label, why.explanation))
        }
    }

    private func pillText(_ r: Double, _ p: ProviderID?, _ w: WindowKind?) -> String {
        switch model.menuBarSelection {
        case .tightest: return tr("最低剩 {0}", ZhFormat.percent(r))
        case .window(let provider, let window): return tr("{0} {1} 剩 {2}", provider.shortName, window.label, ZhFormat.percent(r))
        }
    }
}

struct FooterView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.demo {
                Label(tr("示範資料"), systemImage: "testtube.2").foregroundStyle(Theme.warn)
            } else if model.dryRun {
                Label(tr("測試模式"), systemImage: "testtube.2").foregroundStyle(Theme.warn)
            }
            Text("v\(model.appVersion)").foregroundStyle(.tertiary)
            Spacer()
            Button(tr("結束 Vibe Meter")) { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
    }
}

struct EmptyAgentsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            Text(tr("沒有啟用的 agent")).font(.callout.weight(.semibold))
            Text(tr("到下方「設定」選擇你使用的 agent。")).font(.caption).foregroundStyle(.secondary)
            Button(tr("開啟設定")) { model.expandedSections.insert("settings") }.controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Agent 卡片（精簡）

struct AgentCard: View {
    var report: ProviderReport
    @Bindable var model: AppModel

    var body: some View {
        let accent = Theme.accent(report.provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                AgentIcon(report.provider, size: 22)
                Text(report.provider.displayName).font(.system(size: 12.5, weight: .semibold))
                if let plan = report.state.snapshot?.planName {
                    Text(plan.uppercased()).font(.system(size: 8.5, weight: .bold)).foregroundStyle(accent)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.15)))
                }
                Spacer(minLength: 4)
                freshness
                trailing
            }
            content
            if let note = report.note {
                Label(L10n.display(note), systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if report.provider == .claudeCode {
                Label(model.claudeRefreshStatusText, systemImage: "clock").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            if report.provider == .codex, let status = model.codexLiveStatusText {
                Label(status, systemImage: model.codexLiveStatusIsFailure ? "exclamationmark.triangle" : "clock")
                    .font(.caption2).foregroundStyle(model.codexLiveStatusIsFailure ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.tertiary))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(report.state.snapshot != nil ? 0.11 : 0.04), accent.opacity(0.02)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.55), lineWidth: 0.5))
    }

    @ViewBuilder private var freshness: some View {
        if let snap = report.state.snapshot {
            let stale = snap.isStale(now: model.now)
            HStack(spacing: 3) {
                Circle().fill(stale ? Theme.warn : Theme.ok).frame(width: 5, height: 5)
                Text(stale ? tr("過期 {0}", ZhFormat.ago(snap.observedAt, now: model.now))
                     : snap.source == .codexAppServer ? tr("即時") : ZhFormat.ago(snap.observedAt, now: model.now))
            }
            .font(.caption2).foregroundStyle(stale ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
            .help(tr("資料來源：{0}", snap.source.label))
        }
    }

    @ViewBuilder private var trailing: some View {
        if report.provider == .claudeCode {
            if model.claudeStatus != .installed || model.claudeNeedsUpgrade {
                // 未連接時直接引導：按下後會先說明並詢問，備份 ~/.claude/settings.json 後才修改。
                Button(tr("連接…")) { model.connectClaude() }.controlSize(.mini)
                    .help(tr("連接 Claude Code 官方狀態列以讀取 5 小時／每週用量與重設時間"))
            }
            Button {
                model.refreshClaudeBridge()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(tr("重新讀取 Claude Code 官方狀態列回報"))
        } else if report.provider == .antigravity {
            if model.antigravityDesktopInstalled {
                Button { model.openAntigravityDesktop() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help(tr("開啟 Antigravity Desktop，從 Settings › Models 查看用量"))
            }
            Button { model.copyAntigravitySetup() } label: { Image(systemName: "terminal") }
                .buttonStyle(.borderless).help(tr("複製 Antigravity CLI 狀態列設定"))
            packButton
        } else if report.provider == .cursor {
            Button { model.openCursorUsageHelp() } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help(tr("查看 Cursor 官方用量說明"))
            packButton
        } else if report.state.snapshot == nil {
            packButton
        }
    }

    @ViewBuilder private var content: some View {
        switch report.state {
        case .available(let snap):
            if snap.windows.isEmpty {
                Text(tr("來源沒有回報額度週期")).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(snap.windows, id: \.kind) { window in
                WindowRow(window: window, status: WindowStatus.evaluate(window, in: snap, now: model.now), now: model.now)
            }
        case .notConnected(let reason), .unsupported(let reason):
            Text(L10n.display(reason)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .error(let message):
            Text(L10n.display(message)).font(.caption2).foregroundStyle(Theme.warn)
        case .loading:
            Text(tr("讀取中…")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var packButton: some View {
        Button { model.copyPackPrompt(provider: report.provider, sessionID: nil, cwd: nil) } label: {
            Image(systemName: "shippingbox")
        }
        .buttonStyle(.borderless)
        .help(tr("複製給 {0} 的封裝（交接）指令，讓 Codex 接手", report.provider.displayName))
    }

}

/// 一個額度週期一行：名稱、進度條、剩餘百分比、重設倒數。
struct WindowRow: View {
    var window: UsageWindow
    var status: WindowStatus
    var now: Date

    var body: some View {
        HStack(spacing: 7) {
            Text(window.kind.label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading).lineLimit(1)
            switch status {
            case .current(let used, let resetsAt, let stale):
                UsageBar(remaining: max(0, min(100, 100 - used)), color: stale ? .secondary : Theme.level(used))
                Text(used >= 100 ? tr("用盡") : ZhFormat.percent(max(0, 100 - used)))
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.level(used)))
                    .frame(width: 38, alignment: .trailing)
                // 額度用盡時仍顯示官方重設倒數；來源沒有重設時間時明確標示未知，不推算。
                Text(resetsAt.map { ZhFormat.duration(max(0, ceil($0.timeIntervalSince(now)))) } ?? tr("重設未知"))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing).lineLimit(1)
                    .help(resetsAt.map { tr("{0}（{1}）", ZhFormat.resetIn($0, now: now), ZhFormat.clock($0)) } ?? tr("來源未提供重設時間"))
            case .resetPassedAwaitingData:
                Text(tr("已過重設時間・等待新資料確認")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - 倒三角展開區塊

struct DisclosureSection<Summary: View, Content: View>: View {
    var id: String
    var title: String
    var symbol: String
    var tint: Color
    @Bindable var model: AppModel
    @ViewBuilder var summary: Summary
    @ViewBuilder var content: Content

    private var expanded: Bool { model.expandedSections.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if expanded { model.expandedSections.remove(id) } else { model.expandedSections.insert(id) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    summary
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("{0}，{1}", title, expanded ? tr("已展開") : tr("已收合")))
            if expanded {
                content
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.45), lineWidth: 0.5))
    }
}

// MARK: - 自動繼續

struct AutoContinueSummary: View {
    @Bindable var model: AppModel

    var body: some View {
        let active = model.visiblePlans.filter { !$0.state.isFinished }
        let pending = active.filter { if case .needsConfirmation = $0.state { true } else { false } }.count
        HStack(spacing: 4) {
            if pending > 0 { Pill(text: tr("{0} 待確認", "\(pending)"), color: Theme.planColor(.needsConfirmation(reason: "", at: .distantPast))) }
            if active.count - pending > 0 { Pill(text: tr("{0} 監看中", "\(active.count - pending)"), color: Theme.warn) }
            Pill(text: model.autoContinue ? tr("已啟用") : tr("已停用"), color: model.autoContinue ? Theme.ok : .secondary)
        }
    }
}

struct AutoContinueContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(model.autoContinue
                     ? tr("Codex：只有官方資料確認「同一工作階段、中止時的帳戶與模型、額度已允許」時才會自動送出。無法確認的項目會標為待確認，由你決定是否手動繼續。")
                     : tr("Codex 自動繼續已關閉。你仍可從「待確認」手動繼續。"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(get: { model.autoContinue }, set: { model.setAutoContinue($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.ok)
            }
            HStack {
                Text(tr("Codex 續作模式")).font(.caption.weight(.semibold))
                Spacer()
                Picker(tr("Codex 續作模式"), selection: Binding(get: { model.codexContinuation.mode }, set: model.setCodexContinuationMode)) {
                    Text(tr("自動")).tag(CodexContinuationSettings.Mode.automatic)
                    Text(tr("手動限定")).tag(CodexContinuationSettings.Mode.scoped)
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
            }
            if model.codexContinuation.mode == .scoped {
                if let scope = model.codexContinuation.scope {
                    HStack {
                        Text(tr("Codex 工作階段 {0}・帳戶 {1}・{2}", String(scope.sessionID.prefix(8)),
                                String(scope.accountHash.suffix(8)), scope.model))
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("清除範圍")) { model.clearCodexScope() }.controlSize(.mini)
                    }
                } else {
                    Text(tr("請在最近工作階段的 Codex 選單指定範圍。尚未選擇時，計畫會停在待確認。"))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $model.autoDetect) {
                Text(tr("自動加入官方紀錄確認被額度中止的 Codex 工作階段")).font(.caption2)
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: Binding(get: { model.codexTimedResume }, set: { model.setCodexTimedResume($0) })) {
                Text(tr("只有一般額度時，於官方重設時間＋30 秒嘗試一次")).font(.caption2)
            }
            .toggleStyle(.checkbox)
            Text(tr("帳戶只有一般 codex 額度（官方未標示模型）時使用。仍要求中止前後觀察到同一帳戶與官方重設時間；送出前重新確認帳戶、最新 turn 與用量。這不是官方確認原模型已恢復：可能再次中止，也可能使用已啟用的 credits。每個額度週期只嘗試一次。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)

            let plans = model.visiblePlans.sorted { $0.createdAt > $1.createdAt }
            if plans.isEmpty {
                Text(tr("目前沒有等待中的工作階段。")).font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(plans) { plan in PlanRow(plan: plan, model: model) }
                if plans.contains(where: { $0.state.isFinished }) {
                    Button(tr("清除已結束的項目")) { model.clearFinished() }.buttonStyle(.borderless).font(.caption2)
                }
            }
            if model.agentPrefs.isEnabled(.claudeCode) {
                Divider()
                ClaudeNativeContinueView(model: model)
            }
        }
    }
}

struct PlanRow: View {
    var plan: ResumePlan
    @Bindable var model: AppModel

    var body: some View {
        let color = Theme.planColor(plan.state)
        HStack(alignment: .top, spacing: 7) {
            AgentIcon(plan.provider, size: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(L10n.display(plan.sessionTitle)).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(plan.sessionID.prefix(8)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Pill(text: statusLabel, color: color, symbol: Theme.planSymbol(plan.state))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if plan.provider == .codex, case .needsConfirmation = plan.state {
                    CodexDiagnosisView(diagnosis: model.codexDiagnosis(for: plan))
                }
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 3) {
                if plan.provider == .codex {
                    if case .ready = plan.state { Button(tr("繼續")) { model.launchNow(plan.id) }.controlSize(.mini) }
                    if case .needsConfirmation = plan.state {
                        Button(tr("手動繼續")) { model.launchNow(plan.id) }.controlSize(.mini)
                            .help(tr("未經確認，由你決定現在送出。送出前會確認最新 turn 仍是中止點，並排入原工作階段"))
                    }
                    if plan.state.canRetry { Button(tr("重試")) { model.launchNow(plan.id) }.controlSize(.mini) }
                }
                if !plan.state.isFinished, model.canCancel(plan.id) { Button(tr("取消")) { model.cancelPlan(plan.id) }.controlSize(.mini) }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.07)))
    }

    private var statusLabel: String {
        if plan.codex?.isTimedAttempt == true, case .ready = plan.state {
            return tr("已過一般額度重設＋30 秒・可確認後手動繼續")
        }
        if plan.provider == .claudeCode, case .launched = plan.state {
            return tr("終端機已開啟，請輸入續作指令")
        }
        return plan.state.label
    }

    private var detail: String {
        var parts: [String] = [plan.origin == .autoDetected ? tr("自動偵測") : tr("手動加入")]
        switch plan.state {
        case .waiting:
            if let reset = plan.expectedResetAt {
                parts.append(reset > model.now ? tr("預計 {0} 重設，屆時以官方資料確認", ZhFormat.clock(reset)) : tr("已過預計重設時間，等待官方資料確認"))
            }
            if let due = model.codexTimedDue(for: plan) {
                parts.append(due > model.now
                             ? tr("一般額度重設＋30 秒（{0}）嘗試一次・剩 {1}", ZhFormat.clock(due), ZhFormat.duration(ceil(due.timeIntervalSince(model.now))))
                             : tr("已到重設＋30 秒，等待送出前檢查"))
                parts.append(tr("依時間嘗試，不是官方確認原模型恢復；可能使用已啟用的付費用量"))
            } else if plan.provider == .codex {
                parts.append(model.codexWaitingReason(plan) ?? tr("需 app-server 確認同帳戶、同模型額度且允許一般用量"))
            }
        case .needsConfirmation(let reason, _):
            parts.append(L10n.display(reason))
        case .launched(let at), .resumed(let at):
            parts.append("\(plan.delivery?.label ?? tr("已送出"))・\(ZhFormat.clock(at))")
        default:
            break
        }
        if let note = plan.note { parts.append(L10n.display(note)) }
        return parts.joined(separator: "・")
    }
}

/// 自動續作所需的官方證據逐項狀態，以及目前是否看起來可以手動繼續。
struct CodexDiagnosisView: View {
    var diagnosis: CodexAutomationDiagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if diagnosis.looksReadyForManualContinue {
                Label(tr("Codex 回報同一帳戶已允許一般用量，可按「手動繼續」"), systemImage: "hand.point.right.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.ok).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(diagnosis.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: symbol(item.check)).foregroundStyle(color(item.check)).font(.system(size: 9))
                    Text(L10n.display(item.label) + (item.detail.map { "：" + L10n.display($0) } ?? ""))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private func symbol(_ check: CodexAutomationDiagnosis.Check) -> String {
        switch check { case .ok: "checkmark.circle.fill"; case .missing: "xmark.circle.fill"; case .unknown: "questionmark.circle" }
    }

    private func color(_ check: CodexAutomationDiagnosis.Check) -> Color {
        switch check { case .ok: Theme.ok; case .missing: Theme.critical; case .unknown: .secondary }
    }
}

// MARK: - 保持清醒

struct KeepAwakeSummary: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.keepAwake.mode {
        case .off: Pill(text: tr("關閉"), color: .secondary)
        case .until(let date): Pill(text: tr("剩 {0}", ZhFormat.duration(date.timeIntervalSince(model.now))), color: Theme.warn, symbol: "timer")
        case .whileAgentsWork:
            Pill(text: model.isKeepingAwake ? tr("自動・清醒中") : tr("自動・待命"), color: model.isKeepingAwake ? Theme.warn : Theme.info,
                 symbol: "bolt.horizontal")
        }
    }
}

struct KeepAwakeContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("避免 Mac 在 agent 工作時因閒置進入睡眠而中斷任務，也能讓 SSH、遠端桌面等遠端連線保持連線。使用 macOS 公開的電源管理 API，只在 Vibe Meter 執行期間有效，不修改系統的睡眠設定；闔上筆電仍會睡眠。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Menu(tr("保持一段時間")) {
                    ForEach(KeepAwakeSettings.durationChoices, id: \.self) { minutes in
                        Button(ZhFormat.duration(TimeInterval(minutes * 60))) {
                            model.setKeepAwake(.until(Date().addingTimeInterval(TimeInterval(minutes * 60))))
                        }
                    }
                }
                .controlSize(.small).fixedSize()
                Button(tr("agent 工作時自動")) { model.setKeepAwake(.whileAgentsWork) }.controlSize(.small)
                    .help(tr("只在官方訊號確認 Codex 有 turn 執行中時保持清醒；工作結束或狀態不明就釋放。Claude Code 沒有可靠的執行中訊號，不納入判斷。"))
                if model.keepAwake.mode != .off {
                    Button(tr("停止")) { model.setKeepAwake(.off) }.controlSize(.small)
                }
            }
            Toggle(isOn: Binding(get: { model.keepAwake.preventDisplaySleep }, set: { model.setKeepAwakeDisplay($0) })) {
                Text(tr("也讓顯示器保持開啟（預設只防止系統睡眠，螢幕仍可關閉省電）")).font(.caption2)
            }
            .toggleStyle(.checkbox)
            Label(model.keepAwakeStatusText, systemImage: model.isKeepingAwake ? "bolt.fill" : "moon.zzz")
                .font(.caption2).foregroundStyle(model.isKeepingAwake ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
            if let error = model.keepAwakeError {
                Text(error).font(.caption2).foregroundStyle(Theme.critical)
            }
        }
    }
}

// MARK: - 最近的工作階段

struct SessionsContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.visibleCodexSessions.prefix(3))) { s in
                SessionRow(provider: .codex, id: s.id, title: L10n.display(s.displayTitle), cwd: s.cwd, lastActivity: s.lastActivity,
                           limited: model.codexTurns[s.id]?.isUsageLimitFailure == true,
                           suggested: model.codexSuggestions.contains(s.id), codexSession: s, model: model)
            }
            ForEach(Array(model.visibleClaudeSessions.prefix(3))) { s in
                SessionRow(provider: .claudeCode, id: s.id, title: s.displayTitle, cwd: s.cwd, lastActivity: s.lastActivity,
                           limited: s.limitHit != nil, suggested: false, codexSession: nil, model: model)
            }
        }
    }
}

struct SessionRow: View {
    var provider: ProviderID
    var id: String
    var title: String
    var cwd: String?
    var lastActivity: Date
    /// 官方訊號確認因額度中止。
    var limited: Bool
    /// 未經驗證的推測（不會自動加入）。
    var suggested: Bool
    var codexSession: CodexSessionInfo?
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            AgentIcon(provider, size: 15)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 11.5)).lineLimit(1)
                    if limited { Pill(text: tr("額度中止"), color: Theme.critical) }
                    else if suggested {
                        Pill(text: tr("可能中止・未驗證"), color: Theme.warn)
                            .help(tr("額度已滿時這個工作階段剛好有活動，但官方紀錄沒有確認；不會自動繼續，可手動加入"))
                    }
                    if model.planBook.hasActivePlan(provider: provider, sessionID: id) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundStyle(Theme.ok)
                            .help(tr("已在自動繼續清單中"))
                    }
                }
                Text("\(ZhFormat.ago(lastActivity, now: model.now))・\(id.prefix(8))")
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .help(cwd ?? "")
            Spacer()
            Menu {
                if provider == .codex {
                    Button(tr("加入續作清單")) { model.addPlan(provider: provider, sessionID: id, title: title, cwd: cwd) }
                        .disabled(model.planBook.hasActivePlan(provider: provider, sessionID: id))
                    Divider()
                }
                if let codexSession {
                    Button(tr("設定為手動續作範圍…")) { model.configureCodexScope(codexSession) }
                    Button(tr("送出封裝指令給這個 Codex 工作階段…")) { model.sendPackToCodex(codexSession) }
                }
                Button(tr("複製封裝（交接）指令")) { model.copyPackPrompt(provider: provider, sessionID: id, cwd: cwd) }
                if let cwd { Button(tr("複製 Codex 接手指令")) { model.copyTakeoverCommand(cwd: cwd) } }
                Button(tr("複製 session id")) { model.copy(id, message: tr("已複製 session id")) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - 設定

struct SettingsHeader: View {
    var title: String
    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }
}

struct SettingsContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 語言
            HStack {
                SettingsHeader(title: tr("語言"))
                Spacer()
                Picker("", selection: $model.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }

            Divider().padding(.vertical, 2)
            SettingsHeader(title: tr("顯示的 agent"))
            ForEach(ProviderID.allCases) { p in
                HStack(spacing: 7) {
                    AgentIcon(p, size: 16)
                    Text(p.displayName).font(.system(size: 11.5))
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.agentPrefs.isEnabled(p) }, set: { model.setAgent(p, enabled: $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.accent(p))
                }
            }
            Text(tr("停用的 agent 不會顯示、不讀取用量，也不參與自動繼續。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)
            MenuBarSettings(model: model)

            Divider().padding(.vertical, 2)
            AlertSettingsView(model: model)

            Divider().padding(.vertical, 2)
            ClaudeRefreshSettings(model: model)

            Divider().padding(.vertical, 2)
            CodexPollingSettings(model: model)

            Divider().padding(.vertical, 2)
            PermissionSettings(model: model)

            Divider().padding(.vertical, 2)
            UpdateSettingsView(model: model)

            Divider().padding(.vertical, 2)
            HStack {
                SettingsHeader(title: tr("Claude Code 狀態列"))
                Spacer()
                switch model.claudeStatus {
                case .installed:
                    if model.claudeNeedsUpgrade {
                        Button(tr("重新連接…")) { model.connectClaude() }.controlSize(.mini)
                    }
                    Button(tr("中斷連接…")) { model.disconnectClaude() }.controlSize(.mini)
                case .partial: Button(tr("重新連接")) { model.connectClaude() }.controlSize(.mini)
                case .notInstalled: Button(tr("連接…")) { model.connectClaude() }.controlSize(.mini)
                case .claudeNotFound: Text(tr("未安裝")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(tr("選用：連接後會修改 ~/.claude/settings.json（會先詢問並備份），讓 Claude Code 每次回應時回報官方額度。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshNotificationStatus() }
    }
}

struct MenuBarSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SettingsHeader(title: tr("狀態列顯示"))
                Spacer()
                Picker("", selection: $model.menuBarSelection) {
                    ForEach(MenuBarSelection.choices(enabled: model.agentPrefs.enabled.union(currentSelectionProviders)), id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            if case .unavailable(let why) = model.menuBarDisplay {
                Label(tr("目前顯示「—」：{0}", why.explanation), systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            Text(tr("固定選擇某個 agent 的週期時，資料不可用就顯示「—」，不會改顯示其他 agent 或週期。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 已選擇但目前停用的 agent 仍列在選單中，讓使用者看到「已停用」狀態而不是被默默換掉。
    private var currentSelectionProviders: Set<ProviderID> {
        if case .window(let p, _) = model.menuBarSelection { return [p] }
        return []
    }
}

struct AlertSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SettingsHeader(title: tr("低額度提醒"))
                Spacer()
                Toggle("", isOn: $model.alertSettings.enabled).toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.ok)
            }
            HStack(spacing: 6) {
                Text(tr("剩餘低於")).font(.caption2)
                Slider(value: $model.alertSettings.remainingThreshold, in: AlertSettings.allowedRange, step: 1)
                    .controlSize(.mini)
                Text(ZhFormat.percent(model.alertSettings.remainingThreshold)).font(.caption2.monospacedDigit().weight(.semibold))
                    .frame(width: 34, alignment: .trailing)
            }
            .disabled(!model.alertSettings.enabled)
            Text(tr("任何已啟用 agent 的 5 小時或每週額度，在資料新鮮可靠時低於門檻就發送本機通知；同一週期只提醒一次，重設後會再提醒。過期或未知的資料不提醒。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ClaudeRefreshSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SettingsHeader(title: tr("自動讀取 Claude Code 用量"))
                Spacer()
                Toggle("", isOn: Binding(get: { model.claudeAutoRefresh }, set: { model.setClaudeAutoRefresh($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.ok)
            }
            Text(tr("啟用後定期重讀官方狀態列送來的資料。Claude Code 只有在收到 API 回應後才會更新 5 小時／每週額度；Vibe Meter 不代送查詢，因此開啟視窗或重新整理不會產生新數值。15 分鐘沒有新資料會標示未更新。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if model.claudeAutoRefresh, !model.claudeRefreshStatusText.isEmpty {
                Text(model.claudeRefreshStatusText).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CodexPollingSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SettingsHeader(title: tr("每 30 秒查詢 Codex 額度"))
                Spacer()
                Toggle("", isOn: Binding(get: { model.codexLivePolling }, set: { model.setCodexLivePolling($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.ok)
            }
            Text(tr("只呼叫官方唯讀 account/rateLimits/read，不掃描工作階段、不觸發續作。離線、睡眠或停用 Codex 時暫停；查詢失敗時顯示上次官方值與時間，並逐步拉長間隔到最多 5 分鐘。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PermissionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SettingsHeader(title: tr("權限"))
            HStack(spacing: 6) {
                Image(systemName: "bell.badge").foregroundStyle(Theme.info)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("通知（低額度提醒、續作狀態）")).font(.caption)
                    Text(model.notificationStatus.label).font(.caption2)
                        .foregroundStyle(model.notificationStatus == .authorized ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(.secondary))
                }
                Spacer()
                if model.notificationStatus == .notDetermined {
                    Button(tr("允許…")) { model.requestNotificationPermission() }.controlSize(.mini)
                }
                Button(tr("系統設定…")) { model.openSystemSettings(.notifications) }.controlSize(.mini)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(Theme.info)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("檔案與資料夾（視情況）")).font(.caption)
                    Text(tr("工作階段位於「文件」「桌面」等受保護資料夾時，macOS 可能詢問；若拒絕，續作前無法確認工作目錄。"))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(tr("系統設定…")) { model.openSystemSettings(.filesAndFolders) }.controlSize(.mini)
            }
            Text(tr("不需要：輔助使用、螢幕錄製、自動化（Apple Events）。保持清醒也不需要額外權限。"))
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct UpdateSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SettingsHeader(title: tr("更新"))
                Spacer()
                Text(tr("目前 v{0}", model.appVersion)).font(.caption2).foregroundStyle(.secondary)
                Button {
                    Task { await model.checkForUpdates() }
                } label: {
                    if model.isCheckingUpdate { ProgressView().controlSize(.mini) } else { Text(tr("檢查更新")) }
                }
                .controlSize(.mini).disabled(model.isCheckingUpdate || model.demo)
            }
            if let result = model.updateResult { resultView(result) }
            downloadView
            Toggle(isOn: $model.updateSettings.autoCheck) { Text(tr("每天自動檢查（匿名讀取 GitHub release）")).font(.caption2) }
                .toggleStyle(.checkbox)
            Toggle(isOn: $model.updateSettings.autoDownload) { Text(tr("有新版本時自動下載並校驗（不會自動安裝）")).font(.caption2) }
                .toggleStyle(.checkbox)
            if model.demo || model.startAutomaticInstall != nil {
                Toggle(isOn: $model.updateSettings.autoInstall) {
                    Text(tr("自動安裝已驗證發布者簽章的更新，並重新啟動 Vibe Meter")).font(.caption2)
                }
                .toggleStyle(.checkbox).disabled(model.updateInstallCommitted)
            } else {
                Label(tr("此安裝位置或版本無法使用簽章自動更新"), systemImage: "lock.shield")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.updateInstallStatus {
                Text(L10n.display(status)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(tr("來源只限 github.com/LeoFeng0816/vibe-meter 的正式 release。"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .disabled(model.updateInstallCommitted)
    }

    @ViewBuilder private func resultView(_ result: UpdateCheckResult) -> some View {
        switch result {
        case .upToDate(_, let latest):
            Label(tr("已是最新版本（最新正式版 v{0}）", latest.description), systemImage: "checkmark.circle").font(.caption2).foregroundStyle(Theme.ok)
        case .available(let info):
            VStack(alignment: .leading, spacing: 3) {
                Label(tr("有新版本 v{0}", info.version.description), systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(Theme.info)
                HStack(spacing: 4) {
                    if info.dmg != nil, !isDownloading {
                        Button(tr("下載並校驗")) { Task { await model.downloadUpdate(info) } }.controlSize(.mini)
                    }
                    Button(tr("開啟 release 頁面")) { model.openReleasePage() }.controlSize(.mini)
                }
                if info.dmg == nil {
                    Text(tr("這個 release 沒有預期的 DMG 檔案")).font(.caption2).foregroundStyle(Theme.warn)
                }
            }
        case .notFound:
            Text(tr("找不到公開的正式 release（儲存庫可能是私人的，或尚未發布）。匿名查詢無法讀取私人儲存庫。"))
                .font(.caption2).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
        case .rateLimited(let reset):
            Text(reset.map { tr("GitHub 查詢次數已達上限，{0}後可再試", ZhFormat.duration($0.timeIntervalSince(model.now))) } ?? tr("GitHub 查詢次數已達上限，請稍後再試"))
                .font(.caption2).foregroundStyle(Theme.warn)
        case .failed(let reason):
            Text(tr("檢查失敗：{0}", L10n.display(reason))).font(.caption2).foregroundStyle(Theme.warn)
        }
    }

    private var isDownloading: Bool { if case .downloading = model.updateDownload { true } else { false } }

    @ViewBuilder private var downloadView: some View {
        switch model.updateDownload {
        case .idle: EmptyView()
        case .downloading(let v):
            Label(tr("下載 v{0} 中…", v), systemImage: "arrow.down.circle").font(.caption2).foregroundStyle(.secondary)
        case .downloaded(_, let v, let sha, let digestOK, let publisherOK):
            VStack(alignment: .leading, spacing: 2) {
                Label(tr("已下載 v{0}：SHA-256 與 GitHub 記錄{1}", v, digestOK ? tr("相符") : tr("未比對")), systemImage: "doc.badge.checkmark")
                    .font(.caption2).foregroundStyle(Theme.ok)
                Text("SHA-256 \(sha.prefix(16))…").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                Text(publisherOK ? tr("發布者簽章：已驗證") : tr("發布者簽章：未驗證（只證明檔案完整，不能證明發布者）"))
                    .font(.caption2).foregroundStyle(publisherOK ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(Theme.warn))
                Button(tr("在 Finder 中顯示")) { model.revealDownloadedUpdate() }.controlSize(.mini)
            }
        case .failed(let reason):
            Text(tr("下載失敗：{0}", L10n.display(reason))).font(.caption2).foregroundStyle(Theme.warn)
        }
    }
}
