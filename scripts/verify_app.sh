#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="${1:-$repo_root/dist/Evee.app}"
verification_root="$(mktemp -d /tmp/evee-verifier.XXXXXX)"
cleanup() {
  local exit_code=$?
  trap - EXIT
  chmod -R u+rwX "$verification_root" 2>/dev/null || true
  rm -rf "$verification_root"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

test -d "$app_dir"
if [[ -L "$app_dir" ]] || find "$app_dir" -type l -print -quit | grep -q .; then
  echo "The app bundle contains an unexpected symbolic link" >&2
  exit 1
fi

foundation_home="$verification_root/FoundationHome"
relocated_app="$verification_root/Installed/Evee.app"
captured_stdout="$verification_root/stdout.log"
captured_stderr="$verification_root/stderr.log"
mkdir -p "$foundation_home" "$(dirname "$relocated_app")"
ditto "$app_dir" "$relocated_app"

contents="$relocated_app/Contents"
main_executable="$contents/MacOS/Evee"
mcp_executable="$contents/Helpers/evee-mcp"
test -x "$main_executable"
test -x "$mcp_executable"
test -f "$contents/Info.plist"
test -f "$contents/Resources/Evee.icns"
test -s "$contents/Resources/.evee-resource-seal.sha256"
test "$(find "$contents/Resources" -maxdepth 1 -type d -name '*.bundle' | wc -l | tr -d ' ')" -gt 0

plutil -lint "$contents/Info.plist" >/dev/null
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$contents/Info.plist")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$contents/Info.plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$contents/Info.plist")"
test "$bundle_identifier" = "com.tumcuctom.evee"
test "$minimum_system" = "14.0"
[[ "$short_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]
[[ "$build_version" =~ ^[1-9][0-9]*$ ]]

codesign --verify --strict --verbose=2 "$relocated_app" >/dev/null 2>/dev/null
codesign --verify --strict --verbose=2 "$mcp_executable" >/dev/null 2>/dev/null
entitlements_plist="$verification_root/entitlements.plist"
codesign -d --entitlements :- --xml "$relocated_app" >"$entitlements_plist" 2>/dev/null
/usr/bin/plutil -lint "$entitlements_plist" >/dev/null
audio_entitlement="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements_plist")"
test "$audio_entitlement" = "true"

while IFS= read -r dependency; do
  case "$dependency" in
    *"not found"*) echo "Unresolved packaged dependency" >&2; exit 1 ;;
    *"$repo_root"*|*"/.build/"*) echo "Packaged executable retains a build-tree dependency" >&2; exit 1 ;;
  esac
done < <(otool -L "$main_executable"; otool -L "$mcp_executable")

result_path="$verification_root/self-test-result.json"
HOME="$foundation_home" CFFIXED_USER_HOME="$foundation_home" EVEE_SELF_TEST_RESULT_PATH="$result_path" \
  "$main_executable" --installation-self-test >>"$captured_stdout" 2>>"$captured_stderr"
test "$(cat "$result_path")" = '{"status":"passed"}'
test ! -e "$foundation_home/Library/Application Support/Evee"

swift build --product evee-verification-fixture >/dev/null
bin_dir="$(swift build --show-bin-path)"
fixture_seeder="$bin_dir/evee-verification-fixture"
test -x "$fixture_seeder"
"$fixture_seeder" --home "$foundation_home" >>"$captured_stdout" 2>>"$captured_stderr"
python3 "$repo_root/scripts/verify_mcp_tools.py" --helper "$mcp_executable" --home "$foundation_home" >>"$captured_stdout" 2>>"$captured_stderr"

for private_value in "$HOME" "$CFFIXED_USER_HOME" "$repo_root" "$verification_root" '/.build/'; do
  if [[ -n "$private_value" ]] && grep -F -q -- "$private_value" "$captured_stdout" "$captured_stderr"; then
    echo "Verification output contained a private path" >&2
    exit 1
  fi
done
if grep -E -qi 'api\.token|REAL-DATA-SENTINEL-DO-NOT-READ|token|webhookSecret' "$captured_stdout" "$captured_stderr"; then
  echo "Verification output contained private fixture data" >&2
  exit 1
fi

echo "Verified isolated relocated bundle $app_dir"
