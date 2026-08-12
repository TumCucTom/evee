import XCTest
@testable import EveeCore

final class WorkspaceLifecycleTests: XCTestCase {
    func testRetentionPurgeRemovesExpiredMetadataAndRetainedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        try await store.prepare()
        let audioRoot = await store.audioURL.appendingPathComponent("Records", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let audio = audioRoot.appendingPathComponent("old.caf")
        try Data("audio".utf8).write(to: audio)
        let old = WorkspaceRecord(
            kind: .memo,
            createdAt: Date(timeIntervalSinceNow: -100 * 86_400),
            title: "Old",
            text: "Expired",
            audioRelativePath: "Audio/Records/old.caf"
        )
        let recent = WorkspaceRecord(kind: .dictation, title: "Recent", text: "Keep")
        try await store.upsert(old)
        try await store.upsert(recent)

        let removed = try await store.purgeRecords(olderThan: Date(timeIntervalSinceNow: -30 * 86_400))
        let remaining = try await store.loadRecords()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(remaining.map(\.id), [recent.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testJSONExportOmitsPrivateWebhookPayload() throws {
        var record = WorkspaceRecord(kind: .meeting, title: "Review", text: "Decisions")
        record.webhookDeliveries = [WebhookDelivery(destination: "https://example.test", payloadBody: Data("private".utf8))]
        let data = try WorkspaceExporter.data(for: [record], format: .json)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("cHJpdmF0ZQ"))
        XCTAssertTrue(text.contains("Review"))
    }

    func testMarkdownExportIncludesTextAndNotes() throws {
        let record = WorkspaceRecord(kind: .meeting, title: "Planning", text: "Launch discussion", notes: "Owner: Sam")
        let data = try WorkspaceExporter.data(for: [record], format: .markdown)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("# Planning"))
        XCTAssertTrue(text.contains("Launch discussion"))
        XCTAssertTrue(text.contains("## Notes"))
        XCTAssertTrue(text.contains("Owner: Sam"))
    }
}
