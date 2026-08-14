import XCTest
@testable import EveeCore

final class AccessibleColorTokensTests: XCTestCase {
    func testEnabledActionStopsMeetTextContrastInEveryAppearance() {
        for appearance in InterfaceAppearance.allCases {
            let foreground = EveeVisualPalette.rgb(.primaryActionForeground, appearance: appearance)
            for stop in AccessibleActionPalette.gradientStops(for: appearance) {
                XCTAssertGreaterThanOrEqual(
                    foreground.contrastRatio(with: stop),
                    4.5,
                    "\(appearance) action stop must meet WCAG AA text contrast"
                )
            }
        }
    }

    func testOrdinarySolidAccentMeetsTextContrastInEveryAppearance() {
        for appearance in InterfaceAppearance.allCases {
            XCTAssertGreaterThanOrEqual(
                EveeVisualPalette.rgb(.primaryActionForeground, appearance: appearance)
                    .contrastRatio(with: EveeVisualPalette.rgb(.accent, appearance: appearance)),
                4.5,
                "\(appearance) solid accent button must meet WCAG AA text contrast"
            )
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
