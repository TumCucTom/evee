import XCTest
@testable import EveeCore

final class MeetingSuggestionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testSuggestionsAreOptInAndNativeMatchesUseBundleAllowlist() {
        let snapshot = MeetingApplicationSnapshot(
            bundleIdentifier: "test.meeting",
            applicationName: "Synthetic Meeting App",
            isBrowser: false,
            permittedWindowTitle: nil,
            observedAt: now
        )
        XCTAssertNil(MeetingSuggestionPolicy(settings: .suggestionsDisabled).evaluate(snapshot))

        let enabled = MeetingSuggestionSettings(
            enabled: true,
            nativeBundleIdentifiers: ["test.meeting"],
            browserBundleIdentifiers: [],
            browserTitleTerms: [],
            dismissedUntilByBundleIdentifier: [:]
        )
        XCTAssertEqual(
            MeetingSuggestionPolicy(settings: enabled).evaluate(snapshot)?.applicationName,
            "Synthetic Meeting App"
        )
    }

    func testBrowserRequiresPermittedMatchingTitleAndDismissalCooldownExpires() {
        let settings = MeetingSuggestionSettings(
            enabled: true,
            nativeBundleIdentifiers: [],
            browserBundleIdentifiers: ["test.browser"],
            browserTitleTerms: ["meeting"],
            dismissedUntilByBundleIdentifier: ["test.browser": now.addingTimeInterval(60)]
        )
        let withoutTitle = MeetingApplicationSnapshot(
            bundleIdentifier: "test.browser",
            applicationName: "Browser",
            isBrowser: true,
            permittedWindowTitle: nil,
            observedAt: now
        )
        XCTAssertNil(MeetingSuggestionPolicy(settings: settings).evaluate(withoutTitle))

        let withinCooldown = MeetingApplicationSnapshot(
            bundleIdentifier: "test.browser",
            applicationName: "Browser",
            isBrowser: true,
            permittedWindowTitle: "Project meeting",
            observedAt: now
        )
        XCTAssertNil(MeetingSuggestionPolicy(settings: settings).evaluate(withinCooldown))

        let afterCooldown = MeetingApplicationSnapshot(
            bundleIdentifier: "test.browser",
            applicationName: "Browser",
            isBrowser: true,
            permittedWindowTitle: "Project meeting",
            observedAt: now.addingTimeInterval(61)
        )
        XCTAssertNotNil(MeetingSuggestionPolicy(settings: settings).evaluate(afterCooldown))
    }
}
