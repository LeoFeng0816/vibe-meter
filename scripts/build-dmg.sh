#!/bin/zsh
# 產生 dist/Vibe-Meter-<版本>.dmg：內含 Vibe Meter.app、指向 /Applications 的連結與拖曳引導背景。
# 步驟可重現：重新建置 App → 產生背景 → 以雜湊鎖定的 dmgbuild 產生 DMG → 掛載驗證內容、版本、圖示與簽章。
# 注意：App 為 ad-hoc 簽章，未經 Apple Developer ID 簽署或公證（notarization）。
set -euo pipefail
cd "$(dirname "$0")/.."

# 發布版一律從乾淨狀態重建（避免殘留舊的中間檔）。
swift package clean
rm -rf "build/Vibe Meter.app" build/AppIcon.iconset
./scripts/build-app.sh
APP="build/Vibe Meter.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="dist/Vibe-Meter-$VERSION.dmg"
WORK=build/dmg
rm -rf "$WORK"; mkdir -p "$WORK" dist

# 背景（1x＋2x 合成 HiDPI TIFF）
swift scripts/make-dmg-background.swift "$WORK/background.png" "$WORK/background@2x.png" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null

# dmgbuild（純 Python、MIT），雜湊鎖定，只裝在 build/dmg-venv
if [[ ! -x build/dmg-venv/bin/dmgbuild ]]; then
  python3 -m venv build/dmg-venv
  build/dmg-venv/bin/python -m pip install --quiet --require-hashes --no-deps -r scripts/dmg-requirements.txt
fi

rm -f "$OUT"
build/dmg-venv/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" -D background="$WORK/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
  "Vibe Meter $VERSION" "$OUT" >/dev/null

# ---- 驗證 ----
hdiutil verify "$OUT" >/dev/null
echo "✓ hdiutil verify 通過"
MNT=$(mktemp -d "$PWD/build/dmg-mount.XXXX")
hdiutil attach "$OUT" -readonly -nobrowse -noautoopen -mountpoint "$MNT" >/dev/null
trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true' EXIT
MAPP="$MNT/Vibe Meter.app"
[[ -d "$MAPP" ]]
echo "✓ 內含 Vibe Meter.app"
[[ "$(readlink "$MNT/Applications")" == "/Applications" ]]
echo "✓ Applications → /Applications 連結"
[[ -f "$MNT/.background.tiff" && -f "$MNT/.VolumeIcon.icns" ]]
echo "✓ 背景圖與卷宗圖示"
build/dmg-venv/bin/python - "$MNT/.DS_Store" <<'PY'
import sys
from ds_store import DSStore
with DSStore.open(sys.argv[1], "r") as d:
    locs = {e.filename: e.value for e in d if e.code == b"Iloc"}
    icvp = next((e.value for e in d if e.filename == "." and e.code == b"icvp"), {})
ok = locs.get("Vibe Meter.app") == (165, 205) and locs.get("Applications") == (495, 205)
print(("✓" if ok else "✗") + f" 視窗版面（.DS_Store）圖示位置 {locs}")
print(("✓" if icvp.get("backgroundType") == 2 else "✗") + f" 背景圖設定 backgroundType={icvp.get('backgroundType')} iconSize={icvp.get('iconSize')}")
sys.exit(0 if ok and icvp.get("backgroundType") == 2 else 1)
PY
MVER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$MAPP/Contents/Info.plist")
MID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$MAPP/Contents/Info.plist")
[[ "$MVER" == "$VERSION" && "$MID" == "com.leofeng.vibemeter" ]]
echo "✓ 版本 $MVER（$MID）"
for file in Resources/AppIcon.icns MacOS/VibeMeter MacOS/vibemeter-bridge; do
  cmp "$MAPP/Contents/$file" "$APP/Contents/$file"
done
echo "✓ 圖示與兩個執行檔均與建置結果一致"
codesign --verify --deep --strict "$MAPP"
echo "✓ codesign --verify 通過（ad-hoc）"
codesign -dv "$MAPP" 2>&1 | grep -E "^(Signature|TeamIdentifier)=" | sed 's/^/  /'
if spctl --assess --type execute "$MAPP" 2>/dev/null; then
  echo "✓ Gatekeeper 接受"
else
  echo "ℹ︎ Gatekeeper 不接受（預期：未經 Apple 公證；如遭封鎖，從系統設定的「隱私權與安全性」允許此次開啟）"
fi
echo "SHA-256 $(shasum -a 256 "$OUT" | awk '{print $1}')"
echo "已產生 $OUT"
