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

    func testSelfActivationPreservesSuggestionWhileExternalNonmatchAndDismissClearIt() {
        let settings = MeetingSuggestionSettings(
            enabled: true,
            nativeBundleIdentifiers: ["test.meeting"],
            browserBundleIdentifiers: [],
            browserTitleTerms: [],
            dismissedUntilByBundleIdentifier: [:]
        )
        let policy = MeetingSuggestionPolicy(settings: settings)
        let matching = MeetingApplicationSnapshot(
            bundleIdentifier: "test.meeting",
            applicationName: "Synthetic Meeting App",
            isBrowser: false,
            permittedWindowTitle: nil,
            observedAt: now
        )
        let unrelated = MeetingApplicationSnapshot(
            bundleIdentifier: "test.editor",
            applicationName: "Synthetic Editor",
            isBrowser: false,
            permittedWindowTitle: nil,
            observedAt: now
        )
        let pending = policy.nextSuggestion(current: nil, event: .observed(matching))

        XCTAssertEqual(
            policy.nextSuggestion(current: pending, event: .ownApplicationActivated),
            pending
        )
        XCTAssertNil(policy.nextSuggestion(current: pending, event: .observed(unrelated)))
        XCTAssertNil(policy.nextSuggestion(current: pending, event: .dismissed))
    }

    func testOwnApplicationIdentityUsesProcessFirstAndBundleAsFallback() {
        let identity = MeetingApplicationIdentity(
            processIdentifier: 42,
            bundleIdentifier: "test.evee"
        )

        XCTAssertTrue(identity.matches(processIdentifier: 42, bundleIdentifier: "unexpected.bundle"))
        XCTAssertTrue(identity.matches(processIdentifier: 99, bundleIdentifier: "test.evee"))
        XCTAssertFalse(identity.matches(processIdentifier: 99, bundleIdentifier: "test.editor"))
        XCTAssertFalse(identity.matches(processIdentifier: 99, bundleIdentifier: nil))
    }
}
