#!/usr/bin/env bash
set -euo pipefail

app_dir="${1:-dist/Evee.app}"
contents="$app_dir/Contents"
main_executable="$contents/MacOS/Evee"
mcp_executable="$contents/Helpers/evee-mcp"

test -d "$app_dir"
test -x "$main_executable"
test -x "$mcp_executable"
test -f "$contents/Info.plist"
test -f "$contents/Resources/Evee.icns"
root_resource_count="$(find "$app_dir" -maxdepth 1 -type d -name '*.bundle' | wc -l | tr -d ' ')"
test "$root_resource_count" -gt 0

plutil -lint "$contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app_dir"
entitlements_plist="$(mktemp)"
codesign -d --entitlements :- --xml "$app_dir" >"$entitlements_plist" 2>/dev/null
/usr/bin/plutil -lint "$entitlements_plist"
audio_entitlement="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements_plist")"
test "$audio_entitlement" = "true"

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
test "$bundle_identifier" = "com.tumcuctom.evee"

# Exercise a real MCP handshake, tool discovery and data-backed call from the
# moved helper instead of treating EOF as proof of protocol correctness.
mcp_output="$(mktemp)"
cleanup_paths=("$mcp_output" "$entitlements_plist")
trap 'rm -rf "${cleanup_paths[@]}"' EXIT
tool_names=(search recent_activity ambient_timeline ambient_app_usage get_context get_journal get_dictation get_meeting get_memo get_stats get_config)
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  request_id=10
  for tool_name in "${tool_names[@]}"; do
    printf '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "$request_id" "$tool_name"
    request_id=$((request_id + 1))
  done
} | "$mcp_executable" >"$mcp_output"
grep -q '"protocolVersion"' "$mcp_output"
grep -q '"name":"search"' "$mcp_output"
if grep -q '"error"' "$mcp_output"; then
  echo "At least one packaged MCP protocol call failed" >&2
  cat "$mcp_output" >&2
  exit 1
fi
for request_id in $(seq 10 20); do
  grep -q "\"id\":$request_id" "$mcp_output"
done

while IFS= read -r dependency; do
  case "$dependency" in
    *"not found"*)
      echo "Unresolved dependency: $dependency" >&2
      exit 1
      ;;
  esac
done < <(otool -L "$main_executable"; otool -L "$mcp_executable")

# Launch the app after moving it away from the SwiftPM build tree and require
# its bundled persistence, search, privacy and helper self-test to complete.
smoke_root="$(mktemp -d)"
cleanup_paths+=("$smoke_root")
ditto "$app_dir" "$smoke_root/Evee.app"
"$smoke_root/Evee.app/Contents/MacOS/Evee" --installation-self-test >"$smoke_root/stdout.log" 2>"$smoke_root/stderr.log"
grep -q 'installation self-test passed' "$smoke_root/stdout.log"

echo "Verified $app_dir"
