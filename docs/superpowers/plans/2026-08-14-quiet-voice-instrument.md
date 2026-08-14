# Quiet Voice Instrument Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Evee’s stock-looking SwiftUI presentation with a cohesive native visual system, meaningful voice-state motion, and polished primary journeys without changing capture, persistence, privacy, or integration semantics.

**Architecture:** Add pure presentation primitives to EveeCore, then build small SwiftUI components that consume values rather than `AppStore`. Recompose the existing shell and journey views around those components while keeping the current store methods, native controls, split-view behavior, accessibility announcements, and privacy protection authoritative.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, macOS 14, existing Swift Package Manager targets only.

**Spec:** `docs/superpowers/specs/2026-08-14-quiet-voice-instrument-design.md`

## Global Constraints

- Tracking issue: TOM-52.
- Do not add dependencies or change persistence formats.
- Keep every safety-critical action connected to its existing `AppStore` method.
- Do not fabricate audio activity; visual level must derive from the existing capture level and clamp to `0...1`.
- Preserve screen-sharing protection, non-activating HUD behavior, privacy mode, keyboard order, VoiceOver copy, and the existing minimum window size.
- Use spectral colour only for the mark, active voice state, primary capture action, and rare attention boundaries.
- Every moving element must have an explicit Reduce Motion rendering.
- Keep screenshots and physical evidence outside the repository unless they use approved synthetic data.
- Before every commit, review the staged diff, reject generated app data/models/audio/packages, run the owner-held restricted-reference scan over the full tree and proposed metadata, and inspect the staged change for secrets or private local paths.
- Inspect memory-heavy processes before broad validation. Run focused checks during iteration and serialize full tests, app builds, packaging, verification, and launch.

---

### Task 1: Semantic visual presentation primitives

**Files:**
- Create: `Sources/EveeCore/Design/EveeVisualPresentation.swift`
- Modify: `Sources/EveeCore/Design/AccessibleColorTokens.swift`
- Create: `Tests/EveeCoreTests/EveeVisualPresentationTests.swift`
- Modify: `Tests/EveeCoreChecks/main.swift`

**Interfaces:**
- Consumes: `RGBColor`, `InterfaceAppearance`, `SystemVoicePhase`, and `WorkspaceRouteKind`.
- Produces: `EveeColorRole`, `EveeVisualPalette`, `EveeMotionKind`, `EveeMotionPolicy`, `VoiceThreadMode`, `VoiceThreadPresentation`, and `EveeSettingsCategory`.

- [ ] **Step 1: Write the failing presentation tests**

```swift
import XCTest
@testable import EveeCore

final class EveeVisualPresentationTests: XCTestCase {
    func testEssentialTextPairsMeetAAInBothAppearances() {
        for appearance in InterfaceAppearance.allCases {
            let canvas = EveeVisualPalette.rgb(.canvas, appearance: appearance)
            let surface = EveeVisualPalette.rgb(.surface, appearance: appearance)
            XCTAssertGreaterThanOrEqual(
                EveeVisualPalette.rgb(.primaryText, appearance: appearance).contrastRatio(with: canvas),
                4.5
            )
            XCTAssertGreaterThanOrEqual(
                EveeVisualPalette.rgb(.secondaryText, appearance: appearance).contrastRatio(with: surface),
                4.5
            )
            XCTAssertGreaterThanOrEqual(
                EveeVisualPalette.rgb(.accent, appearance: appearance).contrastRatio(with: surface),
                3.0
            )
        }
    }

    func testVoiceLevelIsClampedAndMissingLevelStaysQuiet() {
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: -1).level, 0)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: 2).level, 1)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: nil).level, 0.08)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .processing, level: 1).mode, .processing)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .protected, level: nil).mode, .resolved)
    }

    func testReducedMotionRemovesSpatialDurations() {
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: true).duration(for: .route), 0)
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: true).duration(for: .voiceSettlement), 0)
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: false).duration(for: .selection), 0.2)
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: false).duration(for: .route), 0.26)
    }

    func testSettingsCategoriesAreStableAndComplete() {
        XCTAssertEqual(
            EveeSettingsCategory.allCases,
            [.voice, .writing, .meetings, .privacyAndStorage, .integrations, .application]
        )
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm the new API is missing**

Run: `swift test --jobs 2 --filter EveeVisualPresentationTests`

Expected: compilation fails because the semantic presentation types are not defined.

- [ ] **Step 3: Implement the pure presentation API**

```swift
public enum EveeColorRole: CaseIterable, Sendable {
    case canvas, sidebar, surface, elevatedSurface, hairline
    case primaryText, secondaryText, tertiaryText
    case accent, success, warning, destructive
}

public enum EveeVisualPalette {
    public static func rgb(_ role: EveeColorRole, appearance: InterfaceAppearance) -> RGBColor {
        switch (appearance, role) {
        case (.light, .canvas): RGBColor(red: 0.973, green: 0.973, blue: 0.969)
        case (.light, .sidebar): RGBColor(red: 0.956, green: 0.951, blue: 0.976)
        case (.light, .surface), (.light, .elevatedSurface): RGBColor(red: 1, green: 1, blue: 1)
        case (.light, .hairline): RGBColor(red: 0.82, green: 0.82, blue: 0.80)
        case (.light, .primaryText): RGBColor(red: 0.12, green: 0.12, blue: 0.12)
        case (.light, .secondaryText): RGBColor(red: 0.35, green: 0.35, blue: 0.35)
        case (.light, .tertiaryText): RGBColor(red: 0.48, green: 0.48, blue: 0.47)
        case (.light, .accent): RGBColor(red: 0.38, green: 0.16, blue: 0.82)
        case (.light, .success): RGBColor(red: 0.10, green: 0.45, blue: 0.27)
        case (.light, .warning): RGBColor(red: 0.65, green: 0.32, blue: 0.02)
        case (.light, .destructive): RGBColor(red: 0.68, green: 0.08, blue: 0.16)
        case (.dark, .canvas): RGBColor(red: 0.055, green: 0.055, blue: 0.065)
        case (.dark, .sidebar): RGBColor(red: 0.075, green: 0.07, blue: 0.095)
        case (.dark, .surface): RGBColor(red: 0.10, green: 0.095, blue: 0.12)
        case (.dark, .elevatedSurface): RGBColor(red: 0.135, green: 0.125, blue: 0.16)
        case (.dark, .hairline): RGBColor(red: 0.29, green: 0.28, blue: 0.34)
        case (.dark, .primaryText): RGBColor(red: 0.95, green: 0.94, blue: 0.97)
        case (.dark, .secondaryText): RGBColor(red: 0.73, green: 0.72, blue: 0.77)
        case (.dark, .tertiaryText): RGBColor(red: 0.60, green: 0.59, blue: 0.65)
        case (.dark, .accent): RGBColor(red: 0.68, green: 0.58, blue: 1)
        case (.dark, .success): RGBColor(red: 0.39, green: 0.82, blue: 0.59)
        case (.dark, .warning): RGBColor(red: 1, green: 0.67, blue: 0.28)
        case (.dark, .destructive): RGBColor(red: 1, green: 0.45, blue: 0.52)
        }
    }
}

public enum EveeMotionKind: Sendable { case press, selection, route, voiceSettlement }

public struct EveeMotionPolicy: Equatable, Sendable {
    public let reduceMotion: Bool
    public init(reduceMotion: Bool) { self.reduceMotion = reduceMotion }
    public func duration(for kind: EveeMotionKind) -> TimeInterval {
        guard !reduceMotion else { return 0 }
        return switch kind { case .press: 0.12; case .selection: 0.2; case .route: 0.26; case .voiceSettlement: 0.36 }
    }
}

public enum VoiceThreadMode: Equatable, Sendable { case idle, listening, processing, resolved, warning }

public struct VoiceThreadPresentation: Equatable, Sendable {
    public let mode: VoiceThreadMode
    public let level: Double
    public static func make(phase: SystemVoicePhase, level: Double?) -> Self {
        let mode: VoiceThreadMode = switch phase {
        case .wakeListening, .recording: .listening
        case .wakeStarting, .wakeStopping, .captureStarting, .processing, .delivering: .processing
        case .protected: .resolved
        case .failed: .warning
        case .ready: .idle
        }
        let fallback = mode == .listening ? 0.08 : 0
        return Self(mode: mode, level: min(1, max(0, level ?? fallback)))
    }
}

public enum EveeSettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case voice, writing, meetings, privacyAndStorage, integrations, application
    public var id: Self { self }
}
```

Keep `AccessibleActionPalette` source-compatible by implementing its public values from the semantic palette and existing spectral stops. Add a `visual-presentation` filter to `EveeCoreChecks` covering the same invariants without XCTest.

- [ ] **Step 4: Run focused checks**

Run: `swift test --jobs 2 --filter EveeVisualPresentationTests && swift run evee-core-checks --filter visual-presentation`

Expected: both commands pass.

- [ ] **Step 5: Commit the semantic foundation**

Commit subject: `Define Evee visual presentation primitives`

---

### Task 2: Voice thread and shared native components

**Files:**
- Create: `Sources/EveeCore/Design/VoiceThreadGeometry.swift`
- Create: `Tests/EveeCoreTests/VoiceThreadGeometryTests.swift`
- Create: `Sources/EveeApp/UI/Design/EveeVisualSystem.swift`
- Create: `Sources/EveeApp/UI/Design/VoiceThread.swift`
- Create: `Sources/EveeApp/UI/Design/EveeComponents.swift`
- Modify: `Sources/EveeCore/Design/AnimaTheme.swift`

**Interfaces:**
- Consumes: Task 1 semantic roles, `VoiceThreadPresentation`, SwiftUI environment appearance, and Reduce Motion.
- Produces: `VoiceThreadGeometry.points(level:count:)`, `VoiceThread`, `EveeMark`, `EveePageHeader`, `EveePanel`, `EveeStatusChip`, `EveeEmptyState`, `EveeSearchField`, and primary/secondary button styles.

- [ ] **Step 1: Write the failing geometry tests**

```swift
import XCTest
@testable import EveeCore

final class VoiceThreadGeometryTests: XCTestCase {
    func testGeometryIsDeterministicBoundedAndSymmetric() {
        let quiet = VoiceThreadGeometry.points(level: 0, count: 9)
        let active = VoiceThreadGeometry.points(level: 1, count: 9)
        XCTAssertEqual(quiet.count, 9)
        XCTAssertEqual(active.count, 9)
        XCTAssertEqual(active.first, active.last)
        XCTAssertTrue(active.allSatisfy { (-1.0...1.0).contains($0) })
        XCTAssertGreaterThan(active.map(abs).max() ?? 0, quiet.map(abs).max() ?? 0)
    }
}
```

- [ ] **Step 2: Run the geometry test and confirm it fails**

Run: `swift test --jobs 2 --filter VoiceThreadGeometryTests`

Expected: compilation fails because `VoiceThreadGeometry` is missing.

- [ ] **Step 3: Implement deterministic geometry and the SwiftUI renderer**

`VoiceThreadGeometry.points(level:count:)` returns an odd-length symmetric sample array derived from a fixed envelope and clamps level to `0...1`. `VoiceThread` converts those samples into a centred `Path`, draws a low-contrast base stroke, overlays the spectral stroke for active modes, and animates only changes to `presentation` using `EveeMotionPolicy`.

```swift
struct VoiceThread: View {
    let presentation: VoiceThreadPresentation
    var lineWidth: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let samples = VoiceThreadGeometry.points(level: presentation.level, count:  nineSampleCount)
            let path = voicePath(samples: samples, size: size)
            context.stroke(path, with: .color(EveeVisual.hairline), lineWidth: lineWidth)
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: EveeVisual.spectralColors),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                lineWidth: lineWidth
            )
        }
        .animation(EveeVisual.animation(.voiceSettlement, reduceMotion: reduceMotion), value: presentation)
        .accessibilityHidden(true)
    }

    private var nineSampleCount: Int { 9 }
}
```

Use semantic typography, spacing, shapes, and colours from `EveeVisualSystem.swift`. Keep compatibility aliases in `AnimaTheme` and route existing call sites through the new styles so the app stays buildable during migration.

- [ ] **Step 4: Run focused tests and compile the app**

Run: `swift test --jobs 2 --filter VoiceThreadGeometryTests && swift build --jobs 2 --product Evee`

Expected: the geometry tests and app build pass.

- [ ] **Step 5: Commit the shared visual components**

Commit subject: `Build the Evee voice instrument components`

---

### Task 3: Custom shell, navigation, and workspace hierarchy

**Files:**
- Create: `Sources/EveeCore/Design/WorkspaceNavigationPresentation.swift`
- Create: `Tests/EveeCoreTests/WorkspaceNavigationPresentationTests.swift`
- Create: `Sources/EveeApp/UI/Design/EveeSidebar.swift`
- Modify: `Sources/EveeApp/UI/RootView.swift`
- Modify: `Sources/EveeApp/UI/LibraryView.swift`
- Modify: `Sources/EveeApp/UI/RecordDetailView.swift`

**Interfaces:**
- Consumes: Task 2 components, `AppStore.Route`, `SystemVoiceStatus`, record selection, and search bindings.
- Produces: `WorkspaceNavigationPresentation`, a custom sidebar inside native split-view resizing, borderless record rows, and document-style record detail.

- [ ] **Step 1: Write the failing navigation presentation tests**

```swift
import XCTest
@testable import EveeCore

final class WorkspaceNavigationPresentationTests: XCTestCase {
    func testNavigationOrderAndStatusDoNotDependOnColour() {
        XCTAssertEqual(
            WorkspaceNavigationPresentation.items.map(\.route),
            [.library, .meetings, .memos, .dictionary, .settings]
        )
        let recording = WorkspaceNavigationPresentation.status(
            for: SystemVoiceStatus.make(
                capture: .recording(startedAt: .now, level: 0.4),
                hotMic: .disabled,
                warnings: []
            )
        )
        XCTAssertEqual(recording.title, "Recording")
        XCTAssertEqual(recording.symbolName, "record.circle.fill")
        XCTAssertTrue(recording.isMicrophoneOpen)
    }
}
```

- [ ] **Step 2: Run the focused test and confirm the presentation type is missing**

Run: `swift test --jobs 2 --filter WorkspaceNavigationPresentationTests`

Expected: compilation fails because `WorkspaceNavigationPresentation` is missing.

- [ ] **Step 3: Implement the custom shell**

Add a pure navigation item/status model in EveeCore. Replace the sidebar `List` with `EveeSidebar`, using buttons that set the same `AppStore.Route`, explicit selected state, visible focus, hover feedback, and a bottom status module sourced from `store.systemVoiceStatus`. Keep `NavigationSplitView` and `RootLayoutMode` unchanged.

Replace route headers with `EveePageHeader`. Make library rows use alignment, spacing, and selected/hover surface depth instead of a bordered card. Recompose record detail as a readable surface with metadata chips and a consistent action bar; keep all edit, playback, export, relabel, and delete functions unchanged.

- [ ] **Step 4: Run focused and app tests**

Run: `swift test --jobs 2 --filter WorkspaceNavigationPresentationTests && swift test --jobs 2 --filter AccessibilityCopyTests && swift build --jobs 2 --product Evee`

Expected: navigation/accessibility tests and the app build pass.

- [ ] **Step 5: Commit the shell and workspace**

Commit subject: `Refine the workspace shell and hierarchy`

---

### Task 4: Onboarding, meeting, and memo voice journeys

**Files:**
- Modify: `Sources/EveeCore/Lifecycle/OnboardingPresentation.swift`
- Modify: `Tests/EveeCoreTests/OnboardingPresentationTests.swift`
- Modify: `Sources/EveeApp/UI/OnboardingView.swift`
- Modify: `Sources/EveeApp/UI/MeetingWorkspaceView.swift`
- Modify: `Sources/EveeApp/UI/LibraryView.swift`

**Interfaces:**
- Consumes: Task 2 voice thread and shared panels, existing onboarding presentation, capture level, live transcript, meeting notes, and capture actions.
- Produces: width-aware onboarding scene layout, stable readiness rows, and voice-led active meeting/memo surfaces.

- [ ] **Step 1: Add a failing width-aware onboarding test**

```swift
func testSceneLayoutUsesTwoZonesOnlyWhenWidthAndHeightPermit() {
    XCTAssertEqual(OnboardingSceneLayout.forViewport(width: 920, height: 720), .twoZone)
    XCTAssertEqual(OnboardingSceneLayout.forViewport(width: 760, height: 720), .stacked)
    XCTAssertEqual(OnboardingSceneLayout.forViewport(width: 920, height: 640), .stacked)
}
```

- [ ] **Step 2: Run the onboarding test and confirm the new layout type is missing**

Run: `swift test --jobs 2 --filter OnboardingPresentationTests`

Expected: compilation fails because `OnboardingSceneLayout` is missing.

- [ ] **Step 3: Implement the primary voice journeys**

Define `OnboardingSceneLayout.forViewport(width:height:)` with `.twoZone` at width `>= 860` and height `>= 700`; otherwise return `.stacked`. In `OnboardingView`, place the atmospheric brand/voice region beside one ordered readiness panel in two-zone mode and stack the same content in a scroll view otherwise. Keep the existing focus restoration and native model action button.

In `MeetingWorkspaceView`, make `VoiceThreadPresentation.make(phase:level:)` and elapsed state the active-session anchor, then order audio health, live transcript, title, and notes beneath it. In memo mode, replace the generic page-header buttons with the same compact recording state and stop/discard hierarchy. Do not change capture state transitions or shortcuts.

- [ ] **Step 4: Run focused lifecycle tests and compile the app**

Run: `swift test --jobs 2 --filter OnboardingPresentationTests && swift test --jobs 2 --filter AccessibleSystemVoiceLifecycleTests && swift build --jobs 2 --product Evee`

Expected: onboarding and system-voice lifecycle tests pass and the app builds.

- [ ] **Step 5: Commit the voice journeys**

Commit subject: `Polish onboarding and active voice journeys`

---

### Task 5: Focused settings, menu bar, and capture HUD

**Files:**
- Modify: `Sources/EveeCore/Design/EveeVisualPresentation.swift`
- Modify: `Tests/EveeCoreTests/EveeVisualPresentationTests.swift`
- Create: `Sources/EveeApp/UI/Design/EveeSettingsCategoryRail.swift`
- Modify: `Sources/EveeApp/UI/SettingsView.swift`
- Modify: `Sources/EveeApp/UI/MenuBarView.swift`
- Modify: `Sources/EveeApp/UI/RecordingPill.swift`
- Modify: `Sources/EveeApp/EveeApp.swift`

**Interfaces:**
- Consumes: `EveeSettingsCategory`, shared status components, `SystemVoiceStatus`, capture level, existing settings bindings, and existing menu actions.
- Produces: category metadata, a settings category rail, visually consistent menu state, and a compact level-reactive non-activating HUD.

- [ ] **Step 1: Extend the failing settings-category test with stable copy and symbols**

```swift
func testSettingsCategoryMetadataIsExplicit() {
    XCTAssertEqual(EveeSettingsCategory.voice.title, "Voice")
    XCTAssertEqual(EveeSettingsCategory.voice.symbolName, "waveform")
    XCTAssertEqual(EveeSettingsCategory.privacyAndStorage.title, "Privacy & Storage")
    XCTAssertEqual(EveeSettingsCategory.integrations.symbolName, "point.3.connected.trianglepath.dotted")
}
```

- [ ] **Step 2: Run the focused test and confirm category metadata is missing**

Run: `swift test --jobs 2 --filter EveeVisualPresentationTests`

Expected: compilation fails because category title and symbol metadata are not defined.

- [ ] **Step 3: Recompose settings and capture chrome**

Add explicit title and SF Symbol metadata for all six categories. Wrap the existing settings sections in a two-column composition: a keyboard-selectable category rail and one scrollable panel. Map Voice to dictation, Writing to enhancements/per-app styles, Meetings to meeting capture/suggestions, Privacy & Storage to retention/context/activity, Integrations to API/webhook/helper, and Application to model/application controls. Preserve all bindings, save behavior, async refreshes, warnings, and accessibility copy.

Use `EveeStatusChip` and `VoiceThread` in the menu bar. Redesign `RecordingPill` as a compact state-shaped HUD using the same `SystemVoiceStatus`; pass the current capture level from `AppStore` without adding capture ownership to the view. Keep `CaptureHUDPanel` non-activating, protected from sharing, and positioned at the top centre.

- [ ] **Step 4: Run status tests and compile the app**

Run: `swift test --jobs 2 --filter EveeVisualPresentationTests && swift test --jobs 2 --filter SystemVoiceStatusTests && swift build --jobs 2 --product Evee`

Expected: category/status tests pass and the app builds.

- [ ] **Step 5: Commit settings and system chrome**

Commit subject: `Focus settings and capture status surfaces`

---

### Task 6: Accessibility, exact-package visual verification, and closeout

**Files:**
- Modify only files implicated by verified regressions from this task.
- Do not add private screenshots, application data, model files, recordings, package artifacts, or local evidence logs.

**Interfaces:**
- Consumes: the exact combined head from Tasks 1–5.
- Produces: a verified exact package, relocated local launch, physical visual/accessibility evidence in TOM-52, and any narrowly scoped fixes required by that evidence.

- [ ] **Step 1: Inspect resource pressure and run the full automated suite serially**

Run:

```bash
ps -axo pid,rss,%mem,command | sort -k2 -nr | sed -n '1,18p'
swift test --jobs 2
swift build --jobs 2 --product Evee
```

Expected: no competing Evee build is running; all tests and the app build pass without high worker fan-out.

- [ ] **Step 2: Run the accessibility and appearance matrix**

Exercise onboarding, navigation, search, record detail, meeting, memo, settings, menu bar, and HUD with keyboard-only input and VoiceOver in light and dark appearances. Repeat capture, processing, route, selection, and onboarding progress with Reduce Motion enabled. Verify focus is visible, colour is redundant with text/icon state, no control is clipped at the minimum window size, and live voice motion stops when motion is reduced.

Expected: every primary action remains reachable and labelled; no light-on-light or dark-on-dark text; no motion-only status; no fake level activity.

- [ ] **Step 3: Package and verify one exact artifact**

Run serially:

```bash
candidate_commit="$(git rev-parse HEAD)"
scripts/package_app.sh release
scripts/verify_app.sh dist/Evee.app
test "$candidate_commit" = "$(git rev-parse HEAD)"
```

Expected: the exact head is unchanged, the ad-hoc package verifies from isolated synthetic data, and all eleven helper semantics pass.

- [ ] **Step 4: Relocate, launch, and visually review the packaged app**

Copy the verified bundle to a temporary path outside `dist`, launch that copy with Launch Services, and repeat the affected visual journeys. Review onboarding, empty and populated workspace, record detail, active meeting, memo recording, settings, menu bar, and HUD in both appearances. Keep screenshots private and temporary because window content may contain sensitive data.

Expected: the relocated app loads all resources, retains privacy protection, does not steal focus through the HUD, and materially matches the approved hierarchy and motion design.

- [ ] **Step 5: Perform exact-head review and close the implementation boundary**

Have fresh reviewers inspect the exact head for visual/interaction quality, accessibility, code quality, and privacy/distribution regressions. Fix every actionable finding with a focused failing test where possible, rerun Steps 1–4, update TOM-52 with exact commit and evidence, then run the full-tree and metadata policy scan before the final commit and push.

Expected: no P0/P1 visual, accessibility, privacy, or behavioral regression remains; TOM-52 contains honest automated and packaged physical evidence.
