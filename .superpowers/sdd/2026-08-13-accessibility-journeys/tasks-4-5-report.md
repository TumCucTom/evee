# Tasks 4–5 Report: Global Accessible Voice Status

Linear: TOM-49
Base: `d4267e5`

## Outcome

- Added a single `SystemVoiceStatus` presentation model for menu-bar icon/title, the nonactivating HUD, microphone-open state, health warnings, and available global capture actions.
- Added reducer-backed `AccessibilityStatusEvent` announcements for wake listening, capture, recovery, model downloads, channel health, and integration revocation.
- Consolidated every `NSAccessibility.post` call into `AccessibilityAnnouncementCoordinator`.
- Made wake-listener cleanup explicit with a visible `.stopping` phase. The stopped announcement is emitted only after the listener has stopped; stale pending starts cannot publish active state.
- Kept the HUD status-only. Stop and Discard remain independently labelled menu actions, and Discard has a configurable global Option–Command–Escape default.
- Preserved the protected recovery presentation as its own system status phase rather than folding it into failure.

## TDD Evidence

The new `accessibility-events` and `system-voice-status` checks were added first and failed because the production types were absent. The recovery-protected-state check was also observed failing against the initial generic failure mapping before `.protected` was implemented.

Focused green checks:

```text
swift run evee-core-checks --filter accessibility-events
accessibility-events: passed

swift run evee-core-checks --filter system-voice-status
system-voice-status: passed

swift run evee-core-checks --filter hot-mic-race
hot-mic-race: passed

swift run evee-core-checks --filter termination-checkpoint
termination-checkpoint: passed
```

The checks cover duplicate lifecycle publication, monotonic 10% download milestones, capture/wake failures, post-cleanup stop/cancel semantics, channel warnings, revocations, microphone-open state, action availability, and protected recovery state.

## Verification

- All 34 `evee-core-checks` filters passed sequentially on the final tree.
- `swift build --target EveeCore --jobs 2` passed.
- `swift build --target EveeApp --jobs 2` passed after temporarily guarding the dependency's preview-only `#Preview` blocks with `canImport(PreviewsMacros)`. The dependency checkout was restored and is clean.
- `git diff --check` passed.
- `rg -n 'NSAccessibility\.post' Sources/EveeApp` returns only `AccessibilityAnnouncementCoordinator.swift`.
- `rg -n 'Button\(|keyboardShortcut' Sources/EveeApp/UI/RecordingPill.swift` returns no matches.

## Environment Gates

- An unmodified app/package build is blocked in KeyboardShortcuts 2.4.0 because this Command Line Tools installation cannot load `PreviewsMacros` for dependency `#Preview` declarations.
- XCTest is unavailable to this toolchain (`no such module 'XCTest'`), so the XCTest targets could not execute locally. Equivalent behavior is covered by the executable core checks.
- Packaged-app and live VoiceOver verification require an interactive signed macOS build and were not run. No real microphone or user workspace data was used.
