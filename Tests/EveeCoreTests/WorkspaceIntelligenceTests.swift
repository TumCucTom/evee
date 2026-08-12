import XCTest
@testable import EveeCore

final class WorkspaceIntelligenceTests: XCTestCase {
    func testCollectionIsOffByDefault() async throws {
        let (store, root) = makeStore()
        try await store.record(.init(bundleIdentifier: "test.editor", applicationName: "Editor"))

        let timeline = try await store.timeline()
        let context = try await store.currentContext()

        XCTAssertFalse(timeline.enabled)
        XCTAssertTrue(timeline.value.isEmpty)
        XCTAssertNil(context.value)
        try? FileManager.default.removeItem(at: root)
    }

    func testDwellEventsAndContextComeFromRecordedObservations() async throws {
        let (store, root) = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.savePreferences(.init(isEnabled: true, minimumDwellSeconds: 5), at: start)
        try await store.record(.init(bundleIdentifier: "test.editor", applicationName: "Editor", windowTitle: "Private draft"), at: start)
        try await store.record(.init(bundleIdentifier: "test.browser", applicationName: "Browser", windowTitle: "Account"), at: start.addingTimeInterval(12))

        let timeline = try await store.timeline()
        let context = try await store.currentContext()

        XCTAssertTrue(timeline.enabled)
        XCTAssertEqual(timeline.value.count, 1)
        XCTAssertEqual(timeline.value[0].applicationName, "Editor")
        XCTAssertEqual(timeline.value[0].duration, 12, accuracy: 0.001)
        XCTAssertNil(timeline.value[0].windowTitle)
        XCTAssertEqual(context.value?.applicationName, "Browser")
        XCTAssertNil(context.value?.windowTitle)
        try? FileManager.default.removeItem(at: root)
    }

    func testJournalIsGeneratedDurablyFromCompletedEvents() async throws {
        let (store, root) = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let preferences = WorkspaceIntelligencePreferences(isEnabled: true, journalEnabled: true, minimumDwellSeconds: 1)
        try await store.savePreferences(preferences, at: start)
        try await store.record(.init(bundleIdentifier: "test.editor", applicationName: "Editor"), at: start)
        try await store.record(.init(bundleIdentifier: "test.browser", applicationName: "Browser"), at: start.addingTimeInterval(60))
        try await store.stop(at: start.addingTimeInterval(90))

        let reopened = WorkspaceIntelligenceStore(rootURL: root)
        let journal = try await reopened.journal()

        XCTAssertTrue(journal.enabled)
        XCTAssertEqual(journal.value.count, 1)
        XCTAssertEqual(journal.value[0].trackedDuration, 90, accuracy: 0.001)
        XCTAssertEqual(journal.value[0].applications.map(\.applicationName), ["Editor", "Browser"])
        try? FileManager.default.removeItem(at: root)
    }

    func testDisablingWindowTitlesRedactsExistingEvents() async throws {
        let (store, root) = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.savePreferences(.init(isEnabled: true, includeWindowTitles: true, minimumDwellSeconds: 1), at: start)
        try await store.record(.init(bundleIdentifier: "test.editor", applicationName: "Editor", windowTitle: "Roadmap"), at: start)
        try await store.record(.init(bundleIdentifier: "test.browser", applicationName: "Browser", windowTitle: "Search"), at: start.addingTimeInterval(10))
        try await store.savePreferences(.init(isEnabled: true, includeWindowTitles: false, minimumDwellSeconds: 1), at: start.addingTimeInterval(20))

        let timeline = try await store.timeline()
        let context = try await store.currentContext()
        XCTAssertEqual(timeline.value.count, 2)
        XCTAssertTrue(timeline.value.allSatisfy { $0.windowTitle == nil })
        XCTAssertNil(context.value?.windowTitle)
        try? FileManager.default.removeItem(at: root)
    }

    func testDisabledCollectionDoesNotDiscloseHistoricalActivity() async throws {
        let (store, root) = makeStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.savePreferences(.init(isEnabled: true, journalEnabled: true, minimumDwellSeconds: 1), at: start)
        try await store.record(.init(bundleIdentifier: "test.editor", applicationName: "Editor"), at: start)
        try await store.stop(at: start.addingTimeInterval(10))
        try await store.savePreferences(.init(isEnabled: false), at: start.addingTimeInterval(11))

        let timeline = try await store.timeline()
        let usage = try await store.applicationUsage()
        let journal = try await store.journal()
        XCTAssertFalse(timeline.enabled)
        XCTAssertTrue(timeline.value.isEmpty)
        XCTAssertTrue(usage.value.isEmpty)
        XCTAssertTrue(journal.value.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> (WorkspaceIntelligenceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (WorkspaceIntelligenceStore(rootURL: root), root)
    }
}
