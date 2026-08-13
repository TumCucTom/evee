import AVFoundation
import XCTest
@_spi(Testing) @testable import EveeCore

final class WorkspaceLifecycleTests: XCTestCase {
    func testRecoveryTracksAreAssessedIndependently() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let capture = try await recoveryCapture(
            in: store,
            root: root,
            kind: .meeting,
            microphoneData: syntheticSilentWAV(),
            systemData: Data("not audio".utf8)
        )

        let assessments = try await store.assessRecoveryTracks(captureID: capture.id)

        XCTAssertEqual(assessments.count, 2)
        XCTAssertEqual(assessments.first(where: { $0.role == .microphone })?.isValid, true)
        XCTAssertEqual(assessments.first(where: { $0.role == .system })?.isValid, false)
        XCTAssertNotNil(assessments.first(where: { $0.role == .system })?.failureReason)
    }

    func testRecoveryAssessmentSupportsSystemOnlyBothValidAndNeitherValid() async throws {
        let cases: [(Data, Data, Bool, Bool)] = [
            (Data("bad mic".utf8), syntheticSilentWAV(), false, true),
            (syntheticSilentWAV(), syntheticSilentWAV(), true, true),
            (Data(), Data("bad system".utf8), false, false),
        ]

        for (microphone, system, expectedMicrophone, expectedSystem) in cases {
            let root = temporaryLibraryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LibraryStore(rootURL: root)
            let capture = try await recoveryCapture(
                in: store,
                root: root,
                kind: .meeting,
                microphoneData: microphone,
                systemData: system
            )

            let assessments = try await store.assessRecoveryTracks(captureID: capture.id)

            XCTAssertEqual(assessments.first(where: { $0.role == .microphone })?.isValid, expectedMicrophone)
            XCTAssertEqual(assessments.first(where: { $0.role == .system })?.isValid, expectedSystem)
        }
    }

    func testSelectedRecoveryCommitRetainsOnlyExplicitValidRole() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let capture = try await recoveryCapture(
            in: store,
            root: root,
            kind: .meeting,
            microphoneData: syntheticSilentWAV(),
            systemData: Data("not audio".utf8)
        )
        let originals = try await resolvedURLs(capture.tracks, in: store)
        let proposed = WorkspaceRecord(kind: .meeting, title: "Recovered", text: "Transcript")

        let saved = try await store.commitRecoveredRecord(
            proposed,
            recoveryID: capture.id,
            trackSelection: .roles([.microphone]),
            keepAudio: true
        )

        XCTAssertEqual(saved.audioTracks.map(\.role), [.microphone])
        XCTAssertNotEqual(saved.audioTracks.first?.relativePath, capture.tracks.first(where: { $0.role == .microphone })?.relativePath)
        let savedURLs = try await resolvedURLs(saved.audioTracks, in: store)
        XCTAssertTrue(savedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let remainingRecoveries = try await store.recoverableCaptures()
        XCTAssertFalse(remainingRecoveries.contains(where: { $0.id == capture.id }))
    }

    func testRecoveryCommitRejectsEmptyMissingAndInvalidSelectionsWithoutChangingCanonicalState() async throws {
        for selection in [
            RecoveryTrackSelection.roles([]),
            .roles([.mixed]),
            .roles([.system]),
        ] {
            let root = temporaryLibraryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LibraryStore(rootURL: root)
            let capture = try await recoveryCapture(
                in: store,
                root: root,
                kind: .meeting,
                microphoneData: syntheticSilentWAV(),
                systemData: Data("not audio".utf8)
            )
            let originalURLs = try await resolvedURLs(capture.tracks, in: store)
            let existing = WorkspaceRecord(kind: .meeting, title: "Existing", text: "Canonical")
            try await store.upsert(existing)
            let persistedExisting = try await store.record(id: existing.id)

            await XCTAssertThrowsErrorAsync {
                _ = try await store.commitRecoveredRecord(
                    WorkspaceRecord(id: existing.id, kind: .meeting, title: "Replacement", text: "Lost"),
                    recoveryID: capture.id,
                    trackSelection: selection,
                    keepAudio: true
                )
            }

            let unchangedRecord = try await store.record(id: existing.id)
            XCTAssertEqual(unchangedRecord, persistedExisting)
            XCTAssertTrue(originalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    func testMetadataFailureRollsBackNewCopiesAndRetryDoesNotDuplicateCanonicalAudio() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seedingStore = LibraryStore(rootURL: root)
        let recordID = UUID()
        let oldDirectory = root.appendingPathComponent("Audio/Records/\(recordID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldAudio = oldDirectory.appendingPathComponent("existing.wav")
        try syntheticSilentWAV().write(to: oldAudio)
        let oldTrack = WorkspaceAudioTrack(role: .microphone, relativePath: "Audio/Records/\(recordID.uuidString)/existing.wav")
        let existing = WorkspaceRecord(id: recordID, kind: .meeting, title: "Existing", text: "Canonical", audioTracks: [oldTrack])
        try await seedingStore.upsert(existing)
        let persistedExisting = try await seedingStore.record(id: recordID)
        let capture = try await recoveryCapture(
            in: seedingStore,
            root: root,
            kind: .meeting,
            microphoneData: syntheticSilentWAV(),
            systemData: syntheticSilentWAV()
        )
        let originals = try await resolvedURLs(capture.tracks, in: seedingStore)
        let failingStore = LibraryStore(rootURL: root, failNextWritesAt: [.recordMetadataBeforeReplacement])
        let proposed = WorkspaceRecord(id: recordID, kind: .meeting, title: "Recovered", text: "New")

        await XCTAssertThrowsErrorAsync {
            _ = try await failingStore.commitRecoveredRecord(
                proposed,
                recoveryID: capture.id,
                trackSelection: .allValid,
                keepAudio: true
            )
        }

        let unchangedRecord = try await failingStore.record(id: recordID)
        XCTAssertEqual(unchangedRecord, persistedExisting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldAudio.path))
        XCTAssertTrue(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil).map(\.lastPathComponent), ["existing.wav"])

        let saved = try await failingStore.commitRecoveredRecord(
            proposed,
            recoveryID: capture.id,
            trackSelection: .allValid,
            keepAudio: true
        )

        XCTAssertEqual(Set(saved.audioTracks.map(\.role)), Set([.microphone, .system]))
        let ownedFiles = try FileManager.default.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(ownedFiles.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio.path))
        XCTAssertTrue(originals.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let canonicalRecords = try await failingStore.loadRecords()
        XCTAssertEqual(canonicalRecords.filter { $0.id == recordID }.count, 1)
    }

    func testDiscardRemovesRecoveryArtifactsWithoutCreatingRecord() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let capture = try await recoveryCapture(
            in: store,
            root: root,
            kind: .meeting,
            microphoneData: syntheticSilentWAV(),
            systemData: syntheticSilentWAV()
        )

        try await store.discardRecoveryCapture(id: capture.id)

        let records = try await store.loadRecords()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio/Recovery/\(capture.id.uuidString)").path))
    }

    func testCorruptCanonicalSourcesArePreservedPrivatelyAndReturnSafeFallbacks() async throws {
        let cases: [(String, @Sendable (LibraryStore) async throws -> URL?)] = [
            ("records.json", { store in
                let result = try await store.loadRecordsRecoveringCorruption()
                XCTAssertEqual(result.value, [])
                return result.preservedCorruptURL
            }),
            ("settings.json", { store in
                let result = try await store.loadSettingsRecoveringCorruption()
                XCTAssertEqual(result.value, EveeSettings())
                return result.preservedCorruptURL
            }),
            ("meeting-draft.json", { store in
                let result = try await store.loadMeetingDraftRecoveringCorruption()
                XCTAssertNil(result.value)
                return result.preservedCorruptURL
            }),
        ]

        for (filename, load) in cases {
            let root = temporaryLibraryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LibraryStore(rootURL: root)
            try await store.prepare()
            let source = root.appendingPathComponent(filename)
            let unreadable = Data("{".utf8)
            try unreadable.write(to: source, options: .atomic)

            let preservedURL = try await load(store)
            let preserved = try XCTUnwrap(preservedURL)

            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: preserved), unreadable)
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: preserved.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            XCTAssertEqual(preserved.deletingLastPathComponent().lastPathComponent, "Corrupt")
        }
    }

    func testCorruptPreservationFailureLeavesCanonicalSourceUntouchedAndThrows() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        try await store.prepare()
        let source = root.appendingPathComponent("records.json")
        let unreadable = Data("{".utf8)
        try unreadable.write(to: source)
        try Data("blocks directory".utf8).write(to: root.appendingPathComponent("Corrupt"))

        await XCTAssertThrowsErrorAsync {
            _ = try await store.loadRecordsRecoveringCorruption()
        }

        XCTAssertEqual(try Data(contentsOf: source), unreadable)
    }

    func testFutureSchemaRemainsHardErrorAndIsNotMovedAsCorruption() async throws {
        let cases: [(String, (LibraryStore) async throws -> Void)] = [
            ("records.json", { store in _ = try await store.loadRecordsRecoveringCorruption() }),
            ("settings.json", { store in _ = try await store.loadSettingsRecoveringCorruption() }),
        ]

        for (filename, load) in cases {
            let root = temporaryLibraryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LibraryStore(rootURL: root)
            try await store.prepare()
            let source = root.appendingPathComponent(filename)
            let future = Data("{\"schemaVersion\":999,\"payload\":{\"changed\":true},\"records\":\"not-an-array\",\"settings\":false}".utf8)
            try future.write(to: source)

            await XCTAssertThrowsErrorAsync {
                try await load(store)
            } verify: { error in
                guard case LibraryStoreError.unsupportedSchema(found: 999, supported: LibraryStore.currentSchemaVersion) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }

            XCTAssertEqual(try Data(contentsOf: source), future)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Corrupt").path))
        }
    }

    func testRecordsQuarantineSurvivesRelaunchWritesAndRecoveryUntilExplicitReset() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = LibraryStore(rootURL: root)
        try await firstStore.prepare()
        let orphanID = UUID()
        let orphanDirectory = root.appendingPathComponent("Audio/Records/\(orphanID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        let orphanAudio = orphanDirectory.appendingPathComponent("unknown.wav")
        try syntheticSilentWAV().write(to: orphanAudio)
        try Data("{".utf8).write(to: root.appendingPathComponent("records.json"))

        let firstLoad = try await firstStore.loadRecordsRecoveringCorruption()
        let preserved = try XCTUnwrap(firstLoad.preservedCorruptURL)
        let loadedMarker = try await firstStore.recordsQuarantine()
        let marker = try XCTUnwrap(loadedMarker)
        XCTAssertEqual(marker.preservedCorruptRelativePath, "Corrupt/\(preserved.lastPathComponent)")
        XCTAssertFalse(marker.reason.isEmpty)
        let markerPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("records-quarantine.json").path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(markerPermissions.intValue & 0o777, 0o600)

        let secondStore = LibraryStore(rootURL: root)
        let secondLoad = try await secondStore.loadRecordsRecoveringCorruption()
        XCTAssertEqual(secondLoad.preservedCorruptURL, preserved)
        try await secondStore.save([WorkspaceRecord(kind: .memo, title: "Later", text: "Saved")])
        try await secondStore.reconcileAudioStorage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanAudio.path))

        let input = root.appendingPathComponent("input.wav")
        try syntheticSilentWAV().write(to: input)
        let recovery = try await secondStore.beginRecoveryCapture(kind: .memo)
        _ = try await secondStore.addRecoveryTrack(captureID: recovery.id, kind: .memo, role: .microphone, sourceURL: input)
        _ = try await secondStore.commitRecoveredRecord(
            WorkspaceRecord(kind: .memo, title: "Recovered", text: "Retained"),
            recoveryID: recovery.id,
            trackSelection: .allValid,
            keepAudio: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanAudio.path))

        try await secondStore.resetRecordsQuarantine()
        let resetMarker = try await secondStore.recordsQuarantine()
        XCTAssertNil(resetMarker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanAudio.path), "reset action must not delete audio")
    }

    func testPostReplacementFailureKeepsInstalledRecordAndReferencedAudio() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seedStore = LibraryStore(rootURL: root)
        let capture = try await recoveryCapture(
            in: seedStore,
            root: root,
            kind: .meeting,
            microphoneData: syntheticSilentWAV(),
            systemData: syntheticSilentWAV()
        )
        let recoveryOriginals = try await resolvedURLs(capture.tracks, in: seedStore)
        let store = LibraryStore(rootURL: root, failNextWritesAt: [.recordMetadataAfterReplacement])
        let proposed = WorkspaceRecord(kind: .meeting, title: "Installed", text: "Durability uncertain")

        await XCTAssertThrowsErrorAsync {
            _ = try await store.commitRecoveredRecord(
                proposed,
                recoveryID: capture.id,
                trackSelection: .allValid,
                keepAudio: true
            )
        } verify: { error in
            guard case LibraryStoreError.metadataInstalledButDurabilityUncertain = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let installedRecord = try await store.record(id: proposed.id)
        let installed = try XCTUnwrap(installedRecord)
        XCTAssertEqual(installed.title, proposed.title)
        XCTAssertEqual(installed.audioTracks.count, 2)
        for url in try await resolvedURLs(installed.audioTracks, in: store) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertTrue(recoveryOriginals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testRetainedAudioDirectorySyncFailureRollsBackBeforeMetadataReplacement() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seedStore = LibraryStore(rootURL: root)
        let capture = try await recoveryCapture(
            in: seedStore,
            root: root,
            kind: .memo,
            microphoneData: syntheticSilentWAV(),
            systemData: nil
        )
        let originals = try await resolvedURLs(capture.tracks, in: seedStore)
        let store = LibraryStore(rootURL: root, failNextWritesAt: [.recordAudioDirectorySync])
        let proposed = WorkspaceRecord(kind: .memo, title: "Not installed", text: "Rollback")

        await XCTAssertThrowsErrorAsync {
            _ = try await store.commitRecoveredRecord(proposed, recoveryID: capture.id, keepAudio: true)
        }

        let persisted = try await store.record(id: proposed.id)
        XCTAssertNil(persisted)
        XCTAssertTrue(originals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let ownedDirectory = root.appendingPathComponent("Audio/Records/\(proposed.id.uuidString)")
        let files = (try? FileManager.default.contentsOfDirectory(at: ownedDirectory, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

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

private func temporaryLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("evee-workspace-lifecycle-\(UUID().uuidString)", isDirectory: true)
}

private func recoveryCapture(
    in store: LibraryStore,
    root: URL,
    kind: WorkspaceRecordKind,
    microphoneData: Data,
    systemData: Data
) async throws -> CaptureRecoveryManifest {
    let input = root.appendingPathComponent("Inputs", isDirectory: true)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let microphone = input.appendingPathComponent("microphone-\(UUID().uuidString).wav")
    let system = input.appendingPathComponent("system-\(UUID().uuidString).wav")
    try microphoneData.write(to: microphone)
    try systemData.write(to: system)
    let capture = try await store.beginRecoveryCapture(kind: kind)
    _ = try await store.addRecoveryTrack(captureID: capture.id, kind: kind, role: .microphone, sourceURL: microphone)
    return try await store.addRecoveryTrack(captureID: capture.id, kind: kind, role: .system, sourceURL: system)
}

private func resolvedURLs(_ tracks: [WorkspaceAudioTrack], in store: LibraryStore) async throws -> [URL] {
    var urls: [URL] = []
    for track in tracks {
        urls.append(try await store.safeURL(forRelativePath: track.relativePath))
    }
    return urls
}

private func syntheticSilentWAV() -> Data {
    let sampleRate: UInt32 = 8_000
    let sampleCount: UInt32 = 800
    let dataSize = sampleCount * 2
    var data = Data()
    func append(_ text: String) { data.append(contentsOf: text.utf8) }
    func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    append("RIFF"); append(UInt32(36) + dataSize); append("WAVE")
    append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
    append("data"); append(dataSize); data.append(Data(count: Int(dataSize)))
    return data
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}
