#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
bin_dir="$(swift build --show-bin-path)"
helper="$bin_dir/evee-mcp"
test -x "$helper"

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

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
