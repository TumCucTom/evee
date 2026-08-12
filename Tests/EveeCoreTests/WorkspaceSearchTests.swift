import XCTest
@testable import EveeCore

final class WorkspaceSearchTests: XCTestCase {
    func testFTSSearchFindsDiacriticsAndRanksTitleMatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let titleMatch = WorkspaceRecord(kind: .memo, title: "Résumé plan", text: "Outline the next steps")
        let bodyMatch = WorkspaceRecord(kind: .memo, title: "Planning", text: "Update the resume after review")
        try await store.upsert(bodyMatch)
        try await store.upsert(titleMatch)

        let results = try await store.search("resume", kind: .memo)

        XCTAssertEqual(Set(results.map(\.id)), Set([titleMatch.id, bodyMatch.id]))
        XCTAssertEqual(results.first?.id, titleMatch.id)
        try? FileManager.default.removeItem(at: root)
    }

    func testFTSProjectionRefreshesWhenRecordTextChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        var record = WorkspaceRecord(kind: .dictation, title: "Draft", text: "alpha")
        try await store.upsert(record)
        let initialResults = try await store.search("alpha")
        XCTAssertEqual(initialResults.map(\.id), [record.id])

        record.text = "beta"
        record.updatedAt = .now.addingTimeInterval(1)
        try await store.upsert(record)

        let obsoleteResults = try await store.search("alpha")
        let updatedResults = try await store.search("beta")
        XCTAssertTrue(obsoleteResults.isEmpty)
        XCTAssertEqual(updatedResults.map(\.id), [record.id])
        try? FileManager.default.removeItem(at: root)
    }

    func testIndexFileUsesOwnerOnlyPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        try await store.upsert(WorkspaceRecord(kind: .memo, title: "Private", text: "indexed"))
        _ = try await store.search("indexed")

        let path = root.appendingPathComponent("workspace-index.sqlite3").path
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try? FileManager.default.removeItem(at: root)
    }
}
