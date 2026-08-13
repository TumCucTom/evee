#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
bin_dir="$(swift build --show-bin-path)"
helper="$bin_dir/evee-mcp"
test -x "$helper"

smoke_home="${CFFIXED_USER_HOME:-}"
owns_smoke_home=false
if [[ -z "$smoke_home" ]]; then
  smoke_home="$(mktemp -d /tmp/evee-mcp-smoke.XXXXXX)"
  owns_smoke_home=true
fi
if [[ "$smoke_home" == "$HOME" || "$smoke_home" == "/" ]]; then
  echo "MCP smoke requires an isolated temporary home" >&2
  exit 1
fi
export CFFIXED_USER_HOME="$smoke_home"

settings_dir="$smoke_home/Library/Application Support/Evee"
mkdir -p "$settings_dir"
chmod 700 "$settings_dir"
python3 - "$settings_dir/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 2,
        "updatedAt": "2026-08-13T00:00:00Z",
        "settings": {"mcpEnabled": True},
    }, handle)
PY
chmod 600 "$settings_dir/settings.json"

response_file="$(mktemp)"
cleanup() {
  rm -f "$response_file"
  if [[ "$owns_smoke_home" == true ]]; then
    rm -rf "$smoke_home"
  fi
}
trap cleanup EXIT

python3 - <<'PY' | "$helper" >"$response_file"
import json

tools = [
    ("search", {"query": "smoke"}),
    ("recent_activity", {}),
    ("ambient_timeline", {}),
    ("ambient_app_usage", {}),
    ("get_context", {}),
    ("get_journal", {}),
    ("get_dictation", {}),
    ("get_meeting", {}),
    ("get_memo", {}),
    ("get_stats", {}),
    ("get_config", {}),
]
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}))
print(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}))
for index, (name, arguments) in enumerate(tools, start=3):
    print(json.dumps({"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {"name": name, "arguments": arguments}}))
PY

python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    responses = [json.loads(line) for line in handle if line.strip()]

assert len(responses) == 13, f"expected 13 responses, received {len(responses)}"
assert all("error" not in response for response in responses), responses
listed = responses[1]["result"]["tools"]
names = {tool["name"] for tool in listed}
expected = {
    "search", "recent_activity", "ambient_timeline", "ambient_app_usage", "get_context",
    "get_journal", "get_dictation", "get_meeting", "get_memo", "get_stats", "get_config",
}
assert names == expected, (names, expected)
for response in responses[2:]:
    content = response["result"]["content"]
    assert content and content[0]["type"] == "text"
    json.loads(content[0]["text"])
print("MCP protocol smoke passed")
PY
