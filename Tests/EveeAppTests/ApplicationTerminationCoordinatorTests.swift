import EveeCore
import XCTest
@testable import EveeApp

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
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
        let source = root.appendingPathComponent("synthetic.caf")
        try! Data("synthetic".utf8).write(to: source)
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
        let coordinator = ApplicationTerminationCoordinator(deadline: .milliseconds(20))

        XCTAssertEqual(coordinator.requestTermination(
            plan: .invalidateDeliveryAndAwaitCommit,
            checkpoint: checkpoint,
            reply: firstReplies.reply,
            reportFailure: { _ in }
        ), .terminateLater)
        await checkpoint.waitUntilCalled()
        await waitUntil { firstReplies.values == [false] }
        checkpoint.succeed()
        await waitUntil { checkpoint.callCount == 1 }

        checkpoint.beginNewWork()
        let secondReplies = TerminationReplySink()
        XCTAssertEqual(coordinator.requestTermination(
            plan: .invalidateDeliveryAndAwaitCommit,
            checkpoint: checkpoint,
            reply: secondReplies.reply,
            reportFailure: { _ in }
        ), .terminateLater)
        await checkpoint.waitUntilCalled(count: 2)
        XCTAssertEqual(checkpoint.callCount, 2)
        checkpoint.succeed()
        await waitUntil { secondReplies.values == [true] }
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
        await checkpoint.waitUntilCalled()
        checkpoint.beginNewWork()
        checkpoint.succeed()
        await waitUntil { !replies.values.isEmpty }

        XCTAssertEqual(replies.values, [false])
        XCTAssertEqual(failures.count, 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
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
    private var continuation: CheckedContinuation<Void, Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var callCount = 0
    private(set) var terminationWorkGeneration: UInt64 = 0

    func prepareForTerminationCheckpoint() -> UInt64 { terminationWorkGeneration }

    func checkpointForTermination() async throws {
        callCount += 1
        let ready = waiters.filter { callCount >= $0.0 }
        waiters.removeAll { callCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func beginNewWork() { terminationWorkGeneration &+= 1 }

    func waitUntilCalled(count: Int = 1) async {
        guard callCount < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

private enum SyntheticApplicationTerminationError: Error {
    case persistenceFailed
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
