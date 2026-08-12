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

    func testSettingsNeverEncodeLegacyWebhookSecret() throws {
        var settings = EveeSettings()
        settings.webhookURL = "https://example.com/webhook"
        settings.webhookSecret = "must-not-reach-disk"
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("must-not-reach-disk"))
        XCTAssertFalse(json.contains("webhookSecret"))
    }

    func testWebhookEndpointRequiresHTTPSExceptExactLoopback() throws {
        XCTAssertNoThrow(try WebhookEndpointPolicy.validate(URL(string: "https://example.com/hooks/evee")!))
        XCTAssertNoThrow(try WebhookEndpointPolicy.validate(URL(string: "http://127.0.0.1:9000/hook")!))
        XCTAssertNoThrow(try WebhookEndpointPolicy.validate(URL(string: "http://localhost:9000/hook")!))
        XCTAssertThrowsError(try WebhookEndpointPolicy.validate(URL(string: "http://example.com/hook")!))
        XCTAssertThrowsError(try WebhookEndpointPolicy.validate(URL(string: "https://user:password@example.com/hook")!))
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

        let proposed = WorkspaceRecord(kind: .meeting, title: "Recovered", text: "Transcript")
        let committed = try await store.commitRecoveredRecord(proposed, recoveryID: capture.id, keepAudio: true)
        XCTAssertEqual(Set(committed.audioTracks.map(\.role)), Set([.microphone, .system]))
        for track in committed.audioTracks {
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

    func testMeetingDraftRoundTripsAndCanBeCleared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let captureID = UUID()
        let draft = MeetingDraft(captureID: captureID, title: "Weekly review", notes: "Follow up with Sam")

        try await store.saveMeetingDraft(draft)
        let restored = try await store.loadMeetingDraft()
        XCTAssertEqual(restored?.captureID, captureID)
        XCTAssertEqual(restored?.title, "Weekly review")
        XCTAssertEqual(restored?.notes, "Follow up with Sam")

        try await store.saveMeetingDraft(nil)
        let cleared = try await store.loadMeetingDraft()
        XCTAssertNil(cleared)
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReconcilesAudioWrittenBeforeManifestUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let capture = try await store.beginRecoveryCapture(kind: .meeting)
        let recoveryRoot = await store.recoveryURL
        let directory = recoveryRoot.appendingPathComponent(capture.id.uuidString, isDirectory: true)
        try Data("microphone".utf8).write(to: directory.appendingPathComponent("microphone.caf"))
        try Data("system".utf8).write(to: directory.appendingPathComponent("system.m4a"))

        let reconciled = try await store.recoverableCaptures().first { $0.id == capture.id }
        XCTAssertEqual(Set(reconciled?.tracks.map(\.role) ?? []), Set([.microphone, .system]))
        XCTAssertEqual(reconciled?.status, .captured)
        XCTAssertEqual(reconciled?.kind, .meeting)
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveredRecordCommitOwnsAudioBeforeRecoveryIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try Data("audio".utf8).write(to: input)
        let store = LibraryStore(rootURL: root)
        let capture = try await store.beginRecoveryCapture(kind: .memo)
        _ = try await store.addRecoveryTrack(captureID: capture.id, kind: .memo, role: .microphone, sourceURL: input)
        let proposed = WorkspaceRecord(kind: .memo, title: "Recovered memo", text: "Recovered")

        let committed = try await store.commitRecoveredRecord(proposed, recoveryID: capture.id, keepAudio: true)
        let storedRecord = try await store.record(id: proposed.id)
        XCTAssertEqual(storedRecord?.id, proposed.id)
        let track = try XCTUnwrap(committed.audioTracks.first)
        let retainedURL = try await store.safeURL(forRelativePath: track.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
        let recoveriesAfterCommit = try await store.recoverableCaptures()
        XCTAssertFalse(recoveriesAfterCommit.contains { $0.id == capture.id })

        try await store.delete(id: proposed.id)
        let deletedRecord = try await store.record(id: proposed.id)
        XCTAssertNil(deletedRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedURL.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testReconciliationHonoursCommittedRecoveryOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try Data("audio".utf8).write(to: input)
        let store = LibraryStore(rootURL: root)
        let recovery = try await store.beginRecoveryCapture(kind: .dictation)
        _ = try await store.addRecoveryTrack(captureID: recovery.id, kind: .dictation, role: .microphone, sourceURL: input)
        let record = WorkspaceRecord(kind: .dictation, title: "Committed", text: "Saved", recoverySourceID: recovery.id)
        try await store.upsert(record)

        try await store.reconcileAudioStorage()
        let remaining = try await store.recoverableCaptures()
        let persisted = try await store.record(id: record.id)
        XCTAssertFalse(remaining.contains(where: { $0.id == recovery.id }))
        XCTAssertNotNil(persisted)
        try? FileManager.default.removeItem(at: root)
    }

    func testPurgingRecoveryIsRemovedOnLaunchReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try Data("private audio".utf8).write(to: input)
        let store = LibraryStore(rootURL: root)
        let recovery = try await store.beginRecoveryCapture(kind: .memo)
        _ = try await store.addRecoveryTrack(captureID: recovery.id, kind: .memo, role: .microphone, sourceURL: input)
        try await store.updateRecoveryCapture(id: recovery.id, status: .purging)

        try await store.reconcileAudioStorage()
        let remaining = try await store.recoverableCaptures()
        XCTAssertFalse(remaining.contains(where: { $0.id == recovery.id }))
        try? FileManager.default.removeItem(at: root)
    }

    func testNoRetentionCommitPersistsMetadataAndPurgesRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try Data("private audio".utf8).write(to: input)
        let store = LibraryStore(rootURL: root)
        let recovery = try await store.beginRecoveryCapture(kind: .dictation)
        _ = try await store.addRecoveryTrack(captureID: recovery.id, kind: .dictation, role: .microphone, sourceURL: input)
        let proposed = WorkspaceRecord(kind: .dictation, title: "Private", text: "Keep text only")

        let committed = try await store.commitRecoveredRecord(proposed, recoveryID: recovery.id, keepAudio: false)
        let persisted = try await store.record(id: proposed.id)
        let remaining = try await store.recoverableCaptures()

        XCTAssertEqual(committed.recoverySourceID, recovery.id)
        XCTAssertTrue(committed.audioTracks.isEmpty)
        XCTAssertNotNil(persisted)
        XCTAssertFalse(remaining.contains(where: { $0.id == recovery.id }))
        try? FileManager.default.removeItem(at: root)
    }

    func testCommittedRecoveryIsHiddenWhenCleanupIsPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let recovery = try await store.beginRecoveryCapture(kind: .memo)
        try await store.updateRecoveryCapture(id: recovery.id, status: .committed)

        let visible = try await store.recoverableCaptures()

        XCTAssertFalse(visible.contains(where: { $0.id == recovery.id }))
        try? FileManager.default.removeItem(at: root)
    }

    func testRetainedCommitRejectsMissingRecoveryCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let record = WorkspaceRecord(kind: .memo, title: "Missing", text: "Must not silently downgrade")

        do {
            _ = try await store.commitRecoveredRecord(record, recoveryID: UUID(), keepAudio: true)
            XCTFail("Expected retained commit to reject a missing recovery capture")
        } catch LibraryStoreError.missingRecoveryCapture(_) {
            let persisted = try await store.record(id: record.id)
            XCTAssertNil(persisted)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testRetainedCommitRejectsMissingDeclaredAudioSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try Data("audio".utf8).write(to: input)
        let store = LibraryStore(rootURL: root)
        let recovery = try await store.beginRecoveryCapture(kind: .memo)
        let manifest = try await store.addRecoveryTrack(captureID: recovery.id, kind: .memo, role: .microphone, sourceURL: input)
        let retainedSource = try await store.safeURL(forRelativePath: try XCTUnwrap(manifest.tracks.first?.relativePath))
        try FileManager.default.removeItem(at: retainedSource)
        let record = WorkspaceRecord(kind: .memo, title: "Incomplete", text: "Reject incomplete media")

        do {
            _ = try await store.commitRecoveredRecord(record, recoveryID: recovery.id, keepAudio: true)
            XCTFail("Expected retained commit to reject a missing declared source")
        } catch LibraryStoreError.missingAudioSource(_) {
            let persisted = try await store.record(id: record.id)
            XCTAssertNil(persisted)
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: input)
    }

    func testWebhookPayloadIsStableAcrossOutboxMutations() throws {
        var record = WorkspaceRecord(kind: .meeting, title: "Review", text: "Stable body")
        let original = try MeetingWebhook.payload(for: record)
        record.webhookDeliveries.append(WebhookDelivery(destination: "https://example.com/hook", state: .failed, attemptCount: 3))
        let afterOutboxMutation = try MeetingWebhook.payload(for: record)

        XCTAssertEqual(original, afterOutboxMutation)
    }
}
