#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="$root/Sources/EveeApp/AppStore.swift"
settings_file="$root/Sources/EveeApp/UI/SettingsView.swift"
library_file="$root/Sources/EveeApp/UI/LibraryView.swift"
onboarding_file="$root/Sources/EveeApp/UI/OnboardingView.swift"

grep -q 'GlobalShortcutMigration.migratePushToTalkIfNeeded()' "$source_file"
grep -q 'accessibilityPermissionProvider' "$source_file"
grep -q 'frontmostApplicationProvider' "$source_file"
grep -q 'activeTextDeliveryMode = \.copyOnly' "$source_file"

begin_dictation="$({
    sed -n '/func beginDictation()/,/func beginSelectionTransform()/p' "$source_file"
})"

if grep -q 'guard accessibilityPermissionGranted else' <<<"$begin_dictation"; then
    echo "dictation still aborts before capture when Accessibility permission is unavailable" >&2
    exit 1
fi

grep -q 'LabeledContent("Accessibility"' "$settings_file"
grep -q 'store.requestAccessibilityPermission()' "$settings_file"
grep -q 'Hold ⇧⌘Space in any app' "$library_file"
if grep -q 'Hold ⌥⌘Space in any app' "$library_file"; then
    echo "workspace empty state still advertises the macOS-reserved shortcut" >&2
    exit 1
fi
grep -q 'Hold ⇧⌘Space, speak, release' "$onboarding_file"
if grep -q 'Hold ⌥⌘Space, speak, release' "$onboarding_file"; then
    echo "onboarding still advertises the macOS-reserved shortcut" >&2
    exit 1
fi

if ! grep -q 'isEnabled: store.microphonePermissionGranted,' "$onboarding_file"; then
    echo "model setup is not enabled by microphone permission alone" >&2
    exit 1
fi
if grep -q 'isEnabled: store.microphonePermissionGranted && store.accessibilityPermissionGranted' "$onboarding_file"; then
    echo "model setup is still incorrectly blocked by Accessibility permission" >&2
    exit 1
fi

if ! grep -q '\.onAppear {' "$settings_file" ||
   ! grep -q 'NSApplication.didBecomeActiveNotification' "$settings_file"; then
    echo "settings does not observe initial appearance and app activation" >&2
    exit 1
fi
settings_refresh_count="$(grep -c 'store.refreshPermissionState()' "$settings_file")"
if (( settings_refresh_count < 2 )); then
    echo "settings does not refresh Accessibility permission on appearance and app activation" >&2
    exit 1
fi

echo "dictation entrypoint regression: passed"
