# TOM-48 final practical capture fix wave

Context: `059fa55a9ad9596903103055416c984f97778e4c`.

Scope stayed restricted to the four requested findings. Tests and executable
checks use injected providers, temporary library roots, generated silent WAV
containers, and synthetic high-rate level values. No microphone, screen
capture, provider model cache, or Evee user library was accessed.

## 1. Selected-model load readiness and non-destructive repair

### RED

- Added a Core provider test and `model-readiness` executable filter for a
  shallow-present cache whose first `load()` fails, followed by one repair
  download and a successful validation load.
- Added an AppStore test that enters the same state through bootstrap cache
  reconciliation, requires Failed/Retry rather than Ready, activates retry
  twice, and requires exactly one download and a final Ready state.
- Before production interfaces existed, the executable filter failed to
  compile on missing `LocalModelReadiness` and preparation modes.

### GREEN

- `LocalModelReadiness` now defines the provider boundary: existing caches are
  load-validated; downloads and repairs call the provider downloader without
  deleting cache paths, then load-validate.
- AppStore bootstrap/settings reconciliation keeps the selected model in an
  in-flight state until validation succeeds. A load failure publishes Failed,
  records repair intent, and leaves the provider cache untouched.
- Retry uses download-or-repair even when shallow cache paths still exist,
  remains single-flight through the existing operation token, and publishes
  Ready only after the second load succeeds.
- Reconciliation now uses the injected selected-model provider, allowing the
  provider/AppStore contract to be tested directly.

## 2. Capacity-one retained microphone meter consumer

### RED

- Added a Core XCTest and `microphone-meter` executable filter that offer
  10,000 synthetic level values, require peak depth one, require coalescing,
  require exactly one consumer start, and require no live consumer plus a
  final zero after stop.
- The initial filter failed to compile because the retained meter did not yet
  exist.

### GREEN

- The audio tap no longer creates a `Task` per buffer. It performs the RMS
  calculation synchronously and offers the value to a capacity-one
  `BoundedAudioMailbox`.
- One retained MainActor consumer publishes at a 40 ms cadence (25 Hz), which
  preserves responsive metering while bounding queued work.
- Recorder start failure cancels and joins the meter consumer. Recorder stop
  closes/drains and joins it before returning, then publishes the final zero.
  AppStore stop, cancellation, failure, and quit paths now await that join.

## 3. Independent quit track checkpointing

### RED

- Added policy tests and `quit-track-independence` for meeting either-track
  acceptance, memo/dictation microphone requirements, and recovery admission
  reopening after a failed quit.
- Added AppStore tests for valid system/invalid microphone, valid
  microphone/invalid system, and invalid-microphone memo failure.
- Before production interfaces existed, the executable filter failed to
  compile on the missing track policy and gate recovery method.

### GREEN

- Microphone and system writer stops are attempted independently. Their source
  files are then validated/checkpointed independently, so failure in either
  channel cannot skip the other.
- Every successfully validated role is durably added to the recovery manifest.
  Meetings accept either microphone or system audio; dictation and memo still
  require microphone audio.
- A partial success publishes an explicit degraded-channel message. A required
  channel failure cancels quit, retains the manifest/source material, switches
  to the protected checkpoint presentation, reopens the termination admission
  gate, returns capture lifecycle ownership to idle, and refreshes Recovery so
  the still-open app remains actionable.

## 4. OS-central speech-model availability

### RED

- Added Core macOS 14/15 policy tests and the `model-availability` executable
  filter for Qwen support, safe fallback, and explanatory copy.
- Added AppStore tests for macOS 14 bootstrap fallback persistence/diagnostic
  and rejecting an unsupported save before it changes disk state.
- Before production interfaces existed, the executable filter failed to
  compile on the missing availability policy.

### GREEN

- `SpeechModelAvailability` is the central OS policy. Parakeet supports macOS
  14; Qwen requires macOS 15. `TranscriberFactory` consults the same policy.
- Settings disables the unsupported picker row and Download action and shows
  the macOS requirement.
- Save rejects an unsupported selection before settings, secrets, endpoints,
  retention, or model state are persisted.
- Bootstrap replaces a persisted unsupported selection with the safe supported
  model in memory and on disk, retains a diagnostic warning, and continues
  initialization rather than falling back to onboarding failure.

## Fresh verification

- New executable filters passed:
  `model-readiness`, `microphone-meter`, `quit-track-independence`, and
  `model-availability`.
- All 25 pre-existing executable filters passed:
  `context-policy`, `public-record`, `api-revoke`, `api-rotate`, `api-limits`,
  `api-start-races`, `api-revoke-persistence`, `api-public-errors`,
  `mcp-public-output`, `mcp-revocation`, `mcp-legacy`, `webhook-generation`,
  `webhook-signature`, `webhook-payload`, `webhook-legacy`,
  `webhook-transactions`, `termination-checkpoint`, `lifecycle-state`,
  `model-download`, `hot-mic-race`, `bounded-mailbox`, `audio-pipeline`,
  `audio-relay`, `recovery-tracks`, and `corrupt-library-recovery`.
- `swift build --target EveeCore --jobs 2`: passed.
- Direct `swiftc -typecheck` of every EveeApp source against built package
  modules: passed.
- `swift build --target EveeApp --jobs 2`: passed with the established
  temporary preview-only guard in the KeyboardShortcuts checkout. The checkout
  was restored to SHA-256
  `12b7459a955f5566c3f8213ba0634e03e02affa76ae1195452d54261958d0c8e`
  and verified clean immediately afterward.
- `swiftc -frontend -parse` over all changed production and XCTest sources:
  passed.
- `git diff --check`: passed before staging.
- Staged path artifact scan: passed; no audio, model, database, package,
  generated-build, token, or user-library artifact is staged.
- Staged common credential signature scan: passed.
- Neutral subject/branch/path/previous-metadata attribution scan: passed for
  commit subject `Complete capture recovery safeguards`.

## Environment and scan limitations

- Full Xcode is absent. Package XCTest remains blocked before test compilation
  because Command Line Tools has no XCTest module and the unguarded
  KeyboardShortcuts previews cannot load `PreviewsMacros`. The new XCTest files
  parse, but no XCTest execution is claimed.
- `EVEE_SECRET_SCAN_COMMAND` and `EVEE_PRIVATE_SCAN_PATTERN` are unset in this
  worker. Per the existing SDD ledger ruling, the controller owns those
  owner-provided restricted gates; this wave performs the staged artifact,
  common-secret, and neutral metadata scans available locally and does not
  fabricate the unavailable owner-policy result.
