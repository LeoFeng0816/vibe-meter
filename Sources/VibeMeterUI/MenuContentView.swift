import AppKit
import Combine
import SwiftUI
import VibeMeterCore

/// 選單列彈出視窗。頂部與底部固定；中間內容在螢幕高度不足時可捲動，因此重新整理與結束永遠點得到。
public struct MenuContentView: View {
    @Bindable var model: AppModel
    /// 中間可捲動區域的最大高度；nil 時依目前螢幕的可用高度計算。
    var maxScrollHeight: CGFloat?
    @State private var screenHeight: CGFloat?
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    public static let width: CGFloat = 344

    public init(model: AppModel, maxScrollHeight: CGFloat? = nil) {
        self.model = model
        self.maxScrollHeight = maxScrollHeight
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
                        Label(banner, systemImage: "info.circle.fill")
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
                    DisclosureSection(id: "auto", title: "自動繼續", symbol: "arrow.triangle.2.circlepath",
                                      tint: model.autoContinue ? Theme.ok : .secondary, model: model) {
                        AutoContinueSummary(model: model)
                    } content: {
                        AutoContinueContent(model: model)
                    }
                    if !model.visibleCodexSessions.isEmpty || !model.visibleClaudeSessions.isEmpty {
                        DisclosureSection(id: "sessions", title: "最近的工作階段", symbol: "clock.arrow.circlepath",
                                          tint: Theme.info, model: model) {
                            Text("\(min(model.visibleCodexSessions.count, 3) + min(model.visibleClaudeSessions.count, 3))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        } content: {
                            SessionsContent(model: model)
                        }
                    }
                    DisclosureSection(id: "settings", title: "設定", symbol: "gearshape", tint: .secondary, model: model) {
                        Text("\(model.agentPrefs.enabled.count)/\(ProviderID.allCases.count) 個 agent")
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
        .background {
            MenuWindowScreen(keepOnScreen: model.demo) { screenHeight = $0 }
        }
        .onReceive(clock) { _ in model.tick() }
    }
}

/// 選單列在不同螢幕打開時，使用實際容器所在的螢幕。
private struct MenuWindowScreen: NSViewRepresentable {
    var keepOnScreen: Bool
    var updateHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.updateHeight = updateHeight
        view.keepOnScreen = keepOnScreen
        view.scheduleUpdate()
    }

    final class ObserverView: NSView {
        var keepOnScreen = false
        var updateHeight: ((CGFloat) -> Void)?
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
            scheduleUpdate()
        }

        @objc func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in self?.updateScreen() }
        }

        private func updateScreen() {
            guard let window, let visible = window.screen?.visibleFrame else { return }
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
                Text(model.lastRefresh.map { "更新於 \(ZhFormat.ago($0, now: model.now))" } ?? "讀取中…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let remaining = model.menuBarRemaining {
                Text("最低剩 \(ZhFormat.percent(remaining))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.level(100 - remaining))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.level(100 - remaining).opacity(0.13)))
            }
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("重新整理")
            .disabled(model.isRefreshing)
        }
    }
}

struct FooterView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.demo {
                Label("示範資料", systemImage: "testtube.2").foregroundStyle(Theme.warn)
            } else if model.dryRun {
                Label("測試模式", systemImage: "testtube.2").foregroundStyle(Theme.warn)
            }
            Text("v0.1.0").foregroundStyle(.tertiary)
            Spacer()
            Button("結束 Vibe Meter") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
    }
}

struct EmptyAgentsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            Text("沒有啟用的 agent").font(.callout.weight(.semibold))
            Text("到下方「設定」選擇你使用的 agent。").font(.caption).foregroundStyle(.secondary)
            Button("開啟設定") { model.expandedSections.insert("settings") }.controlSize(.small)
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
                Label(note, systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
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
                Text(stale ? "過期 \(ZhFormat.ago(snap.observedAt, now: model.now))"
                     : snap.source == .codexAppServer ? "即時" : ZhFormat.ago(snap.observedAt, now: model.now))
            }
            .font(.caption2).foregroundStyle(stale ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(.secondary))
            .help("資料來源：\(snap.source.label)")
        }
    }

    @ViewBuilder private var trailing: some View {
        if report.provider == .claudeCode {
            Button {
                model.probeClaudeNow()
            } label: {
                if model.isProbingClaude { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.down.circle") }
            }
            .buttonStyle(.borderless)
            .help("查詢 Claude Code 用量：送出一次極小的 Haiku 請求，讀取官方 rate_limit_event（只用於顯示）")
        } else if report.state.snapshot == nil {
            Button {
                model.copyPackPrompt(provider: report.provider, sessionID: nil, cwd: nil)
            } label: {
                Image(systemName: "shippingbox")
            }
            .buttonStyle(.borderless)
            .help("複製給 \(report.provider.displayName) 的封裝（交接）指令，讓 Codex 接手")
        }
    }

    @ViewBuilder private var content: some View {
        switch report.state {
        case .available(let snap):
            if snap.windows.isEmpty {
                Text("來源沒有回報額度週期").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(snap.windows, id: \.kind) { window in
                WindowRow(window: window, status: WindowStatus.evaluate(window, in: snap, now: model.now), now: model.now)
            }
        case .notConnected(let reason), .unsupported(let reason):
            Text(reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .error(let message):
            Text(message).font(.caption2).foregroundStyle(Theme.warn)
        case .loading:
            Text("讀取中…").font(.caption2).foregroundStyle(.secondary)
        }
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
                .frame(width: 44, alignment: .leading).lineLimit(1)
            switch status {
            case .current(let used, let resetsAt, let stale):
                UsageBar(remaining: max(0, min(100, 100 - used)), color: stale ? .secondary : Theme.level(used))
                Text(used >= 100 ? "用盡" : ZhFormat.percent(max(0, 100 - used)))
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stale ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.level(used)))
                    .frame(width: 38, alignment: .trailing)
                Text(resetsAt.map { ZhFormat.duration($0.timeIntervalSince(now)) } ?? "—")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing).lineLimit(1)
                    .help(resetsAt.map { "\(ZhFormat.resetIn($0, now: now))（\(ZhFormat.clock($0))）" } ?? "來源未提供重設時間")
            case .resetPassedAwaitingData:
                Text("已過重設時間・等待新資料確認").font(.caption2).foregroundStyle(.secondary)
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
            .accessibilityLabel("\(title)，\(expanded ? "已展開" : "已收合")")
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
            if pending > 0 { Pill(text: "\(pending) 待確認", color: Theme.planColor(.needsConfirmation(reason: "", at: .distantPast))) }
            if active.count - pending > 0 { Pill(text: "\(active.count - pending) 監看中", color: Theme.warn) }
            Pill(text: model.autoContinue ? "已啟用" : "已停用", color: model.autoContinue ? Theme.ok : .secondary)
        }
    }
}

struct AutoContinueContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(model.autoContinue
                     ? "自動送出需要官方資料確認同一帳戶與模型。目前 Codex／Claude Code 紀錄缺少這些資訊，請從「待確認」手動繼續。"
                     : "自動繼續已關閉。你仍可從「待確認」手動繼續。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(get: { model.autoContinue }, set: { model.setAutoContinue($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.ok)
            }
            Toggle(isOn: $model.autoDetect) {
                Text("自動加入官方紀錄確認被額度中止的工作階段").font(.caption2)
            }
            .toggleStyle(.checkbox)

            let plans = model.visiblePlans.sorted { $0.createdAt > $1.createdAt }
            if plans.isEmpty {
                Text("目前沒有等待中的工作階段。").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(plans) { plan in PlanRow(plan: plan, model: model) }
                if plans.contains(where: { $0.state.isFinished }) {
                    Button("清除已結束的項目") { model.clearFinished() }.buttonStyle(.borderless).font(.caption2)
                }
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
                    Text(plan.sessionTitle).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(plan.sessionID.prefix(8)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Pill(text: plan.state.label, color: color, symbol: Theme.planSymbol(plan.state))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 3) {
                if case .ready = plan.state { Button("繼續") { model.launchNow(plan.id) }.controlSize(.mini) }
                if case .needsConfirmation = plan.state {
                    Button("手動繼續") { model.launchNow(plan.id) }.controlSize(.mini)
                        .help("未經確認，由你決定現在送出（送出前仍會檢查工作階段是否已有新活動）")
                }
                if plan.state.canRetry { Button("重試") { model.launchNow(plan.id) }.controlSize(.mini) }
                if !plan.state.isFinished, model.canCancel(plan.id) { Button("取消") { model.cancelPlan(plan.id) }.controlSize(.mini) }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.07)))
    }

    private var detail: String {
        var parts: [String] = [plan.origin == .autoDetected ? "自動偵測" : "手動加入"]
        switch plan.state {
        case .waiting:
            if let reset = plan.expectedResetAt {
                parts.append(reset > model.now ? "預計 \(ZhFormat.clock(reset)) 重設，屆時以官方資料確認" : "已過預計重設時間，等待官方資料確認")
            }
            if plan.provider == .claudeCode {
                parts.append(model.autoContinue ? "以 \(plan.claude?.model ?? "原模型") 探測確認（最多 \(ProbePolicy.maxAttempts) 次）" : "自動繼續關閉時不探測")
            } else {
                parts.append("需 app-server 確認同帳戶且允許一般用量")
            }
        case .needsConfirmation(let reason, _):
            parts.append(reason)
        case .launched(let at), .resumed(let at):
            parts.append("\(plan.delivery?.label ?? "已送出")・\(ZhFormat.clock(at))")
        default:
            break
        }
        if let note = plan.note { parts.append(note) }
        return parts.joined(separator: "・")
    }
}

// MARK: - 最近的工作階段

struct SessionsContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.visibleCodexSessions.prefix(3))) { s in
                SessionRow(provider: .codex, id: s.id, title: s.displayTitle, cwd: s.cwd, lastActivity: s.lastActivity,
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
                    if limited { Pill(text: "額度中止", color: Theme.critical) }
                    else if suggested {
                        Pill(text: "可能中止・未驗證", color: Theme.warn)
                            .help("額度已滿時這個工作階段剛好有活動，但官方紀錄沒有確認；不會自動繼續，可手動加入")
                    }
                    if model.planBook.hasActivePlan(provider: provider, sessionID: id) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundStyle(Theme.ok)
                            .help("已在自動繼續清單中")
                    }
                }
                Text("\(ZhFormat.ago(lastActivity, now: model.now))・\(id.prefix(8))")
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .help(cwd ?? "")
            Spacer()
            Menu {
                Button("額度恢復後自動繼續") { model.addPlan(provider: provider, sessionID: id, title: title, cwd: cwd) }
                    .disabled(model.planBook.hasActivePlan(provider: provider, sessionID: id))
                Divider()
                if let codexSession {
                    Button("送出封裝指令給這個 Codex 工作階段…") { model.sendPackToCodex(codexSession) }
                }
                Button("複製封裝（交接）指令") { model.copyPackPrompt(provider: provider, sessionID: id, cwd: cwd) }
                if let cwd { Button("複製 Codex 接手指令") { model.copyTakeoverCommand(cwd: cwd) } }
                Button("複製 session id") { model.copy(id, message: "已複製 session id") }
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

struct SettingsContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("顯示的 agent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(ProviderID.allCases) { p in
                HStack(spacing: 7) {
                    AgentIcon(p, size: 16)
                    Text(p.displayName).font(.system(size: 11.5))
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.agentPrefs.isEnabled(p) }, set: { model.setAgent(p, enabled: $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.accent(p))
                }
            }
            Text("停用的 agent 不會顯示、不讀取用量，也不參與自動繼續。")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 2)
            HStack {
                Text("Claude Code 狀態列").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                switch model.claudeStatus {
                case .installed:
                    if model.claudeNeedsUpgrade {
                        Button("重新連接…") { model.connectClaude() }.controlSize(.mini)
                    }
                    Button("中斷連接…") { model.disconnectClaude() }.controlSize(.mini)
                case .partial: Button("重新連接") { model.connectClaude() }.controlSize(.mini)
                case .notInstalled: Button("連接…") { model.connectClaude() }.controlSize(.mini)
                case .claudeNotFound: Text("未安裝").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text("選用：連接後會修改 ~/.claude/settings.json（會先詢問並備份），讓 Claude Code 每次回應時回報官方額度。")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
