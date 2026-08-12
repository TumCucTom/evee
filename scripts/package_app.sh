#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-release}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
binary_path="$bin_dir/Evee"
mcp_binary_path="$bin_dir/evee-mcp"
app_dir="$repo_root/dist/Evee.app"
contents="$app_dir/Contents"

if [[ "$app_dir" != "$repo_root/dist/Evee.app" ]]; then
  echo "Refusing to package to an unexpected destination" >&2
  exit 1
fi
rm -rf "$app_dir"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources"
install -m 755 "$binary_path" "$contents/MacOS/Evee"
install -m 755 "$mcp_binary_path" "$contents/Helpers/evee-mcp"

# SwiftPM dependencies may emit resource bundles beside the executable. Preserve all of
# them so the packaged app behaves like `swift run` instead of silently losing resources.
shopt -s nullglob
resource_bundles=("$bin_dir"/*.bundle)
for bundle in "${resource_bundles[@]}"; do
  ditto "$bundle" "$contents/Resources/$(basename "$bundle")"
done
shopt -u nullglob

cp /dev/stdin "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Evee</string>
  <key>CFBundleIdentifier</key><string>com.tumcuctom.evee</string>
  <key>CFBundleName</key><string>Evee</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Evee records your voice for dictation and meetings.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Evee can capture system audio for meetings when you enable it.</string>
</dict></plist>
PLIST

codesign --force --sign - "$contents/Helpers/evee-mcp"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
