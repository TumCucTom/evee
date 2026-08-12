import XCTest
@testable import EveeCore

final class EveeCoreTests: XCTestCase {
    func testCleanupRemovesFillersAndAppliesDictionary() {
        let result = TextCleanupPipeline().clean(
            "um send the PR to anima full stop",
            terms: [DictionaryTerm(spoken: "anima", replacement: "Anima")]
        )
        XCTAssertEqual(result, "Send the PR to Anima.")
    }

    func testLibraryRoundTripAndSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let record = WorkspaceRecord(kind: .meeting, title: "Scribe review", text: "Discussed transcript storage")
        try await store.upsert(record)
        XCTAssertEqual(try await store.search("transcript").map(\.id), [record.id])
        XCTAssertEqual(try await store.record(id: record.id)?.title, "Scribe review")
        try? FileManager.default.removeItem(at: root)
    }

    func testVerbatimPreservesWords() {
        XCTAssertEqual(TextCleanupPipeline().clean("um keep this", tone: .verbatim), "um keep this")
    }
}
