# Privacy and Integration Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make optional context collection and every local integration fail closed when disabled, revoked, cancelled, malformed, or stale.

**Architecture:** Add explicit privacy policy and public response types in EveeCore, then give the loopback server, webhook outbox, and packaged helper generation-based lifecycle ownership. A small command-line core-check target provides executable red/green checks on Command Line Tools while XCTest remains the CI authority.

**Tech Stack:** Swift 5.10/6.x, Foundation, Network.framework, CryptoKit, Swift concurrency, XCTest, SwiftPM

**Spec:** `docs/superpowers/specs/2026-08-13-production-hardening-design.md`

## Global Constraints

- Minimum deployment target remains macOS 14.
- No hosted service, analytics SDK, or cloud-processing dependency may be added.
- Cancellation is terminal; stale callbacks cannot expose data or mutate durable state.
- Disabled integrations must revoke existing access.
- Optional context collection must be prevented at source.
- Existing unrelated client configuration must be preserved byte-for-byte at the semantic JSON level.
- Public responses must exclude storage paths, recovery identifiers, webhook metadata, private raw text, and unrequested context.
- Repository and GitHub materials must contain only neutral product language.
- Tests and verification must use temporary synthetic data.

---

### Task 1: Command-line core check harness and context collection policy

**Files:**
- Modify: `Package.swift`
- Create: `Tests/EveeCoreChecks/main.swift`
- Create: `Sources/EveeCore/Delivery/ContextCollectionPolicy.swift`
- Modify: `Sources/EveeCore/Delivery/TextDelivery.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Test: `Tests/EveeCoreTests/ContextTransformTests.swift`

**Interfaces:**
- Produces: `ContextCollectionPolicy`, `TextDelivery.frontmostApplication(policy:)`, and `evee-core-checks --filter context-policy`.
- Consumers: AppStore dictation/selection startup and later privacy reviews.

- [ ] **Step 1: Add the failing core check and XCTest cases**

```swift
let ordinary = ContextCollectionPolicy.ordinaryDictation(
    retainMetadata: false,
    captureVisibleText: false
)
precondition(ordinary.collectsDeliveryIdentity)
precondition(!ordinary.collectsSelectedText)
precondition(!ordinary.collectsWindowMetadata)
precondition(!ordinary.collectsVisibleText)

let transform = ContextCollectionPolicy.selectionTransformation(retainMetadata: false)
precondition(transform.collectsSelectedText)
```

Add an executable target depending only on `EveeCore`. The check runner accepts `--filter context-policy` and exits non-zero on a failed precondition. Mirror these assertions in `ContextTransformTests`.

- [ ] **Step 2: Run the red check**

Run: `swift run evee-core-checks --filter context-policy`

Expected: FAIL at compile time because `ContextCollectionPolicy` does not exist.

- [ ] **Step 3: Implement the policy and gated AX reads**

```swift
public struct ContextCollectionPolicy: Equatable, Sendable {
    public var collectsDeliveryIdentity: Bool
    public var collectsSelectedText: Bool
    public var collectsWindowMetadata: Bool
    public var collectsWebAndFileMetadata: Bool
    public var collectsRecipientMetadata: Bool
    public var collectsVisibleText: Bool
}
```

Change `frontmostApplication` so it performs each `AXUIElementCopyAttributeValue` call only when the matching policy field is true. Ordinary dictation collects process/bundle/focused-element identity and role only. Selection transformation explicitly collects selected text. AppStore constructs policy from the operation and settings.

- [ ] **Step 4: Run green checks and inspect call sites**

Run: `swift run evee-core-checks --filter context-policy`

Expected: PASS with `context-policy: passed`.

Run: `rg -n 'frontmostApplication\(' Sources Tests`

Expected: every call supplies a named `policy:` argument.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/ContextTransformTests.swift Sources/EveeCore/Delivery/ContextCollectionPolicy.swift Sources/EveeCore/Delivery/TextDelivery.swift Sources/EveeApp/AppStore.swift
git commit -m "Enforce context collection policy"
```

### Task 2: Revocable loopback API and public record responses

**Files:**
- Create: `Sources/EveeCore/Integrations/PublicWorkspaceRecord.swift`
- Modify: `Sources/EveeCore/Integrations/LocalAPIServer.swift`
- Modify: `Sources/EveeMCP/main.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/LocalAPIServerTests.swift`

**Interfaces:**
- Consumes: `LibraryStore(rootURL:)` and `WorkspaceRecord`.
- Produces: `PublicWorkspaceRecord.init(_:)`, revocable connection generations, bounded connections, and header deadlines.

- [ ] **Step 1: Add failing public-response and socket checks**

```swift
let privateRecord = WorkspaceRecord(
    kind: .meeting,
    title: "Synthetic",
    text: "Visible",
    rawText: "Private raw",
    audioRelativePath: "Audio/private.caf",
    recoverySourceID: UUID()
)
let encoded = try JSONEncoder().encode(PublicWorkspaceRecord(privateRecord))
let json = String(decoding: encoded, as: UTF8.self)
precondition(!json.contains("private.caf"))
precondition(!json.contains("Private raw"))
```

Add an async socket scenario that connects, sends half an authenticated header, calls `server.stop()`, sends the remainder, and requires EOF without `Visible` in the response.

- [ ] **Step 2: Run the red checks**

Run: `swift run evee-core-checks --filter public-record`

Expected: FAIL because `PublicWorkspaceRecord` is missing.

Run: `swift run evee-core-checks --filter api-revoke`

Expected: FAIL because the accepted connection remains live.

- [ ] **Step 3: Implement explicit DTOs and connection ownership**

```swift
public struct PublicWorkspaceRecord: Codable, Sendable {
    public let id: UUID
    public let kind: WorkspaceRecordKind
    public let createdAt: Date
    public let updatedAt: Date
    public let title: String
    public let text: String
    public let sourceApplication: String?
    public let duration: TimeInterval?
    public let segments: [TranscriptSegment]
    public let meetingIntelligence: MeetingIntelligence?
    public let memoIntelligence: MemoIntelligence?
    public let notes: String
    public let tags: [String]
}
```

Track `[ObjectIdentifier: NWConnection]`, an `accessGeneration`, a maximum of 32 connections, and a five-second header deadline under `stateLock`. `stop`, rotation, and revocation increment the generation and cancel the detached registry. Every callback checks generation before reading the store or sending. Clear the in-memory token on stop. Retry legacy token-file deletion after every successful Keychain read.

- [ ] **Step 4: Run focused checks**

Run: `swift run evee-core-checks --filter public-record`

Expected: PASS.

Run: `swift run evee-core-checks --filter api-revoke`

Expected: PASS with the fragmented client receiving EOF.

Run: `swift run evee-core-checks --filter api-limits`

Expected: PASS for timeout and connection-cap scenarios.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Integrations/PublicWorkspaceRecord.swift Sources/EveeCore/Integrations/LocalAPIServer.swift Sources/EveeMCP/main.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/LocalAPIServerTests.swift
git commit -m "Revoke loopback API access completely"
```

### Task 3: Generation-owned webhook outbox

**Files:**
- Create: `Sources/EveeCore/Integrations/WebhookOutboxCoordinator.swift`
- Modify: `Sources/EveeCore/Integrations/MeetingWebhook.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Sources/EveeCore/Models.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/WebhookOutboxTests.swift`
- Modify: `Tests/EveeCoreTests/EveeCoreTests.swift`

**Interfaces:**
- Produces: actor `WebhookOutboxCoordinator`, `WebhookDispatchToken`, canonical signature input, and terminal cancellation.
- Consumers: AppStore initial delivery, scheduled retry, manual retry, settings save, and termination.

- [ ] **Step 1: Add failing generation and signature checks**

```swift
let coordinator = WebhookOutboxCoordinator()
let token = await coordinator.begin(deliveryID: deliveryID)
await coordinator.cancelAll()
precondition(!(await coordinator.mayCommit(token)))

let first = MeetingWebhook.signature(
    body: body,
    secret: "secret",
    event: "meeting.completed",
    deliveryID: deliveryID,
    timestamp: timestamp
)
let changedID = MeetingWebhook.signature(
    body: body,
    secret: "secret",
    event: "meeting.completed",
    deliveryID: UUID(),
    timestamp: timestamp
)
precondition(first != changedID)
```

Add XCTest coverage with a suspended `URLProtocol` task: cancel the outbox, release the response, and assert stored state remains cancelled.

- [ ] **Step 2: Run red checks**

Run: `swift run evee-core-checks --filter webhook-generation`

Expected: FAIL because the coordinator is absent.

Run: `swift run evee-core-checks --filter webhook-signature`

Expected: FAIL because the current signature authenticates only the body.

- [ ] **Step 3: Implement coordinator and canonical signatures**

```swift
public struct WebhookDispatchToken: Hashable, Sendable {
    public let deliveryID: UUID
    public let generation: UInt64
}

public actor WebhookOutboxCoordinator {
    private var generation: UInt64 = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public func begin(deliveryID: UUID) -> WebhookDispatchToken
    public func register(_ task: Task<Void, Never>, for token: WebhookDispatchToken)
    public func mayCommit(_ token: WebhookDispatchToken) -> Bool
    public func finish(_ token: WebhookDispatchToken)
    public func cancelAll() -> [UUID]
}
```

AppStore routes every send through the coordinator. It commits a receipt or failure only after `mayCommit`. Cancelled rows set `retryable = false`, clear `nextAttemptAt`, and are excluded from `webhookOutboxCount`. Manual retry requires a non-empty valid destination and `.pending`/`.failed` plus `retryable`.

- [ ] **Step 4: Run focused checks**

Run: `swift run evee-core-checks --filter webhook-generation && swift run evee-core-checks --filter webhook-signature`

Expected: both PASS.

Run: `swift build --target EveeCore`

Expected: build completes; unrelated pre-existing warnings are recorded, not hidden.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Integrations/WebhookOutboxCoordinator.swift Sources/EveeCore/Integrations/MeetingWebhook.swift Sources/EveeApp/AppStore.swift Sources/EveeCore/Models.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/WebhookOutboxTests.swift Tests/EveeCoreTests/EveeCoreTests.swift
git commit -m "Own webhook cancellation state"
```

### Task 4: Revocable packaged helper registration

**Files:**
- Modify: `Sources/EveeCore/Models.swift`
- Modify: `Sources/EveeCore/Integrations/MCPRegistration.swift`
- Modify: `Sources/EveeMCP/main.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Sources/EveeApp/UI/SettingsView.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Modify: `Tests/EveeCoreTests/EveeCoreTests.swift`

**Interfaces:**
- Produces: `EveeSettings.mcpEnabled`, `MCPRegistration.removeConfiguration(at:)`, detected Codex configuration, and helper fail-closed checks.
- Consumers: Settings integration UI and packaged verifier.

- [ ] **Step 1: Add failing settings and registration checks**

```swift
let legacy = try JSONDecoder().decode(EveeSettings.self, from: Data("{}".utf8))
precondition(!legacy.mcpEnabled)

let result = try MCPRegistration.removeConfiguration(at: configurationURL)
precondition(result.removedRegistration)
let root = try JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL)) as! [String: Any]
let servers = root["mcpServers"] as! [String: Any]
precondition(servers["evee"] == nil)
precondition(servers["other"] != nil)
```

Add tests that no-client detection returns an empty list and never writes a fallback file.

- [ ] **Step 2: Run red checks**

Run: `swift run evee-core-checks --filter mcp-revocation`

Expected: FAIL because the setting and removal API are absent.

- [ ] **Step 3: Implement transactional registration and fail-closed helper**

```swift
public struct MCPRemovalResult: Equatable, Sendable {
    public let configurationURL: URL
    public let removedRegistration: Bool
}
```

Detect supported configurations, including the local Codex configuration path, without inventing a default target. Register selected clients, then save `mcpEnabled = true`. Unregister every Evee-managed target, preserving other JSON fields, then save false. The helper loads settings before initialize and each tool call; disabled access returns a JSON-RPC error explaining that the user must enable local helper access in Evee.

Validate `kind`, `since`, `limit`, and identifiers explicitly. Reuse `PublicWorkspaceRecord` for record responses.

- [ ] **Step 4: Run focused checks and packaged helper smoke**

Run: `swift run evee-core-checks --filter mcp-revocation`

Expected: PASS.

Run: `swift build --target EveeMCP`

Expected: helper builds with Command Line Tools because it does not depend on the app-only UI packages.

Run: `CFFIXED_USER_HOME="$(mktemp -d /tmp/evee-mcp-plan.XXXXXX)" scripts/smoke_mcp.sh`

Expected: smoke script seeds enabled synthetic settings and all 11 tools return valid JSON.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Models.swift Sources/EveeCore/Integrations/MCPRegistration.swift Sources/EveeMCP/main.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/SettingsView.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/EveeCoreTests.swift scripts/smoke_mcp.sh
git commit -m "Add revocable local helper access"
```

### Task 5: Workstream verification and documentation alignment

**Files:**
- Modify: `README.md`
- Modify: `docs/PRODUCT_RELEASE_GATES.md`
- Modify: `docs/superpowers/plans/2026-08-13-privacy-integrations.md`

**Interfaces:**
- Consumes: all Task 1–4 behavior.
- Produces: accurate privacy/integration wording and checked plan steps backed by evidence.

- [x] **Step 1: Run the complete Command Line Tools-compatible checks**

Run: `swift run evee-core-checks`

Expected: every named core check passes.

Result (2026-08-13): the no-argument invocation exits with usage because the
runner requires `--filter`; every listed filter was then run on the exact
workstream head and passed: `context-policy`, `public-record`, `api-revoke`,
`api-rotate`, `api-limits`, `api-start-races`, `api-revoke-persistence`,
`api-public-errors`, `mcp-public-output`, `mcp-revocation`,
`webhook-generation`, `webhook-signature`, and `webhook-transactions`. See the
Task 5 report for command output.

- [x] **Step 2: Run compiler and protocol validation**

Run: `swift build --target EveeCore && swift build --target EveeMCP`

Expected: both targets build.

Run: `bash scripts/smoke_mcp.sh`

Expected: protocol smoke passes using isolated synthetic data.

Result (2026-08-13): `EveeCore` and `EveeMCP` built successfully, and the
script's isolated synthetic-data smoke passed all 11 advertised tools.

- [x] **Step 3: Update wording and mark only evidenced plan steps**

Document that optional content is collected only when enabled, API disable closes active clients, webhook cancellation is terminal, and helper registration is revocable. Do not claim complete packaged or physical validation yet.

- [ ] **Step 4: Scan the complete workstream diff**

Run: `git diff --check df8f21439fbf58d480a24000ccdc5c743257682e...HEAD`

Run the owner-held restricted-reference policy against the complete tree and proposed commit metadata. The policy itself remains outside the repository.

Expected: no diff errors and no matches.

Controller pre-integration gate: the owner-held restricted-reference scan and
proposed commit-metadata review remain outside this repository and are not
checked here.

- [x] **Step 5: Commit**

```bash
git add README.md docs/PRODUCT_RELEASE_GATES.md docs/superpowers/plans/2026-08-13-privacy-integrations.md
git commit -m "Document revocable local integrations"
```
