# HANDOFF — Vibe Meter v0.1.0

更新：2026-11-09。Claude Code Opus 5.5 High 完成選單、圖示及 DMG，遇到 5 小時額度限制後由 GPT-6.1 Sol High 接手安全修正與驗證。

## 目前狀態

- macOS 14 以上的原生選單列工具。主畫面直接顯示啟用的 agent 用量，停用選擇保存在 UserDefaults。自動繼續、最近工作階段及設定可分別展開。內容以視窗所在螢幕的可用高度限制捲動範圍，頂部與頁尾固定。
- Codex 優先使用唯讀 app-server 即時資料，備援來源標示為本機紀錄。Claude Code 使用官方狀態列回報或手動查詢。Cursor／Antigravity 顯示用量來源不支援，保留封裝指令。資料格式、判斷規則和品牌素材來源見 `docs/PLAN.md` 與 `docs/BRAND-ASSETS.md`。
- 自動繼續開關對新使用者預設開啟，保留舊設定。目前官方紀錄無法證明 Codex 中止時的帳戶與模型、Claude Code 中止時的帳戶，因此偵測到的計畫會標成「待確認」，由使用者手動繼續。先前儲存的計畫依相同規則重新檢查。
- 取消計畫、停用 agent 或關閉自動繼續，都能撤銷正在等待檢查的自動送出。同步啟動程序前會重驗授權與該次計畫的狀態，並先保存送出狀態。Claude 探測採單一引擎，重新驗證帳戶後才可能啟動，要求明確的週期許可與無額外付費用量。
- Codex 子代理與來源無法辨識的 thread 均排除。Claude 連接、舊 bridge 升級與中斷都須在 App 內確認，修改前備份。舊資料夾複製到新位置，保留原 bridge 路徑。
- 使用指定 App icon。DMG 含 App、Applications 捷徑及拖曳教學背景。執行檔在簽名前移除含建置路徑的除錯符號。
- 示範模式顯示與選單列相同的 SwiftUI 內容，使用虛構資料，頁尾標示「示範資料」。此模式用於介面截圖與互動驗證。

## 開發版的自動續作紀錄

早期開發版以正常模式運行時，偵測到實際額度中止並嘗試自動續作。兩個 Codex 工作階段經由 `codex queue` 送出後偵測到活動。一次子代理送出被 Codex 拒絕。一次 Claude Code 續作開啟終端機，紀錄沒有確認後續活動。其他計畫因已有新對話或模型無法確認而略過或停在待確認。這次驗證使用測試替身與示範資料。

## 驗證

- `swift build` 與 `env -u HEADROOM_LIVE_CODEX swift test` 通過（71 項通過，1 項選用即時測試略過），涵蓋撤銷競態、明確手動續作、子代理辨識、帳戶與模型證據、Claude 設定備份與 agent 設定持久化。
- 實際示範視窗已全展開並捲至底部，四個 agent 開關、Claude 連接說明與固定頁尾均可見。關閉 Cursor 後卡片隱藏，重新開啟後恢復。實際截圖在 `docs/vibe-meter-screenshot.jpg`。
- 以 `./scripts/build-dmg.sh` 重建，並驗證磁碟映像、App 版本、圖示、Finder 拖曳版面和 ad-hoc 簽章。輸出為 `dist/Vibe-Meter-0.1.0.dmg`。

## 尚待確認

- 目前版本需要使用者手動繼續。正式啟用自動送出仍需要能將中止事件綁定至原帳戶及模型的官方證據。
- 正式安裝包適用於 Apple Silicon，採 ad-hoc 簽章，尚無 Developer ID 簽署及 Apple 公證。
- 這一輪保留本機交接與產物。GitHub 上傳與發布由主代理處理。

## v0.1.1 開始開發時的紀錄（Claude Code Opus 5.5 High）
起始狀態為開發中。所有工作僅在本機；**未經使用者審核前不得 push、發布或修改 GitHub**。
- 開工前基準：`swift build` 通過；`swift test` 72 項通過（核心 67、UI 5）。
- 注意：`build/Vibe Meter.app`（v0.1.0）可能正由使用者執行，v0.1.1 產物要建置到 `build/v0.1.1/`，不覆蓋、不停止該程序，也不寫入 /Applications。
- 已確認的事實（只記錄結構，不記錄內容）：
  - Codex 自動繼續失效的主因：`CodexResumeContext.verifiedAccountAndModelAtBlock` 從未被設為 true，所以 Codex 計畫永遠停在待確認。
  - Codex rollout 的 `turn_context` 帶有 `turn_id` 與 `model`，可把中止的 turn 綁定到模型；`session_meta.creator_account_id` 是建立 thread 的帳戶。協定中沒有逐 turn 的帳戶欄位。
  - `RateLimitSnapshot.normalModelSlug`（位於 `rateLimitsByLimitId`）代表模型專屬的額度桶。
  - GitHub `LeoFeng0816/vibe-meter` 的 releases 匿名讀取會回 404（私人儲存庫）；API 也可能回 403（速率限制）。
- 計畫：L10n（繁／簡／英）、Claude 每 15 分鐘更新、選單列顯示選擇、門檻提醒、保持清醒、權限、檢查更新（安全校驗、無信任根時不自動安裝）、Codex 證據綁定修正、版本 0.1.1、DMG。
- 進度（v0.1.1）：核心模組已完成並有測試，涵蓋 L10n、MenuBarDisplay、AlertPolicy（剩餘門檻）、ClaudeRefreshPolicy、KeepAwake、UpdateChecker／UpdateTrust、CodexEvidence／AccountLedger、thread/read。AppModel 與 MenuContentView 已接線並在地化；核心測試 100 項通過。待辦：UI 整合測試、版本 0.1.1 打包到 build/v0.1.1、DMG、示範截圖、文件。

## v0.1.1 本機審閱版

Claude Code Opus 5.5 High 起始實作。5 小時額度用盡後由 GPT-6.1 Sol High 接手。尚待使用者審核，GitHub 上的下載連結仍為已發布的 v0.1.0。

### 已完成

- 保留 macOS 選單列及可捲動面板，提供繁體中文、簡體中文及英文。選單列可固定顯示啟用 agent 的指定週期，資料不可靠時顯示不可用。
- Claude Code 的官方狀態列 bridge 支援冷啟、原子換檔與直接重新整理。15 分鐘沒有新回報會顯示上次回報時間及未更新。舊探測快照與重播的相同回報無法更新資料時間。Vibe Meter 不發送 Haiku 或其他 Claude 訂閱查詢。
- Codex 預設自動續作，可切換成持久化的手動限定模式，限定一個工作階段、目前帳戶及模型。新版會在額度已恢復後檢查近期的官方中止 turn，並用先前保存的官方拒絕觀察比對。送出前重驗目前模型、帳戶、官方許可及最新 turn，且以原子記錄防止多程序重複送出。取消、模式變更、停用與已觀察到的帳戶切換均會阻止待送出的續作。
- 佇列接受、CLI 喚醒警告及官方偵測到新 turn 各有區別。未確認的發送結果不會自動重送。Claude Code 的手動續作開啟互動式 CLI，由使用者輸入要繼續的內容；Cursor、Antigravity 提供交接指令。
- Antigravity CLI 官方 statusLine bridge 只讀 quota 欄位，未啟用時提供複製設定。Antigravity Desktop 2.31.0 的 AX 與標準快取檢查未找到可驗證的額度來源，使用 Settings › Models 查看。Cursor 個人剩餘用量仍需用官方編輯器或儀表板查看。
- 可設定 5 小時／每週剩餘門檻，成功投遞後才去重。通知授權變更後可再嘗試。定時與 Codex 工作中保持清醒透過 IOKit 管理，狀態未知、期限到期、模式取消或 App 結束時釋放。
- 匿名 GitHub release 檢查與可選自動下載已實作。404 會指出匿名無法讀取；下載驗大小、SHA-256 與發布者簽章，暫存校驗後原子替換。另整合 Sparkle 2.10.0，安裝位置可寫且使用者開啟自動安裝時，會比對最新正式 release 和簽章 appcast，驗證 ZIP 簽章後替換 App 並重新啟動。

### 驗證

- `swift build` 通過；以 115 秒上限執行 `env -u HEADROOM_LIVE_CODEX VIBEMETER_SPARKLE_XCFRAMEWORK=build/dependencies/Sparkle.xcframework swift test`，119 項通過、1 項選用的實機測試略過。續作及更新替身涵蓋帳戶切換、缺失欄位、跨執行觀察、模式撤銷、CLI 喚醒警告、通知重授權及簽章檢查。未向使用者的工作階段送訊。
- 正式 App 位於 `build/v0.1.1/Vibe Meter.app`，DMG 位於 `dist/Vibe-Meter-0.1.1.dmg`。打包驗證版本、Applications 捷徑、Finder 拖曳背景、指定圖示及 ad-hoc 簽章。仍在使用的 v0.1.0 由原位置執行。
- 隔離 Sparkle App 用一次性金鑰及 loopback 驗證實際替換與重啟。竄改 appcast、竄改 ZIP、錯 SHA-256、外站轉址、回覆安裝後的最後授權撤銷及未提交即退出，均保留原版，執行檔與 Info.plist 雜湊及簽章仍一致。測試伺服器發出的 Cookie 未被帶回。
- 以內嵌公開金鑰獨立驗證本機 `dist/appcast.xml`、`dist/Vibe-Meter-0.1.1.zip` 及 `dist/Vibe-Meter-0.1.1.dmg.sig`。唯讀掛載確認 ZIP 與 DMG 內的 App 一致，兩個 bridge 對虛構回報的 stderr 均空白。
- 獨立 demo app 使用同一套視窗及選單列浮窗，示範資料與外部操作隔離。

### 尚待完成或條件限制

- Codex 自動續作需要在中止時段觀察到同一登入帳戶的官方拒絕與可辨識的模型週期，並在重設後收到明確許可。可使用先前保存的觀察；全程未觀察到中止或官方欄位為空時會待確認。觀察無法證明歷史帳戶，也無法排除在兩次觀察之間的未見切換。CLI 無原子錨點比對與排入操作，最後一次預檢之後仍有外部競態。
- Claude Code 靜置、離線、未連接或未收到新的官方回報時，無法保證取得每 15 分鐘一筆的訂閱額度。此版未提供 Claude Code 自動續作。官方 StopFailure 只能回報錯誤，Routine API 啟動新的雲端工作階段，而個人方案規範禁止第三方代送。
- 自動安裝預設關閉。v0.1.0 需要手動升級。安裝 v0.1.1 後可開啟。正式 feed 尚未公開提供匿名存取，所需資產與簽署步驟在 `docs/PLAN.md`。新版本啟動後的健康檢查與自動回滾未實作。
- v0.1.1 供本機審閱。安裝包採 ad-hoc 簽章，Apple 公證尚待辦理。

## v0.1.1 安全審查後修訂（2026-11-13，Claude Code Opus 5.5 High）

依使用者要求與獨立安全審查（`/tmp/vibemeter-official-safety-advisory.md`）修訂。全部僅在本機；未 push、未發布、未修改 GitHub、未改動 `~/.claude/settings.json`。v0.1.0（`build/Vibe Meter.app`）持續運行，未觸碰。

### 已完成

- **Claude Code 續作改用官方原生功能**：已核實官方文件，Claude Code 2.1.234 起 claude.ai 訂閱互動式 session 預設 `autoContinueAtUsageLimit`，在原視窗等待並自行接續（最多 3 次）。Vibe Meter 只呈現能力、使用者設定檔的值（只讀這一鍵）、transcript 可觀察的中止／後續狀態、版本與 entrypoint 例外，並引導 `/config`、`/rate-limit-options`、`/usage`。Claude 不再建立續作計畫；`launchNow`、`addPlan`、`execute` 對 Claude 一律不送出；舊計畫載入時標為已略過。`claude -p` 探測程式與測試已刪除。曾開始撰寫的 Mods `$.prompt.submit` 原視窗注入（ClaudeWindowLink）未接線即移除。
- **Claude bridge**：每工作階段 `cost.total_api_duration_ms` 單調高水位；`flock` 序列化跨程序讀寫；重播、亂序、其他工作階段舊值、窗口消失都不更新；首次看到既有工作階段只在無資料時寫入並標為過期；讀取拒絕未來時間。`observedAt` 只代表 bridge 收到新資料的時間。設定指向的 bridge 不存在時提示重新連接。
- **實機診斷**：此 Mac 的 `~/.claude/settings.json` 沒有 statusLine／StopFailure，`bin/vibemeter-bridge` 不存在，因此 Claude 額度讀不到的直接原因是未連接，需使用者在 App 內重新連接（會詢問並備份）。
- **Codex 30 秒查詢**：只排程官方唯讀 `account/rateLimits/read`，與掃描／續作引擎分離；single-flight（計時器、開視窗、刷新共用）、generation 作廢舊結果、失敗退避 60→300 秒、離線不啟動子程序、睡眠暫停、喚醒 5 秒後重查、可關閉。失敗保留上次官方值並標示「不是目前剩餘」。
- **開視窗刷新**：選單列視窗出現或成為 key window 即重讀 bridge 並查 Codex；5 秒內重複開關不再查；完整刷新執行中只補跑一次。
- **修正既有崩潰**：`defaults.set(...suffix(300))` 存入 `ArraySlice`（非 property list）會丟 `NSInvalidArgumentException`；以 live 模式測試重現後改為 `Array`。正式 App 是否曾觸發未另行驗證。
- 新增 `scripts/build-demo.sh`（可重現的示範 App，無 Sparkle、無 bridge）。README（中／英）、`docs/PLAN.md` 第 7 節、`docs/RELEASE-NOTES-0.1.1.md`、`docs/vibe-meter-preview.png` 已更新。

### 測試結果

- `swift build` 通過；`env -u HEADROOM_LIVE_CODEX VIBEMETER_SPARKLE_XCFRAMEWORK=build/dependencies/Sparkle.xcframework swift test`：133 項通過（Core 111、UI 22），計時相關測試連跑 5 次穩定。新增涵蓋：重播／他工作階段舊值／200→100→200 高水位／窗口消失／舊版無 cost／50 執行緒並行寫入／未來時間；原生續作設定讀取、階段與例外；Codex 輪詢重疊觸發、停用後舊結果、失敗退避、離線、30 秒節奏、睡眠喚醒、開關、非 live／demo／dry-run 無副作用、讀取在主執行緒外、刷新合併；Claude 計畫永不送出。
- 實際建置的 bridge 以暫存 `VIBEMETER_HOME` 與虛構輸入跑 20 個並行程序：最終為最高計數的資料，亂序舊值被忽略，stderr 為空。未向任何真實 Claude／Codex 工作階段送出內容。

### 產物

- `build/v0.1.1/Vibe Meter.app`、`dist/Vibe-Meter-0.1.1.dmg`（ad-hoc，`build-dmg.sh` 驗證通過；SHA-256 見 `build-dmg.sh` 輸出）。`build/v0.1.1/Vibe Meter Demo.app` 由 `build-demo.sh` 重建。
- 先前簽署的 v0.1.1 資產（舊 DMG、`.dmg.sig`、ZIP、`appcast.xml`）已移到 `dist/superseded-2026-11-13/`，**不含本次修改，不可上傳**。

### 尚待完成

- **發布簽章**：需使用者以自己的離線私鑰執行 `./scripts/sign-release.sh /絕對路徑/私鑰 "$PWD/dist/Vibe-Meter-0.1.1.dmg" "$PWD/build/v0.1.1/Vibe Meter.app"`，產生新的 `.sig`、ZIP 與 appcast。本輪未搜尋或讀取私鑰。
- Claude 額度：需使用者重新連接狀態列；沒有新的 API 回應就沒有新數值，App 不會宣稱即時值。transcript 中原生等待標記格式未驗證，故不解析；無法確認原視窗生效設定或是否正在等待。
- 未在使用者真實選單列 App 上做點擊驗證（只做 SwiftUI 渲染預覽與單元／整合測試）。
- 使用者審核後才可 push 或建立 Release；Apple 公證仍待辦。

## v0.1.1 Codex 自動續作根因與回退流程（2026-11-13，Opus 5.5 High 接續 Sol 6.1 High）

全部僅在本機；未 push、未發布、未改 GitHub、未修改 `~/.claude/settings.json`。**使用者正在執行的是 `build/Vibe Meter.app` v0.1.0（未中斷、未替換），它仍有「永遠待確認」的舊缺陷；新行為要本機安裝 v0.1.1 才會生效。**

### 根因（以官方唯讀 RPC 與本機紀錄的欄位結構核對，未輸出 ID 或內容）

- 本機 codex-cli 0.167.0-alpha.3.2：`account/rateLimits/read` 回 `ordinaryUsageAllowed=true`、`accountId` 存在、`rateLimitsByLimitId` 只有 `codex` 一個桶，`normalModelSlug` 為 null。本機 13 個 `usageLimitExceeded` turn 皆為 `failed`、有整數 `completedAt`；rollout `turn_context` 有 `turn_id` 與 `model`。
- v0.1.0 要求永遠無來源的 `verifiedAccountAndModelAtBlock`。v0.1.1 早期版只在「slug 等於模型的桶」記錄拒絕，真實資料永遠不成立。
- 官方 `TurnError` 把多種 429 壓成 `usageLimitExceeded`，不帶失敗的 limit ID；`normalModelSlug` 只是額度別名的描述，官方整合測試也有多個 null slug 桶。**一般桶不能證明適用中止 turn 的模型**，故不以一般桶、百分比或時間授權自動送出。Codex 官方沒有內建「額度重設後自動繼續」（社群仍為功能請求），`codex queue` 文件也未承諾額度受限時的延後送達。

### Sol 6.1 High 接手期間的修改（已確認在 repo 中，測試通過）

- 帳本 v3：只認明確 `ordinaryUsageAllowed=false`、官方 `completedAt`、中止前已確認同帳戶、桶 ID＋slug 完全一致；連續拒絕合併，每週證據保留至重設後 12 小時，重啟可重建；null 許可清除帳本。
- 同工作階段新錨點取代未送出的舊計畫；已有計畫的工作階段優先重檢（8 天）。
- 送出前最近一次查詢若為 false／null／失敗／睡眠則否決；`spendControlReached` 停送；舊持久化旗標不再能授權。
- 30 秒查詢的取消排空改為單一保留 task（修正多呼叫崩潰）；app-server 與 `ProcessRunner` 改用 termination handler，修正 `waitUntilExit` 卡住；查詢加 `excludeResetCreditDetails`。
- `CodexReplayIntegrationTests`：真實 `AppModel`＋假 Python CLI（JSON-RPC 與 `queue --resume`）的情境測試。

### 本輪（Opus）

- **一般桶帳戶的回退流程**（不是全自動）：`CodexAutomationDiagnosis` 逐項顯示官方證據（中止、模型、帳戶、一般用量許可、額度桶對應、拒絕觀察）。同帳戶明確允許一般用量、候選桶（模型專屬，否則唯一的官方 `codex` 一般桶）的中止週期存在且未滿、有未來重設時間、無 spend control、已過預計重設時，提示「看起來可手動繼續」。通知只在系統接受後記錄；權限被拒、失敗、狀態改變可重試，同計畫不並發；重新授權通知時重試。
- **手動續作**：確認視窗一律提示無法保證不使用 credits 等付費用量，帳戶不同時另行警告。送出前檢查最新 turn 仍是錨點、偵測時觀察到的帳戶未變（不同則略過），並與自動送出共用跨程序的錨點記錄（同一中止最多送一次）；支援時以 `queue --resume` 排入原工作階段，不開新視窗。排入成功只標為已送出，官方新 turn 出現才標為已繼續。
- 審查補修：Claude bridge 的較舊 writer 不回退 metadata、數值未變只記活動時間、到期窗口保留／未到期缺窗口不沿用；transcript 只採同 session、非 sidechain、assistant 的額度錯誤；缺時間戳或未來時間不當倒數起點；不合理 reset 視為未知；設定只接受 JSON 布林；dry-run 不讀真實 Claude 設定；查詢失敗後的舊值不再作為即時依據；停用 Codex 時清除舊報表；離線開窗去抖與網路恢復重查。
- 示範資料改為一般桶形狀並顯示診斷；Codex 計畫列移到 Claude 原生續作說明之前。

### 測試

- `swift build`；`env -u HEADROOM_LIVE_CODEX VIBEMETER_SPARKLE_XCFRAMEWORK=build/dependencies/Sparkle.xcframework swift test`：**154 項通過**（Core 123、UI／E2E 31）；UI 套件連跑 3 次穩定。
- 假 CLI E2E 14 情境：模型專屬桶證據完整時恰送一次；null 許可、缺拒絕、一般桶、缺完成時間、帳戶缺口、未支援 CLI、撤銷、較新查詢否決等不送；`generalAssisted`（本帳戶形狀）自動 0 次、診斷正確、取消確認 0 次、確認後 `queue --resume` 恰 1 次、重刷不重送、新 turn 後標為已繼續。
- 協助流程單元測試：通知拒絕→授權、失敗→成功、並行只送一次、投遞前取消不送；空桶、空窗口、缺中止週期、無／過去重設、`codex_other`、重複一般桶、reached、spend control、週額滿、他模型專屬桶皆不提示；帳戶切換與檢查中取消不送；兩個 App 實例同一中止只送一次。
- 所有有副作用的測試都用假 app-server／假 CLI／臨時工作階段；未對使用者真實工作階段送出任何內容，未呼叫 reset-credit。

### 產物與簽章

- `build/v0.1.1/Vibe Meter.app`、`dist/Vibe-Meter-0.1.1.dmg`（ad-hoc，`build-dmg.sh` 驗證通過，SHA-256 `e46bf8578bad5fe89f421d428d96e4174358613b16939871c42f4a83e331c520`）、`build/v0.1.1/Vibe Meter Demo.app`、`docs/vibe-meter-preview.png`。
- **未產生發布簽章**：本輪不知道離線私鑰路徑，先前搜尋私鑰被 auto-review 拒絕，未再嘗試。請使用者自行執行 `./scripts/sign-release.sh /私鑰絕對路徑 "$PWD/dist/Vibe-Meter-0.1.1.dmg" "$PWD/build/v0.1.1/Vibe Meter.app"`。`dist/superseded-2026-11-13/` 的舊簽章資產不含本輪修改，不可上傳。

### 限制

- 一般桶帳戶無法無條件保證自動續作；只提供診斷、通知與一鍵手動送出。若 Codex 未來提供模型專屬桶或帶 limit ID 的失敗資訊，自動路徑即可成立。
- 帳戶連續性只靠 Vibe Meter 觀察（無法排除輪詢間 A→B→A 或同 workspace 換 user）。`queue --resume` 回傳成功可能只是排入；喚醒警告會標示。
- 未在使用者實際選單列 App 上點擊驗證；Apple 公證待辦。

## v0.1.1 重設＋30 秒及跨實例撤銷（2026-11-14）

- 一般 Codex 額度桶按使用者授權，在官方重設＋30 秒通過同帳戶、原模型、最新中止錨點、限定範圍與費用控制檢查後嘗試一次。等待期間採用官方更新的較晚重設。工作階段的自動嘗試記錄跨型態與重啟，下一次須先有明確手動續作。排入不等於已喚醒，須觀察到新的官方 turn 才顯示後續活動。
- 共用資料目錄的新版實例以同一檔案鎖保存設定與取消，並在鎖內核對授權、保留工作階段、認領中止錨點和同步啟動 CLI。關閉總開關、停用 Codex、關閉定時嘗試或變更範圍會使舊的自動授權失效，即使之後重新開啟。個別計畫取消會跨實例保留。共用政策已初始化後若消失或損毀，App 停止送出。CLI 啟動之後無法由 App 撤回。
- Claude Code 原視窗控制原生續作時點，Vibe Meter 被動顯示本機可觀察狀態。此版沒有 Claude Code 的重設＋30 秒計時或額外發送。
- `swift build` 與完整 Swift 測試通過（187 個測試宣告通過、1 個選用實機測試略過，另有參數化案例）。假 CLI 停在最後一次預檢時，由另一個 AppModel 操作。正常對照只送一次，撤銷、取消、設定關再開、政策遺失或損毀均未送出。取消後舊實例保存仍維持已取消；沒有啟動真實工作階段。
- 新 DMG 為 `dist/Vibe-Meter-0.1.1.dmg`，SHA-256 `f665af97c66b5d5ef966cb3fa1bd2e3fc66a1068338a9c51b9dda813706df794`。目前為本機 ad-hoc 審閱版。正式發布者簽章資產仍須使用者離線簽署，舊資產勿上傳。GitHub 未變更。
