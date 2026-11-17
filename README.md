# Vibe Meter v0.1.0

<img src="Resources/AppIcon/VibeMeter-AppIcon.png" width="96" alt="Vibe Meter App icon">

給 vibe coder 的 macOS 選單列（上方狀態列）工具。點選單列的量規圖示，先看到各個已啟用 agent 的剩餘用量；自動繼續、最近的工作階段與設定收在可展開的區塊裡。Windows 版之後再開發。

![實際執行中的 Vibe Meter 示範視窗，使用虛構資料](docs/vibe-meter-screenshot.jpg)

上圖是**實際執行中的示範視窗，使用虛構資料**。正式模式從 macOS 選單列開啟浮窗，並共用同一套內容。淺色、深色與展開版面可見 [離屏介面預覽](docs/vibe-meter-preview.png)。

## 安裝
1. 下載 `Vibe-Meter-0.1.0.dmg` 並開啟。
2. 依視窗中的箭頭，把 **Vibe Meter** 拖到 **Applications（應用程式）**。
3. 在「應用程式」資料夾開啟 Vibe Meter。這個版本採 **ad-hoc 簽章**，尚未經 Apple 公證。如 macOS 封鎖開啟，可在「系統設定 › 隱私權與安全性」核對後允許。[Apple 安裝說明](https://support.apple.com/en-gb/102445)
4. 開啟後不會出現 Dock 圖示，請到螢幕上方選單列點 Vibe Meter 的量規圖示。

此安裝包適用於 Apple Silicon，需 macOS 14 以上。

## 實際功能
| Agent | 用量來源 | 備註 |
|---|---|---|
| Codex | 官方 `codex app-server` 的 `account/rateLimits/read`（唯讀）；查詢失敗時改顯示本機 `~/.codex` 紀錄並標示 | 需要已安裝 Codex（ChatGPT／Codex App 內附的 CLI 也可以） |
| Claude Code | 選用其一：(a) 連接 Claude Code 狀態列（會修改 `~/.claude/settings.json`，先詢問並備份）；(b) 按卡片上的查詢鈕，送出一次極小的 Haiku 請求，讀取官方 `rate_limit_event` | 只有 claude.ai 訂閱帳戶提供額度資料 |
| Cursor | **不顯示數字**：沒有個人方案的官方用量 API | 提供「封裝指令」按鈕 |
| Antigravity | **不顯示數字**：沒有公開的額度查詢介面 | 提供「封裝指令」按鈕 |

- **只顯示你用的 agent**：在「設定」中開關各 agent。停用的 agent 不顯示、不讀取用量，也不參與自動繼續；選擇會被保存。
- **低額度提醒與封裝指令**：用量達 80%、95% 時發通知。可以複製「封裝（交接）指令」，讓正在工作的 agent 寫好 HANDOFF.md 交給 Codex 接手；Codex 工作階段也可以經確認後，用官方 `codex queue` 直接送進該 thread。
- **續作計畫**：可自動加入官方紀錄確認曾因額度中止的 Codex／Claude Code 工作階段。自動繼續開關預設開啟，並保留原有選擇。現有紀錄缺少中止當下的帳戶或模型證據，v0.1.0 會顯示「待確認・暫不自動繼續」。請在計畫上選「手動繼續」，App 會再次確認工作階段沒有新活動才送出。
- **測試模式**：用 `open -n --env VIBEMETER_DRY_RUN=1 "/Applications/Vibe Meter.app"` 以唯讀方式檢視目前用量與工作階段。
- **示範模式**：用 `open -n --env VIBEMETER_DEMO=1 "/Applications/Vibe Meter.app"` 開啟使用虛構資料的 SwiftUI 視窗，頁尾顯示「示範資料」。

## 權限與存取
- **通知**：第一次需要提醒時，macOS 會詢問是否允許通知。
- **讀取的本機資料**：`~/.codex` 的工作階段與額度紀錄、`~/.claude/projects` 的 Claude Code transcript。App 透過官方 CLI 查詢 Codex 用量。
- **Claude Code 設定**：連接、更新舊 bridge 或中斷連接，都需在 App 內確認。修改 `~/.claude/settings.json` 前會先備份。
- **手動繼續**：Codex thread 由 Codex App 持有時，以 `codex queue` 送出，其他情況以終端機開啟對應的 CLI。這會實際使用該 agent 的額度。資料存放於 `~/Library/Application Support/Vibe Meter`。

## 已知限制

- Codex 的 turn 紀錄缺少中止當下的帳戶與模型，Claude Code transcript 缺少中止時的帳戶。兩者現階段需由使用者確認後手動繼續。
- Codex App 控制佇列中的訊息何時執行。在偵測到新活動前，Vibe Meter 顯示「已送出・等待 agent 回應」。
- Cursor／Antigravity 沒有可靠的官方用量來源，因此不顯示數字。
- 各 agent 的品牌圖示僅作識別用途，來源與限制見 [docs/BRAND-ASSETS.md](docs/BRAND-ASSETS.md)。

## 從原始碼建置
```bash
swift build && swift test           # 單元測試
./scripts/build-app.sh              # build/Vibe Meter.app（App icon 取自 Resources/AppIcon/VibeMeter-AppIcon.png）
./scripts/build-dmg.sh              # dist/Vibe-Meter-0.1.0.dmg，並掛載驗證內容、版本、圖示與簽章
./scripts/render-preview.sh         # 重新產生 docs/vibe-meter-preview.png（介面預覽）
```
- DMG 版面使用以雜湊鎖定的 `dmgbuild`（MIT 授權，見 `scripts/dmg-requirements.txt`），只安裝在 `build/dmg-venv`。
- Cursor／Antigravity 官方圖示由 `scripts/fetch-brand-icons.sh` 從官方素材頁下載並驗證 SHA-256，不放進 git。
- 需求、資料來源與設計：[docs/PLAN.md](docs/PLAN.md)；交接：[HANDOFF.md](HANDOFF.md)。
