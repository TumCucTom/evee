#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-release}"
swift build -c "$configuration"

binary_path="$(swift build -c "$configuration" --show-bin-path)/Evee"
app_dir="dist/Evee.app"
contents="$app_dir/Contents"

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_path" "$contents/MacOS/Evee"

cp /dev/stdin "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Evee</string>
  <key>CFBundleIdentifier</key><string>com.tumcuctom.evee</string>
  <key>CFBundleName</key><string>Evee</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Evee records your voice for dictation and meetings.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Evee can capture system audio for meetings when you enable it.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
