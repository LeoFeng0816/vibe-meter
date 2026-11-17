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
