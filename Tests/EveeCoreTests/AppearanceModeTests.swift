import XCTest
@testable import EveeCore

final class AppearanceModeTests: XCTestCase {
    func testAutomaticFollowsSystemWhileExplicitModesRemainStable() {
        XCTAssertEqual(EveeAppearanceMode.automatic.resolve(systemAppearance: .light), .light)
        XCTAssertEqual(EveeAppearanceMode.automatic.resolve(systemAppearance: .dark), .dark)
        XCTAssertEqual(EveeAppearanceMode.glass.resolve(systemAppearance: .light), .light)
        XCTAssertEqual(EveeAppearanceMode.glass.resolve(systemAppearance: .dark), .dark)
        XCTAssertEqual(EveeAppearanceMode.light.resolve(systemAppearance: .dark), .light)
        XCTAssertEqual(EveeAppearanceMode.dark.resolve(systemAppearance: .light), .dark)
        XCTAssertEqual(EveeAppearanceMode.anima.resolve(systemAppearance: .dark), .anima)
        XCTAssertEqual(EveeAppearanceMode.anima.resolve(systemAppearance: .light), .anima)
    }

    func testGlassMaterialUsesAQuieterTintThanStandardMaterial() {
        let glass = EveeMaterialPresentation.make(
            mode: .glass,
            layer: .panel,
            reduceTransparency: false,
            increaseContrast: false
        )
        let standard = EveeMaterialPresentation.make(
            mode: .automatic,
            layer: .panel,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertTrue(glass.usesTranslucency)
        XCTAssertLessThan(glass.tintOpacity, standard.tintOpacity)
        XCTAssertGreaterThan(glass.edgeOpacity, 0)
    }

    func testGlassMaterialBecomesOpaqueWhenTransparencyIsReduced() {
        let presentation = EveeMaterialPresentation.make(
            mode: .glass,
            layer: .rail,
            reduceTransparency: true,
            increaseContrast: false
        )

        XCTAssertFalse(presentation.usesTranslucency)
        XCTAssertEqual(presentation.tintOpacity, 1)
    }

    func testGlassMaterialStrengthensItsBoundaryForIncreasedContrast() {
        let standard = EveeMaterialPresentation.make(
            mode: .glass,
            layer: .panel,
            reduceTransparency: false,
            increaseContrast: false
        )
        let increased = EveeMaterialPresentation.make(
            mode: .glass,
            layer: .panel,
            reduceTransparency: false,
            increaseContrast: true
        )

        XCTAssertGreaterThan(increased.edgeOpacity, standard.edgeOpacity)
    }

    func testAppearanceModePersistsWithoutTouchingOperationalSettings() {
        let suite = "AppearanceModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(EveeAppearancePreference.load(from: defaults), .automatic)
        for mode in EveeAppearanceMode.allCases {
            EveeAppearancePreference.save(mode, to: defaults)
            XCTAssertEqual(EveeAppearancePreference.load(from: defaults), mode)
        }
    }

    func testUnknownPersistedAppearanceFallsBackToAutomatic() {
        let suite = "AppearanceModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("future-mode", forKey: EveeAppearancePreference.key)
        XCTAssertEqual(EveeAppearancePreference.load(from: defaults), .automatic)
    }
}
