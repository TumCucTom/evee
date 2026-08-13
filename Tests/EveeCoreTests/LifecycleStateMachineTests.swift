import XCTest
@testable import EveeCore

final class LifecycleStateMachineTests: XCTestCase {
    func testModelDownloadRetainsCancellationUntilProviderAcknowledges() throws {
        var download = ModelDownloadStateMachine()
        let first = try XCTUnwrap(download.begin(model: .parakeet))

        XCTAssertNil(download.begin(model: .parakeet))
        XCTAssertTrue(download.requestCancellation(first))

        XCTAssertEqual(download.state, .cancelling(model: .parakeet))
        XCTAssertNil(download.begin(model: .parakeet))
        XCTAssertFalse(download.update(first, progress: ModelProgress(fraction: 0.5, status: "Synthetic progress")))
        XCTAssertFalse(download.complete(first))
        XCTAssertTrue(download.acknowledgeCancellation(first, message: "Download cancelled. Retry when ready."))
        XCTAssertEqual(download.state, .failed(model: .parakeet, message: "Download cancelled. Retry when ready."))
        XCTAssertNotNil(download.begin(model: .parakeet))
    }

    func testModelDownloadCanRetryAfterFailure() throws {
        var download = ModelDownloadStateMachine()
        let first = try XCTUnwrap(download.begin(model: .qwen3))

        XCTAssertTrue(download.fail(first, message: "Synthetic failure"))
        XCTAssertNotNil(download.begin(model: .qwen3))
    }

    func testHotMicRejectsStaleStartAfterDisable() throws {
        var hotMic = HotMicStateMachine()
        let start = try XCTUnwrap(hotMic.beginStart())

        XCTAssertNil(hotMic.beginStart())
        hotMic.disable()

        XCTAssertFalse(hotMic.didStart(start))
        XCTAssertTrue(hotMic.isDisabled)
    }

    func testShutdownPlanMapsLifecycleSnapshots() {
        let recoveryID = UUID()

        XCTAssertEqual(CaptureShutdownPlan.make(for: .idle), .terminateImmediately)
        XCTAssertEqual(CaptureShutdownPlan.make(for: .failed), .terminateImmediately)
        XCTAssertEqual(
            CaptureShutdownPlan.make(for: .starting(kind: .dictation, recoveryID: recoveryID)),
            .cancelStartAndCheckpoint
        )
        XCTAssertEqual(
            CaptureShutdownPlan.make(for: .recording(kind: .meeting, recoveryID: recoveryID)),
            .stopWritersAndCheckpoint(kind: .meeting, recoveryID: recoveryID)
        )
        XCTAssertEqual(
            CaptureShutdownPlan.make(for: .finishing(recoveryID: recoveryID)),
            .awaitDurableCommitOrCheckpoint(recoveryID: recoveryID)
        )
        XCTAssertEqual(CaptureShutdownPlan.make(for: .delivering), .invalidateDeliveryAndAwaitCommit)
        XCTAssertEqual(CaptureShutdownPlan.make(for: .cancelling), .awaitCancellationCleanup)
    }

    func testShutdownPlanFailsClosedWhenActiveCaptureLacksRecoveryIdentifier() {
        let activeSnapshots: [CaptureLifecycleSnapshot] = [
            .starting(kind: .memo, recoveryID: nil),
            .recording(kind: .dictation, recoveryID: nil),
            .finishing(recoveryID: nil),
        ]

        for snapshot in activeSnapshots {
            guard case .cancelTermination(let message) = CaptureShutdownPlan.make(for: snapshot) else {
                return XCTFail("Active capture without a recovery identifier was allowed to terminate")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }
}
