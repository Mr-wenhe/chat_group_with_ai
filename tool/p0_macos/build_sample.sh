#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
variant="${1:-bug}"
case "$variant" in
  bug) flags=(-D P0_BUG); version=1 ;;
  fixed) flags=(-D P0_FIXED); version=2 ;;
  *) echo 'usage: bash tool/p0_macos/build_sample.sh bug|fixed' >&2; exit 2 ;;
esac
bundle="$PWD/build/p0_macos/$variant/P0Sample.app"
mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.chatgroup.p0.sample</string>
<key>CFBundleExecutable</key><string>P0Sample</string>
<key>CFBundleName</key><string>P0Sample</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>ChatGroupTestDataEnvironment</key><string>CHAT_GROUP_TEST_DATA_DIR</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleShortVersionString</key><string>1.0.$version</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
xcrun swiftc "${flags[@]}" tool/p0_macos/Sample.swift -o "$bundle/Contents/MacOS/P0Sample"
codesign --force --sign - "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
codesign --verify --strict "$bundle"
test -x "$bundle/Contents/MacOS/P0Sample"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" = com.chatgroup.p0.sample
shasum -a 256 "$bundle/Contents/MacOS/P0Sample"
