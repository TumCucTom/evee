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

plutil -lint "$contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app_dir"

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
test "$bundle_identifier" = "com.tumcuctom.evee"

# The MCP executable is a stdio server. EOF must terminate it successfully;
# this catches missing dynamic libraries and packaging paths without requiring a
# client configuration.
"$mcp_executable" </dev/null

while IFS= read -r dependency; do
  case "$dependency" in
    *"not found"*)
      echo "Unresolved dependency: $dependency" >&2
      exit 1
      ;;
  esac
done < <(otool -L "$main_executable")

echo "Verified $app_dir"
