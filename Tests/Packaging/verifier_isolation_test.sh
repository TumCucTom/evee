#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

real_home="$(mktemp -d /tmp/evee-real-sentinel.XXXXXX)"
output="$(mktemp)"
errors="$(mktemp)"
malformed_root=""
cleanup() {
  chmod 600 "$real_home/Library/Application Support/Evee/records.json" 2>/dev/null || true
  rm -rf "$real_home" "$output" "$errors" "$malformed_root"
}
trap cleanup EXIT

sentinel="$real_home/Library/Application Support/Evee/records.json"
mkdir -p "$(dirname "$sentinel")"
printf '%s\n' 'REAL-DATA-SENTINEL-DO-NOT-READ' >"$sentinel"
before="$(shasum -a 256 "$sentinel" | awk '{print $1}')"
chmod 000 "$sentinel"

HOME="$real_home" CFFIXED_USER_HOME="$real_home" scripts/verify_app.sh dist/Evee.app >"$output" 2>"$errors"

chmod 600 "$sentinel"
after="$(shasum -a 256 "$sentinel" | awk '{print $1}')"
test "$before" = "$after"
grep -q 'Verified isolated relocated bundle' "$output"
! grep -R -q 'REAL-DATA-SENTINEL-DO-NOT-READ' "$output" "$errors" /tmp/evee-verifier.* 2>/dev/null
! find /tmp -maxdepth 1 -type d -name 'evee-verifier.*' -print -quit | grep -q .

malformed_root="$(mktemp -d /tmp/evee-malformed-bundle.XXXXXX)"
ditto dist/Evee.app "$malformed_root/Evee.app"
rm "$malformed_root/Evee.app/Contents/Helpers/evee-mcp"
if HOME="$real_home" CFFIXED_USER_HOME="$real_home" scripts/verify_app.sh "$malformed_root/Evee.app"; then
  echo "verifier accepted a malformed bundle" >&2
  exit 1
fi
! find /tmp -maxdepth 1 -type d -name 'evee-verifier.*' -print -quit | grep -q .
