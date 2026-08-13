import EveeCore
import XCTest

@MainActor
final class TerminationCheckpointTests: XCTestCase {
    func testMeetingAcceptsEitherValidTrackButMemoAndDictationRequireMicrophone() throws {
        XCTAssertNoThrow(try CaptureCheckpointTrackPolicy.validate(kind: .meeting, validRoles: [.system]))
        XCTAssertNoThrow(try CaptureCheckpointTrackPolicy.validate(kind: .meeting, validRoles: [.microphone]))
        XCTAssertThrowsError(try CaptureCheckpointTrackPolicy.validate(kind: .memo, validRoles: [.system]))
        XCTAssertThrowsError(try CaptureCheckpointTrackPolicy.validate(kind: .dictation, validRoles: [.system]))
    }

    func testFailedTerminationCheckpointCanReopenAdmissionForRecovery() {
        var gate = TerminationWorkGate()
        _ = gate.prepareCheckpoint()
        XCTAssertFalse(gate.beginWork())

        gate.resumeAfterCheckpointFailure()

        XCTAssertTrue(gate.beginWork())
    }

    func testConcurrentCheckpointsJoinOneDurabilityOperation() async throws {
        let checkpointer = DelayedCaptureCheckpointer()
        let coordinator = TerminationCheckpointCoordinator(checkpointer: checkpointer)

        async let first: Void = coordinator.checkpoint()
        async let second: Void = coordinator.checkpoint()
        _ = try await (first, second)
        XCTAssertEqual(checkpointer.callCount, 1)
    }

    func testFailureIsReplayedUntilExplicitRetryStartsOneNewOperation() async throws {
        let checkpointer = SequencedCaptureCheckpointer(results: [
            .failure(SyntheticCheckpointError.persistenceFailed),
            .success(()),
        ])
        let coordinator = TerminationCheckpointCoordinator(checkpointer: checkpointer)

        await XCTAssertThrowsErrorAsync { try await coordinator.checkpoint() }
        await XCTAssertThrowsErrorAsync { try await coordinator.checkpoint() }
        XCTAssertEqual(checkpointer.callCount, 1)

        try await coordinator.retry()
        XCTAssertEqual(checkpointer.callCount, 2)
    }

    func testBeginningExistingRecoveryCaptureDoesNotEraseCheckpointedTracks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-termination-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let capture = try await store.beginRecoveryCapture(kind: .meeting)
        let microphone = root.appendingPathComponent("synthetic-microphone.caf")
        try Data("synthetic audio".utf8).write(to: microphone)
        _ = try await store.addRecoveryTrack(
            captureID: capture.id,
            kind: .meeting,
            role: .microphone,
            sourceURL: microphone
        )

        let repeated = try await store.beginRecoveryCapture(kind: .meeting, id: capture.id)

        XCTAssertEqual(repeated.tracks.map(\.role), [.microphone])
        XCTAssertEqual(repeated.status, .captured)
    }

    func testTerminationJoinsSuspendedCommitExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-suspended-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let recovery = try await store.beginRecoveryCapture(kind: .memo)
        let source = root.appendingPathComponent("synthetic.caf")
        try terminationSilentWAV().write(to: source)
        _ = try await store.addRecoveryTrack(
            captureID: recovery.id,
            kind: .memo,
            role: .microphone,
            sourceURL: source
        )
        let gate = SyntheticOperationGate<Void>()
        let operation = TerminationOwnedOperation<WorkspaceRecord>()
        let record = WorkspaceRecord(kind: .memo, title: "Synthetic", text: "Saved")

        _ = await operation.begin {
            try await gate.wait()
            return try await store.commitRecoveredRecord(record, recoveryID: recovery.id, keepAudio: true)
        }
        let joined = Task { try await operation.join() }
        await gate.release(())

        XCTAssertEqual(try await joined.value?.id, record.id)
        XCTAssertNil(try await operation.join())
        XCTAssertEqual(try await store.loadRecords().map(\.id), [record.id])
        XCTAssertTrue(try await store.recoverableCaptures().isEmpty)
    }

    func testTerminationWaitsForRecorderStartThenStopsOnce() async throws {
        let gate = SyntheticOperationGate<URL>()
        let operation = TerminationOwnedOperation<URL>()
        let output = URL(fileURLWithPath: "/tmp/synthetic-recorder.caf")

        _ = await operation.begin { try await gate.wait() }
        let stopped = Task { () -> URL? in
            guard let started = try await operation.join() else { return nil }
            return started
        }
        await gate.release(output)

        XCTAssertEqual(try await stopped.value, output)
        XCTAssertFalse(await operation.isActive)
    }

    func testTerminationCancelsSuspendedDeliveryBeforeAutoSend() async throws {
        let gate = SyntheticOperationGate<Void>()
        let operation = TerminationOwnedOperation<Void>()
        let sent = SyntheticSendCounter()
        _ = await operation.begin {
            try await gate.wait()
            try Task.checkCancellation()
            await sent.increment()
        }

        await gate.waitUntilStarted()
        await operation.cancel()
        let cancelled = Task { try? await operation.join() }
        await gate.release(())
        _ = await cancelled.value

        XCTAssertEqual(await sent.value, 0)
    }

    func testTemporaryClipboardRestoresSnapshotWhenCancelledDuringDelay() async {
        let clipboard = SyntheticClipboard()
        let gate = SyntheticOperationGate<Void>()
        let task = Task { @MainActor in
            try await TemporaryClipboardTransaction.withRestoration(
                currentRevision: { clipboard.revision },
                restore: { clipboard.restoreSnapshot() }
            ) { markOwned in
                clipboard.writeTemporaryValue()
                markOwned(clipboard.revision)
                try await gate.wait()
                try Task.checkCancellation()
            }
        }
        await gate.waitUntilStarted()

        task.cancel()
        await gate.release(())
        _ = try? await task.value

        XCTAssertEqual(clipboard.restoreCount, 1)
        XCTAssertEqual(clipboard.value, "original")
    }

    func testMeetingCommitWinnerClearsOnlyMatchingDraftAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-meeting-commit-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let recovery = try await store.beginRecoveryCapture(kind: .meeting)
        try await store.saveMeetingDraft(MeetingDraft(captureID: recovery.id, title: "Synthetic", notes: "Retain until commit"))
        let record = WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Saved")

        let committed = try await store.commitRecoveredRecord(record, recoveryID: recovery.id, keepAudio: false)
        XCTAssertTrue(try await store.clearMeetingDraft(forCommitted: committed, recoveryID: recovery.id))

        let relaunched = LibraryStore(rootURL: root)
        XCTAssertNil(try await relaunched.loadMeetingDraft())

        let unrelatedID = UUID()
        try await relaunched.saveMeetingDraft(MeetingDraft(captureID: unrelatedID, title: "Other", notes: "Keep"))
        XCTAssertFalse(try await relaunched.clearMeetingDraft(matching: recovery.id))
        XCTAssertEqual(try await LibraryStore(rootURL: root).loadMeetingDraft()?.captureID, unrelatedID)
    }

    func testRecoveryAdmissionIsRejectedDuringCheckpointAndAdvancesGenerationAfterward() {
        var suspendedGate = TerminationWorkGate()
        let checkpointGeneration = suspendedGate.prepareCheckpoint()
        XCTAssertFalse(suspendedGate.beginWork())
        XCTAssertEqual(suspendedGate.generation, checkpointGeneration)

        var availableGate = TerminationWorkGate()
        let priorGeneration = availableGate.generation
        XCTAssertTrue(availableGate.beginWork())
        XCTAssertGreaterThan(availableGate.generation, priorGeneration)
        let recoveryID = UUID()
        XCTAssertEqual(
            CaptureShutdownPlan.make(for: .finishing(recoveryID: recoveryID)),
            .awaitDurableCommitOrCheckpoint(recoveryID: recoveryID)
        )
    }
}

private func terminationSilentWAV() -> Data {
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

@MainActor
private final class SyntheticClipboard {
    private(set) var value = "original"
    private(set) var revision = 0
    private(set) var restoreCount = 0
    func writeTemporaryValue() { value = "temporary"; revision += 1 }
    func restoreSnapshot() { value = "original"; revision += 1; restoreCount += 1 }
}

private actor SyntheticOperationGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private actor SyntheticSendCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private enum SyntheticCheckpointError: Error {
    case persistenceFailed
}

@MainActor
private final class DelayedCaptureCheckpointer: CaptureCheckpointing {
    private(set) var callCount = 0

    func checkpointForTermination() async throws {
        callCount += 1
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private final class SequencedCaptureCheckpointer: CaptureCheckpointing {
    private var results: [Result<Void, Error>]
    private(set) var callCount = 0

    init(results: [Result<Void, Error>]) {
        self.results = results
    }

    func checkpointForTermination() async throws {
        callCount += 1
        try results.removeFirst().get()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
