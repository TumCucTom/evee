import EveeCore
import XCTest

@MainActor
final class TerminationCheckpointTests: XCTestCase {
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
