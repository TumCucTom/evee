# Capture Lifecycle and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make model download, wake listening, audio ingestion, capture shutdown, and interrupted-recording recovery single-owner, cancellable, bounded, and loss-resistant.

**Architecture:** Put pure generation-based transition logic, a synchronous-producer bounded mailbox, and a testable checkpoint joiner in EveeCore, leaving AppStore as a main-actor adapter over concrete recorders and transcribers. AppKit termination waits for a durable recovery checkpoint and cancels termination instead of claiming safety when checkpointing fails. Recovery validates and commits selected tracks atomically, independently of ordinary retention defaults.

**Tech Stack:** Swift concurrency, AVFoundation, ScreenCaptureKit, AppKit termination lifecycle, FluidAudio, XCTest, SwiftPM

**Spec:** `docs/superpowers/specs/2026-08-13-production-hardening-design.md`

## Global Constraints

- Minimum deployment target remains macOS 14.
- One logical capture, wake listener, or model download has one current operation identifier.
- Cancellation invalidates callbacks before awaiting slow cleanup.
- Producers cannot create an unbounded task per audio buffer.
- Normal quit cannot discard valid audio or notes.
- Recovery choices are independent of long-term retention defaults.
- No destructive model-cache cleanup is allowed.
- Tests use synthetic buffers and temporary application data.
- Repository and metadata use neutral product language only.
- Execute this plan only after Tasks 1–3 of `docs/superpowers/plans/2026-08-13-privacy-integrations.md` are committed and verified. They produce `evee-core-checks`, generation-owned API shutdown, and generation-owned webhook cancellation consumed here.
- The external prohibited-reference policy remains outside the repository. Set `EVEE_PRIVATE_SCAN_PATTERN` to the owner-provided expression and `EVEE_SECRET_SCAN_COMMAND` to the approved staged-secret scanner before any commit; a missing scanner or policy blocks the commit, not implementation and local testing.

## Ordered Workstream and Child Evidence Boundaries

This remains one ordered workstream because termination consumes the lifecycle primitives and integration revocation delivered earlier. Track and review the following completion-critical children separately under the capture/recovery parent issue, while executing them in this document's order:

1. Tasks 1–2: model-download lifecycle and accessible cancellation;
2. Tasks 1, 3–4: wake lifecycle and bounded live ingestion;
3. Task 5: normal-termination checkpoint, blocked on the privacy/integration dependency above;
4. Task 6A: partial-track validation and explicit recovery selection;
5. Task 6B: corrupt draft, records, and settings preserve-and-continue behavior;
6. Task 7: packaged-app and physical evidence for the exact combined head.

Each boundary records its focused automated evidence and exact commit in its child ticket. The parent remains open until Task 7 and fresh independent review complete.

Before the final commit of each child boundary (Tasks 2, 4, 5, 6A, and 6B), run the complete XCTest suite, build and package the app, verify it with an isolated temporary Foundation home, relocate the bundle, and repeat the affected packaged-app journey. The task-specific Step 4 names the affected journey. Serialize those heavyweight commands and record a genuine full-Xcode blocker instead of weakening or silently skipping the gate.

---

### Task 1: Pure lifecycle state machines

**Files:**
- Create: `Sources/EveeCore/Lifecycle/ModelDownloadStateMachine.swift`
- Create: `Sources/EveeCore/Lifecycle/HotMicStateMachine.swift`
- Create: `Sources/EveeCore/Lifecycle/CaptureShutdownPlan.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/LifecycleStateMachineTests.swift`

**Interfaces:**
- Produces: `ModelDownloadStateMachine`, `HotMicStateMachine`, `CaptureLifecycleSnapshot`, and `CaptureShutdownPlan`.
- Consumers: Tasks 2, 3, and 5.

- [ ] **Step 1: Add failing stale-completion checks**

```swift
var download = ModelDownloadStateMachine()
let first = download.begin(model: .parakeet)!
precondition(download.begin(model: .parakeet) == nil)
download.cancel(first)
precondition(!download.complete(first))

var hotMic = HotMicStateMachine()
let start = hotMic.beginStart()!
hotMic.disable()
precondition(!hotMic.didStart(start))
```

Add shutdown-plan assertions mapping:

- idle and terminal failure to `.terminateImmediately`;
- starting with a recovery identifier to `.cancelStartAndCheckpoint`;
- recording to `.stopWritersAndCheckpoint(kind:recoveryID:)`;
- finishing/transcribing to `.awaitDurableCommitOrCheckpoint(recoveryID:)`;
- delivering to `.invalidateDeliveryAndAwaitCommit`;
- cancelling to `.awaitCancellationCleanup`.

Every active snapshot without the required recovery identifier returns `.cancelTermination(message:)`; it never invents a safe immediate exit.

- [ ] **Step 2: Run red checks**

Run: `swift run evee-core-checks --filter lifecycle-state`

Expected: compile failure because the lifecycle types are absent.

- [ ] **Step 3: Implement value-semantic transitions**

```swift
public struct LifecycleOperation: Hashable, Sendable { public let id: UUID }

public enum CaptureLifecycleSnapshot: Equatable, Sendable {
    case idle
    case starting(kind: WorkspaceRecordKind, recoveryID: UUID?)
    case recording(kind: WorkspaceRecordKind, recoveryID: UUID?)
    case finishing(recoveryID: UUID?)
    case delivering
    case cancelling
    case failed
}

public struct ModelDownloadStateMachine: Sendable {
    public private(set) var state: ModelDownloadState = .idle
    public mutating func begin(model: SpeechModel) -> LifecycleOperation?
    public mutating func cancel(_ operation: LifecycleOperation)
    public mutating func update(_ operation: LifecycleOperation, progress: ModelProgress) -> Bool
    public mutating func complete(_ operation: LifecycleOperation) -> Bool
    public mutating func fail(_ operation: LifecycleOperation, message: String) -> Bool
}
```

Use the same operation-token pattern for hot mic. `AppStore` maps its private `CaptureLifecycle` to `CaptureLifecycleSnapshot`; EveeCore never imports the app-private enum. `CaptureShutdownPlan` is a pure enum-producing function with no recorder side effects.

- [ ] **Step 4: Run green checks**

Run: `swift run evee-core-checks --filter lifecycle-state`

Expected: PASS for reentrancy, cancellation, stale progress, stale completion, and shutdown mapping.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Lifecycle Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/LifecycleStateMachineTests.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Add capture lifecycle state machines'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Add capture lifecycle state machines"
```

### Task 2: Single-flight cancellable model download

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Sources/EveeApp/UI/OnboardingView.swift`
- Modify: `Sources/EveeCore/Transcription/LocalTranscribers.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeAppTests/ModelDownloadLifecycleTests.swift`

**Interfaces:**
- Consumes: `ModelDownloadStateMachine`.
- Produces: `LocalModelDownloading`, an injected `AppStore.ModelDownloaderFactory`, `AppStore.startModelDownload()`, `AppStore.cancelModelDownload()`, accessible download state and retry, and an `EveeAppTests` test target that depends on `EveeApp`.

- [ ] **Step 1: Add a failing delayed-downloader scenario**

```swift
let fake = DelayedModelDownloader()
let store = await AppStore(modelDownloaderFactory: { _ in fake })
await store.startModelDownload()
await store.startModelDownload()
await fake.waitUntilStarted()
precondition(await fake.startCount == 1)
await store.cancelModelDownload()
await fake.finish()
precondition(await store.modelDownloadState == .idle)
```

Place this scenario in `EveeAppTests`. Add `.testTarget(name: "EveeAppTests", dependencies: ["EveeApp"])` in `Package.swift`. Keep the Command Line Tools-compatible core check limited to stale operation identifiers and late progress/completion on `ModelDownloadStateMachine`.

- [ ] **Step 2: Run red check**

Run: `swift run evee-core-checks --filter model-download`

Expected: FAIL because the state-machine scenario is not registered.

Run under full Xcode: `swift test --filter ModelDownloadLifecycleTests`

Expected: compile failure because `LocalModelDownloading`, injection, and app actions are absent. If full Xcode is unavailable, record that external toolchain blocker and continue only with the core red/green cycle; do not claim the app integration test passed.

- [ ] **Step 3: Implement controller and UI actions**

```swift
public protocol LocalModelDownloading: Sendable {
    var isDownloaded: Bool { get }
    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws
    func load() async throws
}
```

Make `LocalTranscriber` refine `LocalModelDownloading`, and make both concrete transcribers conform without duplicating implementation. `AppStore` accepts a factory with a production default backed by `TranscriberFactory`, retains one `Task<Void, Never>?`, invalidates the state machine synchronously on cancel, and ignores stale callbacks. `startModelDownload()` returns after installing the retained task so repeated activation can be tested without blocking on provider completion. Onboarding shows Download, Cancel, Retry, or Ready with explicit accessibility label, value, and hint. Cancel never deletes a completed cache. Relaunch maps a complete provider cache to Ready and an incomplete cache after a prior failure/cancellation to Retry.

- [ ] **Step 4: Run focused checks**

Run: `swift run evee-core-checks --filter model-download`

Expected: PASS.

Run under full Xcode: `swift test --filter ModelDownloadLifecycleTests && swift build --target Evee`

Expected: delayed start is single-flight, cancellation ignores late progress/completion, retry starts one new operation, and the app target builds. Record a full-Xcode blocker rather than substituting a core-only build.

Run the child-boundary gate serially: `swift test --parallel --num-workers 2`, `scripts/package_app.sh release`, then `env CFFIXED_USER_HOME="$(mktemp -d /tmp/evee-model-verify.XXXXXX)" scripts/verify_app.sh dist/Evee.app`. Relocate the verified bundle and repeat the packaged onboarding download/repeated activation/Cancel/interruption/relaunch Retry/success journey with keyboard and VoiceOver in isolated macOS state. Record the exact bundle identity and result in the model-download child ticket before committing.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/OnboardingView.swift Sources/EveeCore/Transcription/LocalTranscribers.swift Tests/EveeCoreChecks/main.swift Tests/EveeAppTests/ModelDownloadLifecycleTests.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Make model download cancellable'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Make model download cancellable"
```

### Task 3: Race-safe wake listener lifecycle

**Files:**
- Create: `Sources/EveeCore/Audio/WakePhraseListening.swift`
- Modify: `Sources/EveeCore/Audio/WakePhraseListener.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeAppTests/HotMicLifecycleTests.swift`

**Interfaces:**
- Consumes: `HotMicStateMachine`.
- Produces: injectable `WakePhraseListening`, `AppStore.WakeListenerFactory`, startup generation checks, and a single state-machine-derived published hot-mic state.

- [ ] **Step 1: Add a failing delayed-start race**

```swift
let fake = DelayedWakeListener()
let store = await AppStore(wakeListenerFactory: { fake })
await MainActor.run { store.settings.hotMicEnabled = true }
let start = Task { await store.updateHotMicState() }
await fake.waitUntilStarting()
await store.disableHotMic()
await fake.releaseStart()
await start.value
precondition(await fake.stopCount == 1)
precondition(await store.hotMicState == .disabled)
```

Put the delayed race in `EveeAppTests`. The core check separately drives `HotMicStateMachine` through enable/disable, enable/capture, stale start completion, start failure, and repeated disable without referencing `AppStore`.

- [ ] **Step 2: Run red check**

Run: `swift run evee-core-checks --filter hot-mic-race`

Expected: FAIL because the hot-mic transition scenario is not registered.

Run under full Xcode: `swift test --filter HotMicLifecycleTests`

Expected: compile failure because listener injection and the single published state are absent.

- [ ] **Step 3: Implement invalidation-before-await semantics**

```swift
public protocol WakePhraseListening: Sendable {
    var transcripts: AsyncStream<String> { get }
    func start(deviceUID: String?, lowLatency: Bool) async throws
    func stop() async
}
```

`WakePhraseListener` conforms to the protocol. `AppStore` accepts a factory with a production default, invalidates the hot-mic operation before stopping, and derives UI/accessibility state from `HotMicStateMachine` rather than a separate Boolean. After listener creation, start, and transcript subscription, it rechecks settings, foreground capture, and operation identity. A stale listener is stopped and never assigned. `beginCapture` invalidates the hot-mic generation before awaiting listener cleanup.

- [ ] **Step 4: Run green check**

Run: `swift run evee-core-checks --filter hot-mic-race`

Expected: PASS for enable/disable, enable/capture, failure, and repeated disable.

Run under full Xcode: `swift test --filter HotMicLifecycleTests && swift build --target Evee`

Expected: delayed startup cannot publish after disable or foreground capture, visible/accessibility state remains disabled, and the app target builds.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Audio/WakePhraseListening.swift Sources/EveeCore/Audio/WakePhraseListener.swift Sources/EveeApp/AppStore.swift Tests/EveeCoreChecks/main.swift Tests/EveeAppTests/HotMicLifecycleTests.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Make wake listening race safe'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Make wake listening race safe"
```

### Task 4: Bounded audio mailbox

**Files:**
- Create: `Sources/EveeCore/Audio/BoundedAudioMailbox.swift`
- Create: `Sources/EveeCore/Audio/CopiedAudioBuffer.swift`
- Modify: `Sources/EveeCore/Audio/AudioBufferRelay.swift`
- Modify: `Sources/EveeCore/Audio/WakePhraseListener.swift`
- Modify: `Sources/EveeCore/Transcription/LiveMeetingTranscriber.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/BoundedAudioMailboxTests.swift`

**Interfaces:**
- Produces: lock-backed `BoundedAudioMailbox<Element: Sendable>` with synchronous producer `send`, asynchronous single-consumer `next`, newest retention, close, drain/discard close modes, dropped-count and peak-depth metrics; and immutable `CopiedAudioBuffer: @unchecked Sendable` that owns a deep PCM copy.
- Consumers: microphone/system live transcription and wake listening.

- [ ] **Step 1: Add a failing slow-consumer check**

```swift
let mailbox = BoundedAudioMailbox<Int>(capacity: 3)
let consumer = Task {
    var received: [Int] = []
    while let value = await mailbox.next() {
        received.append(value)
        try? await Task.sleep(for: .milliseconds(5))
    }
    return received
}
for value in 0..<100 { mailbox.send(value) }
precondition(mailbox.depth <= 3)
precondition(mailbox.peakDepth == 3)
precondition(mailbox.droppedCount > 0)
mailbox.close(mode: .drain)
let received = await consumer.value
precondition(received.suffix(3) == [97, 98, 99])
```

Mirror with XCTest for capacity one, newest ordering, a suspended waiter awakened by send, a suspended waiter awakened with `nil` by close, `.drain`, `.discard`, repeated close, and concurrent producers. Add a PCM copy test that mutates the source after construction and proves `CopiedAudioBuffer` owns independent bytes.

- [ ] **Step 2: Run red check**

Run: `swift run evee-core-checks --filter bounded-mailbox`

Expected: compile failure because the mailbox and copied-buffer wrapper are absent.

- [ ] **Step 3: Implement one producer-safe bounded stream per channel**

```swift
public final class BoundedAudioMailbox<Element: Sendable>: @unchecked Sendable {
    public enum CloseMode: Sendable { case drain, discard }
    public init(capacity: Int)
    // Synchronous and lock-protected so real-time tap callbacks do not spawn Tasks.
    public func send(_ element: Element)
    public func next() async -> Element?
    public func close(mode: CloseMode)
    public var depth: Int { get }
    public var peakDepth: Int { get }
    public var droppedCount: Int { get }
}

public struct CopiedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init?(copying source: AVAudioPCMBuffer)
}
```

Implement a fixed-capacity ring with an internal `NSLock`; do not add a collections dependency. Resume continuations only after releasing the lock. Enforce one suspended consumer and make a second simultaneous `next()` a documented programmer error caught by tests. Use `capacity >= 1`; when full, replace the oldest element and increment `droppedCount`. Audio tap callbacks deep-copy into `CopiedAudioBuffer` and synchronously publish to one mailbox. One retained consumer task per channel unwraps the buffer and calls the recognizer. On normal stop use `.drain` and await the consumer before recognizer finish; on cancellation use `.discard`, then await the consumer. Remove per-buffer unstructured `Task` creation from wake and live meeting paths.

- [ ] **Step 4: Run focused check and source scan**

Run: `swift run evee-core-checks --filter bounded-mailbox`

Expected: PASS with peak depth equal to capacity.

Run: `rg -n 'buffer in Task|Task \{ await .*streamAudio' Sources/EveeCore Sources/EveeApp`

Expected: no per-buffer task pattern remains.

Run under full Xcode: `swift test --filter BoundedAudioMailboxTests && swift build --target Evee`

Expected: slow-consumer capacity/order/close/copy tests pass and the app target builds.

Run the child-boundary gate serially: `swift test --parallel --num-workers 2`, `scripts/package_app.sh release`, then `env CFFIXED_USER_HOME="$(mktemp -d /tmp/evee-audio-verify.XXXXXX)" scripts/verify_app.sh dist/Evee.app`. Relocate the verified bundle and repeat rapid wake enable/disable, wake-to-capture, dual-channel live preview, cancellation, and a bounded-memory soak long enough to expose task growth. Record mailbox metrics, resident memory, task count, exact bundle identity, and result in the wake/audio child ticket before committing; Task 7 repeats the full two-hour acceptance soak.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Audio/BoundedAudioMailbox.swift Sources/EveeCore/Audio/CopiedAudioBuffer.swift Sources/EveeCore/Audio/AudioBufferRelay.swift Sources/EveeCore/Audio/WakePhraseListener.swift Sources/EveeCore/Transcription/LiveMeetingTranscriber.swift Sources/EveeApp/AppStore.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/BoundedAudioMailboxTests.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Bound live audio buffering'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Bound live audio buffering"
```

### Task 5: Durable termination checkpoint

**Files:**
- Create: `Sources/EveeCore/Lifecycle/TerminationCheckpointCoordinator.swift`
- Create: `Sources/EveeApp/ApplicationTerminationCoordinator.swift`
- Modify: `Sources/EveeApp/EveeApp.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Sources/EveeCore/Audio/MicrophoneRecorder.swift`
- Modify: `Sources/EveeCore/Audio/SystemAudioRecorder.swift`
- Create: `Tests/EveeCoreTests/TerminationCheckpointTests.swift`
- Create: `Tests/EveeAppTests/ApplicationTerminationCoordinatorTests.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`

**Interfaces:**
- Consumes: `CaptureShutdownPlan` and existing recovery manifests.
- Produces: `CaptureCheckpointing`, actor `TerminationCheckpointCoordinator`, `AppStore.checkpointForTermination() async throws`, and AppKit terminate-later coordination installed through `@NSApplicationDelegateAdaptor`.

- [ ] **Step 1: Add failing checkpoint idempotency checks**

```swift
let recorder = FakeCaptureCheckpointing()
let coordinator = TerminationCheckpointCoordinator(checkpointer: recorder)
async let first = coordinator.checkpoint()
async let second = coordinator.checkpoint()
try await (first, second)
precondition(await recorder.callCount == 1)
```

Add Core XCTest asserting duplicate calls join one task, success clears the joined task, failure is replayed to every waiter, and a later explicit retry creates one new task. Add app-target tests with a fake AppKit reply sink asserting a checkpoint failure or deadline returns `.terminateCancel`, never `.terminateNow`, and a late completion after cancellation cannot reply again.

- [ ] **Step 2: Run red check**

Run: `swift run evee-core-checks --filter termination-checkpoint`

Expected: FAIL because the core coordinator/protocol are absent.

Run under full Xcode: `swift test --filter ApplicationTerminationCoordinatorTests`

Expected: compile failure because AppKit delegate installation/reply ownership is absent.

- [ ] **Step 3: Implement AppKit termination ownership**

```swift
@MainActor
public protocol CaptureCheckpointing: AnyObject {
    func checkpointForTermination() async throws
}

public actor TerminationCheckpointCoordinator {
    public init(checkpointer: any CaptureCheckpointing)
    public func checkpoint() async throws
}

@MainActor
final class ApplicationTerminationCoordinator: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
}
```

Install the delegate with `@NSApplicationDelegateAdaptor` in `EveeApp`, then assign the `@StateObject` store once before bootstrap. `applicationShouldTerminate` returns `.terminateNow` only for `.terminateImmediately`; every active plan returns `.terminateLater`, starts or joins one coordinator task, and eventually calls `sender.reply(toApplicationShouldTerminate:)` exactly once.

Checkpoint invalidates shortcut, wake, live-transcription, delivery, API, and webhook generations before awaiting cleanup. It then stops/finalises both writers, validates and adds every produced track to the existing manifest, persists meeting title/notes, stops the privacy-plan integration coordinators, and only then replies `true`. Starting, recording, finishing/transcribing, delivering, and cancelling follow their Task 1 shutdown actions. Checkpoint never starts a long transcription.

Use an operation identifier for the delegate reply and race the joined checkpoint against a conservative deadline. Deadline invalidates only the reply operation, cancels termination with `reply(false)`, leaves the app open, and presents an actionable recovery path; it does not cancel or overlap the durability task. Failure follows the same single-reply path. Any later track or manifest completion is preserved but cannot issue a second AppKit reply, and a repeated quit joins the still-running task. If writers have already stopped when a later durability step fails, transition the UI to a recoverable failed/checkpointed state rather than recording, retain all produced paths, and make the next quit retry only unfinished durability steps.

- [ ] **Step 4: Run focused checks**

Run: `swift run evee-core-checks --filter termination-checkpoint`

Expected: PASS for idle, duplicate quit, successful checkpoint, and failed checkpoint.

Run under full Xcode: `swift test --filter ApplicationTerminationCoordinatorTests && swift build --target Evee`

Expected: terminate-later wiring, deadline, exactly-once reply, retry after partial failure, and the app target build pass.

Run the child-boundary gate serially: `swift test --parallel --num-workers 2`, `scripts/package_app.sh release`, then `env CFFIXED_USER_HOME="$(mktemp -d /tmp/evee-quit-verify.XXXXXX)" scripts/verify_app.sh dist/Evee.app`. Relocate the verified bundle and repeat idle, starting, recording, transcribing, delivering, and cancelling quit paths plus duplicate quit and injected durability failure in isolated data. Relaunch and validate both retained tracks and notes. Record exact bundle identity and result in the termination child ticket before committing.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Lifecycle/TerminationCheckpointCoordinator.swift Sources/EveeApp/ApplicationTerminationCoordinator.swift Sources/EveeApp/EveeApp.swift Sources/EveeApp/AppStore.swift Sources/EveeCore/Audio/MicrophoneRecorder.swift Sources/EveeCore/Audio/SystemAudioRecorder.swift Tests/EveeCoreTests/TerminationCheckpointTests.swift Tests/EveeAppTests/ApplicationTerminationCoordinatorTests.swift Tests/EveeCoreChecks/main.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Checkpoint active capture before quit'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Checkpoint active capture before quit"
```

### Task 6A: Partial-track validation and explicit recovery selection

**Files:**
- Create: `Sources/EveeCore/Audio/RecoveryTrackValidator.swift`
- Modify: `Sources/EveeCore/Persistence/LibraryStore.swift`
- Modify: `Sources/EveeCore/Models.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Sources/EveeApp/UI/LibraryView.swift`
- Modify: `Sources/EveeApp/UI/MeetingWorkspaceView.swift`
- Modify: `Tests/EveeCoreTests/WorkspaceLifecycleTests.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`

**Interfaces:**
- Produces: `RecoveryTrackAssessment`, `RecoveryTrackSelection`, `LibraryStore.assessRecoveryTracks(captureID:)`, and selected-role commit semantics.
- Consumers: recovery UI, normal capture commit, Task 6B bootstrap, and Task 7 physical recovery.

- [ ] **Step 1: Add failing independent-track and atomic-commit checks**

```swift
let assessments = try await store.assessRecoveryTracks(captureID: captureID)
precondition(assessments.first(where: { $0.role == .microphone })?.isValid == true)
precondition(assessments.first(where: { $0.role == .system })?.isValid == false)

let saved = try await store.commitRecoveredRecord(
    proposed,
    recoveryID: captureID,
    trackSelection: .roles([.microphone]),
    keepAudio: true
)
precondition(saved.audioTracks.map(\.role) == [.microphone])
```

Add XCTest fixtures for valid microphone/invalid system, valid system/invalid microphone, both valid, neither valid, missing selected source, selection of an invalid role, metadata-write failure after copies, retry after that failure, and explicit discard. Assert failure preserves the recovery originals and any pre-existing destination record/audio.

- [ ] **Step 2: Run red checks**

Run: `swift run evee-core-checks --filter recovery-tracks`

Expected: compile failure because assessment and selected-role commit APIs are absent.

Run under full Xcode: `swift test --filter WorkspaceLifecycleTests`

Expected: new partial-track cases fail while existing retention/recovery cases remain green.

- [ ] **Step 3: Implement independent validation and selected-role commit**

```swift
public struct RecoveryTrackAssessment: Identifiable, Equatable, Sendable {
    public let track: WorkspaceAudioTrack
    public let isValid: Bool
    public let failureReason: String?
    public var id: UUID { track.id }
    public var role: AudioTrackRole { track.role }
}

public enum RecoveryTrackSelection: Equatable, Sendable {
    case allValid
    case roles(Set<AudioTrackRole>)
}
```

`RecoveryTrackValidator` resolves paths through `LibraryStore.safeURL`, rejects links/directories/empty files, opens the container through AVFoundation, requires at least one decodable audio track and finite positive duration, and returns one assessment per manifest track without failing the remaining tracks. It does not run ASR during listing.

Extend `commitRecoveredRecord` with `trackSelection`, defaulting normal capture completion to all recorded tracks. Resolve `.allValid` from fresh assessments at commit time. Reject an empty selection and any explicitly selected invalid/missing role before copying. Copy selected files under unique, never-overwritten names in the record directory, verify byte count and decodable container, durably save metadata pointing to those copies, then remove recovery originals and any formerly owned files no longer referenced. On metadata failure remove only the new unique copies; recovery originals and any previous metadata/audio remain untouched. A crash before metadata commit leaves recovery authoritative and only harmless new orphan copies for reconciliation; a crash after commit leaves valid metadata-owned copies.

Explicit interrupted-capture recovery always passes `keepAudio: true`, independent of ordinary retention defaults. A system-only meeting uses the system transcript as its primary text, produces system-channel segments, and remains labelled as recovered from system audio; dictation and memo recovery reject system-only selection. `LibraryView` owns the per-track validity rows and Recover all valid / microphone / system / Discard actions. `MeetingWorkspaceView` shows the matching notes/recovery warning. Remove the current microphone-only UI disable and `AppStore.recover` guard only after these paths exist.

- [ ] **Step 4: Run focused checks and build the app**

Run: `swift run evee-core-checks --filter recovery-tracks`

Expected: PASS for independent validation and selected-role commit.

Run under full Xcode: `swift test --filter WorkspaceLifecycleTests && swift build --target Evee`

Expected: all recovery/rollback cases pass and the app target builds.

Run the child-boundary gate serially: `swift test --parallel --num-workers 2`, `scripts/package_app.sh release`, then `env CFFIXED_USER_HOME="$(mktemp -d /tmp/evee-track-verify.XXXXXX)" scripts/verify_app.sh dist/Evee.app`. Relocate the verified bundle and exercise both-valid, microphone-only, system-only, neither-valid, each explicit selection, discard, playback, export, notes, and retention independence. Record disk effects, exact bundle identity, and result in the partial-track child ticket before committing.

- [ ] **Step 5: Review, scan, and commit the partial-track boundary**

```bash
git add Sources/EveeCore/Audio/RecoveryTrackValidator.swift Sources/EveeCore/Persistence/LibraryStore.swift Sources/EveeCore/Models.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/LibraryView.swift Sources/EveeApp/UI/MeetingWorkspaceView.swift Tests/EveeCoreTests/WorkspaceLifecycleTests.swift Tests/EveeCoreChecks/main.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Recover every valid capture track'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Recover every valid capture track"
```

### Task 6B: Preserve corrupt draft, records, and settings and continue safely

**Files:**
- Modify: `Sources/EveeCore/Persistence/LibraryStore.swift`
- Modify: `Sources/EveeCore/Models.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Sources/EveeApp/UI/RootView.swift`
- Modify: `Tests/EveeCoreTests/WorkspaceLifecycleTests.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`

**Interfaces:**
- Produces: `RecoveredLibraryLoad<Value>`, `loadRecordsRecoveringCorruption()`, `loadSettingsRecoveringCorruption()`, and `loadMeetingDraftRecoveringCorruption()`.
- Consumers: `AppStore.bootstrap()` and user-facing recovery status.

- [ ] **Step 1: Add failing corrupt canonical-source checks**

```swift
try Data("{".utf8).write(to: root.appendingPathComponent("meeting-draft.json"), options: .atomic)
let result = try await store.loadMeetingDraftRecoveringCorruption()
precondition(result.value == nil)
precondition(result.preservedCorruptURL != nil)
precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting-draft.json").path))
```

Repeat for malformed `records.json` and `settings.json`. Assert records continue as an empty in-memory library, settings continue with privacy-safe defaults, the unreadable bytes are present unchanged at the reported private Corrupt path, the blocking source is absent only after preservation succeeds, and a forced preservation failure leaves the original source untouched and throws.

- [ ] **Step 2: Run red checks**

Run: `swift run evee-core-checks --filter corrupt-library-recovery`

Expected: compile failure because recovering load APIs are absent.

Run under full Xcode: `swift test --filter WorkspaceLifecycleTests`

Expected: corrupt draft/records/settings preserve-and-continue cases fail before implementation.

- [ ] **Step 3: Implement preserve-and-continue loading**

```swift
public struct RecoveredLibraryLoad<Value: Sendable>: Sendable {
    public let value: Value
    public let preservedCorruptURL: URL?
}
```

For each canonical source, decode normally first. On a decoding error, create the private Corrupt directory, move the unreadable file to a unique private destination without overwriting, verify the destination bytes and owner-only permissions, and only then return the safe fallback plus path. A failed move/verification throws and leaves or restores the original source; it never returns a fallback after losing the unreadable bytes. Unsupported future schema remains a hard error and is not treated as corruption.

Use `[]` for unreadable records, a new privacy-safe `EveeSettings()` for unreadable settings, and `nil` for an unreadable draft. `AppStore.bootstrap()` uses all three recovering loads, continues model/transcriber setup, and presents one actionable, deduplicated message listing preserved paths. It does not overwrite fallback records/settings until the user changes data or settings. `RootView` exposes the warning without trapping the app in onboarding.

- [ ] **Step 4: Run focused checks and build the app**

Run: `swift run evee-core-checks --filter corrupt-library-recovery`

Expected: PASS for all three sources, preservation failure, permissions, byte equality, and unsupported schema.

Run under full Xcode: `swift test --filter WorkspaceLifecycleTests && swift build --target Evee`

Expected: preserve-and-continue cases pass and the app target builds.

Run the child-boundary gate serially: `swift test --parallel --num-workers 2`, `scripts/package_app.sh release`, then `env CFFIXED_USER_HOME="$(mktemp -d /tmp/evee-corrupt-verify.XXXXXX)" scripts/verify_app.sh dist/Evee.app`. Relocate the verified bundle and exercise malformed draft, records, and settings in isolated data. Compare preserved bytes, permissions, bootstrap/UI result, and absence of fallback overwrite. Record exact bundle identity and result in the corrupt-state child ticket before committing.

- [ ] **Step 5: Review, scan, and commit the corrupt-source boundary**

```bash
git add Sources/EveeCore/Persistence/LibraryStore.swift Sources/EveeCore/Models.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/RootView.swift Tests/EveeCoreTests/WorkspaceLifecycleTests.swift Tests/EveeCoreChecks/main.swift
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Continue safely after corrupt local state'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Continue safely after corrupt local state"
```

### Task 7: Complete workstream validation and evidence

**Files:**
- Modify: `docs/PRODUCT_RELEASE_GATES.md`
- Modify: `docs/superpowers/plans/2026-08-13-capture-recovery.md`
- Do not add: private acceptance matrices, application data, recordings, model caches, screenshots containing private data, or generated package artifacts.

**Interfaces:**
- Consumes: every prior task and the privacy-plan API/webhook lifecycle.
- Produces: exact-head automated, packaged-app, physical journey, memory, and recovery evidence in the child tickets and release-gate documentation.

- [ ] **Step 1: Run all automated validation serially**

Before heavyweight commands, inspect existing workloads with `ps -axo pid,rss,command | sort -nr -k2 | head -20` and `docker ps` when Docker is available. Do not stop pre-existing user workloads. Then, under full Xcode, run serially:

```bash
swift run evee-core-checks
swift test --num-workers 2
swift build --target Evee
```

Expected: every named core check, all XCTest targets including `EveeAppTests`, and the app target pass. If full Xcode remains unavailable, record the exact blocker; do not replace this gate with a core-only success claim.

- [ ] **Step 2: Package, verify, relocate, and launch an isolated artifact**

```bash
scripts/package_app.sh release
EVEE_VERIFY_HOME="$(mktemp -d /tmp/evee-capture-verify.XXXXXX)"
CFFIXED_USER_HOME="$EVEE_VERIFY_HOME" scripts/verify_app.sh dist/Evee.app
EVEE_RELOCATED_ROOT="$(mktemp -d /tmp/evee-relocated.XXXXXX)"
ditto dist/Evee.app "$EVEE_RELOCATED_ROOT/Evee.app"
```

Expected: packaging and verification pass for the exact head, including the packaged self-test. Retain the temporary paths only for the current validation session, then remove them after the app exits. For Launch Services UI journeys, use a disposable macOS test account or back up and restore real Evee data first; shell environment variables alone are not accepted as proof that Launch Services isolated Application Support.

- [ ] **Step 3: Repeat affected packaged Mac journeys**

Using the relocated bundle as a normal user, record in the private acceptance matrix and the relevant child ticket:

- model first download, repeated activation, Cancel, provider-delayed cancellation, interruption, relaunch Retry, and successful completion with keyboard and VoiceOver;
- rapid wake enable/disable and wake-to-foreground-capture transitions, proving no tap/listening remains after disable in visible and accessible state;
- a two-hour dual-channel live-transcription session with resident memory, task count, mailbox peak depth/drop count, transcript health, and time to first significant issue;
- idle quit, quit while starting, recording, transcribing, delivering, and cancelling; duplicate quit; injected checkpoint failure/deadline; relaunch and recovery;
- interrupted meetings with both valid, microphone-only valid, system-only valid, and neither valid; each explicit recovery choice, playback, export, notes, transcript provenance, and retention independence;
- malformed draft, records, and settings in isolated data, proving preserved bytes, continued bootstrap, actionable UI, and no overwrite before user action.

Expected: every affected journey records output, disk effects, privacy state, accessibility feedback, recovery semantics, exact bundle identity, and elapsed time to first significant issue. A no-crash result alone is not a pass.

- [ ] **Step 4: Run fresh review and final repository gates**

Have fresh reviewers inspect the exact head for capture/concurrency integrity, privacy/security, product journey behavior, and accessibility/visual state. Fix actionable findings through a new coherent cycle and repeat Steps 1–3. Then verify the complete proposed tree and metadata with the same external policy used before commits.

- [ ] **Step 5: Review, scan, and commit only durable documentation**

```bash
git add docs/PRODUCT_RELEASE_GATES.md docs/superpowers/plans/2026-08-13-capture-recovery.md
git diff --cached --check
git diff --cached --stat
git diff --cached
if git diff --cached --name-only | rg -n '\.(caf|m4a|wav|aiff|png|jpe?g|sqlite3|mlmodel|mlmodelc|zip|dmg)$|(records\.json|settings\.json|meeting-draft\.json|api\.token)$|(^|/)(\.build|dist|DerivedData|Application Support|Audio/(Recovery|Records)/|Corrupt/)'; then exit 1; fi
test -n "${EVEE_SECRET_SCAN_COMMAND:?Set the approved staged-secret scanner path}"
"$EVEE_SECRET_SCAN_COMMAND" --staged
test -n "${EVEE_PRIVATE_SCAN_PATTERN:?Set the owner-provided prohibited-reference expression}"
if rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN" . --hidden -g '!.git/**'; then exit 1; fi
EVEE_COMMIT_SUBJECT='Record capture recovery validation evidence'
if { printf '%s\n' "$EVEE_COMMIT_SUBJECT" "$(git branch --show-current)"; git for-each-ref --format='%(refname)'; git log --all --format='%s%n%b'; git diff --cached --name-only; } | rg -n -i -e "$EVEE_PRIVATE_SCAN_PATTERN"; then exit 1; fi
git commit -m "Record capture recovery validation evidence"
```

Expected: only durable, redacted documentation is staged. The private matrix and generated artifacts remain outside Git, every child ticket contains exact-head evidence, and the parent remains open until no P0/P1 finding remains and the complete review is clean.
