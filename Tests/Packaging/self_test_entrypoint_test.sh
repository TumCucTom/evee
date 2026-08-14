#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

test "$(rg -l '^@main' Sources/EveeApp/*.swift | tr '\n' ' ')" = 'Sources/EveeApp/EveeMain.swift '
rg -q 'EveeApplication\.main\(\)' Sources/EveeApp/EveeMain.swift
! rg -q '\.shared|bootstrap\(' Sources/EveeApp/InstallationSelfTest.swift
rg -q 'ResourceSealVerifier\.verify' Sources/EveeApp/InstallationSelfTest.swift

if [[ -n "${EVEE_PACKAGED_APP:-}" ]]; then
    home="$(mktemp -d /tmp/evee-self-test-home.XXXXXX)"
    trap 'rm -rf "$home"' EXIT
    HOME="$home" CFFIXED_USER_HOME="$home" "$EVEE_PACKAGED_APP/Contents/MacOS/Evee" --installation-self-test
    test ! -e "$home/Library/Application Support/Evee"
fi
