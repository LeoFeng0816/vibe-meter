#!/bin/zsh
# Pinned official Sparkle tools and source. Build the framework with Vibe Meter's download policy.
set -euo pipefail
cd "$(dirname "$0")/.."
base=build/dependencies
version=2.10.0
mkdir -p "$base"

fetch() {
  local archive="$1" expected="$2" url="$3" temporary
  if [[ ! -f "$archive" ]]; then
    temporary=$(mktemp "$base/.sparkle-download.XXXXXX")
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 --max-time 90 "$url" -o "$temporary" ||
       [[ "$(shasum -a 256 "$temporary" | cut -d ' ' -f1)" != "$expected" ]]; then
      rm -f "$temporary"
      return 1
    fi
    mv "$temporary" "$archive"
  fi
  [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f1)" == "$expected" ]]
}

tools_zip="$base/Sparkle-for-Swift-Package-Manager-$version.zip"
source_tgz="$base/Sparkle-source-$version.tar.gz"
# SwiftPM archive digest comes from Sparkle's 2.10.0 Package.swift.
fetch "$tools_zip" 17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-for-Swift-Package-Manager.zip"
fetch "$source_tgz" cf43af1f26a921a8dc0be80834b9c3038bea5fd645708d26375126cbc57c316b \
  "https://codeload.github.com/sparkle-project/Sparkle/tar.gz/refs/tags/$version"

patch_file=scripts/sparkle-anonymous-download.patch
patch_id=$(shasum -a 256 "$patch_file" | cut -d ' ' -f1)
source_dir="$base/Sparkle-$version-$patch_id"
if [[ ! -d "$source_dir" ]]; then
  source_stage=$(mktemp -d "$base/.sparkle-source.XXXXXX")
  trap 'rm -rf "$source_stage"' EXIT
  tar -xf "$source_tgz" -C "$source_stage" --strip-components=1
  patch -d "$source_stage" -p1 < "$patch_file" >&2
  mv "$source_stage" "$source_dir"
fi

xcodebuild -project "$source_dir/Sparkle.xcodeproj" -scheme Sparkle -configuration Release \
  -derivedDataPath "$PWD/$base/sparkle-derived" -disableAutomaticPackageResolution \
  -destination 'generic/platform=macOS' ARCHS="$(uname -m)" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  -quiet build >&2
framework="$base/sparkle-derived/Build/Products/Release/Sparkle.framework"
codesign --verify --deep --strict "$framework"

unpack=$(mktemp -d "$base/.sparkle-unpack.XXXXXX")
trap 'rm -rf "$unpack"' EXIT
ditto -x -k "$tools_zip" "$unpack"
cp "$unpack/LICENSE" "$base/Sparkle-LICENSE.txt"
cp "$unpack/bin/sign_update" "$base/sparkle-sign-update"
codesign --verify --strict "$base/sparkle-sign-update"

xcodebuild -create-xcframework -framework "$framework" -output "$unpack/Sparkle-patched.xcframework" >&2
rm -rf "$base/Sparkle.xcframework"
mv "$unpack/Sparkle-patched.xcframework" "$base/Sparkle.xcframework"
