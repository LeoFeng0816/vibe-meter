#!/bin/zsh
# 只產生本機正式資產。必須提供離線私鑰路徑，不使用 Keychain。
set -euo pipefail
cd "$(dirname "$0")/.."
private_key=${1:?用法：scripts/sign-release.sh /絕對路徑/ed25519-signing-key /絕對路徑/Vibe-Meter.dmg /絕對路徑/Vibe-Meter.app}
dmg=${2:?需要 DMG 路徑}
app=${3:?需要 App 路徑}
[[ "$private_key" == /* && -f "$private_key" && ! -L "$private_key" ]]
[[ "$(stat -f %Lp "$private_key")" == 600 && "$(stat -f %u "$private_key")" == "$(id -u)" ]]
[[ -f "$dmg" && -d "$app" ]]
plist="$app/Contents/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
build=$(plutil -extract CFBundleVersion raw "$plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' ]]
[[ "${dmg:t}" == "Vibe-Meter-$version.dmg" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == com.leofeng.vibemeter ]]
[[ "$(plutil -extract SUPublicEDKey raw "$plist")" == "$(cat Resources/Update/PublisherPublicKey.txt)" ]]
[[ "$(plutil -extract SURequireSignedFeed raw "$plist")" == true ]]
[[ "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$plist")" == true ]]
[[ "$(plutil -extract SUFeedURL raw "$plist")" == 'https://github.com/LeoFeng0816/vibe-meter/releases/latest/download/appcast.xml' ]]
codesign --verify --deep --strict "$app"
hdiutil verify "$dmg" >/dev/null
./scripts/fetch-sparkle.sh

signer=build/dependencies/sparkle-sign-update
work=$(mktemp -d "${dmg:h}/.vibemeter-signing.XXXXXX")
secret_dir=
mount_dir="$work/mount"
mounted=0
cleanup() {
  [[ -z "$secret_dir" ]] || rm -rf "$secret_dir"
  if (( mounted )); then hdiutil detach "$mount_dir" -quiet || return 1; fi
  rm -rf "$work"
}
trap cleanup EXIT
secret_dir=$(mktemp -d "${private_key:h}/.vibemeter-release-signing.XXXXXX")
snapshot="$secret_dir/key"
(umask 077; cat "$private_key" >"$snapshot")
# 同時確認私鑰正是 App 內嵌公鑰的配對，從未輸出私鑰。
if ! swift scripts/sign-dmg-digest.swift "$snapshot" Resources/Update/PublisherPublicKey.txt "$dmg" >"$work/${dmg:t}.sig" 2>"$secret_dir/signer.log"; then
  echo "無法使用指定私鑰簽署 DMG，請確認金鑰與內嵌公鑰相符。" >&2; exit 1
fi
mkdir "$mount_dir"
hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" >/dev/null
mounted=1
mounted_app="$mount_dir/Vibe Meter.app"
codesign --verify --deep --strict "$mounted_app"
cdhash() {
  codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p'
}
built_hash=$(cdhash "$app")
[[ -n "$built_hash" && "$built_hash" == "$(cdhash "$mounted_app")" ]]
zip_name="Vibe-Meter-$version.zip"
zip="$work/$zip_name"
ditto -c -k --keepParent "$mounted_app" "$zip"
hdiutil detach "$mount_dir" -quiet
mounted=0
if ! signature=$("$signer" --ed-key-file "$snapshot" -p "$zip" 2>"$secret_dir/signer.log"); then
  echo "無法簽署更新 ZIP。" >&2; exit 1
fi
[[ "$signature" =~ '^[A-Za-z0-9+/]{86}==$' ]]
length=$(stat -f %z "$zip")
(( length > 0 && length <= 128 * 1024 * 1024 ))
feed="$work/appcast.xml"
cat >"$feed" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Vibe Meter</title>
    <item>
      <title>Vibe Meter $version</title>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/LeoFeng0816/vibe-meter/releases/download/v$version/$zip_name" length="$length" type="application/octet-stream" sparkle:edSignature="$signature" />
    </item>
  </channel>
</rss>
XML
if ! "$signer" --ed-key-file "$snapshot" "$feed" >"$secret_dir/signer.log" 2>&1 ||
   ! "$signer" --verify --ed-key-file "$snapshot" "$zip" "$signature" >"$secret_dir/signer.log" 2>&1 ||
   ! "$signer" --verify --ed-key-file "$snapshot" "$feed" >"$secret_dir/signer.log" 2>&1; then
  echo "無法簽署或驗證 appcast／ZIP。" >&2; exit 1
fi
for artifact in "$zip_name" appcast.xml "${dmg:t}.sig"; do
  mv "$work/$artifact" "${dmg:h}/$artifact"
done
echo "已在 DMG 同目錄產生 $zip_name、appcast.xml 與 ${dmg:t}.sig。"
