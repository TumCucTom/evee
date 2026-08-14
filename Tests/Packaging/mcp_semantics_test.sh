#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

swift build --product evee-mcp
swift build --product evee-verification-fixture
bin_dir="$(swift build --show-bin-path)"
fixture_home="$(mktemp -d /tmp/evee-mcp-semantics.XXXXXX)"
fake_helper="$fixture_home/fake-helper"
trap 'rm -rf "$fixture_home"' EXIT

"$bin_dir/evee-verification-fixture" --home "$fixture_home"
python3 scripts/verify_mcp_tools.py --helper "$bin_dir/evee-mcp" --home "$fixture_home"

cat >"$fake_helper" <<'SH'
#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "tools/list":
        result = {"tools": [{"name": name} for name in [
            "search", "recent_activity", "ambient_timeline", "ambient_app_usage", "get_context",
            "get_journal", "get_dictation", "get_meeting", "get_memo", "get_stats", "get_config",
        ]]}
    elif method == "initialize":
        result = {"protocolVersion": "2025-03-26"}
    else:
        result = {"content": [{"type": "text", "text": "{}"}]}
    print(json.dumps({"jsonrpc": "2.0", "id": request.get("id"), "result": result}), flush=True)
SH
chmod 700 "$fake_helper"

if python3 scripts/verify_mcp_tools.py --helper "$fake_helper" --home "$fixture_home"; then
  echo "semantic verifier accepted constant tool output" >&2
  exit 1
fi
