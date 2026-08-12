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
        let matches = try await store.search("transcript")
        let roundTripped = try await store.record(id: record.id)
        XCTAssertEqual(matches.map(\.id), [record.id])
        XCTAssertEqual(roundTripped?.title, "Scribe review")
        let saved = try Data(contentsOf: root.appendingPathComponent("records.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, LibraryStore.currentSchemaVersion)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("records.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try? FileManager.default.removeItem(at: root)
    }

    func testVerbatimPreservesWords() {
        XCTAssertEqual(TextCleanupPipeline().clean("um keep this", tone: .verbatim), "um keep this")
    }

    func testLegacyLibraryMigratesWithoutLosingRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = WorkspaceRecord(kind: .memo, title: "Legacy memo", text: "Keep me")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([record]).write(to: root.appendingPathComponent("records.json"))

        let store = LibraryStore(rootURL: root)
        let loaded = try await store.loadRecords()
        XCTAssertEqual(loaded.map(\.id), [record.id])
        XCTAssertEqual(loaded.first?.text, "Keep me")
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("records.json"))) as? [String: Any]
        XCTAssertEqual(migrated?["schemaVersion"] as? Int, LibraryStore.currentSchemaVersion)
        try? FileManager.default.removeItem(at: root)
    }

    func testSettingsDecodeMissingNewerKeys() throws {
        let settings = try JSONDecoder().decode(EveeSettings.self, from: Data("{\"languageCode\":\"en\"}".utf8))
        XCTAssertEqual(settings.languageCode, "en")
        XCTAssertEqual(settings.model, .parakeet)
        XCTAssertFalse(settings.localAPIEnabled)
        XCTAssertTrue(settings.dictionary.isEmpty)
    }

    func testDualTrackRecoveryCanBeRetained() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let microphone = input.appendingPathComponent("microphone.caf")
        let system = input.appendingPathComponent("system.m4a")
        try Data("microphone".utf8).write(to: microphone)
        try Data("system".utf8).write(to: system)

        let store = LibraryStore(rootURL: root)
        let capture = try await store.beginRecoveryCapture(kind: .meeting)
        _ = try await store.addRecoveryTrack(captureID: capture.id, kind: .meeting, role: .microphone, sourceURL: microphone)
        let completed = try await store.addRecoveryTrack(captureID: capture.id, kind: .meeting, role: .system, sourceURL: system)
        XCTAssertEqual(Set(completed.tracks.map(\.role)), Set([.microphone, .system]))

        let retained = try await store.retainRecoveryCapture(id: capture.id, for: UUID())
        XCTAssertEqual(Set(retained.map(\.role)), Set([.microphone, .system]))
        for track in retained {
            let url = try await store.safeURL(forRelativePath: track.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: input)
    }

    func testUnsafeAudioPathIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        do {
            _ = try await store.safeURL(forRelativePath: "../outside")
            XCTFail("Expected traversal to be rejected")
        } catch is LibraryStoreError {
            // Expected.
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testMCPRegistrationPreservesOtherServersAndUsesPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("evee-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configuration = root.appendingPathComponent("client/config.json")
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"mcpServers\":{\"other\":{\"command\":\"other\"}}}".utf8).write(to: configuration)

        let result = try MCPRegistration.writeConfiguration(at: configuration, executableURL: executable)
        XCTAssertFalse(result.replacedExistingRegistration)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        XCTAssertNotNil(servers["evee"])
        let permissions = try FileManager.default.attributesOfItem(atPath: configuration.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try? FileManager.default.removeItem(at: root)
    }

    func testWebhookSignatureIsStableAndHexEncoded() {
        let signature = MeetingWebhook.signature(for: Data("payload".utf8), secret: "secret")
        XCTAssertEqual(signature.count, 64)
        XCTAssertEqual(signature, MeetingWebhook.signature(for: Data("payload".utf8), secret: "secret"))
        XCTAssertNotEqual(signature, MeetingWebhook.signature(for: Data("different".utf8), secret: "secret"))
    }
}
