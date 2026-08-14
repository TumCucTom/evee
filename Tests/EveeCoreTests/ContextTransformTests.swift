import XCTest
@testable import EveeCore

final class ContextTransformTests: XCTestCase {
    func testOrdinaryDictationWithoutRetentionCollectsOnlyDeliveryIdentity() {
        let policy = ContextCollectionPolicy.ordinaryDictation(
            retainMetadata: false,
            captureVisibleText: false
        )

        XCTAssertTrue(policy.collectsDeliveryIdentity)
        XCTAssertFalse(policy.collectsSelectedText)
        XCTAssertFalse(policy.collectsWindowMetadata)
        XCTAssertFalse(policy.collectsWebAndFileMetadata)
        XCTAssertFalse(policy.collectsRecipientMetadata)
        XCTAssertFalse(policy.collectsVisibleText)
    }

    func testSelectionTransformationAlwaysCollectsSelectedText() {
        let policy = ContextCollectionPolicy.selectionTransformation(retainMetadata: false)

        XCTAssertTrue(policy.collectsSelectedText)
    }

    func testWorkspaceContextRoundTripsWithSelection() throws {
        let record = WorkspaceRecord(
            kind: .dictation,
            title: "Transform",
            text: "SHIP TODAY",
            rawText: "make uppercase",
            sourceApplication: "TextEdit",
            operation: .selectionTransform,
            context: WorkspaceContext(
                bundleIdentifier: "com.apple.TextEdit",
                applicationName: "TextEdit",
                windowTitle: "Notes",
                document: "file:///tmp/notes.txt",
                focusedRole: "AXTextArea",
                selectedText: "ship today"
            )
        )

        let restored = try JSONDecoder().decode(WorkspaceRecord.self, from: JSONEncoder().encode(record))

        XCTAssertEqual(restored.operation, .selectionTransform)
        XCTAssertEqual(restored.context, record.context)
        XCTAssertEqual(restored.context?.selectedText, "ship today")
    }

    func testLegacyRecordDefaultsToCaptureWithoutContext() throws {
        let record = WorkspaceRecord(kind: .dictation, title: "Legacy", text: "Saved")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        object.removeValue(forKey: "operation")
        object.removeValue(forKey: "context")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder().decode(WorkspaceRecord.self, from: legacyData)

        XCTAssertEqual(restored.operation, .capture)
        XCTAssertNil(restored.context)
    }

    func testNewPrivacyAndDeliverySettingsHaveSafeLegacyDefaults() throws {
        let settings = try JSONDecoder().decode(EveeSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(settings.textDeliveryMode, .paste)
        XCTAssertFalse(settings.retainContextMetadata)
        XCTAssertFalse(settings.retainSelectedText)
    }

    func testSelectionTransformSupportsDeterministicCommands() throws {
        let pipeline = SelectionTransformPipeline()

        XCTAssertEqual(
            try pipeline.transform(selectedText: "ship this today", instruction: "Make uppercase"),
            "SHIP THIS TODAY"
        )
        XCTAssertEqual(
            try pipeline.transform(selectedText: "alpha. beta. gamma", instruction: "Make this a bullet list"),
            "• alpha\n• beta\n• gamma"
        )
        XCTAssertEqual(
            try pipeline.transform(selectedText: "Alice met ALICE", instruction: "replace Alice with Bob"),
            "Bob met Bob"
        )
    }

    func testUnsupportedSelectionTransformDoesNotInventARewrite() {
        XCTAssertThrowsError(
            try SelectionTransformPipeline().transform(
                selectedText: "Quarterly results",
                instruction: "Rewrite this as a sonnet"
            )
        ) { error in
            XCTAssertEqual(error as? SelectionTransformError, .unsupportedInstruction)
        }
        XCTAssertEqual(
            SelectionTransformPipeline.supportedCommandSummary,
            "Concise, clean up, uppercase, lowercase, title case, bullets, numbered list, and replace … with … (case-insensitive, all matches)"
        )
    }
}
