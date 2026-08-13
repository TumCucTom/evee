# Evee Production Hardening Design

**Date:** 2026-08-13
**Tracking:** TOM-45 with TOM-46 through TOM-50
**Baseline:** `12488566e2a892077dd6e4f5f1755abac5e04449`

## Purpose

This design closes the confirmed software blockers between Evee's current release candidate and a production-ready native macOS voice workspace. It treats product completeness as a property of complete packaged-app journeys, including failure, cancellation, privacy, accessibility, recovery, and installed-product behavior.

The implementation is divided into four ordered workstreams:

1. privacy boundaries and integration revocation;
2. capture, download, shutdown, and recovery lifecycle ownership;
3. journey consistency, accessibility, and visual correctness;
4. isolated packaging, physical validation, and independent review.

Each workstream must leave the app usable and independently testable. A later workstream may build on an earlier interface, but no workstream may weaken a privacy or data-integrity invariant to simplify its own implementation.

## Product invariants

The following rules apply across every workstream.

- A transcript or retained recording is durably committed before any external delivery reports success.
- Cancellation is terminal for the cancelled operation. A late callback cannot restart it, send data, or overwrite its state.
- Disabling an integration revokes existing access, not only future setup.
- Privacy controls prevent optional content collection at source. They do not merely remove collected data before persistence.
- Evee may transiently retain only the minimum target identity needed to verify guarded delivery.
- Auto-send occurs only after insertion into the original focused control is positively verified.
- Normal termination checkpoints recoverable audio and notes before allowing the process to exit.
- If one meeting channel is damaged, every valid channel remains recoverable and the fallback is explicit.
- Search is a rebuildable projection. Projection failure cannot corrupt or invalidate canonical records.
- Generated verification data never uses the real Evee application-support directory.
- Accessibility state and visible state describe the same operation.
- Approximate attribution and extractive insights remain labelled honestly.
- The distributed app bundle, rather than a SwiftPM executable in its build directory, is the physical-test subject.

## Workstream 1: privacy boundaries and integration revocation

### Context collection policy

Replace the boolean `includeVisibleText` capture API with a `ContextCollectionPolicy` value. It separately controls:

- transient delivery identity: process identifier, bundle identifier, focused element identity, and non-content role;
- selected text;
- window and document metadata;
- web address and code-file metadata;
- recipient metadata;
- visible accessibility text.

Ordinary dictation always collects the transient delivery identity because safe delivery depends on it. It does not read selection, URL, document, recipient, window title, or visible text unless the corresponding opt-in behavior needs that value. Selection transformation reads selected text because the user explicitly invoked that operation. Per-application style selection uses the bundle identifier without reading focused content.

The persisted `WorkspaceContext` remains independently filtered. This provides defence in depth but is not the primary privacy control.

### Loopback API lifecycle

`LocalAPIServer` will own a lock-protected registry of accepted connections and a monotonically increasing access generation.

- `startWithCredentials` begins a new generation.
- `stop`, `rotateToken`, and `revokeToken` increment the generation and cancel every accepted connection.
- Every receive, asynchronous record lookup, and send captures its generation and aborts if it is no longer current.
- Stopping clears the in-memory token as well as public credentials.
- Connections have a header-completion deadline and a bounded active-connection count.
- Rejected, expired, or revoked requests close without a workspace response.

Token-file migration cleanup runs after every successful Keychain read so a failed legacy-file deletion is retried on later launches.

Public API responses use explicit data-transfer types. They exclude audio storage paths, recovery identifiers, webhook destinations and state, private raw text, and context fields that the route does not explicitly document.

### Webhook ownership

Move outbox execution behind a dedicated actor. The actor owns exactly one task per delivery identifier and an integration generation.

- Enabling or changing a destination starts a new generation.
- Disabling, cancelling, or changing the destination cancels every active task and marks matching stored deliveries terminally cancelled.
- A completion may mutate durable state only when its task is still registered and its generation still matches.
- Manual retry accepts only retryable pending or failed deliveries while the integration is enabled.
- A cancelled delivery is never counted as actionable and cannot be retried.
- Payload bytes remain immutable for a delivery identifier. Regenerating bytes creates a new identifier.

Webhook signatures cover a canonical version, event name, timestamp, delivery identifier, and body digest. Redirect refusal remains in place.

### Packaged helper revocation

Add an explicit `mcpEnabled` setting with a safe legacy default of `false`.

Registration is a transaction:

1. detect supported installed clients;
2. show the exact targets;
3. write only selected configurations;
4. persist `mcpEnabled = true` after successful writes.

No fallback configuration is written when no client is detected. Detection includes the supported local Codex configuration path.

Unregister removes only Evee's server entry, preserves every unrelated configuration value, and then persists `mcpEnabled = false`. The packaged helper checks the shared setting before initialization and every tool call, so a stale client configuration fails closed after revocation.

Malformed narrow filters return invalid-parameter errors. They never broaden a query to all record kinds or all history. Helper responses use the same explicit public data-transfer types as the loopback API.

## Workstream 2: capture, download, shutdown, and recovery

### Testable state machines

Add focused state-machine types to `EveeCore` rather than testing the 1,500-line UI store indirectly.

- `ModelDownloadStateMachine` provides idle, downloading, cancelling, ready, and failed states with operation identifiers.
- `HotMicStateMachine` provides disabled, starting, listening, stopping, and failed states with generation checks.
- `CaptureShutdownPlan` converts the current capture lifecycle into an explicit checkpoint action.
- `BoundedAudioMailbox` provides a single-consumer, bounded-newest buffer path for live transcription.

`AppStore` remains the main-actor orchestrator. It delegates transition decisions to these types and owns the concrete recorder, transcriber, and UI effects.

### Model download

Only one model-download task may exist.

- Repeated activation while downloading has no effect.
- The onboarding primary action becomes Cancel while a download is active.
- Cancellation invalidates the operation identifier immediately and updates accessible status.
- Progress and completion callbacks are ignored unless their identifier is current.
- Relaunch inspects the model provider's cache and presents Retry when the model is incomplete.
- Cancellation never removes a previously complete model.

The app reports provider cancellation limitations honestly. If the underlying transfer cannot stop immediately, Evee stops observing and loading it, remains disabled for capture, and allows a clean retry when provider cleanup finishes.

### Wake listening

Wake-listener startup captures the current generation. After every suspension point it confirms that:

- wake listening is still enabled;
- no foreground capture is active;
- the generation is current.

If any condition fails, the newly created listener is stopped before it can be published. Disable and foreground capture invalidate the generation before awaiting cleanup. Visible and accessible hot-mic state derives from the state machine rather than a separate Boolean.

### Bounded live audio

Audio tap callbacks copy into a bounded mailbox with newest-buffer retention. One consumer task per channel drains the mailbox into its streaming recognizer. Producers never create an unbounded task per buffer. Stop closes the mailbox, drains or discards according to operation semantics, and awaits the consumer.

Mailbox unit tests use a deliberately slow consumer and prove the configured capacity cannot be exceeded. Physical long-session tests record resident memory and task count.

### Normal termination

An application delegate participates in `applicationShouldTerminate`. If no capture is active, termination proceeds immediately. Otherwise it returns terminate-later, begins one checkpoint task, and replies to AppKit only after durable checkpoint completion. If checkpointing exceeds a conservative deadline, Evee cancels termination, keeps the app open, and presents an actionable error; it does not claim a safe exit.

Checkpointing does not attempt a long transcription. It:

1. invalidates shortcut, wake, live-transcription, and delivery generations;
2. stops microphone and system writers so their containers are finalised;
3. records every valid track in the existing recovery manifest;
4. saves the latest meeting title and notes;
5. stops local integrations and active sends;
6. permits termination.

Repeated quit requests join the same task. Force termination remains recoverable to the extent that the operating system allowed buffered data to reach disk.

### Recovery

Recovery validates tracks independently. The UI presents valid and invalid channels and offers:

- recover every valid channel;
- recover microphone only;
- recover system audio only;
- discard the capture.

These choices are available independently of long-term audio-retention preferences because recovery prevents accidental loss after interruption. The final record keeps audio only when the user explicitly chooses a recovery action that retains it.

Malformed meeting drafts are moved to the existing private corrupt-data area and bootstrap continues with an actionable message. Canonical records and settings follow the same preserve-and-continue rule when a safe default can be used without overwriting the unreadable source.

## Workstream 3: journey consistency, accessibility, and visual UX

### Accessibility foundations

Every action receives an explicit accessibility label and, where stateful, a value or hint. This includes onboarding permissions and download, search clearing, per-application deletion, recovery notes, speaker labels, helper registration, and destructive actions.

Onboarding uses a scrollable adaptive container, a default focus target, explicit denied-permission recovery text, and focus restoration after returning from System Settings. Download progress exposes a percentage and status through the accessibility tree.

The primary action style uses an adaptive foreground/background pairing that reaches at least 4.5:1 in both appearances. Disabled state remains visually distinguishable without relying only on opacity.

Status announcements are deduplicated and include:

- wake listening started and stopped;
- capture started, stopped, cancelled, failed, and recovered;
- microphone silence or channel failure;
- model download progress milestones, cancellation, failure, and readiness;
- webhook and helper revocation.

### System-wide controls

The nonactivating HUD remains status-only so it never steals focus from a delivery target. Stop and Discard move to the accessible menu-bar surface and global shortcut commands. The HUD text tells keyboard and VoiceOver users where those actions are available.

Hands-free and wake-listening state appears in the menu icon, menu text, HUD, and VoiceOver announcements. Disabled listening removes the audio tap before reporting success.

### Meeting workspace

- Stop recording no longer owns unmodified Return while notes are editable.
- Privacy-setting actions are separate accessibility children, not combined into status prose.
- Microphone and system-channel health warnings appear in the meeting view, menu bar, HUD, and announcements.
- Speaker-label edits atomically rebuild the speaker-prefixed transcript, search projection, exports, API/helper response, and extractive intelligence.
- Speaker inputs identify the segment time and current label.

The main and settings windows apply the strongest supported window-sharing exclusion. Because modern third-party screen capture may not honor every AppKit exclusion, product copy describes this as best-effort protection and presents a one-action privacy mode that hides transcript, notes, context, and credentials in Evee windows during sharing. No UI claims guaranteed invisibility when the platform cannot prove it.

### Workspace consistency

The FTS projection indexes title, finished text, raw text when retained, notes, tags, source application, permitted context fields, segment labels/text, and extractive insight fields. Search snippets come from the field that matched.

Every SQLite step loop distinguishes `SQLITE_ROW`, `SQLITE_DONE`, and error. An error invalidates and rebuilds the projection from canonical records.

Audio export copies to a private sibling temporary file, verifies the copy, and atomically replaces the destination. Failure preserves the previous destination.

### Product scope honesty

Selection transformations remain deterministic while Evee has no suitable local generative rewrite engine across its supported macOS range. Unsupported free-form rewrites fail clearly instead of inventing output. The acceptance review must establish whether current target behavior actually requires unrestricted generation. If it does, this branch cannot claim parity until a separately designed, licensed, locally testable rewrite model is delivered; deterministic commands must not be presented as equivalent.

Meeting detection in this workstream is suggestion-only and opt-in. While enabled, Evee observes a user-editable allowlist of running native meeting applications. Browser detection additionally requires the existing window-metadata permission and matches a documented user-editable title list. A match shows an accessible start-meeting suggestion with a dismiss action and cooldown. It never starts recording automatically, reads call content, or claims that application presence proves a call is active.

## Workstream 4: packaging, verification, and release evidence

### Safe self-test mode

Installation self-test mode renders no normal application scene and never starts `AppStore.bootstrap`, workspace intelligence, shortcuts, capture, integrations, or shared stores. It runs only the explicit temporary-root checks and exits.

The self-test recalculates and verifies every resource-seal entry rather than checking only that the seal file exists.

### Safe verifier

`verify_app.sh` creates its own temporary Foundation home and passes it to every app and helper subprocess. It seeds synthetic records and verifies that all 11 helper tools return the correct domain-specific values. It asserts that a sentinel real-data path is never present in output.

Temporary directories are removed on success and failure. The script never reads or writes the operator's Evee application-support data.

### Toolchain preflight

Build and packaging scripts fail early with an actionable message when the selected developer directory is Command Line Tools rather than full Xcode. CI continues to select a pinned Xcode installation.

Full local validation requires enough free disk for Xcode, dependencies, both local speech models under test, recordings, and temporary package copies. Existing unrelated processes and containers are inspected before heavyweight validation; tests, builds, packaging, and long recordings run serially.

### Physical acceptance evidence

The private acceptance matrix records, for each of the ten requested journey groups:

- exact commit and packaged bundle identity;
- setup and isolated data root;
- input action and expected output;
- UI, accessibility, privacy, and disk effects;
- recovery or cancellation result;
- pass, fail, or externally blocked status;
- elapsed time to the first significant issue.

The final candidate requires two hours of normal use without a significant issue. Model download and permission tests use disposable macOS state where possible; any test that would alter existing user permissions or real data is preceded by a backup and a restoration plan.

## Testing strategy

### Automated layers

1. Pure state-machine tests cover operation identifiers, cancellation, stale callbacks, repeated events, and late completion.
2. Integration tests use temporary stores and real local sockets for API fragmentation, revocation, timeout, connection caps, and token rotation.
3. Webhook tests use a controllable local URL protocol or loopback server for redirects, delayed bodies, cancellation, relaunch, immutable payloads, and retry state.
4. Persistence tests cover corrupted drafts, search step errors, projection rebuild, atomic export, and partial-track recovery.
5. Registration tests cover detection, no-client behavior, preservation of unrelated configuration, unregister, permissions, and fail-closed helper access.
6. Packaging tests use the relocated app and synthetic isolated data.

### Physical layers

After every coherent workstream:

1. run focused tests;
2. run the complete suite;
3. package and verify the app;
4. relocate and launch through Launch Services;
5. repeat affected journeys in real macOS applications;
6. inspect data and accessibility effects;
7. update the acceptance matrix and Linear evidence.

Heavyweight commands remain serialized. Independent source reviews may run in parallel.

## Migration and compatibility

New settings decode to privacy-safe defaults. Existing helper registrations are not silently treated as enabled; the settings UI detects them and asks the user to adopt or remove them. Revocation preserves unrelated client configuration.

Existing records remain decodable. Search schema changes invalidate and rebuild the projection. Existing webhook delivery identifiers keep their stored payload bytes; records lacking immutable bytes receive new identifiers on explicit retry.

No migration deletes recovery audio, canonical records, model files, or user configuration without an explicit user action.

## Release gates

The branch is eligible for a pull request only when:

- all focused and full tests pass under full Xcode;
- the exact head packages and verifies from an isolated root;
- affected physical journeys pass on the relocated bundle;
- no P0 or P1 software finding remains;
- fresh product, integrity, security/privacy, and accessibility/visual reviews inspect the exact head;
- the complete proposed tree, commits, branches, pull-request text, workflows, and generated artifact names pass the prohibited-reference scan;
- local data, model weights, screenshots, credentials, and generated reports are absent from the commit;
- external signing, notarisation, publication, and immutable-hosting-metadata blockers are reported separately and honestly.

## External blockers

The following items require owner-controlled access or external platform action and do not block unsigned local hardening:

- installation of full Xcode after sufficient disk space is available;
- Developer ID Application certificate and private key;
- Apple notarisation credentials;
- public release publication approval;
- hosting-provider support for immutable historical metadata that cannot be edited through supported repository APIs.
