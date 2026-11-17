#!/bin/zsh
# 以真實 SwiftUI 選單畫面＋範例資料輸出介面預覽（非螢幕截圖），不含任何使用者真實資料。
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Resources/BrandIcons/cursor-light.png ]] || ./scripts/fetch-brand-icons.sh
swift build --product vibemeter-preview
VIBEMETER_BRAND_DIR="$PWD/Resources/BrandIcons" "$(swift build --show-bin-path)/vibemeter-preview" docs/vibe-meter-preview.png Resources/AppIcon/VibeMeter-AppIcon.png
