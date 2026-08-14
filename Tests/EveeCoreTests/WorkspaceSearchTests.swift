import XCTest
import SQLite3
@testable import EveeCore

final class WorkspaceSearchTests: XCTestCase {
    func testSearchResultsCoverEveryCanonicalTextProjectionAndReturnMatchingSnippets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let segmentID = UUID()
        let meeting = WorkspaceRecord(
            kind: .meeting,
            title: "TitularQuasar",
            text: "FinishedNebula",
            rawText: "RetainedComet",
            sourceApplication: "SourcePulsar",
            segments: [.init(
                id: segmentID,
                start: 0,
                end: 2,
                speaker: "Facilitator",
                text: "SegmentMeteor"
            )],
            meetingIntelligence: .init(
                summary: ["SummaryOrbit"],
                decisions: [.init(kind: .decision, text: "DecisionGalaxy")],
                actionItems: [.init(kind: .actionItem, text: "ActionCosmos", assignee: "OwnerSatellite", dueText: "DueSolstice")],
                topics: [.init(title: "TopicAsteroid", start: 0, end: 2, sourceSegmentIDs: [segmentID])]
            ),
            notes: "NotesZenith",
            tags: ["TagAurora"],
            context: .init(
                bundleIdentifier: "test.context.bundle",
                applicationName: "ContextNova",
                windowTitle: "Project Atlas",
                document: "DocumentEquinox",
                focusedRole: "RoleApogee",
                selectedText: "SelectionHorizon",
                url: "https://example.test/UrlEclipse",
                codeFile: "CodePerigee.swift",
                recipient: "RecipientLunar",
                visibleText: "VisiblePhoton"
            )
        )
        let memo = WorkspaceRecord(
            kind: .memo,
            title: "Memo",
            text: "Ordinary body",
            memoIntelligence: .init(
                title: "MemoSupernova",
                highlights: ["HighlightRadiance"],
                actionItems: ["MemoActionGravity"]
            )
        )
        try await store.upsert(meeting)
        try await store.upsert(memo)

        let meetingTerms = [
            "TitularQuasar", "FinishedNebula", "RetainedComet", "SourcePulsar",
            "Facilitator", "SegmentMeteor", "SummaryOrbit", "DecisionGalaxy",
            "ActionCosmos", "OwnerSatellite", "DueSolstice", "TopicAsteroid",
            "NotesZenith", "TagAurora", "ContextNova", "Project Atlas",
            "DocumentEquinox", "RoleApogee", "SelectionHorizon", "UrlEclipse",
            "CodePerigee", "RecipientLunar", "VisiblePhoton",
        ]
        for term in meetingTerms {
            let results = try await store.searchResults(term, kind: .meeting)
            XCTAssertEqual(results.first?.record.id, meeting.id, "missing indexed field for \(term)")
            XCTAssertEqual(results.first?.snippet.localizedCaseInsensitiveContains(term), true, "missing indexed snippet for \(term)")
        }

        for term in ["MemoSupernova", "HighlightRadiance", "MemoActionGravity"] {
            let results = try await store.searchResults(term, kind: .memo)
            XCTAssertEqual(results.first?.record.id, memo.id, "missing memo insight field for \(term)")
            XCTAssertEqual(results.first?.snippet.localizedCaseInsensitiveContains(term), true, "missing memo snippet for \(term)")
        }
    }

    func testMatchingHitsThrowsWhenSQLiteStepFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("index.sqlite3")
        var shouldFail = true
        let index = try WorkspaceSearchIndex(url: url) { statement in
            if shouldFail {
                shouldFail = false
                return SQLITE_IOERR
            }
            return sqlite3_step(statement)
        }
        try index.rebuild(records: [WorkspaceRecord(kind: .memo, title: "Step", text: "text")])

        XCTAssertThrowsError(try index.matchingHits(query: "text", kind: nil, limit: 20))
    }

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

    func testFTSProjectionRefreshesAfterMeetingSpeakerRelabel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let segmentID = UUID()
        let original = WorkspaceRecord(
            kind: .meeting,
            title: "Planning",
            text: "Participant 1: First statement",
            segments: [TranscriptSegment(
                id: segmentID,
                start: 0,
                end: 4,
                speaker: "Participant 1",
                text: "First statement",
                attribution: .diarized
            )]
        )
        try await store.upsert(original)

        let changed = try MeetingRecordProjection().relabel(
            record: original,
            segmentID: segmentID,
            label: "Facilitator"
        )
        try await store.upsert(changed)

        let newLabelResults = try await store.search("Facilitator")
        let oldLabelResults = try await store.search("Participant 1")
        XCTAssertEqual(newLabelResults.map(\.id), [original.id])
        XCTAssertTrue(oldLabelResults.isEmpty)
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

    func testCorruptIndexIsRebuiltFromDurableRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = WorkspaceRecord(kind: .memo, title: "Durable", text: "recoverable index content")
        do {
            let initialStore = LibraryStore(rootURL: root)
            try await initialStore.upsert(record)
            _ = try await initialStore.search("recoverable")
        }

        let index = root.appendingPathComponent("workspace-index.sqlite3")
        try Data("not a sqlite database".utf8).write(to: index, options: .atomic)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: index.path + suffix))
        }

        let reopenedStore = LibraryStore(rootURL: root)
        let results = try await reopenedStore.search("recoverable")
        XCTAssertEqual(results.map(\.id), [record.id])
        try? FileManager.default.removeItem(at: root)
    }
}
