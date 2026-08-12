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

plutil -lint "$contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app_dir"

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
test "$bundle_identifier" = "com.tumcuctom.evee"

# Exercise a real MCP handshake, tool discovery and data-backed call from the
# moved helper instead of treating EOF as proof of protocol correctness.
mcp_output="$(mktemp)"
cleanup_paths=("$mcp_output")
trap 'rm -rf "${cleanup_paths[@]}"' EXIT
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_config","arguments":{}}}'
} | "$mcp_executable" >"$mcp_output"
grep -q '"protocolVersion"' "$mcp_output"
grep -q '"name":"search"' "$mcp_output"
grep -q '"id":3' "$mcp_output"
grep -q '"content"' "$mcp_output"

while IFS= read -r dependency; do
  case "$dependency" in
    *"not found"*)
      echo "Unresolved dependency: $dependency" >&2
      exit 1
      ;;
  esac
done < <(otool -L "$main_executable"; otool -L "$mcp_executable")

# Launch the app after moving it away from the SwiftPM build tree. A process
# that dies during bootstrap fails this smoke check. CI owns and then removes
# only the temporary copy and process it creates.
smoke_root="$(mktemp -d)"
cleanup_paths+=("$smoke_root")
ditto "$app_dir" "$smoke_root/Evee.app"
"$smoke_root/Evee.app/Contents/MacOS/Evee" >"$smoke_root/stdout.log" 2>"$smoke_root/stderr.log" &
smoke_pid=$!
sleep 5
if ! kill -0 "$smoke_pid" 2>/dev/null; then
  wait "$smoke_pid" || true
  echo "Packaged Evee exited during launch smoke test" >&2
  cat "$smoke_root/stderr.log" >&2
  exit 1
fi
kill -TERM "$smoke_pid"
wait "$smoke_pid" || true

echo "Verified $app_dir"
