import XCTest
@testable import EveeCore

final class LocalAPIServerTests: XCTestCase {
    func testPublicRecordExcludesPrivatePersistenceFields() throws {
        let privateRecord = WorkspaceRecord(
            kind: .meeting,
            title: "Synthetic",
            text: "Visible",
            rawText: "Private raw",
            audioRelativePath: "Audio/private.caf",
            recoverySourceID: UUID(),
            context: WorkspaceContext(selectedText: "Private selection")
        )

        let encoded = try JSONEncoder().encode(PublicWorkspaceRecord(privateRecord))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(json.contains("Visible"))
        XCTAssertFalse(json.contains("private.caf"))
        XCTAssertFalse(json.contains("Private raw"))
        XCTAssertFalse(json.contains("Private selection"))
        XCTAssertFalse(json.contains("recoverySourceID"))
        XCTAssertFalse(json.contains("webhookDeliveries"))
        XCTAssertFalse(json.contains("context"))
    }
}
