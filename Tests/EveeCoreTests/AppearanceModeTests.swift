import XCTest
@testable import EveeCore

final class AppearanceModeTests: XCTestCase {
    func testAutomaticFollowsSystemWhileExplicitModesRemainStable() {
        XCTAssertEqual(EveeAppearanceMode.automatic.resolve(systemAppearance: .light), .light)
        XCTAssertEqual(EveeAppearanceMode.automatic.resolve(systemAppearance: .dark), .dark)
        XCTAssertEqual(EveeAppearanceMode.light.resolve(systemAppearance: .dark), .light)
        XCTAssertEqual(EveeAppearanceMode.dark.resolve(systemAppearance: .light), .dark)
        XCTAssertEqual(EveeAppearanceMode.anima.resolve(systemAppearance: .dark), .anima)
        XCTAssertEqual(EveeAppearanceMode.anima.resolve(systemAppearance: .light), .anima)
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
