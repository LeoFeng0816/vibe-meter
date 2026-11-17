# Vibe Meter v0.1.0 — 需求、可行性、資料來源與分階段計畫

2026-11-09 整理（同日下午依使用者更正改版為 Vibe Meter）。

## 0. 使用者原話（產品目標，完整保留）
> 叫Claude code opus 5.5-high
> 專屬vibe coder
> 在mac上方狀態欄顯示claude code/codex usage/antigravity/cursor等agent的剩餘用量
>
> Codex/cursor/antigravity:當工作正在進行中usage 快用完時 給codex包起來的指令
>
> 當session limit恢復後 自動告知codex/claude code恢復作業狀態
> 先做一個v0.1.0
> Windows版之後再開發

官方資料格式曾以唯讀實測核對。發行版的安全與介面驗證使用測試替身及示範資料。

## 1. 需求摘要
| # | 需求 | 本階段狀態 |
|---|---|---|
| R1 | 選單列查看各 agent 剩餘額度、週期、重設時間；不可用時明確顯示，不捏造；區分週期與過期資料 | Codex ✅、Claude Code ✅（需使用者連接）、Cursor／Antigravity 顯示「不支援」 |
| R2 | 額度快耗盡時提醒，並提供可交接給 Codex 的封裝指令（目標、進度、已改檔案、測試、下一步），不送錯工作階段 | 通知 ✅（80%／95%）；封裝與接手指令 ✅（以複製到剪貼簿的方式，指令內含 session id 與 cwd 供核對） |
| R3 | Session limit 恢復後**自動告知** Codex／Claude Code 恢復作業 | 開關預設開啟。現有來源缺少中止當時的必要身分證據，因此 v0.1.0 先列為待確認，由使用者手動繼續。見第 5 節 |
| R4 | 繁中 UI、名稱 Vibe Meter、簡單少色 App icon、各 agent 官方圖示 | ✅ Claude／Codex 官方圖示取自本機官方 App；Cursor／Antigravity 取自官方品牌素材頁（驗證 SHA-256、建置時打包、不進 git），見 docs/BRAND-ASSETS.md |
| — | Windows 版 | 未來（核心邏輯不依賴 AppKit，可移植思路） |

## 2. 各服務資料來源與可行性

### Codex（可行，已驗證）
- **主要**：官方 `codex app-server`（stdio JSON-RPC）。順序：`initialize` → `initialized` → `account/rateLimits/read`。回傳 `primary`（300 分鐘）與 `secondary`（10080 分鐘）的 `usedPercent`、`resetsAt`，以及 `planType`、`rateLimitReachedType`。這個協定標示為 experimental，未來欄位可能變動，所以解析時容忍缺欄位。
- **備援**：`~/.codex/sessions/**/rollout-*.jsonl` 中最後一筆 `token_count.rate_limits`（Codex 每次回應時寫入）。標示為「本機紀錄」，並顯示資料時間。
- **CLI 位置**：PATH 中的 `codex`；或 ChatGPT.app 內附的 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`。
- **工作階段身分**：rollout 第一行 `session_meta.payload.id`（UUID）與 `cwd`；名稱取自 `session_index.jsonl`。
- **恢復**：`codex resume <UUID> [PROMPT]`（互動）、`codex exec resume <UUID> [PROMPT]`（非互動）。
- **傳訊給指定 thread**：`codex queue --thread <UUID> --message <TEXT> [--resume]`。送出封裝指令前會在 App 內詢問，並確認是可辨識的主工作階段。
- **禁止**：`account/rateLimitResetCredit/consume`（會用掉使用者的免費重設額度）。client 以 allowlist 限制方法，並有測試保護。

### Claude Code（可行，需使用者同意連接）
- **官方 statusLine**：stdin JSON 帶 `session_id`、`cwd`、`transcript_path`，以及 `rate_limits.five_hour／seven_day {used_percentage, resets_at}`。只有訂閱帳號提供，而且要在第一次 API 回應後才出現。連接時 Vibe Meter 把 `statusLine.command` 指向 `~/Library/Application Support/Vibe Meter/bin/vibemeter-bridge claude-statusline`；如果使用者原本就有 statusLine，會保存下來，由 bridge 代為執行並輸出原內容。
- **官方 `StopFailure` hook**（matcher `rate_limit`）：回合因額度中止時，記錄 session id 與 cwd。
- **限制**：只有 Claude Code 正在執行且有回應時才會更新，所以資料會標示時間；重設後要等下一次回應，才能確認已恢復。
- **刻意不做**：讀 Keychain OAuth token、呼叫未公開的 usage API。
- **恢復**：`claude --resume <session-id> [prompt]`。

### Cursor（目前不可行）
- 個人方案只有 cursor.com 儀表板（需要登入 cookie）。Admin API 只限 Team。官方說明顯示用量以月為單位、依帳單日重設，另有短期 rate limit。
- 決策：不讀 cookie、不爬網頁，UI 顯示「不支援」。未來如果 Cursor 推出官方本機或 CLI 介面再評估。

### Google Antigravity（目前不可行）
- 沒有公開的額度 API，只在 App 內顯示。社群回報有 5 小時刷新與每週基準兩種額度，但時間顯示不一致。
- 決策：UI 顯示「不支援」，不使用逆向工程的本機 language server 端點。

## 3. 正確性規則（已實作並測試）
1. 百分比只代表觀察當下；超過來源的過期門檻（即時查詢 15 分鐘、本機紀錄／狀態列 30 分鐘）會標示過期，也不參與選單列摘要和提醒。
2. 重設時間已過，就顯示「已過重設時間・待新資料確認」，不沿用舊值，也不假設已歸零。
3. 「確認恢復」需要同時滿足：新資料在計畫建立之後、而且在預期重設時間之後觀察到；資料本身新鮮；來源沒有回報 `rateLimitReachedType`；被擋住的週期用量 < 90%；所有週期都 < 100%（例如每週額度已滿時，5 小時重設也不算恢復）。
4. 恢復計畫只接受 UUID session id 和絕對路徑 cwd。每個工作階段同時只能有一個進行中的計畫。只有當前的 `launching(startedAt:)` 嘗試有資格送出。手動續作、取消與停用會依狀態機處理，重複事件不會再次送出。
5. 指令參數一律用 POSIX 單引號跳脫。`.command` 檔權限為 0700。

## 4. 分階段計畫

- **v0.1.0**：原生選單列、用量查詢及提醒、Claude bridge、封裝交接、待確認續作計畫、agent 設定、指定 App icon 與 DMG。
- **後續**：評估能綁定中止帳戶、模型與工作階段的官方訊號，完成自動送出驗收。Cursor／Antigravity 的用量支援依賴官方介面。Windows 版另行規劃。

## 5. 續作的官方證據

- **Codex 中止**：`thread/turns/list` 的最新 turn 須為 failed 或 interrupted，且 `error.codexErrorInfo == usageLimitExceeded`。最近活動與額度快照只用來挑選檢查對象。rollout 的 `source.subagent`、`parent_thread_id` 與 `thread_source` 都可辨識子代理。來源無法判讀時也排除。
- **Claude Code 中止**：transcript 的最後一筆對話須為 `rate_limit` 錯誤。保留額度週期、訊息 UUID 和最後一次有實際回應的模型。
- **v0.1.0 的決策**：官方 Codex turn 資料沒有中止當時的帳戶或模型，Claude Code transcript 沒有帳戶。當前登入帳戶無法補足這段證據。計畫進入「待確認」，使用者可明確選擇手動繼續。既有計畫也依此規則重驗。
- **自動路徑的條件**：須有將中止事件綁定至原帳戶與模型的證據。Codex 另外要求重設後即時資料回報同一帳戶及 `ordinaryUsageAllowed == true`。Claude 探測還須確認訂閱帳戶相同、原模型回覆、`isUsingOverage == false` 與被擋週期明確 `allowed`。兩條路徑均以測試替身驗證。
- **送出前**：最新 turn 或訊息須仍是原錨點，工作目錄須存在，最近活動亦須通過檢查。非同步檢查後，在同一 MainActor turn 核對計畫、agent 與自動繼續授權，再同步啟動子程序。保存 `launching` 後才允許送出。
- **交付方式**：Codex App 持有 thread 時使用 `codex queue`，其他 Codex 工作階段用終端機 `codex resume`。Claude Code 用終端機 `claude --resume`。

## 6. 介面與安裝

選單先顯示啟用的 agent。自動繼續、最近工作階段與設定使用倒三角區塊。內容可用滑鼠滾輪或觸控板捲動，頂部與頁尾固定。設定會保存各 agent 的啟用狀態與區塊展開狀態。

`VIBEMETER_DEMO=1` 使用虛構資料開啟獨立 SwiftUI 視窗。`VIBEMETER_DRY_RUN=1` 提供本機唯讀檢視。Claude 設定連接、升級或中斷皆須在 App 內確認並先備份。DMG 含 App、Applications 捷徑及拖曳說明。
