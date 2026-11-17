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
            case .antigravity: reports.append(antigravityCLIReport())
            }
        }
        return reports
    }

    public func collectAll() async -> [ProviderReport] { await collect(Set(ProviderID.allCases)) }

    public func codexReport() async -> ProviderReport {
        let logSnapshot = codexStore.latestRateLimitSnapshot()
        if let binary = codexBinary {
            do {
                return Self.codexLiveReport(try await CodexAppServerClient(binary: binary).readRateLimits())
            } catch {
                if let logSnapshot {
                    return ProviderReport(provider: .codex, state: .available(logSnapshot),
                                          note: L10n.token("即時查詢失敗（{0}），顯示本機紀錄；本機紀錄不作為自動繼續依據", [error.localizedDescription]))
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

    public static func codexLiveReport(_ live: UsageSnapshot) -> ProviderReport {
        let note: String?
        switch live.usageAllowed {
        case true?: note = nil
        case false?: note = "後端回報目前不可使用一般用量"
        case nil: note = "後端未提供使用許可（ordinaryUsageAllowed 為 null），自動繼續不會據此判定恢復"
        }
        return ProviderReport(provider: .codex, state: .available(live), note: note)
    }

    public func claudeReport() -> ProviderReport {
        switch claudeInstaller.status() {
        case .claudeNotFound:
            return ProviderReport(provider: .claudeCode, state: .notConnected(reason: "這台 Mac 沒有 Claude Code 設定資料夾"))
        case .notInstalled:
            if let snap = claudeStore.latestSnapshot() {
                return ProviderReport(provider: .claudeCode, state: .available(snap),
                                      note: "目前未連接 Claude Code 狀態列，顯示上次回報")
            }
            return ProviderReport(provider: .claudeCode,
                                  state: .notConnected(reason: "尚未連接。連接 Claude Code 狀態列以接收官方用量回報。"))
        case .partial, .installed:
            let bridgeMissing = !claudeInstaller.usesLegacyBridge()
                && !FileManager.default.isExecutableFile(atPath: claudeStore.paths.installedBridge.path)
            let note: String? = bridgeMissing ? "設定指向的 Vibe Meter bridge 不存在，Claude Code 無法回報用量，請重新連接"
                : claudeInstaller.status() == .partial ? "連接設定不完整，請重新連接" : nil
            if let snap = claudeStore.latestSnapshot() {
                return ProviderReport(provider: .claudeCode, state: .available(snap), note: note)
            }
            return ProviderReport(provider: .claudeCode,
                                  state: .notConnected(reason: "已連接，等待 Claude Code 下一次回應時回報額度（僅訂閱帳號提供）"),
                                  note: note)
        }
    }

    public func antigravityCLIReport() -> ProviderReport {
        if let snapshot = AntigravityBridgeStore(paths: claudeStore.paths).latestSnapshot() {
            return ProviderReport(provider: .antigravity, state: .available(snapshot))
        }
        return Self.antigravityReport
    }

    public static let cursorReport = ProviderReport(
        provider: .cursor,
        state: .unsupported(reason: "個人用量可在 Cursor 編輯器設定或官方儀表板查看。公開 API 僅涵蓋團隊或 Cloud Agent，無法匯入個人剩餘用量。"))

    public static let antigravityReport = ProviderReport(
        provider: .antigravity,
        state: .notConnected(reason: "Desktop 的用量在 Settings › Models。Vibe Meter 可讀取另行安裝的 Antigravity CLI 狀態列，等待設定與回報。"))
}
