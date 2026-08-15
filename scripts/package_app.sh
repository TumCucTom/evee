#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-release}"
version="${EVEE_VERSION:-0.2.0}"
build_number="${EVEE_BUILD_NUMBER:-2}"
build_jobs="${SWIFT_BUILD_JOBS:-2}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]; then
  echo "EVEE_VERSION must be a semantic version such as 1.2.3" >&2
  exit 64
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "EVEE_BUILD_NUMBER must be a positive integer" >&2
  exit 64
fi

swift build -c "$configuration" --product Evee --jobs "$build_jobs"
swift build -c "$configuration" --product evee-mcp --jobs "$build_jobs"
bin_dir="$(swift build -c "$configuration" --jobs "$build_jobs" --show-bin-path)"
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

icon_work="$(mktemp -d)"
trap 'rm -rf "$icon_work"' EXIT
swiftc Sources/EveeCore/Design/EveeMarkGeometry.swift scripts/generate_app_icon.swift -o "$icon_work/evee-icon-generator"
mkdir -p "$icon_work/Evee.iconset"
for points in 16 32 128 256 512; do
  pixels="$points"
  retina="$((points * 2))"
  "$icon_work/evee-icon-generator" "$icon_work/Evee.iconset/icon_${points}x${points}.png" "$pixels"
  "$icon_work/evee-icon-generator" "$icon_work/Evee.iconset/icon_${points}x${points}@2x.png" "$retina"
done
iconutil -c icns "$icon_work/Evee.iconset" -o "$contents/Resources/Evee.icns"

# SwiftPM dependencies may emit resource bundles beside the executable. Preserve all of
# them so the packaged app behaves like `swift run` instead of silently losing resources.
shopt -s nullglob
resource_bundles=("$bin_dir"/*.bundle)
for bundle in "${resource_bundles[@]}"; do
  ditto "$bundle" "$contents/Resources/$(basename "$bundle")"
done
shopt -u nullglob

# Record every packaged resource before signing. Code signing seals these files
# as well, while this portable digest makes omissions and post-build corruption
# explicit during verification and installation self-test runs.
resource_seal="$contents/Resources/.evee-resource-seal.sha256"
(
  cd "$contents/Resources"
  while IFS= read -r resource; do
    shasum -a 256 "$resource"
  done < <(find . -type f ! -name '.evee-resource-seal.sha256' -print | LC_ALL=C sort)
) | sed 's#  \./#  #' >"$resource_seal"
test -s "$resource_seal"

cp /dev/stdin "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Evee</string>
  <key>CFBundleIdentifier</key><string>com.tumcuctom.evee</string>
  <key>CFBundleName</key><string>Evee</string>
  <key>CFBundleIconFile</key><string>Evee</string>
  <key>CFBundleShortVersionString</key><string>0.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Evee records your voice for dictation and meetings.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Evee can capture system audio for meetings when you enable it.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents/Info.plist"

signing_identity="${EVEE_CODESIGN_IDENTITY:--}"
codesign_arguments=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  codesign_arguments+=(--options runtime --timestamp)
fi
codesign "${codesign_arguments[@]}" "$contents/Helpers/evee-mcp"
codesign "${codesign_arguments[@]}" --entitlements "$repo_root/Evee.entitlements" "$app_dir"
echo "$app_dir"
