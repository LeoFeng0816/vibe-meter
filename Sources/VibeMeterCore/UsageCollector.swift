import Foundation

public struct ProviderReport: Sendable, Equatable, Identifiable {
    public var provider: ProviderID
    public var state: ProviderState
    /// 補充說明，例如「即時查詢失敗，改用本機紀錄」。
    public var note: String?

    public var id: ProviderID { provider }

    public init(provider: ProviderID, state: ProviderState, note: String? = nil) {
        self.provider = provider
        self.state = state
        self.note = note
    }
}

/// 彙整各服務狀態。每個服務都有明確的「無法讀取」原因，不產生推估值。
public struct UsageCollector: Sendable {
    public var codexStore: CodexLocalStore
    public var claudeStore: ClaudeBridgeStore
    public var claudeInstaller: ClaudeSettingsInstaller
    public var codexBinary: URL?

    public init(codexStore: CodexLocalStore = CodexLocalStore(), claudeStore: ClaudeBridgeStore = ClaudeBridgeStore(),
                claudeInstaller: ClaudeSettingsInstaller = ClaudeSettingsInstaller(), codexBinary: URL? = CodexLocator.find()) {
        self.codexStore = codexStore
        self.claudeStore = claudeStore
        self.claudeInstaller = claudeInstaller
        self.codexBinary = codexBinary
    }

    /// 只讀取啟用的 agent（停用的不啟動任何子程序、不讀任何檔案）。
    public func collect(_ enabled: Set<ProviderID>) async -> [ProviderReport] {
        var reports: [ProviderReport] = []
        for p in ProviderID.allCases where enabled.contains(p) {
            switch p {
            case .claudeCode: reports.append(claudeReport())
            case .codex: reports.append(await codexReport())
            case .cursor: reports.append(Self.cursorReport)
            case .antigravity: reports.append(Self.antigravityReport)
            }
        }
        return reports
    }

    public func collectAll() async -> [ProviderReport] { await collect(Set(ProviderID.allCases)) }

    public func codexReport() async -> ProviderReport {
        let logSnapshot = codexStore.latestRateLimitSnapshot()
        if let binary = codexBinary {
            do {
                let live = try await CodexAppServerClient(binary: binary).readRateLimits()
                let note: String?
                switch live.usageAllowed {
                case true?: note = nil
                case false?: note = "後端回報目前不可使用一般用量"
                case nil: note = "後端未提供使用許可（ordinaryUsageAllowed 為 null），自動繼續不會據此判定恢復"
                }
                return ProviderReport(provider: .codex, state: .available(live), note: note)
            } catch {
                if let logSnapshot {
                    return ProviderReport(provider: .codex, state: .available(logSnapshot),
                                          note: "即時查詢失敗（\(error.localizedDescription)），顯示本機紀錄；本機紀錄不作為自動繼續依據")
                }
                return ProviderReport(provider: .codex, state: .error(message: error.localizedDescription))
            }
        }
        if let logSnapshot {
            return ProviderReport(provider: .codex, state: .available(logSnapshot), note: "找不到 Codex CLI，顯示本機紀錄")
        }
        if !codexStore.isInstalled {
            return ProviderReport(provider: .codex, state: .notConnected(reason: "這台 Mac 沒有 Codex 資料（~/.codex）"))
        }
        return ProviderReport(provider: .codex, state: .notConnected(reason: "找不到 Codex CLI，也沒有含額度的本機紀錄"))
    }

    public func claudeReport() -> ProviderReport {
        switch claudeInstaller.status() {
        case .claudeNotFound:
            return ProviderReport(provider: .claudeCode, state: .notConnected(reason: "這台 Mac 沒有 Claude Code 設定資料夾"))
        case .notInstalled:
            if let snap = claudeStore.latestSnapshot() {
                return ProviderReport(provider: .claudeCode, state: .available(snap))
            }
            return ProviderReport(provider: .claudeCode,
                                  state: .notConnected(reason: "尚未連接。可連接狀態列自動回報，或按「查詢」送出一次極小的官方探測請求"))
        case .partial, .installed:
            let note: String? = claudeInstaller.status() == .partial ? "連接設定不完整，請重新連接" : nil
            if let snap = claudeStore.latestSnapshot() {
                return ProviderReport(provider: .claudeCode, state: .available(snap), note: note)
            }
            return ProviderReport(provider: .claudeCode,
                                  state: .notConnected(reason: "已連接，等待 Claude Code 下一次回應時回報額度（僅訂閱帳號提供）"),
                                  note: note)
        }
    }

    public static let cursorReport = ProviderReport(
        provider: .cursor,
        state: .unsupported(reason: "Cursor 沒有提供個人方案的官方用量 API（只有需登入的網頁儀表板），因此不顯示數字"))

    public static let antigravityReport = ProviderReport(
        provider: .antigravity,
        state: .unsupported(reason: "Antigravity 沒有公開的額度查詢介面（只在其 App 內顯示），因此不顯示數字"))
}
