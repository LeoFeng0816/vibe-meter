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

## 7. v0.1.1 本機審閱版

- **Claude Code 用量** 使用官方 statusLine 的 `rate_limits`。statusLine 也會因權限模式切換、`refreshInterval`、到達 `resets_at` 或畫面更新而重跑，這時資料仍是該工作階段上次 API 回應的值；到期窗口會被 CLI 移除。bridge 規則：每個工作階段保存 `cost.total_api_duration_ms` 的單調高水位，只有嚴格超過才寫入新快照；相同或較低計數（重播、晚結束的舊 script、其他工作階段的舊值）不更新數值或時間；第一次看到既有工作階段且沒有任何資料時才寫入，並標成「無法確認是否為舊值」（一律視為過期）；窗口消失不寫入，也不代表已恢復；讀取→判斷→寫入在 `claude/.bridge.lock` 的 `flock` 內完成。官方未保證此計數與伺服器額度採樣同步，所以 `observedAt` 只代表 bridge 收到新資料的時間，不作為官方採樣時間或恢復依據。讀取時拒絕未來時間。未找到個人訂閱 5 小時／每週額度的公開唯讀端點，`/usage` 是互動畫面；Vibe Meter 不使用 `claude -p` 或任何查詢探測（該模式可用 API key 計費）。冷啟、檔案監看與手動／開窗重讀維持原設計；設定指向的 bridge 執行檔不存在時會提示重新連接。本機診斷（2026-11-13）：`~/.claude/settings.json` 沒有 statusLine 與 StopFailure，`bin/vibemeter-bridge` 不存在，所以實機上「已連接」並不成立；需由使用者在 App 內重新連接。 [官方 statusLine](https://code.claude.com/docs/en/statusline#available-data) [官方用量說明](https://code.claude.com/docs/en/costs#when-the-usage-request-fails)
- **Claude Code 續作** 以官方原生 `autoContinueAtUsageLimit`（v2.1.234 起，claude.ai 訂閱互動式 session 預設開啟）為正向路徑：原視窗等待重設後由 Claude Code 自行接續，最多連續 3 次；Esc、送出新提示、`/login`、`/clear`、`/resume`、退出、設定關閉或重設超過 24 小時會結束或不開始等待；電腦睡超過約 30 分鐘且期間重設需按 Enter；`-p`、SDK、背景、API key、雲端與按量計費沒有等待。設定優先序為 managed、`--settings`、使用者設定，三者未設時 project／local 同名鍵會關閉功能。Vibe Meter 只讀使用者設定檔的這一個鍵並標為「使用者設定開啟／關閉／未設定」，從官方 transcript 讀中止訊息的 `version`、`entrypoint`、重設時間與之後是否有新對話，顯示「最後可觀察」狀態與例外提示，引導在原 CLI 用 `/config`、`/rate-limit-options`。不讀程序 argv／env、憑證或私有快取，不代跑 `/config`，不修改設定，不送出提示、不開新視窗、不取消原生等待，也無法確認原視窗的生效設定或是否正在等待。transcript 中原生等待標記的格式未經驗證，故不解析。舊 Claude 續作計畫載入時標為已略過；`launchNow`、`addPlan`、`execute` 對 Claude 一律不送出。曾短暫評估的 Mods `$.prompt.submit` 原視窗注入因會與原生等待重複、增加介入與隱私風險，已移除未接線的程式。探測（`claude -p`）程式碼已刪除。 [官方原生續作](https://code.claude.com/docs/en/interactive-mode#wait-for-a-usage-limit-to-reset) [設定參考](https://code.claude.com/docs/en/settings-reference#autocontinueatusagelimit)
- **Codex 30 秒額度查詢** 只排程官方唯讀 `account/rateLimits/read`，與工作階段掃描、thread RPC、通知與續作引擎（約 5 分鐘）分離。計時器、開視窗與刷新按鈕共用 single-flight：查詢進行中時其他要求等待同一結果，不另啟 app-server；開視窗 5 秒內重複不再查詢；完整刷新執行中再要求只補跑一次。每次 await 後依 generation、Codex 啟用、dry-run、demo、關閉狀態決定是否採用結果；停用、關閉輪詢、睡眠與結束會作廢進行中的查詢。單次逾時 10 秒；失敗間隔 60、120、240、最多 300 秒，成功恢復 30 秒；離線（NWPathMonitor）時不啟動子程序也不累積退避；喚醒後 5 秒再查。失敗時保留上次官方值與時間並標示「不是目前剩餘」，過期規則照常；沒有官方值時才顯示本機紀錄（不作續作依據）。官方 `account/rateLimits/updated` 通知未承諾獨立 app-server 能收到其他工作階段的更新，故不依賴。 [官方 Codex App Server](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
- **Antigravity** 官方 CLI statusLine JSON 提供 `product`、`quota`、`remaining_fraction`、`reset_time` 與 `disabled`。bridge 只解析上述必要欄位，不存 email、專案或對話資訊。已知的 `gemini-weekly` 顯示為每週，其他有效比例保留原 bucket 名；缺少總額的 `remaining_amount` 不換算百分比。現場 Desktop 2.31.0 的 AX 樹只呈現視窗外框，仍從 Settings › Models 查看 Desktop 用量；CLI 需另行安裝並由使用者設定。 [官方 CLI statusLine](https://antigravity.google/docs/cli/statusline) [官方 Plans](https://antigravity.google/docs/plans)
- **Cursor** 個人用量入口為編輯器設定或官方儀表板。公開 Teams Admin API 及 Cloud Agent API 的資料範圍不同；目前無公開的個人剩餘額度來源。 [Cursor 官方用量指南](https://cursor.com/help/models-and-usage/usage-limits)
- **一般額度重設＋30 秒嘗試（2026-11-14，使用者明確授權）** `CodexTimedResumePolicy` 與 `CodexQuotaObservations.bindTimed`：身分、時間邊界與官方路徑相同（中止前已確認同帳戶、官方 `completedAt`、中止前後 2 分鐘內的用盡觀察、許可非 null），只把額度對應放寬為官方唯一的一般 `codex` 桶；同模型別名有 0 個桶才適用，1 個走官方路徑，2 個以上為歧義不送。明確費用障礙（spend control、`workspace_owner/member_usage_limit_reached`、`workspace_owner/member_credits_depleted`）不記錄證據、不延期、不送。授權只存在記憶體，每次由帳本重建；計畫檔只保存可延後送出的已核對延期（`timedDeferredResetAt`，最多晚原重設 7 天，證據保留同步延長）。到期後以到期後取得的新鮮官方回應檢查同帳戶與非 null 許可（`false` 依授權仍嘗試一次；仍 100% 但無較晚有效重設也嘗試；有較晚有效重設則延期），最後讀最新 turn 與模型，以固定中性提示 `ResumePlan.timedAttemptPrompt` 經 `queue --resume` 送出。工作階段層級的跨程序原子保留在 `Codex Timed Sessions/`（`flock`，`version` 與 entry 驗證，損壞或不可讀即 fail closed）；送出後要使用者手動續作（以手動送出開始時間在鎖內比對）才解除後續自動嘗試，官方 turn 的進行中或完成都不解除。排程：睡眠計時器與實際檢查分離（以 ID 清除自身 handle），喚醒與網路恢復只查額度再評估，不等完整掃描。
- **一般額度桶帳戶（2026-11-13 實測）** codex-cli 0.167 對此 Mac 的 `account/rateLimits/read` 回 `ordinaryUsageAllowed=true`、有 `accountId`、只有 `rateLimitsByLimitId.codex` 一個桶且 `normalModelSlug` 為 null；本機 13 個 `usageLimitExceeded` turn 都有整數 `completedAt`。官方 `TurnError` 不帶造成失敗的 limit ID，`normalModelSlug` 只是額度別名的模型描述，官方整合測試也有多個 null slug 桶，因此一般桶不能證明適用中止 turn 的模型。自動授權只接受 slug 等於該模型的唯一桶（v3 帳本，見 `CodexQuotaObservations`）。一般桶帳戶改為：待確認並逐項診斷（`CodexAutomationDiagnosis`）；同帳戶明確允許一般用量、相關桶的中止週期存在且未滿、有未來重設時間、無 spend control、已過預計重設時，系統確實接受通知後才記錄並只通知一次；使用者確認（一律提示可能使用 credits）後，送出前再檢查最新 turn、帳戶與跨程序送出記錄，以 `queue --resume` 排入原工作階段。官方目前沒有 Codex 內建的額度重設後自動繼續（社群仍為功能請求），`queue` 文件也未承諾額度受限時的延後送達。 [Codex CLI queue](https://learn.chatgpt.com/docs/developer-commands#codex-queue) [功能請求](https://community.openai.com/t/feature-request-auto-resume-after-usage-limit/1397124)
- **Codex 續作** 預設自動，也可持久化限定指定帳戶雜湊、工作階段與模型。即使當前已恢復也查近期最新 turn，從 rollout 的 `turn_context` 綁定模型。可使用已保存的同帳戶官方拒絕觀察重建計畫，涵蓋重啟後才偵測到中止；觀察不是中止瞬間帳戶的證明。若沒有記錄拒絕、缺 `accountId`、`ordinaryUsageAllowed` 或 `normalModelSlug`，或比對不一致，需待確認。已觀察到的帳戶切換會清除舊觀察；監測間斷中的切換無法確認。
- **Codex 發送** 確認 CLI 支援 `queue --resume`，送出前重讀模型、目前帳戶和額度許可，最後重驗中止 turn 錨點。CLI 沒有以錨點為條件的原子 queue，App 無法排除最後一次檢查與 CLI 之間的外部操作。發送前保存計畫與同錨點原子記錄，逾時或結果不明不自動重試。CLI 結束成功或回報 warning 只代表已排入，另用官方新 turn 確認有後續活動。 [Codex CLI wake-up 說明](https://github.com/openai/codex/issues/54991)
- **保持清醒** 使用 IOKit idle assertion，可指定期限並獨立選擇顯示器，或由官方 Codex turn `inProgress` 觸發。長時間無新輸出的已知工作仍追蹤；未知或抽樣不完整不假定為閒置。關閉 App、到期、取消及無法確認活動時釋放。僅支援可辨識的 Codex 工作。
- **更新** 匿名 HTTPS 查 GitHub 正式 release，綁定 repo、tag 與 asset 名稱。DMG 驗大小、SHA-256 及發布者簽章，同目錄暫存校驗後才替換。另可開啟 Sparkle 2.10.0 簽章自動安裝。App 要求簽章 appcast、同一正式版本及確切 ZIP URL、大小與 SHA-256，解包前驗 Ed25519。下載限 GitHub 固定 HTTPS 路徑及檔案主機，使用無 Cookie／認證的工作階段。替換及重新啟動只在最後重查授權並明確提交後執行。送入安裝程序後不能撤回。隔離 App 驗證成功替換及重啟，也確認竄改 appcast、竄改 ZIP、錯 SHA-256、跨來源轉址、最後階段撤銷和未提交即退出均保留原 App。尚無新版本啟動後的健康檢查及自動回滾。發布後 feed 必須可匿名取得。私人／無正式版回 404，離線會報連線失敗。v0.1.0 尚無內建信任根，首次須手動安裝。 [Sparkle 發布文件](https://sparkle-project.org/documentation/publishing/)

- **跨實例續作撤銷** 共用資料目錄內的政策檔以 `flock` 序列化設定、單一計畫取消、發送保留與同步啟動 CLI。總開關、Codex 開關、定時模式或限定範圍變更會作廢較早的自動授權；關閉後重開亦作廢。個別取消依計畫及工作階段的中止錨點保存，其他實例載入或保存時仍維持取消。已啟動的 CLI 請求無法從 App 撤回。檔案缺失或損毀時，既有實例不送出。此同步邊界只涵蓋採用共用政策的新版與同資料目錄。

### 產生未上傳的發布資產

1. 執行 `./scripts/build-dmg.sh`。腳本驗證鎖定版本的 Sparkle 檔案雜湊，並將公開金鑰嵌入 App。
2. 在發布機上執行 `./scripts/sign-release.sh /絕對路徑/ed25519-signing-key /絕對路徑/Vibe-Meter-0.1.1.dmg '/絕對路徑/Vibe Meter.app'`。私鑰需要由目前帳戶持有且權限為 `0600`。腳本以明確的私鑰檔案簽章，產物為 DMG 旁的 `Vibe-Meter-0.1.1.dmg.sig`、`Vibe-Meter-0.1.1.zip` 與 `appcast.xml`。
3. 審核通過後，四個檔案放在同一個正式 `v0.1.1` GitHub Release。以匿名請求驗證 Latest Release API、`releases/latest/download/appcast.xml` 及 appcast 指定的版本化 ZIP。之後每個新版增加 `CFBundleVersion` 並使用同一個發布者私鑰簽章。私鑰應另外加密備份，保存在版本控制與發布範圍以外。遺失這把私鑰後，現有 ad-hoc 安裝需要手動升級以建立新信任根。
