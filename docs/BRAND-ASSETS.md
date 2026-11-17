# 各 agent 官方圖示：來源、取得方式與使用限制

整理日期：2026-11-09。Vibe Meter 只用這些圖示**標示「這一列是哪個 agent」**（指稱性使用），不當作 Vibe Meter 自己的 App 圖示或名稱，也不暗示與這些公司有合作或背書。Vibe Meter 自己的 App 圖示是使用者指定的 `Resources/AppIcon/VibeMeter-AppIcon.png`。

| Agent | 取得方式 | 官方來源 | 顯示處理 |
|---|---|---|---|
| Claude Code | 執行時讀取本機官方 App 的圖示（不散布檔案） | `/Applications/Claude.app`（`com.anthropic.claudefordesktop`） | 原樣顯示 |
| Codex | 執行時讀取本機官方 App 內附檔案（不散布檔案） | `com.openai.codex` App 的 `Contents/Resources/icon-codex-light.png`、`icon-codex-dark-color.png` | 原樣顯示，依淺色／深色切換 |
| Cursor | 建置時下載（`scripts/fetch-brand-icons.sh`），驗證 SHA-256 | 官方品牌頁 <https://cursor.com/en-US/brand> → 品牌素材 ZIP `cursor-brand-assets.zip`（SHA-256 `97488a77…3928`）內 `App Icons/PNG/APP_ICON_25D_LIGHT.png`、`APP_ICON_25D_DARK.png` | 縮成 256px；以 macOS 圓角遮罩顯示（此素材為滿版方形 App 圖示），圖形與顏色不變 |
| Google Antigravity | 建置時下載，驗證 SHA-256 | 官方媒體素材頁 <https://www.antigravity.google/press> → 「Icon – Full Color」PNG `antigravity-icon__full-color.png`（SHA-256 `e0cd08cc…f51e`） | 縮成 256px；透明背景的標誌放在中性白（深色模式為深灰）圓角底板上，標誌本身不變 |

若本機有安裝 Cursor 或 Antigravity 的官方 App，會優先使用該 App 自己的圖示。

## 取得與打包
- `scripts/fetch-brand-icons.sh`：從上表的官方網址下載、比對 SHA-256、只取出需要的檔案並縮放，放到 `Resources/BrandIcons/`（附 `SOURCES.txt`）。官方素材若更新、雜湊不符，腳本會停止，需要人工確認後再更新雜湊。
- `Resources/BrandIcons/` 已列入 `.gitignore`，**不隨儲存庫散布**這些商標圖檔。`scripts/build-app.sh` 缺檔時會自動執行下載，並把圖檔複製到 `Vibe Meter.app/Contents/Resources/BrandIcons/`。
- 取不到任何官方圖示時，介面顯示虛線外框的字母標記，並註明「未取得官方圖示」，不會用通用符號冒充。

## 官方指引與限制（實際查到的內容）
- **Cursor**：品牌頁提供 logo、App Icon 與 Avatar 的公開下載，說明這些是用來「一致且正確地呈現 Cursor」的資源，並要求稱呼為「Cursor」（不要寫成 Cursor AI／Cursor Code）。頁面與 ZIP 都**沒有附明確的授權條款**。本專案遵守：名稱寫作「Cursor」、使用官方 App Icon、不修改圖形。
- **Google Antigravity**：媒體素材頁提供 icon／lockup／wordmark 的 PNG、SVG 與 ZIP。素材頁、ZIP 與 Terms 頁都**沒有找到明確的授權文字**。Google 的一般品牌規範表示：Google 品牌元素只能依其指引用於核准的用途；可以說明產品與 Google 產品相容，但不得把 Google 產品圖示放進自己的 App 圖示或名稱。超出指引的用途，需透過 Google Brand Permissions 表單申請。本專案只把圖示放在 Antigravity 那一列作為識別，而且 Vibe Meter 並不讀取 Antigravity 的資料（該列明確標示「沒有可靠的官方用量來源」）。
- **結論**：目前用途是個人工具中的指稱性識別，沒有發現明確的授權障礙。但兩家都沒有提供正式授權文字，若 Vibe Meter 要**公開發布或商業散布**，建議先確認 Cursor 的品牌使用政策，並向 Google 申請品牌許可；或改成只在執行時讀取使用者已安裝 App 的圖示。

## 參考
- Cursor Brand：<https://cursor.com/en-US/brand>
- Google Antigravity Press：<https://www.antigravity.google/press>
- Google 開發者品牌元素指引：<https://about.google/brand-resource-center/guidance/apis>
- Google Brand Permissions 申請：<https://support.google.com/contact/brand_request_form>
