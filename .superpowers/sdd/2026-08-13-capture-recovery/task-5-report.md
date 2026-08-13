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
