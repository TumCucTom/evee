# Task 5 — Durable quit checkpoint

## Scope

Implemented TOM-48's normal-termination capture checkpoint from context commit
`274f54d`. The existing AppKit delegate and `ApplicationTerminationCoordinator`
remain the only termination-reply owner; this task extends that path rather than
installing a second delegate.

All executable checks used synthetic checkpoint closures, temporary manifests,
and text bytes. No microphone, screen capture, model, provider, or real Evee
workspace data was used.

## RED

- Added Core XCTest and `evee-core-checks` coverage for joined duplicate
  checkpoints, cached failure, explicit idempotent retry, and preserving an
  existing recovery manifest. Before production implementation,
  `swift run evee-core-checks --filter termination-checkpoint` failed to compile
  because `CaptureCheckpointing` and `TerminationCheckpointCoordinator` were
  absent.
- The existing `beginRecoveryCapture` behavior then failed the synthetic check
  with `repeated recovery begin erased a checkpointed track` before its
  idempotency fix.
- Added App-target XCTest coverage for terminate-now mapping, failure
  cancellation, deadline cancellation, and rejecting a late second reply. The
  XCTest gate is not claimed as executed because the Command Line Tools host
  cannot load the dependency's `PreviewsMacros` plugin and has no importable
  `XCTest` module.

## GREEN

- Added `CaptureCheckpointing` and actor `TerminationCheckpointCoordinator`.
  Concurrent waiters join one task; a failure is replayed until explicit retry;
  concurrent retries join one new task.
- Refactored the existing `ApplicationTerminationCoordinator` into the single
  operation-ID reply owner. Active plans return terminate-later. Failure and a
  15-second deadline cancel termination exactly once. Deadline expiry does not
  cancel durability, and late completion cannot issue a second reply.
- Mapped AppStore's actual starting, recording, transcribing/finishing,
  delivering, cancelling, failed, and idle states to `CaptureShutdownPlan`.
- Active capture checkpointing invalidates shortcut, delivery, wake, API, live
  preview, and webhook work before cleanup; stops recorders only when active;
  never starts or awaits final transcription; validates produced audio; and
  durably stores valid microphone/system paths in the existing recovery
  manifest. An invalid system track cannot block a valid microphone fallback.
- Meeting title and notes are saved with the recovery identifier before quit is
  allowed. User cancellation cleanup is completed without restarting hot-mic
  listening.
- Recovery begin is idempotent. Track persistence now copies and fsyncs the
  stopped recorder output, atomically/fsyncs the manifest, and removes the
  source best-effort only after both durable writes complete. A normal partial
  failure therefore retains the source path for retry.
- The AppKit delegate is still installed once through
  `@NSApplicationDelegateAdaptor`; repeated view appearance cannot replace its
  store reference.

## Verification

- `swift run --jobs 2 evee-core-checks --filter termination-checkpoint`:
  passed. This runs joined-success, failure replay, explicit retry, manifest
  idempotency, deadline cancellation, and late-reply rejection.
- The built termination check was also repeated 10 times under a five-second
  per-run deadline: 10/10 passed.
- `.build/arm64-apple-macosx/debug/evee-core-checks --filter lifecycle-state`:
  passed.
- `.build/arm64-apple-macosx/debug/evee-core-checks --filter webhook-generation`:
  passed.
- `swift build --target EveeCore --jobs 2`: passed.
- Direct `swiftc -typecheck` of every EveeApp Swift source against the built
  package modules: passed.
- `swift build --target EveeApp --jobs 2`: blocked before EveeApp compilation
  because KeyboardShortcuts previews cannot load `PreviewsMacros` under the
  active Command Line Tools SDK.
- `swift test --filter TerminationCheckpointTests` and the App coordinator
  XCTest gate are blocked by the same preview plugin and unavailable XCTest
  toolchain. Full package, release packaging, relocated bundle, physical capture,
  and full-Xcode checks were not run and are not claimed.

## Self-review

- A timeout invalidates only its reply operation. The underlying durability task
  continues, and a new quit joins it without overlapping recorder or manifest
  work.
- After a partial failure, stopped writers are not restarted. Completed manifest
  tracks are reused, the original source survives a normal pre-commit failure,
  and retry performs only unfinished persistence.
- The microphone track is the safe recovery baseline. System-audio finalization
  or validation failure is surfaced as an explicit microphone-only fallback and
  does not discard the valid channel.
- Meeting notes are persisted directly with throwing durability semantics rather
  than relying on the debounced autosave.
- No binary, recording, database, model, generated build, token, or user-data
  artifact is included.

## External blockers

- Full Xcode is not installed: `xcode-select -p` is
  `/Library/Developer/CommandLineTools`, and `xcodebuild -version` rejects that
  developer directory.
- The approved staged secret scanner and owner-provided restricted-reference
  expression are absent from this worker environment. The controller owns the
  restricted-reference gate; this worker performs staged artifact, common-secret,
  diff, and neutral-metadata inspection before committing.

## Fix round 1

Addressed all five termination-race findings without adding another AppKit
delegate or reply owner.

- A retained complete-record operation is now joined by termination. A durable
  commit is published idempotently and is never deleted because the capture
  lifecycle changed. If termination gates the path before commit creation, the
  existing stopped sources are checkpointed instead. The synthetic suspended
  commit check uses a temporary `LibraryStore` and verifies exactly one record
  plus removal of the committed recovery.
- Termination synchronously closes capture, shortcut, hot-mic, clipboard, and
  delivery starts. `CaptureCheckpointing` exposes a work generation; the reply
  owner snapshots and revalidates it before replying success, and cannot reuse a
  cached success after later work. A generation change during the await cancels
  termination visibly.
- Timeout/failure publishes an explicit `checkpointed` capture presentation.
  The overlay no longer offers Discard, `cancelCapture` cannot remove artifacts
  once the termination gate is active, and the menu offers Open Recovery and
  Retry Quit.
- Microphone and system-audio start tasks are retained. The checkpoint joins a
  start already in progress, then stops/finalises the writer and checkpoints its
  produced path or the existing fallback. Test seams use synthetic continuations
  and temporary paths only; no capture permission or hardware was touched.
- Text delivery is retained, invalidated and joined before a termination reply.
  `TextDelivery` now checks task cancellation before clipboard mutation, paste,
  every verification iteration, and Return. A suspended synthetic delivery is
  cancelled before its auto-send boundary.

Fix-round verification:

- Rebuilt `evee-core-checks`, then ran `--filter termination-checkpoint` ten
  consecutive times: 10/10 passed. Coverage includes suspended commit,
  in-flight recorder start, delivery cancellation, stale cached success, and a
  generation change while checkpointing.
- `--filter lifecycle-state`: passed.
- `--filter webhook-generation`: passed.
- `swift build --target EveeCore --jobs 2`: passed.
- Direct `swiftc -typecheck` of every EveeApp source against built modules:
  passed after the fix-round changes.
- `swift test --filter TerminationCheckpointTests --jobs 1` remains blocked
  before test compilation by KeyboardShortcuts' unavailable `PreviewsMacros`
  plugin under Command Line Tools. No full-Xcode, package, physical capture, or
  packaged-app result is claimed.

## Fix round 2

Closed the remaining normal-use presentation, recovery, clipboard, and meeting
draft issues without changing AppKit reply ownership.

- Termination deadline/failure now maps every live starting, recording,
  transcribing/stopping, or delivering presentation to explicit protected
  `checkpointed` state. This removes Discard/live controls and preserves the
  existing Open Recovery and Retry Quit actions.
- A synchronous `TerminationWorkGate` now owns both admission and generation.
  Recovery is rejected while checkpointing, accepted recovery advances the same
  generation observed by the reply owner, and Recovery/Discard/New Memo UI is
  disabled while the checkpoint gate is closed.
- Temporary clipboard ownership is centralized in a defer-backed transaction.
  Once the delivery's clipboard revision is owned, success, verification error,
  cancellation, and restore-delay cancellation all restore the prior snapshot
  when no other application has replaced it. Paste verification and the final
  cancellation check before Return remain intact.
- When an in-flight meeting record commit durably wins, termination clears the
  on-disk draft only if its capture identifier matches the commit's recovery
  identifier. Draft-clear failure cancels termination after preserving the
  durable record; failed commits and recovery-only checkpoints do not clear a
  draft. The temporary-store check reopens the library and confirms the matching
  draft stays absent while an unrelated draft survives.

Fix-round 2 verification:

- Rebuilt `evee-core-checks`, then ran `--filter termination-checkpoint` ten
  consecutive times: 10/10 passed. The filter now includes protected
  presentation, recovery admission/generation, cancellation-time clipboard
  restoration, and matching meeting-draft relaunch coverage.
- `--filter context-policy`: passed.
- `--filter lifecycle-state`: passed.
- `--filter webhook-generation`: passed.
- `swift build --target EveeCore --jobs 2`: passed.
- Direct `swiftc -typecheck` of every EveeApp source against built modules:
  passed.
- `swift test --filter ApplicationTerminationCoordinatorTests --jobs 1` remains
  blocked before app-test compilation by KeyboardShortcuts' unavailable
  `PreviewsMacros` plugin under Command Line Tools. No full-Xcode, package,
  physical capture, or packaged-app result is claimed.
