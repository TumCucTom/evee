# Accessibility and Product Journeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Evee's packaged macOS journeys visually legible, keyboard- and VoiceOver-operable, privacy-aware, internally consistent, and recoverable under the failure states required by TOM-49.

**Architecture:** Keep lifecycle truth in the state machines defined by the capture plan, derive one presentation model for the menu bar, HUD, and announcements, and put record/search/export consistency in small EveeCore types. SwiftUI views render those models with explicit accessibility semantics; AppKit window integration provides best-effort sharing exclusion, while an independent privacy mode removes sensitive views from both rendering and the accessibility tree.

**Tech Stack:** Swift 5.10/6.x, SwiftUI, AppKit, ApplicationServices accessibility APIs, AVFoundation permission APIs, SQLite FTS5, Swift concurrency, XCTest, SwiftPM

**Spec:** `docs/superpowers/specs/2026-08-13-production-hardening-design.md`

## Global Constraints

- Minimum deployment target remains macOS 14.
- No hosted service, analytics SDK, cloud-processing dependency, or new model dependency may be added.
- The nonactivating HUD remains status-only and must never steal focus from the delivery target.
- Accessibility state and visible state must describe the same current operation.
- Primary-action text must reach at least 4.5:1 contrast in light and dark appearances.
- Privacy mode must avoid constructing sensitive transcript, notes, context, and credential views while active; visual redaction alone is insufficient.
- Window-sharing exclusion is best effort and product copy must not claim guaranteed invisibility.
- Speaker-label changes must update canonical records and every derived projection in one durable save.
- Search remains a rebuildable projection; projection failure cannot damage canonical records.
- Tests and verification use temporary synthetic data and never the real Evee application-support directory.
- Repository, commit, branch, pull-request, issue, workflow, and artifact text must use neutral product language.
- Execute `docs/superpowers/plans/2026-08-13-capture-recovery.md` Tasks 1–3 first; this plan consumes `ModelDownloadState`, `HotMicState`, `AppStore.startModelDownload()`, and `AppStore.cancelModelDownload()`.
- Execute `docs/superpowers/plans/2026-08-13-privacy-integrations.md` Tasks 1–4 before the cross-surface verification in Tasks 6 and 11; those tasks consume `PublicWorkspaceRecord` and revocable helper state.

---

### Task 1: Contrast-safe primary actions

**Files:**
- Create: `Sources/EveeCore/Design/AccessibleColorTokens.swift`
- Modify: `Sources/EveeCore/Design/AnimaTheme.swift:4-90`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/AccessibleColorTokensTests.swift`

**Interfaces:**
- Produces: `RGBColor.relativeLuminance`, `RGBColor.contrastRatio(with:)`, and `AccessibleActionPalette` light/dark tokens.
- Consumers: `AlphaButtonStyle`, `EveeMark`, and future visual regression checks.

- [ ] **Step 1: Write failing palette contrast checks**

```swift
let white = RGBColor(red: 1, green: 1, blue: 1)
for appearance in InterfaceAppearance.allCases {
    for stop in AccessibleActionPalette.gradientStops(for: appearance) {
        precondition(white.contrastRatio(with: stop) >= 4.5)
    }
}
```

Mirror this in `AccessibleColorTokensTests`, including exact assertions that every enabled stop reaches 4.5:1 and the disabled border reaches 3:1 against `paper`.

- [ ] **Step 2: Run the red checks**

Run: `swift run evee-core-checks --filter action-contrast`

Expected: FAIL at compile time because `RGBColor` and `AccessibleActionPalette` do not exist.

- [ ] **Step 3: Implement explicit appearance tokens and a non-opacity-only disabled state**

```swift
public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(with other: RGBColor) -> Double {
        let high = max(relativeLuminance, other.relativeLuminance)
        let low = min(relativeLuminance, other.relativeLuminance)
        return (high + 0.05) / (low + 0.05)
    }
}

public enum InterfaceAppearance: CaseIterable, Sendable { case light, dark }

public enum AccessibleActionPalette {
    private static let magenta = RGBColor(red: 0.714, green: 0.102, blue: 0.835)
    private static let violet = RGBColor(red: 0.486, green: 0.141, blue: 0.882)
    private static let electric = RGBColor(red: 0.098, green: 0.220, blue: 0.953)

    public static func gradientStops(for appearance: InterfaceAppearance) -> [RGBColor] {
        _ = appearance
        return [magenta, violet, electric]
    }
    public static let foreground = RGBColor(red: 1, green: 1, blue: 1)
    public static let disabledBorder = RGBColor(red: 0.365, green: 0.373, blue: 0.937)
}
```

Use the current light action stops for both action appearances because each reaches more than 5:1 against white. Keep the brighter dark accent colors for non-button accents. In `AlphaButtonStyle`, add reduced saturation and a dashed border when disabled; opacity may supplement but cannot be the only disabled cue. Map tokens into SwiftUI colors without changing semantic red/orange/green status colors.

- [ ] **Step 4: Run focused tests**

Run: `swift run evee-core-checks --filter action-contrast`

Expected: PASS and print the minimum enabled contrast ratio, which is at least 4.5.

Run: `swift test --filter AccessibleColorTokensTests`

Expected: PASS under full Xcode.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Design/AccessibleColorTokens.swift Sources/EveeCore/Design/AnimaTheme.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/AccessibleColorTokensTests.swift
git commit -m "Make primary actions accessible in both appearances"
```

### Task 2: Adaptive, cancellable onboarding

**Files:**
- Create: `Sources/EveeCore/Lifecycle/OnboardingPresentation.swift`
- Modify: `Sources/EveeCore/Audio/MicrophoneRecorder.swift:40-49`
- Modify: `Sources/EveeApp/AppStore.swift:35-57,338-384`
- Modify: `Sources/EveeApp/UI/OnboardingView.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/OnboardingPresentationTests.swift`

**Interfaces:**
- Consumes: `ModelDownloadState`, `AppStore.startModelDownload()`, and `AppStore.cancelModelDownload()` from the capture plan.
- Produces: `PermissionState`, `OnboardingPresentation`, `OnboardingFocusTarget`, and `MicrophoneRecorder.authorizationState`.

- [ ] **Step 1: Write failing onboarding-state checks**

```swift
let denied = OnboardingPresentation(
    microphone: .denied,
    accessibility: .granted,
    model: .idle
)
precondition(denied.focusTarget == .microphoneRecovery)
precondition(denied.microphoneActionTitle == "Open Microphone Settings")

let downloading = OnboardingPresentation(
    microphone: .granted,
    accessibility: .granted,
    model: .downloading(fraction: 0.42, status: "Downloading")
)
precondition(downloading.modelAction == .cancel)
precondition(downloading.modelAccessibilityValue == "42 percent, Downloading")
```

Add XCTest cases for not-determined, denied, granted, interrupted/failed, cancelling, and ready states, plus first-incomplete focus selection.

- [ ] **Step 2: Run the red checks**

Run: `swift run evee-core-checks --filter onboarding-presentation`

Expected: FAIL because the presentation types are absent.

- [ ] **Step 3: Implement adaptive layout, explicit semantics, and focus restoration**

```swift
public enum PermissionState: Equatable, Sendable {
    case notDetermined, denied, granted
}

public enum OnboardingModelState: Equatable, Sendable {
    case idle
    case downloading(fraction: Double, status: String)
    case cancelling
    case failed(String)
    case ready
}

public enum OnboardingFocusTarget: Hashable, Sendable {
    case microphoneRequest, microphoneRecovery
    case accessibilityRequest, modelAction
}

public enum ModelOnboardingAction: Equatable, Sendable {
    case download, cancel, retry, none
}

public struct OnboardingPresentation: Equatable, Sendable {
    public let focusTarget: OnboardingFocusTarget
    public let microphoneActionTitle: String
    public let modelAction: ModelOnboardingAction
    public let modelAccessibilityLabel: String
    public let modelAccessibilityValue: String?

    public init(
        microphone: PermissionState,
        accessibility: PermissionState,
        model: OnboardingModelState
    ) {
        microphoneActionTitle = microphone == .denied ? "Open Microphone Settings" : "Allow Microphone"
        if microphone != .granted {
            focusTarget = microphone == .denied ? .microphoneRecovery : .microphoneRequest
        } else if accessibility != .granted {
            focusTarget = .accessibilityRequest
        } else {
            focusTarget = .modelAction
        }
        switch model {
        case .idle:
            (modelAction, modelAccessibilityLabel, modelAccessibilityValue) = (.download, "Download local model", nil)
        case .downloading(let fraction, let status):
            (modelAction, modelAccessibilityLabel, modelAccessibilityValue) =
                (.cancel, "Cancel local model download", "\(Int((fraction * 100).rounded())) percent, \(status)")
        case .cancelling:
            (modelAction, modelAccessibilityLabel, modelAccessibilityValue) = (.none, "Cancelling local model download", nil)
        case .failed(let message):
            (modelAction, modelAccessibilityLabel, modelAccessibilityValue) = (.retry, "Retry local model download", message)
        case .ready:
            (modelAction, modelAccessibilityLabel, modelAccessibilityValue) = (.none, "Local model ready", nil)
        }
    }
}
```

Map `AVAuthorizationStatus` without collapsing denied and not-determined. Adapt the capture plan's `ModelDownloadState` into `OnboardingModelState` in `AppStore`, so UI copy does not depend on operation identifiers. Track whether Accessibility settings have been requested, since macOS exposes trust but not a complete authorization enum. Replace the fixed root stack with a `ScrollView`; use `ViewThatFits(in: .vertical)` with the current spacious stack first and a compact stack second. Add `@FocusState`, set default focus to the first incomplete step, and restore focus after `didBecomeActive`. Give every permission and download action an explicit label and hint. The progress view exposes status and integer percentage. During download, the only model action is Cancel; repeated activation cannot start another task. A denied microphone shows a direct System Settings recovery action rather than another ineffective permission request.

- [ ] **Step 4: Run focused tests and source checks**

Run: `swift run evee-core-checks --filter onboarding-presentation && swift run evee-core-checks --filter model-download`

Expected: both PASS.

Run: `rg -n 'Button\(|ProgressView' Sources/EveeApp/UI/OnboardingView.swift`

Expected: every result is followed by an explicit accessibility label; the progress view also has an accessibility value.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Lifecycle/OnboardingPresentation.swift Sources/EveeCore/Audio/MicrophoneRecorder.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/OnboardingView.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/OnboardingPresentationTests.swift
git commit -m "Make onboarding adaptive and accessible"
```

### Task 3: Explicit action semantics and responsive workspace layouts

**Files:**
- Create: `Sources/EveeCore/Design/AccessibilityCopy.swift`
- Modify: `Sources/EveeApp/UI/RootView.swift`
- Modify: `Sources/EveeApp/UI/LibraryView.swift`
- Modify: `Sources/EveeApp/UI/DictionaryView.swift`
- Modify: `Sources/EveeApp/UI/MeetingWorkspaceView.swift`
- Modify: `Sources/EveeApp/UI/RecordDetailView.swift`
- Modify: `Sources/EveeApp/UI/SettingsView.swift`
- Modify: `Sources/EveeApp/WorkspaceIntelligenceRuntime.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/AccessibilityCopyTests.swift`

**Interfaces:**
- Produces: `AccessibilityCopy.recordRow(record:snippet:)`, contextual delete labels, recovery labels, and `RootLayoutMode`.
- Consumers: every SwiftUI action surface and the packaged AX smoke verifier in Task 11.

- [ ] **Step 1: Write failing semantic-copy and layout checks**

```swift
let label = AccessibilityCopy.recordRow(record: syntheticMeeting, snippet: "…matched decision text…")
precondition(label.contains("matched decision text"))
precondition(AccessibilityCopy.removeAppStyle(named: "Mail") == "Remove writing style for Mail")
precondition(RootLayoutMode.route(.settings, captureState: .idle) == .sidebarAndDetail)
precondition(RootLayoutMode.route(.library, captureState: .idle) == .threeColumn)
```

Add cases for search clearing, retained-track export, recovered notes, speaker input, helper registration/revocation, and every destructive action.

- [ ] **Step 2: Run the red check**

Run: `swift run evee-core-checks --filter accessibility-copy`

Expected: FAIL because `AccessibilityCopy` and `RootLayoutMode` are absent.

- [ ] **Step 3: Apply explicit labels and make dense routes span the window**

```swift
public enum AccessibilityCopy {
    public static func recordRow(record: WorkspaceRecord, snippet: String?) -> String {
        [record.kind.rawValue.capitalized, record.title, snippet, record.sourceApplication]
            .compactMap { $0 }.joined(separator: ", ")
    }
    public static func removeAppStyle(named applicationName: String) -> String {
        "Remove writing style for \(applicationName)"
    }
    public static func recoveredNotes(startedAt: Date) -> String {
        "Recovered meeting notes from \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
    public static func speakerLabel(start: TimeInterval, currentLabel: String?) -> String {
        "Speaker at \(Int(start / 60)) minutes \(Int(start) % 60) seconds, \(currentLabel ?? "unlabelled")"
    }
}

public enum WorkspaceRouteKind: Equatable, Sendable {
    case library, meetings, memos, dictionary, settings
}

public enum RootLayoutMode: Equatable, Sendable {
    case threeColumn
    case sidebarAndDetail

    public static func route(_ route: WorkspaceRouteKind, captureState: CaptureState) -> Self {
        switch route {
        case .settings, .dictionary: .sidebarAndDetail
        case .meetings where captureState != .idle: .sidebarAndDetail
        default: .threeColumn
        }
    }
}
```

Use a two-column sidebar/detail split for Settings, Dictionary, and active meeting capture; retain three columns for library browsing. Replace dense Settings `HStack` rows with `ViewThatFits(in: .horizontal)` or a labelled vertical fallback. Add explicit labels/hints to every `Button`, including text-labelled actions, search clear, per-app removal, helper registration, recovery choices, export, playback, and destructive controls. Label the recovered-notes editor and distinguish each speaker field with timestamp and current label. Mark decorative symbols hidden. Search-row accessibility labels include the same matched snippet visible on screen.

- [ ] **Step 4: Run semantic checks and scan action sites**

Run: `swift run evee-core-checks --filter accessibility-copy`

Expected: PASS.

Run: `rg -n 'Button\s*\{|Button\(' Sources/EveeApp/UI Sources/EveeApp/WorkspaceIntelligenceRuntime.swift`

Expected: manual review confirms each action has an explicit accessibility label at the call site; icon-only actions also have a hint when the consequence is not obvious.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Design/AccessibilityCopy.swift Sources/EveeApp/UI Sources/EveeApp/WorkspaceIntelligenceRuntime.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/AccessibilityCopyTests.swift
git commit -m "Label actions and adapt workspace layouts"
```

### Task 4: Deduplicated status announcements

**Files:**
- Create: `Sources/EveeCore/Lifecycle/AccessibilityStatusEvent.swift`
- Create: `Sources/EveeApp/AccessibilityAnnouncementCoordinator.swift`
- Modify: `Sources/EveeApp/EveeApp.swift:58-206`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/AccessibilityStatusEventTests.swift`

**Interfaces:**
- Consumes: `CaptureState`, `HotMicState`, `ModelDownloadState`, helper revocation state, and webhook revocation state.
- Produces: `AccessibilityStatusEvent`, `AccessibilityAnnouncementReducer.receive(_:) -> String?`, and `AccessibilityAnnouncementCoordinator.post(_:)`.

- [ ] **Step 1: Write failing deduplication and milestone checks**

```swift
var reducer = AccessibilityAnnouncementReducer()
precondition(reducer.receive(.wakeListeningStarted) == "Wake phrase listening started.")
precondition(reducer.receive(.wakeListeningStarted) == nil)
precondition(reducer.receive(.modelDownloadProgress(0.09)) == nil)
precondition(reducer.receive(.modelDownloadProgress(0.10)) == "Local model download 10 percent.")
precondition(reducer.receive(.microphoneSilence) == "No microphone signal has been detected. Check the selected input and mute switch.")
```

Cover capture start/stop/cancel/failure/recovery, wake start/stop/failure, model 10% milestones/cancel/failure/ready, channel failure, and integration revocation.

- [ ] **Step 2: Run the red checks**

Run: `swift run evee-core-checks --filter accessibility-events`

Expected: FAIL because the reducer is absent.

- [ ] **Step 3: Replace ad-hoc announcements with one coordinator**

```swift
public enum AccessibilityStatusEvent: Equatable, Sendable {
    case wakeListeningStarted, wakeListeningStopped
    case captureStarted, captureStopped, captureCancelled, captureRecovered
    case captureFailed(String)
    case microphoneSilence, channelFailed(AudioTrackRole, String)
    case modelDownloadStarted, modelDownloadProgress(Double), modelDownloadCancelled
    case modelDownloadFailed(String), modelReady
    case webhookRevoked, helperRevoked
}

public struct AccessibilityAnnouncementReducer: Sendable {
    private var lastEvent: AccessibilityStatusEvent?
    private var lastProgressBucket = 0

    public init() {}

    public mutating func receive(_ event: AccessibilityStatusEvent) -> String? {
        if case .modelDownloadProgress(let fraction) = event {
            let bucket = min(10, max(0, Int(fraction * 10)))
            guard bucket > 0, bucket != lastProgressBucket else { return nil }
            lastProgressBucket = bucket
            return "Local model download \(bucket * 10) percent."
        }
        guard event != lastEvent else { return nil }
        lastEvent = event
        switch event {
        case .wakeListeningStarted: return "Wake phrase listening started."
        case .wakeListeningStopped: return "Wake phrase listening stopped."
        case .captureStarted: return "Recording started."
        case .captureStopped: return "Recording stopped. Transcribing locally."
        case .captureCancelled: return "Recording discarded."
        case .captureRecovered: return "Interrupted capture recovered."
        case .captureFailed(let message): return "Capture failed. \(message)"
        case .microphoneSilence: return "No microphone signal has been detected. Check the selected input and mute switch."
        case .channelFailed(let role, let message): return "\(role.rawValue.capitalized) audio warning. \(message)"
        case .modelDownloadStarted:
            lastProgressBucket = 0
            return "Local model download started."
        case .modelDownloadCancelled:
            lastProgressBucket = 0
            return "Local model download cancelled."
        case .modelDownloadFailed(let message):
            lastProgressBucket = 0
            return "Local model download failed. \(message)"
        case .modelReady:
            lastProgressBucket = 0
            return "Local model is ready."
        case .webhookRevoked: return "Meeting webhook access revoked."
        case .helperRevoked: return "Local helper access revoked."
        case .modelDownloadProgress: return nil
        }
    }
}

@MainActor
final class AccessibilityAnnouncementCoordinator {
    private var reducer = AccessibilityAnnouncementReducer()

    func post(_ event: AccessibilityStatusEvent) {
        guard let message = reducer.receive(event) else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message,
                       .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
```

Inject one coordinator into `AppStore` and the overlay controller. Remove direct duplicate `NSAccessibility.post` calls. Emit stopped/cancelled only after recorder/listener cleanup has completed, never when cleanup merely starts. Progress announcements occur only at ten-percent boundaries. Status text remains visible for users who do not use VoiceOver.

- [ ] **Step 4: Run focused checks**

Run: `swift run evee-core-checks --filter accessibility-events`

Expected: PASS with no duplicate messages for repeated state publication or audio-level updates.

Run: `rg -n 'NSAccessibility\.post' Sources/EveeApp`

Expected: only `AccessibilityAnnouncementCoordinator.swift` posts announcements.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Lifecycle/AccessibilityStatusEvent.swift Sources/EveeApp/AccessibilityAnnouncementCoordinator.swift Sources/EveeApp/EveeApp.swift Sources/EveeApp/AppStore.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/AccessibilityStatusEventTests.swift
git commit -m "Centralize accessible status announcements"
```

### Task 5: Accessible system-wide capture controls and health state

**Files:**
- Create: `Sources/EveeCore/Lifecycle/SystemVoiceStatus.swift`
- Modify: `Sources/EveeApp/AppStore.swift:8-12,123-203,1070-1181`
- Modify: `Sources/EveeApp/EveeApp.swift:38-55,104-190`
- Modify: `Sources/EveeApp/UI/RecordingPill.swift`
- Modify: `Sources/EveeApp/UI/MenuBarView.swift`
- Modify: `Sources/EveeApp/UI/SettingsView.swift:20-24`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/SystemVoiceStatusTests.swift`

**Interfaces:**
- Consumes: race-safe `HotMicState` and existing capture lifecycle.
- Produces: `SystemVoiceStatus`, `CaptureHealthWarning`, and global `KeyboardShortcuts.Name.cancelCapture`.

- [ ] **Step 1: Write failing system-status checks**

```swift
let listening = SystemVoiceStatus.make(capture: .idle, hotMic: .listening, warnings: [])
precondition(listening.phase == .wakeListening)
precondition(listening.isMicrophoneOpen)
precondition(listening.menuTitle.contains("listening"))

let warning = CaptureHealthWarning(channel: .microphone, reason: .silence)
let recording = SystemVoiceStatus.make(
    capture: .recording(startedAt: .now, level: 0),
    hotMic: .disabled,
    warnings: [warning]
)
precondition(recording.hudWarning != nil)
precondition(recording.availableActions == [.stopAndTranscribe, .discard])
```

Add cases for wake starting/stopping/failure, hands-free capture, microphone silence, unavailable system channel, transcription, delivery, and capture failure.

- [ ] **Step 2: Run the red checks**

Run: `swift run evee-core-checks --filter system-voice-status`

Expected: FAIL because the presentation model is absent.

- [ ] **Step 3: Derive every global surface from one status model**

```swift
public enum SystemVoicePhase: Equatable, Sendable {
    case ready, wakeStarting, wakeListening, wakeStopping
    case captureStarting, recording, processing, delivering, failed
}

public enum SystemVoiceAction: Hashable, Sendable {
    case stopAndTranscribe, discard
}

public enum CaptureHealthReason: Equatable, Sendable {
    case silence, unavailable, failed(String)
}

public struct CaptureHealthWarning: Equatable, Sendable {
    public let channel: AudioTrackRole
    public let reason: CaptureHealthReason
}

public struct SystemVoiceStatus: Equatable, Sendable {
    public let phase: SystemVoicePhase
    public let isMicrophoneOpen: Bool
    public let menuTitle: String
    public let hudTitle: String
    public let hudDetail: String
    public let warnings: [CaptureHealthWarning]
    public let availableActions: Set<SystemVoiceAction>

    public static func make(
        capture: CaptureState,
        hotMic: HotMicState,
        warnings: [CaptureHealthWarning]
    ) -> SystemVoiceStatus
}
```

Publish `systemVoiceStatus` from `AppStore`. Menu icon, menu label, HUD, and VoiceOver all consume it. Remove Stop and Discard buttons and the unused Return shortcut from the nonactivating HUD; its copy directs users to the menu bar and configured shortcuts. Keep Stop/Discard as independently labelled menu actions. Add a configurable global cancel shortcut, defaulting to Option-Command-Escape, and show it beside the existing hands-free shortcut. Surface microphone silence and missing/failed system channel in the menu and HUD. Disable wake listening by invalidating its generation and removing the audio tap before announcing success.

- [ ] **Step 4: Run focused tests and source assertions**

Run: `swift run evee-core-checks --filter system-voice-status && swift run evee-core-checks --filter hot-mic-race`

Expected: PASS.

Run: `rg -n 'Button\(|keyboardShortcut' Sources/EveeApp/UI/RecordingPill.swift`

Expected: no buttons or keyboard shortcuts remain in the HUD.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Lifecycle/SystemVoiceStatus.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/EveeApp.swift Sources/EveeApp/UI/RecordingPill.swift Sources/EveeApp/UI/MenuBarView.swift Sources/EveeApp/UI/SettingsView.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/SystemVoiceStatusTests.swift
git commit -m "Expose accessible system-wide capture state"
```

### Task 6: Atomic speaker-label and meeting projection updates

**Files:**
- Create: `Sources/EveeCore/Transcription/MeetingRecordProjection.swift`
- Modify: `Sources/EveeApp/UI/MeetingWorkspaceView.swift:37-150`
- Modify: `Sources/EveeApp/UI/RecordDetailView.swift:74-117`
- Modify: `Sources/EveeApp/AppStore.swift:1192-1210`
- Modify: `Sources/EveeCore/Persistence/WorkspaceExport.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/MeetingRecordProjectionTests.swift`
- Modify: `Tests/EveeCoreTests/WorkspaceSearchTests.swift`

**Interfaces:**
- Consumes: `WorkspaceRecord`, `MeetingIntelligencePipeline`, `LibraryStore.upsert(_:)`, and `PublicWorkspaceRecord`.
- Produces: `MeetingRecordProjection.relabel(record:segmentID:label:) throws -> WorkspaceRecord`.

- [ ] **Step 1: Write a failing cross-projection relabel check**

```swift
let changed = try MeetingRecordProjection().relabel(
    record: syntheticMeeting,
    segmentID: participantOneSegmentID,
    label: "Facilitator"
)
precondition(changed.segments.filter { $0.speaker == "Facilitator" }.count == 2)
precondition(changed.text.contains("Facilitator: First statement"))
precondition(changed.rawText?.contains("Facilitator: First statement") == true)
precondition(changed.meetingIntelligence == MeetingIntelligencePipeline().generate(from: changed.segments, generatedAt: changed.updatedAt))
precondition(String(decoding: try WorkspaceExporter.data(for: [changed], format: .markdown), as: UTF8.self).contains("Facilitator"))
precondition(String(decoding: try JSONEncoder().encode(PublicWorkspaceRecord(changed)), as: UTF8.self).contains("Facilitator"))
```

Use two segments sharing the old anonymous cluster label and one unrelated segment. Assert whitespace-only labels normalize to `nil`, missing segment IDs fail without mutation, and the original value remains unchanged.

- [ ] **Step 2: Run the red checks**

Run: `swift run evee-core-checks --filter meeting-relabel`

Expected: FAIL because `MeetingRecordProjection` is absent.

- [ ] **Step 3: Implement one canonical mutation and remove Return interception**

```swift
public enum MeetingRecordProjectionError: Error, Equatable {
    case segmentNotFound(UUID)
}

public struct MeetingRecordProjection: Sendable {
    public func relabel(
        record: WorkspaceRecord,
        segmentID: UUID,
        label: String?
    ) throws -> WorkspaceRecord {
        guard let target = record.segments.first(where: { $0.id == segmentID }) else {
            throw MeetingRecordProjectionError.segmentNotFound(segmentID)
        }
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = normalized?.isEmpty == false ? normalized : nil
        var changed = record
        for index in changed.segments.indices {
            let belongsToCluster = target.attribution == .diarized
                && changed.segments[index].attribution == .diarized
                && changed.segments[index].speaker == target.speaker
            if changed.segments[index].id == segmentID || belongsToCluster {
                changed.segments[index].speaker = finalLabel
            }
        }
        changed.segments.sort { $0.start < $1.start }
        let transcript = changed.segments.map { segment in
            if let speaker = segment.speaker { return "\(speaker): \(segment.text)" }
            return segment.text
        }.joined(separator: "\n")
        let now = Date.now
        changed.rawText = transcript
        changed.text = transcript
        changed.updatedAt = now
        changed.meetingIntelligence = MeetingIntelligencePipeline()
            .generate(from: changed.segments, generatedAt: now)
        return changed
    }
}
```

Find the target's previous anonymous label and update every segment in that cluster; channel-only segments update only the selected segment. Re-sort segments chronologically, rebuild speaker-prefixed raw and finished transcript text, regenerate extractive intelligence, and advance `updatedAt`. `RecordDetailView` calls this method rather than directly mutating one binding. Saving performs one `LibraryStore.upsert`, which synchronizes the search projection before publishing the changed record. Explain beside the speaker timeline that relabelling rebuilds the transcript from timed segments. Remove the unmodified Return shortcut from meeting Stop so Return in Live Notes always inserts a newline. Keep the privacy-settings button outside any `.accessibilityElement(children: .combine)` container.

- [ ] **Step 4: Run cross-surface tests**

Run: `swift run evee-core-checks --filter meeting-relabel`

Expected: PASS for record, intelligence, search, export, API, and helper projections.

Run: `swift test --filter MeetingRecordProjectionTests && swift test --filter WorkspaceSearchTests`

Expected: PASS under full Xcode.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Transcription/MeetingRecordProjection.swift Sources/EveeApp/UI/MeetingWorkspaceView.swift Sources/EveeApp/UI/RecordDetailView.swift Sources/EveeApp/AppStore.swift Sources/EveeCore/Persistence/WorkspaceExport.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/MeetingRecordProjectionTests.swift Tests/EveeCoreTests/WorkspaceSearchTests.swift
git commit -m "Keep speaker labels consistent across projections"
```

### Task 7: Best-effort window protection and true privacy mode

**Files:**
- Create: `Sources/EveeCore/Design/PrivacyPresentation.swift`
- Create: `Sources/EveeApp/WindowSharingProtection.swift`
- Create: `Sources/EveeApp/UI/PrivacyModeView.swift`
- Modify: `Sources/EveeApp/EveeApp.swift:25-45`
- Modify: `Sources/EveeApp/AppStore.swift:24-58`
- Modify: `Sources/EveeApp/UI/RootView.swift`
- Modify: `Sources/EveeApp/UI/MenuBarView.swift`
- Modify: `Sources/EveeApp/UI/SettingsView.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/PrivacyPresentationTests.swift`

**Interfaces:**
- Produces: `WindowSharingProtectionInstaller`, ephemeral `AppStore.privacyModeEnabled`, and `PrivacyPresentation`.
- Consumers: main window, Settings scene, menu bar, transcript/detail routes, and physical sharing tests.

- [ ] **Step 1: Write failing privacy-presentation checks**

```swift
let protected = PrivacyPresentation(enabled: true)
precondition(!protected.constructsWorkspaceContent)
precondition(!protected.constructsSettingsContent)
precondition(protected.accessibilityLabel == "Privacy mode is on. Sensitive Evee content is hidden.")
precondition(protected.windowProtectionCopy.contains("best-effort"))
```

Add a check that the menu action remains available while main and Settings content are hidden.

- [ ] **Step 2: Run the red check**

Run: `swift run evee-core-checks --filter privacy-presentation`

Expected: FAIL because `PrivacyPresentation` is absent.

- [ ] **Step 3: Protect windows and gate construction of sensitive content**

```swift
public struct PrivacyPresentation: Equatable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
    public var constructsWorkspaceContent: Bool { !enabled }
    public var constructsSettingsContent: Bool { !enabled }
    public var accessibilityLabel: String {
        enabled ? "Privacy mode is on. Sensitive Evee content is hidden." : "Privacy mode is off."
    }
    public var windowProtectionCopy: String {
        "Window sharing exclusion is best-effort. Turn on privacy mode to hide sensitive in-app content."
    }
}

struct WindowSharingProtectionInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        protect(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { protect(view) }
    private func protect(_ view: NSView) {
        DispatchQueue.main.async { view.window?.sharingType = .none }
    }
}

@ViewBuilder
private var protectedRootContent: some View {
    if store.privacyModeEnabled {
        PrivacyModeView()
    } else {
        workspaceContent
    }
}
```

When the representable reaches an `NSWindow`, apply the strongest supported AppKit sharing exclusion and reapply after window replacement. Install it in main and Settings scenes. Privacy mode is session-only and toggled from the menu bar and Settings. When enabled, branch before constructing transcript, notes, retained context, activity context, API token, webhook secret, or helper result views; do not rely on `.redacted` or `.accessibilityHidden`. Show only neutral privacy copy and a menu-accessible action to turn protection off. Copy states that window exclusion is best effort and privacy mode is the reliable in-app hiding control.

- [ ] **Step 4: Run focused checks and inspect sensitive construction sites**

Run: `swift run evee-core-checks --filter privacy-presentation`

Expected: PASS.

Run: `rg -n 'RecordDetailView|SettingsView|meetingNotes|webhookSecret|localAPICredentials' Sources/EveeApp/UI/RootView.swift Sources/EveeApp/EveeApp.swift`

Expected: each sensitive root is constructed only in the privacy-mode-off branch.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Design/PrivacyPresentation.swift Sources/EveeApp/WindowSharingProtection.swift Sources/EveeApp/UI/PrivacyModeView.swift Sources/EveeApp/EveeApp.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/RootView.swift Sources/EveeApp/UI/MenuBarView.swift Sources/EveeApp/UI/SettingsView.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/PrivacyPresentationTests.swift
git commit -m "Add best-effort window protection and privacy mode"
```

### Task 8: Complete, self-healing search with matched snippets

**Files:**
- Modify: `Sources/EveeCore/Persistence/WorkspaceSearchIndex.swift`
- Modify: `Sources/EveeCore/Persistence/LibraryStore.swift:159-207`
- Modify: `Sources/EveeApp/AppStore.swift:41,150-239`
- Modify: `Sources/EveeApp/UI/LibraryView.swift:16-157`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Modify: `Tests/EveeCoreTests/WorkspaceSearchTests.swift`

**Interfaces:**
- Produces: `WorkspaceSearchHit { id: UUID, snippet: String }`, `WorkspaceSearchResult { record: WorkspaceRecord, snippet: String }`, `LibraryStore.searchResults(_:kind:limit:)`, and an injectable SQLite step function.
- Preserves: `LibraryStore.search(_:kind:limit:)` for API/helper callers by mapping results to records.

- [ ] **Step 1: Write failing field-coverage, snippet, and step-error tests**

```swift
let results = try store.searchResults("Facilitator", kind: .meeting)
XCTAssertEqual(results.first?.record.id, meeting.id)
XCTAssertTrue(results.first?.snippet.contains("Facilitator") == true)

let contextResults = try store.searchResults("Project Atlas", kind: nil)
XCTAssertEqual(contextResults.first?.record.id, dictation.id)

let failingIndex = try WorkspaceSearchIndex(url: indexURL) { statement in
    stepCounter += 1
    return stepCounter == 2 ? SQLITE_IOERR : sqlite3_step(statement)
}
XCTAssertThrowsError(try failingIndex.matchingHits(query: "text", kind: nil, limit: 20))
```

Seed raw text, notes, tags, source app, permitted context, segment labels/text, summary, decisions, actions, highlights, and topics with unique terms. Assert each returns the right record and a snippet containing the matching term. Corrupt the projection and assert canonical records rebuild it.

- [ ] **Step 2: Run the red tests**

Run: `swift test --filter WorkspaceSearchTests`

Expected: FAIL because current indexing omits fields, returns no indexed snippet, and treats a step error like normal completion.

- [ ] **Step 3: Expand the projection and distinguish every SQLite result**

```swift
struct WorkspaceSearchHit: Equatable, Sendable {
    let id: UUID
    let snippet: String
}

public struct WorkspaceSearchResult: Sendable {
    public let record: WorkspaceRecord
    public let snippet: String

    public init(record: WorkspaceRecord, snippet: String) {
        self.record = record
        self.snippet = snippet
    }
}

while true {
    switch sqliteStep(statement) {
    case SQLITE_ROW:
        hits.append(readHit(statement))
    case SQLITE_DONE:
        return hits
    default:
        throw lastError()
    }
}
```

Version the FTS schema so existing projections rebuild. Index title, finished text, retained raw text, notes, tags, source application, permitted context values, segment labels/text, and extractive insight fields. Query `snippet(workspace_fts, -1, "", "", "…", 24)` so the returned snippet comes from the matching indexed column. `AppStore` publishes `[WorkspaceSearchResult]`, and `LibraryView` renders and exposes the returned snippet rather than rescanning only text/notes/tags. On any prepare/step error, close and invalidate the index, rebuild once from canonical records, then retry once.

- [ ] **Step 4: Run focused and regression tests**

Run: `swift test --filter WorkspaceSearchTests`

Expected: PASS for all indexed fields, snippets, injected step failure, corruption, and rebuild.

Run: `swift run evee-core-checks --filter search-projection`

Expected: PASS using a temporary store.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Persistence/WorkspaceSearchIndex.swift Sources/EveeCore/Persistence/LibraryStore.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/LibraryView.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/WorkspaceSearchTests.swift
git commit -m "Complete and self-heal workspace search"
```

### Task 9: Atomic retained-audio export

**Files:**
- Create: `Sources/EveeCore/Persistence/AtomicFileExporter.swift`
- Modify: `Sources/EveeApp/UI/RecordDetailView.swift:420-445`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/AtomicFileExporterTests.swift`

**Interfaces:**
- Produces: `AtomicFileExporter.export(source:to:) async throws`, injectable `FileExportOperations`, and the production `FoundationFileExportOperations` implementation.
- Consumers: retained microphone/system/mixed audio export.

- [ ] **Step 1: Write failing preservation checks**

```swift
try Data("old destination".utf8).write(to: destination)
let operations = FailingFileExportOperations(failAfterCopy: true)
do {
    try await AtomicFileExporter(operations: operations).export(source: source, to: destination)
    XCTFail("Expected injected export failure")
} catch {
    XCTAssertEqual(error as? SyntheticExportError, .injectedFailure)
}
XCTAssertEqual(try Data(contentsOf: destination), Data("old destination".utf8))
XCTAssertTrue(try siblingTemporaryFiles(of: destination).isEmpty)
```

Add success coverage that compares byte count and SHA-256 digest before atomic replacement, and failure coverage for copy, verification, and replacement.

- [ ] **Step 2: Run the red tests**

Run: `swift test --filter AtomicFileExporterTests`

Expected: FAIL because the exporter is absent and current UI removes the existing destination before copying.

- [ ] **Step 3: Implement verified sibling replacement**

```swift
public enum AtomicFileExportError: Error, Equatable {
    case verificationFailed
}

public protocol FileExportOperations: Sendable {
    func copy(_ source: URL, _ destination: URL) throws
    func verifySameBytes(_ source: URL, _ destination: URL) throws
    func replaceAtomically(_ destination: URL, with replacement: URL) throws
    func removeIfPresent(_ url: URL) throws
}

public struct FoundationFileExportOperations: FileExportOperations {
    public init() {}
    public func copy(_ source: URL, _ destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    public func verifySameBytes(_ source: URL, _ destination: URL) throws {
        let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let destinationSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard sourceSize == destinationSize, try digest(source) == digest(destination) else {
            throw AtomicFileExportError.verificationFailed
        }
    }
    public func replaceAtomically(_ destination: URL, with replacement: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: destination)
        }
    }
    public func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    private func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}

public struct AtomicFileExporter: Sendable {
    private let operations: any FileExportOperations

    public init(operations: any FileExportOperations = FoundationFileExportOperations()) {
        self.operations = operations
    }

    public func export(source: URL, to destination: URL) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".evee-export-\(UUID().uuidString)")
        defer { try? operations.removeIfPresent(temporary) }
        try operations.copy(source, temporary)
        try operations.verifySameBytes(source, temporary)
        try operations.replaceAtomically(destination, with: temporary)
    }
}
```

Keep the temporary file in the destination directory so replacement stays on one volume. Set owner-only permissions before replacement. `RecordDetailView` resolves the library-safe source, obtains the save destination, calls the exporter, and reports success/failure through the announcement coordinator without destroying an existing destination.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter AtomicFileExporterTests`

Expected: PASS for successful export and every injected failure, with no temporary files left behind.

Run: `swift run evee-core-checks --filter atomic-export`

Expected: PASS using temporary synthetic audio bytes.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Persistence/AtomicFileExporter.swift Sources/EveeApp/UI/RecordDetailView.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/AtomicFileExporterTests.swift
git commit -m "Preserve existing files during audio export"
```

### Task 10: Opt-in meeting suggestions and honest transform scope

**Files:**
- Create: `Sources/EveeCore/Intelligence/MeetingSuggestionPolicy.swift`
- Create: `Sources/EveeApp/MeetingSuggestionRuntime.swift`
- Modify: `Sources/EveeCore/Models.swift`
- Modify: `Sources/EveeApp/AppStore.swift`
- Modify: `Sources/EveeApp/UI/RootView.swift`
- Modify: `Sources/EveeApp/UI/SettingsView.swift`
- Modify: `Sources/EveeCore/Transcription/SelectionTransform.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`
- Create: `Tests/EveeCoreTests/MeetingSuggestionPolicyTests.swift`
- Modify: `Tests/EveeCoreTests/ContextTransformTests.swift`

**Interfaces:**
- Produces: privacy-safe `EveeSettings.meetingSuggestionsEnabled`, native and browser allowlists, `MeetingSuggestionPolicy.evaluate(_:)`, and `AppStore.meetingSuggestion`.
- Preserves: deterministic `SelectionTransformPipeline` and `.unsupportedInstruction` for unrestricted rewrites.

- [ ] **Step 1: Write failing opt-in, browser-metadata, cooldown, and transform checks**

```swift
let disabled = MeetingSuggestionPolicy(settings: .suggestionsDisabled)
precondition(disabled.evaluate(nativeSnapshot) == nil)

let enabled = MeetingSuggestionPolicy(settings: suggestionSettings)
precondition(enabled.evaluate(nativeSnapshot)?.applicationName == "Synthetic Meeting App")
precondition(enabled.evaluate(browserSnapshotWithoutWindowPermission) == nil)
precondition(enabled.evaluate(browserSnapshotWithMatchingPermittedTitle) != nil)
precondition(enabled.evaluate(dismissedSnapshotWithinCooldown) == nil)

XCTAssertThrowsError(
    try SelectionTransformPipeline().transform(selectedText: "Original", instruction: "Rewrite this persuasively")
) { error in
    XCTAssertEqual(error as? SelectionTransformError, .unsupportedInstruction)
}
XCTAssertEqual(
    SelectionTransformPipeline.supportedCommandSummary,
    "Concise, clean up, uppercase, lowercase, title case, bullets, numbered list, and exact replacement"
)
```

- [ ] **Step 2: Run the red suggestion checks**

Run: `swift run evee-core-checks --filter meeting-suggestion`

Expected: FAIL because the policy and settings do not exist.

- [ ] **Step 3: Implement suggestion-only observation and accessible actions**

```swift
public struct MeetingSuggestionSettings: Equatable, Sendable {
    public var enabled: Bool
    public var nativeBundleIdentifiers: Set<String>
    public var browserBundleIdentifiers: Set<String>
    public var browserTitleTerms: [String]
    public var dismissedUntilByBundleIdentifier: [String: Date]

    public static let suggestionsDisabled = MeetingSuggestionSettings(
        enabled: false,
        nativeBundleIdentifiers: [],
        browserBundleIdentifiers: [],
        browserTitleTerms: [],
        dismissedUntilByBundleIdentifier: [:]
    )
}

public struct MeetingApplicationSnapshot: Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationName: String
    public let isBrowser: Bool
    public let permittedWindowTitle: String?
    public let observedAt: Date

    public init(
        bundleIdentifier: String,
        applicationName: String,
        isBrowser: Bool,
        permittedWindowTitle: String?,
        observedAt: Date
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.isBrowser = isBrowser
        self.permittedWindowTitle = permittedWindowTitle
        self.observedAt = observedAt
    }
}

public struct MeetingSuggestion: Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationName: String

    public init(bundleIdentifier: String, applicationName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }
}

public struct MeetingSuggestionPolicy: Sendable {
    private let settings: MeetingSuggestionSettings

    public init(settings: MeetingSuggestionSettings) { self.settings = settings }

    public func evaluate(_ snapshot: MeetingApplicationSnapshot) -> MeetingSuggestion? {
        guard settings.enabled,
              (settings.dismissedUntilByBundleIdentifier[snapshot.bundleIdentifier] ?? .distantPast) <= snapshot.observedAt else {
            return nil
        }
        if snapshot.isBrowser {
            guard settings.browserBundleIdentifiers.contains(snapshot.bundleIdentifier),
                  let title = snapshot.permittedWindowTitle,
                  settings.browserTitleTerms.contains(where: {
                      title.localizedCaseInsensitiveContains($0)
                  }) else { return nil }
        } else {
            guard settings.nativeBundleIdentifiers.contains(snapshot.bundleIdentifier) else { return nil }
        }
        return MeetingSuggestion(
            bundleIdentifier: snapshot.bundleIdentifier,
            applicationName: snapshot.applicationName
        )
    }
}
```

Default suggestions to off. Persist allowlists as ordered arrays in `EveeSettings` for stable Codable output, then adapt them to sets in `MeetingSuggestionSettings`. Observe running application identity only when enabled. Native matches use a user-editable bundle-identifier allowlist. Browser matches require the existing window-metadata permission and a user-editable title allowlist; never read page content. Publish an accessible banner with explicitly labelled Start Meeting and Dismiss actions. Dismissal records a per-application cooldown. Never call `beginMeeting()` without the user activating Start Meeting. Add the exact `SelectionTransformPipeline.supportedCommandSummary` constant asserted above and use it in Settings and the unsupported-instruction error so product copy cannot drift from implemented commands. Unrestricted requests preserve the selection and return the existing actionable error.

- [ ] **Step 4: Run focused tests**

Run: `swift run evee-core-checks --filter meeting-suggestion`

Expected: PASS for disabled, native, browser permission, allowlist, dismissal, and cooldown paths.

Run: `swift test --filter MeetingSuggestionPolicyTests && swift test --filter ContextTransformTests`

Expected: PASS under full Xcode.

- [ ] **Step 5: Commit**

```bash
git add Sources/EveeCore/Intelligence/MeetingSuggestionPolicy.swift Sources/EveeApp/MeetingSuggestionRuntime.swift Sources/EveeCore/Models.swift Sources/EveeApp/AppStore.swift Sources/EveeApp/UI/RootView.swift Sources/EveeApp/UI/SettingsView.swift Sources/EveeCore/Transcription/SelectionTransform.swift Tests/EveeCoreChecks/main.swift Tests/EveeCoreTests/MeetingSuggestionPolicyTests.swift Tests/EveeCoreTests/ContextTransformTests.swift
git commit -m "Add opt-in meeting suggestions"
```

### Task 11: Packaged accessibility and journey verification

**Files:**
- Create: `scripts/verify_accessibility.swift`
- Modify: `scripts/verify_app.sh`
- Modify: `docs/PRODUCT_RELEASE_GATES.md`
- Test: all files under `Tests/EveeCoreTests/`

**Interfaces:**
- Consumes: all Tasks 1–10 plus the completed privacy and capture plans.
- Produces: a packaged-app AX verifier and evidence-backed release-gate wording.

- [ ] **Step 1: Write the AX verifier before running the app**

```swift
let application = AXUIElementCreateApplication(pid)
let elements = try descendants(of: application)
let unnamedButtons = elements.filter {
    role(of: $0) == kAXButtonRole && accessibleName(of: $0).isEmpty
}
guard unnamedButtons.isEmpty else {
    fputs("Unnamed AX buttons: \(unnamedButtons.count)\n", stderr)
    exit(EXIT_FAILURE)
}
```

The verifier accepts `--pid`, recursively walks bounded descendants, fails any enabled action without a non-empty accessible name, and supports `--require-label`, `--require-value`, and `--forbid-text` assertions. It logs roles and sanitized labels only; it never logs transcript, notes, context, tokens, or secrets.

- [ ] **Step 2: Run all automated validation serially**

Run: `ps -axo pid,rss,command | sort -k2 -nr | head -20` and `docker ps --format '{{.ID}} {{.Status}} {{.Names}}'`

Expected: inspect existing heavyweight work before starting validation; do not stop user-owned processes.

Run: `swift run evee-core-checks`

Expected: every focused core check passes.

Run: `swift test --parallel --num-workers 2`

Expected: all XCTest cases pass under full Xcode.

- [ ] **Step 3: Package, verify, relocate, and run the AX smoke cases**

```bash
scripts/package_app.sh release
scripts/verify_app.sh dist/Evee.app
candidate_dir="$(mktemp -d)"
automation_root="$(mktemp -d)"
trap 'rm -rf "$candidate_dir" "$automation_root"' EXIT
ditto dist/Evee.app "$candidate_dir/Evee.app"
CFFIXED_USER_HOME="$automation_root" "$candidate_dir/Evee.app/Contents/MacOS/Evee" &
candidate_pid="$!"
swift scripts/verify_accessibility.swift --pid "$candidate_pid" --require-label "Download local model"
```

Expected: package verification and AX automation pass from an isolated synthetic root. On fresh onboarding, the AX verifier finds named Microphone, Accessibility, and model actions plus a progress value. Repeat with the app ready and require named search, meeting, memo, Settings, playback/export, helper, privacy-mode, Stop, and Discard actions. Separately launch the relocated bundle through Launch Services in a disposable macOS test account for installed-product behavior; do not point that launch at the operator's real application data.

- [ ] **Step 4: Execute affected physical journeys and record private evidence**

Use the relocated bundle and isolated Application Support data. Verify:

1. keyboard-only and VoiceOver onboarding, denied permissions, focus restoration, cancel/interruption/retry, and dark/light contrast;
2. wake listening and hands-free visibility in menu/HUD, exact announcements, global Stop/Discard, and no listening after disable;
3. Return inserts a newline in live notes, channel warnings reach every surface, and relabelled speakers match transcript/search/export/API/helper results;
4. best-effort sharing exclusion plus privacy mode hiding content from pixels and AX, with no guarantee claim;
5. all indexed fields return useful snippets and a corrupted projection self-heals;
6. failed audio export preserves an existing destination;
7. meeting suggestions remain off by default, respect allowlists/cooldown, and never start capture automatically;
8. reduced motion, smallest supported window, enlarged text, and rapid route/record changes remain readable and operable.

Expected: no P0/P1 issue. Any failure reopens the owning task before release-gate wording changes.

- [ ] **Step 5: Run final exact-head and prohibited-reference gates, then commit evidence-safe changes**

Run: `git diff --check && git status --short && git rev-parse HEAD`

Expected: no whitespace errors; only intentional source, tests, scripts, and neutral documentation are staged.

Run the repository's private prohibited-reference scan across the proposed tree and every new commit subject/body.

Expected: zero matches. Do not print prohibited terms into a tracked file or generated upload.

```bash
git add scripts/verify_accessibility.swift scripts/verify_app.sh docs/PRODUCT_RELEASE_GATES.md
git commit -m "Verify packaged accessibility journeys"
```

Update TOM-49 with the exact commit, focused/full test totals, packaged journey results, first-significant-issue time, and remaining external gates. Mark a checklist item complete only when the corresponding relocated-bundle evidence exists.
