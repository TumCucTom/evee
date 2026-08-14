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
