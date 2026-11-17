#!/bin/zsh
# 建置 build/v0.1.1/Vibe Meter.app（release、ad-hoc 簽章）。不安裝、不發布。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
APP="build/v0.1.1/Vibe Meter.app"
./scripts/fetch-sparkle.sh
export VIBEMETER_SPARKLE_XCFRAMEWORK=build/dependencies/Sparkle.xcframework
SPARKLE_FRAMEWORK="$VIBEMETER_SPARKLE_XCFRAMEWORK/macos-$(uname -m)/Sparkle.framework"
publisher_key=$(cat Resources/Update/PublisherPublicKey.txt)
[[ "$publisher_key" =~ '^[A-Za-z0-9+/]{43}=$' ]]
swift build -c "$CONFIG" --product VibeMeter
swift build -c "$CONFIG" --product vibemeter-bridge
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VibeMeter" "$APP/Contents/MacOS/VibeMeter"
cp "$BIN/vibemeter-bridge" "$APP/Contents/MacOS/vibemeter-bridge"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp build/dependencies/Sparkle-LICENSE.txt "$APP/Contents/Resources/Sparkle-LICENSE.txt"

# Cursor／Antigravity 官方圖示（來源與限制見 docs/BRAND-ASSETS.md；不在 git 中，缺少時從官方網址下載並驗證）
if [[ ! -f Resources/BrandIcons/cursor-light.png || ! -f Resources/BrandIcons/antigravity.png ]]; then
  ./scripts/fetch-brand-icons.sh || echo "⚠︎ 無法取得 Cursor／Antigravity 官方圖示，App 會改顯示文字標記" >&2
fi
if [[ -d Resources/BrandIcons ]]; then
  mkdir -p "$APP/Contents/Resources/BrandIcons"
  cp Resources/BrandIcons/*.png Resources/BrandIcons/SOURCES.txt "$APP/Contents/Resources/BrandIcons/" 2>/dev/null || true
fi

# App icon：使用者指定的 Resources/AppIcon/VibeMeter-AppIcon.png（原圖不修改），產生各尺寸後打包成 AppIcon.icns。
ICON_SRC=Resources/AppIcon/VibeMeter-AppIcon.png
ICONSET=build/v0.1.1/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -s format png -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -s format png -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.leofeng.vibemeter</string>
  <key>CFBundleName</key><string>Vibe Meter</string>
  <key>CFBundleDisplayName</key><string>Vibe Meter</string>
  <key>CFBundleExecutable</key><string>VibeMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

plist="$APP/Contents/Info.plist"
plutil -insert SUPublicEDKey -string "$publisher_key" "$plist"
plutil -insert SUFeedURL -string "https://github.com/LeoFeng0816/vibe-meter/releases/latest/download/appcast.xml" "$plist"
plutil -insert SURequireSignedFeed -bool YES "$plist"
plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$plist"
plutil -insert SUEnableAutomaticChecks -bool NO "$plist"
plutil -insert SUAllowsAutomaticUpdates -bool NO "$plist"
plutil -insert SUEnableSystemProfiling -bool NO "$plist"

# 移除 debug symbol stabs（OSO／SO 等，含建置者的本機絕對路徑）。只用 -S：保留動態連結所需的一般符號。
for exe in "$APP/Contents/MacOS/VibeMeter" "$APP/Contents/MacOS/vibemeter-bridge"; do
  strip -S "$exe"
  if nm -a "$exe" | grep -E " (OSO|SO|SOL|BINCL|EINCL|FUN|STSYM|LCSYM|GSYM|BNSYM|ENSYM) " >/dev/null; then
    echo "✗ $exe 仍含 debug stabs" >&2; exit 1
  fi
done
# 整個 App 不得含建置者的家目錄或專案路徑。
for needle in "$HOME" "$PWD"; do
  if LC_ALL=C grep -ralF -- "$needle" "$APP" >/dev/null 2>&1; then
    echo "✗ App 內含建置者路徑：$(LC_ALL=C grep -ralF -- "$needle" "$APP" | head -3)" >&2; exit 1
  fi
done

codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "已建置 $APP"
