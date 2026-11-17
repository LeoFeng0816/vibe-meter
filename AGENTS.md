# AGENTS.md — Vibe Meter

- 繁體中文溝通；技術名稱維持原文。開始前先讀 `HANDOFF.md` 與 `docs/PLAN.md`。
- 建置／測試：`swift build && swift test`；打包：`./scripts/build-app.sh`。
- 不沿用舊 Vibe Meter／Terra 程式碼。依使用者要求，本專案（對外名稱 Vibe Meter，開發期曾名 Headroom）放在既有的 `LeoFeng0816/vibe-meter` 儲存庫；部署或後續 push 須有使用者指示。
- 不可捏造用量：無可靠來源就顯示未連接／不支援。新資料來源要寫進 `docs/PLAN.md` 並附測試。
- Codex app-server 只能呼叫 `CodexAppServerClient.allowedMethods`（唯讀的 `account/rateLimits/read`、`thread/turns/list`、`thread/read`）；禁止 `account/rateLimitResetCredit/consume` 與任何寫入方法。
- Codex 自動續作須確認同一工作階段的官方額度失敗、原模型及相關週期的明確恢復許可。依使用者對 v0.1.1 的明示授權，可用中止時段同一登入帳戶的官方拒絕觀察與目前帳戶比對。此觀察無法證明歷史帳戶。缺欄位或發現帳戶切換時標成待確認，不可只靠時間或百分比。
- 不讀 Keychain、cookie、OAuth token。修改 `~/.claude/settings.json` 只能經使用者在 App 內確認，且需先備份。
- 工作結束更新 `HANDOFF.md`（已完成、未完成、測試結果、下一步）。
