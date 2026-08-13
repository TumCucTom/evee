import EveeCore
import XCTest
@testable import EveeApp

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
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
