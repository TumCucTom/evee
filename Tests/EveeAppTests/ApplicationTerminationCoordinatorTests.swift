import EveeCore
import XCTest
@testable import EveeApp

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    func testQuitCheckpointsValidSystemTrackWhenMicrophoneIsInvalid() async throws {
        let harness = try await CaptureCheckpointHarness(kind: .meeting, microphoneValid: false, systemValid: true)
        defer { harness.cleanUp() }

        try await harness.store.checkpointForTermination()

        let captures = try await harness.library.recoverableCaptures()
        XCTAssertEqual(captures.first?.tracks.map(\.role), [.system])
        XCTAssertTrue(harness.store.statusMessage?.localizedCaseInsensitiveContains("microphone") == true)
    }

    func testQuitCheckpointsValidMicrophoneTrackWhenSystemIsInvalid() async throws {
        let harness = try await CaptureCheckpointHarness(kind: .meeting, microphoneValid: true, systemValid: false)
        defer { harness.cleanUp() }

        try await harness.store.checkpointForTermination()

        let captures = try await harness.library.recoverableCaptures()
        XCTAssertEqual(captures.first?.tracks.map(\.role), [.microphone])
        XCTAssertTrue(harness.store.statusMessage?.localizedCaseInsensitiveContains("system") == true)
    }

    func testQuitFailsMemoWhenMicrophoneTrackIsInvalidAndRecoveryRemainsUsable() async throws {
        let harness = try await CaptureCheckpointHarness(kind: .memo, microphoneValid: false, systemValid: false)
        defer { harness.cleanUp() }

        await XCTAssertThrowsErrorAsync { try await harness.store.checkpointForTermination() }

        XCTAssertFalse(harness.store.isTerminationCheckpointActive)
        XCTAssertTrue(harness.store.captureState.isCheckpointedForTests)
        let recoverableCaptures = try await harness.library.recoverableCaptures()
        XCTAssertFalse(recoverableCaptures.isEmpty)
    }

    func testDeadlineFailureReplacesLivePresentationWithProtectedRecovery() {
        let store = AppStore(modelDownloadDefaults: nil)
        store.captureState = .recording(startedAt: .now, level: 0.5)

        store.reportApplicationTerminationCheckpointFailure(ApplicationTerminationDeadlineError())

        guard case .checkpointed(let message) = store.captureState else {
            return XCTFail("Deadline left live capture controls visible")
        }
        XCTAssertTrue(message.contains("protected") || message.contains("recovery"))
    }

    func testRecoveryIsRejectedDuringCheckpointAndNewRecoveryAdvancesGeneration() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-recovery-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        let capture = try! await library.beginRecoveryCapture(kind: .memo)
        let source = root.appendingPathComponent("synthetic.wav")
        try! syntheticSilentWAV().write(to: source)
        let manifest = try! await library.addRecoveryTrack(
            captureID: capture.id,
            kind: .memo,
            role: .microphone,
            sourceURL: source
        )
        let gatedStore = AppStore(modelDownloadDefaults: nil, library: library)
        let checkpointGeneration = gatedStore.prepareForTerminationCheckpoint()

        await gatedStore.recover(manifest)

        XCTAssertEqual(gatedStore.terminationWorkGeneration, checkpointGeneration)
        XCTAssertTrue(gatedStore.isTerminationCheckpointActive)
        XCTAssertNotEqual(gatedStore.captureState, .transcribing)

        let recoveryStore = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            recoveryTranscriberFactory: { _ in throw SyntheticApplicationTerminationError.persistenceFailed }
        )
        let initialGeneration = recoveryStore.terminationWorkGeneration
        await recoveryStore.recover(manifest)
        XCTAssertGreaterThan(recoveryStore.terminationWorkGeneration, initialGeneration)
    }

    func testAdmittedRecoveryPublishesActiveShutdownPlanBeforeTranscriptionSuspends() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-recovery-shutdown-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        let capture = try! await library.beginRecoveryCapture(kind: .memo)
        let source = root.appendingPathComponent("synthetic.caf")
        try! syntheticSilentWAV().write(to: source)
        let manifest = try! await library.addRecoveryTrack(
            captureID: capture.id,
            kind: .memo,
            role: .microphone,
            sourceURL: source
        )
        let transcriber = SuspendedRecoveryTranscriber()
        let store = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            recoveryTranscriberFactory: { _ in transcriber }
        )

        let recovery = Task { @MainActor in await store.recover(manifest) }
        await transcriber.waitUntilCalled()

        XCTAssertEqual(store.captureState, .transcribing)
        XCTAssertEqual(
            store.captureShutdownPlan,
            .awaitDurableCommitOrCheckpoint(recoveryID: manifest.id)
        )
        let checkpoint = Task { @MainActor in try await store.checkpointForTermination() }
        await waitUntil { store.isTerminationCheckpointActive }
        transcriber.fail()
        try! await checkpoint.value
        XCTAssertEqual(store.captureState, .checkpointed("Capture checkpointed for recovery. Quit again to close Evee, or open Recovery to review it."))
        let recoverableCaptures = try! await library.recoverableCaptures()
        XCTAssertTrue(recoverableCaptures.contains(where: { $0.id == manifest.id }))
        await recovery.value
        XCTAssertTrue(store.isTerminationCheckpointActive)
    }

    func testSystemOnlyMeetingRecoveryRetainsAudioAndSystemChannelWhenRetentionIsOff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-system-only-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        let capture = try await library.beginRecoveryCapture(kind: .meeting)
        let source = root.appendingPathComponent("system.wav")
        try syntheticSilentWAV().write(to: source)
        let manifest = try await library.addRecoveryTrack(
            captureID: capture.id,
            kind: .meeting,
            role: .system,
            sourceURL: source
        )
        let store = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            recoveryTranscriberFactory: { _ in ImmediateRecoveryTranscriber(text: "A system-only recovery") }
        )
        XCTAssertFalse(store.settings.retainMeetingAudio)

        await store.recover(manifest, trackSelection: .roles([.system]))

        let recoveredRecords = try await library.loadRecords()
        let record = try XCTUnwrap(recoveredRecords.first)
        XCTAssertEqual(record.audioTracks.map(\.role), [.system])
        XCTAssertFalse(record.segments.isEmpty)
        XCTAssertTrue(record.segments.allSatisfy { $0.channel == .system })
        XCTAssertTrue(record.tags.contains("Recovered from system audio"))
        for track in record.audioTracks {
            let retainedURL = try await library.safeURL(forRelativePath: track.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
        }
        let remainingRecoveries = try await library.recoverableCaptures()
        XCTAssertFalse(remainingRecoveries.contains(where: { $0.id == capture.id }))
    }

    func testSystemOnlyMemoRecoveryIsRejectedWithoutDiscardingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-invalid-system-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        let capture = try await library.beginRecoveryCapture(kind: .memo)
        let source = root.appendingPathComponent("system.wav")
        try syntheticSilentWAV().write(to: source)
        let manifest = try await library.addRecoveryTrack(
            captureID: capture.id,
            kind: .memo,
            role: .system,
            sourceURL: source
        )
        let store = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            recoveryTranscriberFactory: { _ in ImmediateRecoveryTranscriber(text: "Must not run") }
        )

        await store.recover(manifest, trackSelection: .roles([.system]))

        let records = try await library.loadRecords()
        let recoveries = try await library.recoverableCaptures()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(recoveries.contains(where: { $0.id == capture.id }))
        XCTAssertTrue(store.statusMessage?.localizedCaseInsensitiveContains("meeting") == true)
    }

    func testDeadlineCancelsTerminationAndLateCheckpointCannotReplyAgain() async {
        let checkpoint = DelayedCaptureCheckpointer()
        let replies = TerminationReplySink()
        let failures = FailureSink()
        let coordinator = ApplicationTerminationCoordinator(deadline: .milliseconds(20))
        let recoveryID = UUID()

        let decision = coordinator.requestTermination(
            plan: .stopWritersAndCheckpoint(kind: .meeting, recoveryID: recoveryID),
            checkpoint: checkpoint,
            reply: replies.reply,
            reportFailure: failures.report
        )

        XCTAssertEqual(decision, .terminateLater)
        await waitUntil { replies.values == [false] }
        checkpoint.succeed()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(replies.values, [false])
        XCTAssertEqual(failures.count, 1)
    }

    func testFailureCancelsTerminationAndNeverReturnsTerminateNow() async {
        let checkpoint = FailingCaptureCheckpointer()
        let replies = TerminationReplySink()
        let coordinator = ApplicationTerminationCoordinator(deadline: .seconds(1))

        let decision = coordinator.requestTermination(
            plan: .cancelStartAndCheckpoint,
            checkpoint: checkpoint,
            reply: replies.reply,
            reportFailure: { _ in }
        )

        XCTAssertEqual(decision, .terminateLater)
        await waitUntil { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [false])
    }

    func testImmediatePlanDoesNotStartCheckpoint() {
        let checkpoint = FailingCaptureCheckpointer()
        let replies = TerminationReplySink()
        let coordinator = ApplicationTerminationCoordinator(deadline: .seconds(1))

        let decision = coordinator.requestTermination(
            plan: .terminateImmediately,
            checkpoint: checkpoint,
            reply: replies.reply,
            reportFailure: { _ in }
        )

        XCTAssertEqual(decision, .terminateNow)
        XCTAssertEqual(checkpoint.callCount, 0)
        XCTAssertTrue(replies.values.isEmpty)
    }

    func testUnsafePlanCancelsWithoutStartingCheckpoint() {
        let checkpoint = FailingCaptureCheckpointer()
        let replies = TerminationReplySink()
        let failures = FailureSink()
        let coordinator = ApplicationTerminationCoordinator(deadline: .seconds(1))

        let decision = coordinator.requestTermination(
            plan: .cancelTermination(message: "Synthetic unsafe capture"),
            checkpoint: checkpoint,
            reply: replies.reply,
            reportFailure: failures.report
        )

        XCTAssertEqual(decision, .terminateCancel)
        XCTAssertEqual(checkpoint.callCount, 0)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(replies.values.isEmpty)
    }

    func testDeadlineCompletionCannotBeReusedAfterNewWorkStarts() async {
        let checkpoint = GenerationCaptureCheckpointer()
        let firstReplies = TerminationReplySink()
        let coordinator = ApplicationTerminationCoordinator(deadline: .milliseconds(100))

        XCTAssertEqual(coordinator.requestTermination(
            plan: .invalidateDeliveryAndAwaitCommit,
            checkpoint: checkpoint,
            reply: firstReplies.reply,
            reportFailure: { _ in }
        ), .terminateLater)
        let firstCheckpointStarted = await waitUntil { checkpoint.callCount == 1 }
        XCTAssertTrue(firstCheckpointStarted)
        guard checkpoint.callCount == 1 else { return }
        let firstRequestExpired = await waitUntil { firstReplies.values == [false] }
        XCTAssertTrue(firstRequestExpired)
        guard firstReplies.values == [false] else { return }

        checkpoint.beginNewWork()
        let secondReplies = TerminationReplySink()
        XCTAssertEqual(coordinator.requestTermination(
            plan: .invalidateDeliveryAndAwaitCommit,
            checkpoint: checkpoint,
            reply: secondReplies.reply,
            reportFailure: { _ in }
        ), .terminateLater)
        let overlapped = await waitUntil(timeout: .milliseconds(10)) { checkpoint.callCount > 1 }
        XCTAssertFalse(overlapped)
        XCTAssertEqual(checkpoint.maximumActiveCallCount, 1)
        checkpoint.succeed()
        let freshCheckpointStarted = await waitUntil { checkpoint.callCount == 2 }
        XCTAssertTrue(freshCheckpointStarted)
        guard checkpoint.callCount == 2 else { return }
        XCTAssertEqual(checkpoint.maximumActiveCallCount, 1)
        checkpoint.succeed()
        let freshRequestSucceeded = await waitUntil { secondReplies.values == [true] }
        XCTAssertTrue(freshRequestSucceeded)
    }

    func testWorkStartingWhileCheckpointSuspendedCancelsTermination() async {
        let checkpoint = GenerationCaptureCheckpointer()
        let replies = TerminationReplySink()
        let failures = FailureSink()
        let coordinator = ApplicationTerminationCoordinator(deadline: .seconds(1))

        XCTAssertEqual(coordinator.requestTermination(
            plan: .invalidateDeliveryAndAwaitCommit,
            checkpoint: checkpoint,
            reply: replies.reply,
            reportFailure: failures.report
        ), .terminateLater)
        let checkpointStarted = await waitUntil { checkpoint.callCount == 1 }
        XCTAssertTrue(checkpointStarted)
        guard checkpoint.callCount == 1 else { return }
        checkpoint.beginNewWork()
        checkpoint.succeed()
        let requestFinished = await waitUntil { !replies.values.isEmpty }
        XCTAssertTrue(requestFinished)

        XCTAssertEqual(replies.values, [false])
        XCTAssertEqual(failures.count, 1)
    }

    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class CaptureCheckpointHarness {
    let root: URL
    let library: LibraryStore
    let store: AppStore

    init(kind: WorkspaceRecordKind, microphoneValid: Bool, systemValid: Bool) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-independent-checkpoint-\(UUID().uuidString)")
        library = LibraryStore(rootURL: root)
        let microphoneURL = root.appendingPathComponent("microphone.wav")
        let systemURL = root.appendingPathComponent("system.wav")
        store = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            microphoneStarter: { url, _, _ in
                let data = microphoneValid ? syntheticSilentWAV() : Data()
                try data.write(to: url)
                try data.write(to: microphoneURL)
            },
            microphoneStopper: { microphoneURL },
            microphoneRecordingProbe: { true },
            systemAudioStarter: { url in
                try (systemValid ? syntheticSilentWAV() : Data()).write(to: url)
            },
            systemAudioStopper: {}
        )
        if kind == .meeting {
            store.settings.meetingCaptureEnabled = true
            store.settings.liveMeetingTranscriptionEnabled = false
            await store.beginMeeting()
        } else {
            await store.beginMemo()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while store.captureShutdownPlan == .cancelStartAndCheckpoint, ContinuousClock.now < deadline {
            await Task.yield()
        }
        _ = systemURL
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
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

private extension CaptureState {
    var isCheckpointedForTests: Bool {
        if case .checkpointed = self { return true }
        return false
    }
}

@MainActor
private final class DelayedCaptureCheckpointer: CaptureCheckpointing {
    private var continuation: CheckedContinuation<Void, Error>?

    func checkpointForTermination() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FailingCaptureCheckpointer: CaptureCheckpointing {
    private(set) var callCount = 0

    func checkpointForTermination() async throws {
        callCount += 1
        throw SyntheticApplicationTerminationError.persistenceFailed
    }
}

@MainActor
private final class GenerationCaptureCheckpointer: CaptureCheckpointing {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var callCount = 0
    private(set) var activeCallCount = 0
    private(set) var maximumActiveCallCount = 0
    private(set) var terminationWorkGeneration: UInt64 = 0

    func prepareForTerminationCheckpoint() -> UInt64 { terminationWorkGeneration }

    func checkpointForTermination() async throws {
        callCount += 1
        activeCallCount += 1
        maximumActiveCallCount = max(maximumActiveCallCount, activeCallCount)
        defer { activeCallCount -= 1 }
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func beginNewWork() { terminationWorkGeneration &+= 1 }

    func succeed() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private enum SyntheticApplicationTerminationError: Error {
    case persistenceFailed
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

private final class SuspendedRecoveryTranscriber: LocalTranscriber, @unchecked Sendable {
    let model = SpeechModel.parakeet
    var isDownloaded: Bool { true }
    private var continuation: CheckedContinuation<LocalTranscript, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
    func load() async throws {}
    func unload() {}
    func transcribe(fileURL: URL, languageCode: String?) async throws -> String { "" }
    func transcribeDetailed(fileURL: URL, languageCode: String?) async throws -> LocalTranscript {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.continuation = continuation
                self.waiter?.resume()
                self.waiter = nil
            }
        }
    }
    @MainActor func waitUntilCalled() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    @MainActor func fail() {
        continuation?.resume(throwing: SyntheticApplicationTerminationError.persistenceFailed)
        continuation = nil
    }
}

private final class ImmediateRecoveryTranscriber: LocalTranscriber, @unchecked Sendable {
    let model = SpeechModel.parakeet
    var isDownloaded: Bool { true }
    private let text: String
    init(text: String) { self.text = text }
    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
    func load() async throws {}
    func unload() {}
    func transcribe(fileURL: URL, languageCode: String?) async throws -> String { text }
    func transcribeDetailed(fileURL: URL, languageCode: String?) async throws -> LocalTranscript {
        LocalTranscript(
            text: text,
            duration: 0.1,
            segments: [LocalTranscriptSegment(start: 0, end: 0.1, text: text, timingSource: .trackEstimate)]
        )
    }
}

@MainActor
private final class TerminationReplySink {
    private(set) var values: [Bool] = []
    lazy var reply: @MainActor (Bool) -> Void = { [weak self] value in
        self?.values.append(value)
    }
}

@MainActor
private final class FailureSink {
    private(set) var count = 0
    lazy var report: @MainActor (Error) -> Void = { [weak self] _ in
        self?.count += 1
    }
}
