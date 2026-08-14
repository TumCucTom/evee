import XCTest
@testable import EveeCore

final class AccessibilityCopyTests: XCTestCase {
    func testRecordRowIncludesVisibleSearchSnippetAndSource() {
        let record = WorkspaceRecord(
            kind: .meeting,
            title: "Weekly review",
            text: "Full transcript",
            sourceApplication: "Meet"
        )
        let label = AccessibilityCopy.recordRow(record: record, snippet: "…matched decision text…")
        XCTAssertTrue(label.contains("matched decision text"))
        XCTAssertTrue(label.contains("Meet"))
    }

    func testContextualActionLabelsIdentifyTheirTarget() {
        XCTAssertEqual(AccessibilityCopy.clearSearch, "Clear workspace search")
        XCTAssertEqual(AccessibilityCopy.removeAppStyle(named: "Mail"), "Remove writing style for Mail")
        XCTAssertEqual(AccessibilityCopy.removeSmartLink(phrase: "Anima"), "Remove smart link for Anima")
        XCTAssertEqual(
            AccessibilityCopy.removeDictionaryTerm(spoken: "eye vee", replacement: "IV"),
            "Remove dictionary replacement eye vee with IV"
        )
        XCTAssertEqual(AccessibilityCopy.exportRetainedTrack(named: "Microphone"), "Export retained Microphone audio")
        XCTAssertEqual(AccessibilityCopy.helperRegistration(clientCount: 2), "Enable local helper access for 2 selected clients")
        XCTAssertEqual(AccessibilityCopy.helperRevocation, "Revoke local helper access from registered clients")
        XCTAssertEqual(AccessibilityCopy.revokeLocalAPIAccess, "Revoke local API access and delete its token")
        XCTAssertEqual(AccessibilityCopy.cancelWebhookOutbox, "Cancel all undelivered webhook items")
    }

    func testRecoverySpeakerAndDestructiveLabelsCarryContext() {
        let startedAt = Date(timeIntervalSince1970: 1_786_616_100)
        XCTAssertTrue(AccessibilityCopy.recoveredNotes(startedAt: startedAt).contains("Recovered meeting notes from"))
        XCTAssertEqual(
            AccessibilityCopy.speakerLabel(start: 125, currentLabel: nil),
            "Speaker at 2 minutes 5 seconds, unlabelled"
        )
        XCTAssertEqual(AccessibilityCopy.deleteRecord(kind: .memo, title: "Idea"), "Delete memo Idea permanently")
        XCTAssertEqual(AccessibilityCopy.discardRecovery(kind: .meeting, startedAt: startedAt).hasPrefix("Discard interrupted meeting from"), true)
        XCTAssertEqual(AccessibilityCopy.deleteActivityData, "Delete all stored activity and journal data")
    }

    func testLayoutUsesTwoColumnsForDenseRoutesAndActiveMeeting() {
        XCTAssertEqual(RootLayoutMode.route(.settings, captureState: .idle), .sidebarAndDetail)
        XCTAssertEqual(RootLayoutMode.route(.dictionary, captureState: .idle), .sidebarAndDetail)
        XCTAssertEqual(RootLayoutMode.route(.meetings, captureState: .recording(startedAt: .distantPast, level: 0)), .sidebarAndDetail)
        XCTAssertEqual(RootLayoutMode.route(.library, captureState: .idle), .threeColumn)
        XCTAssertEqual(RootLayoutMode.route(.meetings, captureState: .idle), .threeColumn)
    }
}
