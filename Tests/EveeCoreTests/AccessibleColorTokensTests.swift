import XCTest
@testable import EveeCore

final class AccessibleColorTokensTests: XCTestCase {
    func testEnabledActionStopsMeetTextContrastInEveryAppearance() {
        for appearance in InterfaceAppearance.allCases {
            for stop in AccessibleActionPalette.gradientStops(for: appearance) {
                XCTAssertGreaterThanOrEqual(
                    AccessibleActionPalette.foreground.contrastRatio(with: stop),
                    4.5,
                    "\(appearance) action stop must meet WCAG AA text contrast"
                )
            }
        }
    }

    func testDisabledBorderMeetsNonTextContrastInEveryAppearance() {
        for appearance in InterfaceAppearance.allCases {
            XCTAssertGreaterThanOrEqual(
                AccessibleActionPalette.disabledBorder.contrastRatio(
                    with: AccessibleActionPalette.paper(for: appearance)
                ),
                3,
                "\(appearance) disabled border must remain visible without relying on opacity"
            )
        }
    }
}
