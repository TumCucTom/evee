import Foundation
import XCTest
@testable import EveeCore

final class EveeVisualPresentationTests: XCTestCase {
    func testDarkCanvasUsesGraphiteRatherThanNearBlack() {
        let canvas = EveeVisualPalette.rgb(.canvas, appearance: .dark)
        let surface = EveeVisualPalette.rgb(.surface, appearance: .dark)

        XCTAssertGreaterThanOrEqual(canvas.red, 0.08)
        XCTAssertEqual(canvas.red, canvas.green, accuracy: 0.015)
        XCTAssertEqual(canvas.green, canvas.blue, accuracy: 0.015)
        XCTAssertGreaterThan(surface.red, canvas.red)
    }

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

    func testLightTertiaryTextMeetsAAAgainstEveryRealSurface() {
        let tertiary = EveeVisualPalette.rgb(.tertiaryText, appearance: .light)
        for backgroundRole in [EveeColorRole.canvas, .sidebar, .surface] {
            let background = EveeVisualPalette.rgb(backgroundRole, appearance: .light)
            XCTAssertGreaterThanOrEqual(
                tertiary.contrastRatio(with: background),
                4.5,
                "light tertiary text must meet AA against \(backgroundRole)"
            )
        }
    }

    func testSmallSemanticStateTextMeetsAAOnChangedSurfaces() {
        for appearance in InterfaceAppearance.allCases {
            for foregroundRole in [EveeColorRole.success, .warning, .destructive] {
                let foreground = EveeVisualPalette.rgb(foregroundRole, appearance: appearance)
                for backgroundRole in [EveeColorRole.canvas, .surface, .elevatedSurface] {
                    let background = EveeVisualPalette.rgb(backgroundRole, appearance: appearance)
                    XCTAssertGreaterThanOrEqual(
                        foreground.contrastRatio(with: background),
                        4.5,
                        "\(foregroundRole) text must meet AA against \(backgroundRole) in \(appearance)"
                    )
                }
            }
        }
    }

    func testVoiceLevelUsesOnlyFiniteMeasuredSignal() {
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: -1).level, 0)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: 2).level, 1)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: nil).level, 0)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .wakeListening, level: nil).level, 0)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: .nan).level, 0)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: .infinity).level, 0)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .recording, level: -.infinity).level, 0)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .processing, level: 1).mode, .processing)
        XCTAssertEqual(VoiceThreadPresentation.make(phase: .protected, level: nil).mode, .resolved)
    }

    func testCaptureOverlaySnapshotCarriesFiniteRecordingLevel() {
        let status = SystemVoiceStatus.make(
            capture: .recording(startedAt: .now, level: 0.42),
            hotMic: .disabled,
            warnings: []
        )
        let snapshot = CaptureOverlaySnapshot.make(
            status: status,
            capture: .recording(startedAt: .now, level: 0.42)
        )

        XCTAssertEqual(snapshot.status, status)
        XCTAssertEqual(snapshot.level ?? -1, Double(Float(0.42)), accuracy: 0.0001)
    }

    func testCaptureOverlaySnapshotHasNoWakeOrNonFiniteLevel() {
        let wakeStatus = SystemVoiceStatus.make(capture: .idle, hotMic: .active, warnings: [])
        let wake = CaptureOverlaySnapshot.make(status: wakeStatus, capture: .idle)
        let nonFinite = CaptureOverlaySnapshot.make(
            status: SystemVoiceStatus.make(
                capture: .recording(startedAt: .now, level: .nan),
                hotMic: .disabled,
                warnings: []
            ),
            capture: .recording(startedAt: .now, level: .nan)
        )

        XCTAssertNil(wake.level)
        XCTAssertNil(nonFinite.level)
    }

    func testCaptureOverlaySnapshotChangesWithSamePhaseLevel() {
        let startedAt = Date(timeIntervalSince1970: 1_786_617_000)
        let status = SystemVoiceStatus.make(
            capture: .recording(startedAt: startedAt, level: 0.2),
            hotMic: .disabled,
            warnings: []
        )
        let quiet = CaptureOverlaySnapshot.make(
            status: status,
            capture: .recording(startedAt: startedAt, level: 0.2)
        )
        let louder = CaptureOverlaySnapshot.make(
            status: status,
            capture: .recording(startedAt: startedAt, level: 0.8)
        )

        XCTAssertNotEqual(quiet, louder)
        XCTAssertEqual(quiet.status.phase, louder.status.phase)
    }

    func testReducedMotionRemovesSpatialDurations() {
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: true).duration(for: .route), 0)
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: true).duration(for: .voiceSettlement), 0)
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: false).duration(for: .selection), 0.2)
        XCTAssertEqual(EveeMotionPolicy(reduceMotion: false).duration(for: .route), 0.26)
    }

    func testReadyIsNeutralAndSuccessIsReservedForProtectedState() {
        XCTAssertEqual(VoiceStatusTone.make(phase: .ready, hasWarning: false), .neutral)
        XCTAssertEqual(VoiceStatusTone.make(phase: .protected, hasWarning: false), .success)
        XCTAssertEqual(VoiceStatusTone.make(phase: .recording, hasWarning: false), .accent)
        XCTAssertEqual(VoiceStatusTone.make(phase: .processing, hasWarning: false), .neutral)
        XCTAssertEqual(VoiceStatusTone.make(phase: .failed, hasWarning: false), .destructive)
        XCTAssertEqual(VoiceStatusTone.make(phase: .ready, hasWarning: true), .warning)
    }

    func testDisabledDestructiveButtonUsesRedundantVisualCues() {
        let enabled = EveeButtonStatePresentation.destructive(isEnabled: true)
        let disabled = EveeButtonStatePresentation.destructive(isEnabled: false)

        XCTAssertFalse(enabled.showsDisabledBoundary)
        XCTAssertTrue(disabled.showsDisabledBoundary)
        XCTAssertLessThan(disabled.opacity, enabled.opacity)
        XCTAssertLessThan(disabled.saturation, enabled.saturation)
    }

    func testSettingsCategoriesAreStableAndComplete() {
        XCTAssertEqual(
            EveeSettingsCategory.allCases,
            [.voice, .writing, .meetings, .privacyAndStorage, .integrations, .application]
        )
    }

    func testSettingsCategoryMetadataIsExplicit() {
        XCTAssertEqual(EveeSettingsCategory.voice.title, "Voice")
        XCTAssertEqual(EveeSettingsCategory.voice.symbolName, "waveform")
        XCTAssertEqual(EveeSettingsCategory.writing.title, "Writing")
        XCTAssertEqual(EveeSettingsCategory.writing.symbolName, "textformat")
        XCTAssertEqual(EveeSettingsCategory.meetings.title, "Meetings")
        XCTAssertEqual(EveeSettingsCategory.meetings.symbolName, "person.2")
        XCTAssertEqual(EveeSettingsCategory.privacyAndStorage.title, "Privacy & Storage")
        XCTAssertEqual(EveeSettingsCategory.privacyAndStorage.symbolName, "lock.doc")
        XCTAssertEqual(EveeSettingsCategory.integrations.title, "Integrations")
        XCTAssertEqual(EveeSettingsCategory.integrations.symbolName, "point.3.connected.trianglepath.dotted")
        XCTAssertEqual(EveeSettingsCategory.application.title, "Application")
        XCTAssertEqual(EveeSettingsCategory.application.symbolName, "gearshape")
    }
}
