import XCTest
@testable import EveeCore

final class PrivacyPresentationTests: XCTestCase {
    func testEnabledPrivacyModeHidesSensitiveRootsAndKeepsMenuActionAvailable() {
        let presentation = PrivacyPresentation(enabled: true)

        XCTAssertFalse(presentation.constructsWorkspaceContent)
        XCTAssertFalse(presentation.constructsSettingsContent)
        XCTAssertTrue(presentation.constructsMenuContent)
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Privacy mode is on. Sensitive Evee content is hidden."
        )
        XCTAssertTrue(presentation.windowProtectionCopy.contains("best-effort"))
    }

    func testDisabledPrivacyModeConstructsSensitiveRoots() {
        let presentation = PrivacyPresentation(enabled: false)

        XCTAssertTrue(presentation.constructsWorkspaceContent)
        XCTAssertTrue(presentation.constructsSettingsContent)
        XCTAssertTrue(presentation.constructsMenuContent)
        XCTAssertEqual(presentation.accessibilityLabel, "Privacy mode is off.")
    }
}
