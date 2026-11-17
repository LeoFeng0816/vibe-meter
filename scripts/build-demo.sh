#!/bin/zsh
# 建置獨立示範 App：build/v0.1.1/Vibe Meter Demo.app。只顯示虛構資料（VibeMeterDemoOnly），
# 不含 Sparkle 與 bridge，不讀寫使用者資料、不查詢任何服務、不送出任何訊息。不安裝、不發布。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/v0.1.1/Vibe Meter Demo.app"
SCRATCH=build/demo-build
# 不設定 VIBEMETER_SPARKLE_XCFRAMEWORK，產生不連結 Sparkle 的執行檔；使用獨立暫存路徑，不影響正式建置。
env -u VIBEMETER_SPARKLE_XCFRAMEWORK swift build -c release --product VibeMeter --scratch-path "$SCRATCH"
BIN=$(env -u VIBEMETER_SPARKLE_XCFRAMEWORK swift build -c release --scratch-path "$SCRATCH" --show-bin-path)
if otool -L "$BIN/VibeMeter" | grep -q Sparkle; then echo "✗ 示範執行檔不應連結 Sparkle" >&2; exit 1; fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VibeMeter" "$APP/Contents/MacOS/VibeMeter"
[[ -f build/v0.1.1/AppIcon.iconset/icon_512x512@2x.png ]] || ./scripts/build-app.sh
iconutil -c icns build/v0.1.1/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
if [[ -d Resources/BrandIcons ]]; then
  mkdir -p "$APP/Contents/Resources/BrandIcons"
  cp Resources/BrandIcons/*.png Resources/BrandIcons/SOURCES.txt "$APP/Contents/Resources/BrandIcons/" 2>/dev/null || true
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.leofeng.vibemeter.demo.v011</string>
  <key>CFBundleName</key><string>Vibe Meter Demo</string>
  <key>CFBundleDisplayName</key><string>Vibe Meter Demo</string>
  <key>CFBundleExecutable</key><string>VibeMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>VibeMeterDemoOnly</key><true/>
</dict>
</plist>
PLIST
strip -S "$APP/Contents/MacOS/VibeMeter"
for needle in "$HOME" "$PWD"; do
  if LC_ALL=C grep -ralF -- "$needle" "$APP" >/dev/null 2>&1; then echo "✗ 示範 App 內含建置者路徑" >&2; exit 1; fi
done
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "已建置 $APP"
