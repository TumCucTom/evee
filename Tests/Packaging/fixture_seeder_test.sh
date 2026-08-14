#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fixture_home="$(mktemp -d /tmp/evee-fixture-test.XXXXXX)"
trap 'rm -rf "$fixture_home"' EXIT

swift run evee-verification-fixture --home "$fixture_home"

workspace="$fixture_home/Library/Application Support/Evee"
test -f "$workspace/records.json"
test -f "$workspace/settings.json"
test -f "$workspace/Intelligence/dwell-events.json"
test "$(find "$fixture_home" -type f -perm -004 -print | wc -l | tr -d ' ')" = 0

python3 - "$workspace" <<'PY'
import json
import pathlib
import sys

workspace = pathlib.Path(sys.argv[1])
records = json.loads((workspace / "records.json").read_text())["records"]
expected = {
    "10000000-0000-0000-0000-000000000001": "dictation",
    "20000000-0000-0000-0000-000000000002": "meeting",
    "30000000-0000-0000-0000-000000000003": "memo",
}
assert {record["id"]: record["kind"] for record in records} == expected
settings = json.loads((workspace / "settings.json").read_text())["settings"]
assert settings["mcpEnabled"] is True
assert "webhookSecret" not in settings
assert settings["webhookURL"] == ""
PY
