# Tasks 4–5 Report: Global Accessible Voice Status

Linear: TOM-49
Base: `d4267e5`

## Outcome

- Added a single `SystemVoiceStatus` presentation model for menu-bar icon/title, the nonactivating HUD, microphone-open state, health warnings, and available global capture actions.
- Added reducer-backed `AccessibilityStatusEvent` announcements for wake listening, capture, recovery, model downloads, channel health, and integration revocation.
- Consolidated every `NSAccessibility.post` call into `AccessibilityAnnouncementCoordinator`.
- Made wake-listener cleanup explicit with a visible `.stopping` phase. The stopped announcement is emitted only after the listener has stopped; stale pending starts cannot publish active state.
- Kept the HUD status-only. Stop and Discard remain independently labelled menu actions, and Discard has a configurable global Control–Option–Command–Escape default.
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

## Review Round 1/5

Addressed all five practical findings:

- Added an independent `CaptureMicrophoneState` input to `SystemVoiceStatus`. The app publishes `.open` immediately after microphone startup succeeds, keeps `.stopping` visibly open until the awaited stop completes, and retains microphone-open truth in failure/protected presentations.
- Moved `.transcribing` publication to the first post-recorder-stop boundary. Stop and Discard disappear before live-transcript cleanup and recovery persistence awaits; `captureStopped` remains after recorder/live cleanup and before persistence.
- Gated the global discard handler through `systemVoiceStatus.availableActions` and restricted `cancelCapture()` to starting/recording lifecycles. Finishing, transcription, delivery, and existing recovery-discard paths cannot be conflated.
- Replaced the reserved Option–Command–Escape default with Control–Option–Command–Escape, verified it does not collide with the push-to-talk or transform defaults, and displayed the exact default in Settings.
- Added a microphone-signal-restored reducer event. Repeated publications during one silence incident remain suppressed; silence→clear→silence announces the new incident exactly once.

TDD additions include executable reducer/status contracts plus app lifecycle contracts that suspend system-audio startup and recovery persistence. The suspended-persistence contract verifies processing state, empty actions, rejected shortcut/direct cancellation, retained source audio, failure presentation, and discoverable recovery audio.

Review verification:

```text
accessibility-events: passed
accessibility-copy: passed
system-voice-status: passed
hot-mic-race: passed
lifecycle-state: passed
termination-checkpoint: passed
quit-track-independence: passed
```

- All 34 `evee-core-checks` filters passed sequentially.
- `swift build --target EveeCore --jobs 2` passed.
- `swift build --target EveeApp --jobs 2` passed with the same temporary preview-only dependency guard described above; the checkout was restored clean.
- The new app lifecycle/shortcut test source passed a synthetic XCTest-module typecheck. Native XCTest execution remains blocked because this Command Line Tools installation has no `XCTest` module.
- `git diff --check` and the direct accessibility-post/HUD-control source scans passed. No real microphone or user data was used.

## Review Round 2/5

Resolved the remaining teardown timing finding:

- `finishCapture()` now publishes `.transcribing` at the same synchronous boundary where the lifecycle enters `.finishing`, before awaiting microphone, system-audio, or live-transcript cleanup. Global Stop and Discard actions therefore disappear for the full teardown interval.
- While the microphone is still open, the shared processing presentation explicitly says `Microphone open · Stopping capture`; after it closes, the HUD remains in local processing while system-audio cleanup completes.
- The capture-stopped announcement remains after microphone, system-audio, and live-transcript cleanup, and before recovery persistence.
- Added a delayed meeting system-stop contract that holds teardown open and verifies processing state, empty actions, microphone truth, processing HUD copy, and suppression of `captureStopped` until the stop continuation completes.

Round 2 verification:

- The new system-status contract was observed failing against the previous teardown copy, then passed after the finishing-boundary change.
- All 34 `evee-core-checks` filters passed sequentially, including system voice, accessibility, lifecycle, hot-mic, and both termination filters.
- `swift build --target EveeCore --jobs 2` passed.
- `swift build --target EveeApp --jobs 2` passed with the temporary preview-only dependency guard; the dependency checkout was restored clean.
- The expanded app lifecycle test source passed the synthetic XCTest-module typecheck. Native XCTest and interactive VoiceOver/package gates remain environment-blocked. No real microphone or user data was used.
