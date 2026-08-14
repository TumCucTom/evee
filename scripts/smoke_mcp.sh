#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
swift build --product evee-mcp
swift build --product evee-verification-fixture
bin_dir="$(swift build --show-bin-path)"
smoke_home="$(mktemp -d /tmp/evee-mcp-smoke.XXXXXX)"
trap 'rm -rf "$smoke_home"' EXIT

"$bin_dir/evee-verification-fixture" --home "$smoke_home"
python3 scripts/verify_mcp_tools.py --helper "$bin_dir/evee-mcp" --home "$smoke_home"
