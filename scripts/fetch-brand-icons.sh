#!/bin/zsh
# 從官方品牌素材頁下載 Cursor 與 Google Antigravity 的官方圖示，驗證 SHA-256 後縮成 256px，
# 放到 Resources/BrandIcons/（已列入 .gitignore，不隨儲存庫散布；建置時打包進 App）。
# 來源與使用限制見 docs/BRAND-ASSETS.md。Claude／Codex 圖示改由執行時讀取本機官方 App，不在此下載。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=Resources/BrandIcons
WORK=build/brand-downloads
CURSOR_ZIP_URL="https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/brand/cursor-brand-assets.zip"
CURSOR_ZIP_SHA="97488a7751914e60f9ff532bc33810cdeaebdddc017548abe6ca2bc29bbc3928"
AG_PNG_URL="https://www.antigravity.google/assets/image/brand/antigravity-icon__full-color.png"
AG_PNG_SHA="e0cd08ccd10cd8d08ccf0ba449823ee88495825c0841619618100d3ab089f51e"

verify() { # <file> <sha256>
  local actual
  actual=$(shasum -a 256 "$1" | awk '{print $1}')
  if [[ "$actual" != "$2" ]]; then
    echo "✗ $1 的 SHA-256 與記錄不符（$actual）。官方素材可能已更新，請人工確認後更新 docs/BRAND-ASSETS.md 與本腳本。" >&2
    return 1
  fi
}

rm -rf "$WORK"; mkdir -p "$WORK/cursor" "$WORK/antigravity" "$OUT"
curl -sfL --max-time 120 -o "$WORK/cursor/cursor-brand-assets.zip" "$CURSOR_ZIP_URL"
verify "$WORK/cursor/cursor-brand-assets.zip" "$CURSOR_ZIP_SHA"
curl -sfL --max-time 60 -o "$WORK/antigravity/antigravity-icon__full-color.png" "$AG_PNG_URL"
verify "$WORK/antigravity/antigravity-icon__full-color.png" "$AG_PNG_SHA"

# 只取出需要的兩個檔案，不解開整個壓縮檔。
unzip -p "$WORK/cursor/cursor-brand-assets.zip" "App Icons/PNG/APP_ICON_25D_LIGHT.png" > "$WORK/cursor/light.png"
unzip -p "$WORK/cursor/cursor-brand-assets.zip" "App Icons/PNG/APP_ICON_25D_DARK.png" > "$WORK/cursor/dark.png"

# 只縮放尺寸，不改動圖形與顏色。
sips -s format png -Z 256 "$WORK/cursor/light.png" --out "$OUT/cursor-light.png" >/dev/null
sips -s format png -Z 256 "$WORK/cursor/dark.png" --out "$OUT/cursor-dark.png" >/dev/null
sips -s format png -Z 256 "$WORK/antigravity/antigravity-icon__full-color.png" --out "$OUT/antigravity.png" >/dev/null

cat > "$OUT/SOURCES.txt" <<EOF
cursor-light.png  ← $CURSOR_ZIP_URL (App Icons/PNG/APP_ICON_25D_LIGHT.png)，來源頁 https://cursor.com/en-US/brand
cursor-dark.png   ← 同上 (App Icons/PNG/APP_ICON_25D_DARK.png)
antigravity.png   ← $AG_PNG_URL，來源頁 https://www.antigravity.google/press
下載時間：$(date -u +%Y-%m-%dT%H:%M:%SZ)；僅縮放為 256px，未修改圖形。用途與限制見 docs/BRAND-ASSETS.md。
EOF
echo "已更新 $OUT"
