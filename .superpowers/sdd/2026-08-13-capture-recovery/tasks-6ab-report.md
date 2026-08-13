# Tasks 6A–6B — Capture recovery parity

## Scope

Implemented TOM-48's practical recovery parity cycle from context commit
`b95ed41`. Interrupted captures are assessed one track at a time, users can
explicitly recover every valid role independent of ordinary retention, and
system-only meeting recovery produces system-channel transcript segments.
Malformed canonical draft, records, and settings files are moved to private,
verified `Corrupt` copies while bootstrap continues with safe in-memory
fallbacks.

All executable checks use temporary library roots and generated silent WAV
containers. No microphone, screen capture, provider model, or real Evee user
data was accessed.

## Task 6A RED — independent tracks and atomic selected-role commit

- Added `WorkspaceLifecycleTests` cases for valid microphone/invalid system,
  valid system/invalid microphone, both valid, neither valid, empty/missing/
  invalid selection, selected-role retention, metadata failure, retry,
  superseded-audio cleanup, and discard before production APIs existed.
- Added app-target cases for system-only meeting recovery and rejecting a
  system-only memo. The meeting case starts with retention disabled and
  requires retained system audio, system-channel segments, and a durable
  recovered-from-system label.
- Added the `recovery-tracks` executable check before implementation.
  `swift run evee-core-checks --filter recovery-tracks` failed to compile
  because `RecoveryTrackAssessment`, `RecoveryTrackSelection`,
  `assessRecoveryTracks`, and selected-role commit were absent.

## Task 6A GREEN

- Added synchronous AVFoundation validation that rejects linked, directory,
  empty, missing, and undecodable track sources independently without ASR.
- `commitRecoveredRecord` resolves fresh assessments, validates explicit
  roles, copies only selected tracks to never-overwritten UUID names, verifies
  byte count and decodability, and durably writes one canonical record before
  recovery cleanup.
- A pre-metadata failure removes only its new copies. Recovery originals and a
  persisted prior record/audio remain available; retry replaces the one record
  and reconciliation removes obsolete/orphan copies.
- Normal completion still selects every recorded role when audio retention is
  enabled. Explicit interrupted recovery always retains selected audio,
  regardless of dictation/memo/meeting retention defaults.
- App recovery handles microphone-only, dual-channel, and system-only meeting
  transcription. System-only meeting segments use the system channel and the
  finished record remains visibly labelled. Dictation and memo recovery still
  require a microphone track.
- `LibraryView`, the existing recovery owner, now shows a status ledger per
  track plus Recover all valid, Microphone, System, and Discard controls.
  `MeetingWorkspaceView` explains system-only and no-valid-track cases.

## Task 6B RED — preserve corrupt canonical sources and continue

- Added malformed records, settings, and meeting-draft cases requiring exact
  byte preservation, owner-only permissions, removal of the blocking canonical
  source only after preservation, and the documented safe fallback.
- Added preservation-failure coverage that blocks the `Corrupt` directory and
  requires the original canonical bytes to remain, plus a future-schema case
  that must remain a hard error and must not be moved.
- Added the `corrupt-library-recovery` executable check before implementation.
  It failed to compile because the three recovering load APIs and
  `RecoveredLibraryLoad` were absent.

## Task 6B GREEN

- Added recovering load APIs for records, settings, and meeting draft. Decode
  happens first; malformed bytes are moved to a unique private destination,
  chmod'd, fsync'd, compared byte-for-byte, and directory-synced before the
  fallback is returned. Verification failure restores or leaves the source and
  throws.
- Future records/settings envelopes remain `unsupportedSchema` errors.
- Bootstrap uses all recovering loads, deduplicates preserved paths into one
  actionable warning, and exposes Show in Finder/Dismiss without routing the
  user into onboarding.
- A corrupt settings fallback is not written during helper-registration
  reconciliation. A corrupt records fallback skips automatic retention,
  webhook retirement, and audio reconciliation so unreadable metadata cannot
  cause retained audio deletion or an empty fallback write. Later user changes
  remain the point at which canonical data is written again.

## Fresh verification

- `swift run evee-core-checks --filter recovery-tracks`: passed. Coverage
  includes invalid/empty selections, microphone-only commit, system-only
  commit, metadata rollback, retry without duplicate metadata/audio, and
  explicit discard.
- `swift run evee-core-checks --filter corrupt-library-recovery`: passed for
  all three canonical sources, byte/permission checks, preservation failure,
  and unsupported schema.
- `swift run evee-core-checks --filter termination-checkpoint`: passed after
  replacing its text-with-audio-suffix retained fixture with a generated valid
  WAV.
- `swift run evee-core-checks --filter lifecycle-state`: passed.
- `swift build --target EveeCore`: passed.
- Direct `swiftc -typecheck` of all EveeApp Swift sources against built package
  modules: passed.
- `swiftc -parse` over all changed Swift production and test sources: passed.
- `git diff --check`: passed.

## Limitations and external gates

- Full Xcode is absent. `xcode-select -p` is
  `/Library/Developer/CommandLineTools`, and `/Applications/Xcode.app` does not
  exist.
- `swift test --filter WorkspaceLifecycleTests` is blocked before these tests
  can run because the host cannot import `XCTest`; the app dependency also
  cannot load the `PreviewsMacros` plugin under Command Line Tools.
- `swift build --target EveeApp` is blocked in the unchanged
  `KeyboardShortcuts` preview source before EveeApp compilation. The direct
  all-source EveeApp typecheck is the available compile evidence and passed.
- Release packaging, `verify_app.sh`, relocated-bundle/manual recovery journeys,
  playback/export/notes exercises, exact bundle identity, and physical capture
  were not run and are not claimed. They remain controller/Task 7 gates.
- The shared UI design file named by `AGENTS.md` was absent at both the exact
  path and the lowercase Codex design directory. UI changes therefore reuse the
  existing `AnimaTheme`, card, typography, spacing, and native button patterns.
- The controller owns the owner-provided restricted-reference scan. This cycle
  performs staged artifact/common-secret and neutral metadata inspection before
  committing; no restricted-scan result is fabricated when its inputs are
  unavailable.

## Fix round 1/5 — RED

- Added lifecycle cases before implementation for a records quarantine that
  must survive two `LibraryStore` instances, an ordinary records save, explicit
  reconciliation, and a newly retained recovery. A pre-existing UUID record
  audio directory must survive until explicit marker reset, and reset itself
  must not delete audio.
- Expanded future-schema cases to records and settings whose version is newer
  but whose payload fields/types cannot decode as the current envelope. Both
  canonical inputs must remain byte-identical and no `Corrupt` copy may appear.
- Split retained-commit fault coverage into record-directory sync failure,
  metadata failure before replacement, and failure after replacement. The first
  two require rollback of copied audio; the last requires installed metadata,
  its referenced copies, and recovery originals all to remain.
- `swift test --filter WorkspaceLifecycleTests/testRecordsQuarantineSurvivesRelaunchWritesAndRecoveryUntilExplicitReset`
  reached the known host gates (`XCTest` unavailable and `PreviewsMacros`
  missing), so the new XCTest cases could not execute here. Equivalent
  temp-root/generated-WAV journeys were added to the executable
  `corrupt-library-recovery` and `recovery-tracks` filters for runnable evidence.

## Fix round 1/5 — GREEN

- Corrupt `records.json` preservation now installs a private, fsync'd
  `records-quarantine.json` marker containing the preserved relative path,
  reason, and timestamp. Recovering loads surface the same preserved copy on
  later launches even after a valid canonical records file is written.
- Every record-audio reconciliation entry point checks the marker and fails
  closed while it exists. Ordinary saves do not clear it, and newly retained
  recovery commits cannot orphan-clean unknown UUID record directories.
- The existing corruption banner now offers **Keep preserved data** (dismisses
  the banner but leaves protection durable) and **Reset library metadata**.
  Reset requires a destructive confirmation, removes only the marker, and
  explicitly reports that no audio was deleted by that action.
- Atomic private writes now create/chmod/fsync a same-directory temporary file,
  then use `rename` as the metadata commit point. Retained files and their
  record and Records directories are fsync'd before that point. Failures after
  replacement surface `metadataInstalledButDurabilityUncertain`; commit cleanup
  recognizes that installed state and preserves every metadata-owned copy.
- Records/settings decode now probes only the top-level `schemaVersion` before
  selecting a decoder. A newer integer version is rejected as
  `unsupportedSchema` without interpreting, moving, or rewriting its payload;
  only the current envelope is decoded, while an absent version may use the
  legacy decoder.

## Fix round 1/5 — verification and limits

- `swift run evee-core-checks --filter corrupt-library-recovery`: passed,
  including marker privacy/reference, two bootstraps, ordinary save,
  quarantine-gated reconciliation, retained recovery, explicit non-deleting
  reset, and incompatible future records/settings payloads.
- `swift run evee-core-checks --filter recovery-tracks`: passed, including
  record-directory sync rollback, pre-replacement rollback, retry, and
  post-replacement installed-metadata/audio preservation.
- `swift run evee-core-checks --filter termination-checkpoint`: passed.
- `swift build --target EveeCore`: passed.
- Direct all-source EveeApp `swiftc -typecheck`: passed; `swiftc -parse` and
  `git diff --check` over the changed sources/tests also passed.
- The existing full-Xcode, package XCTest, EveeApp package build, physical
  capture, and controller-owned restricted-scan limitations above remain
  unchanged and are not claimed as passing.
