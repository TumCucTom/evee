import EveeCore
import XCTest
@testable import EveeApp

@MainActor
final class HotMicLifecycleTests: XCTestCase {
    func testDelayedStartCannotPublishAfterDisable() async {
        let fake = DelayedWakeListener()
        let store = AppStore(
            wakeListenerFactory: { fake },
            microphonePermissionProvider: { true },
            modelDownloadDefaults: nil
        )
        store.settings.hotMicEnabled = true
        store.settings.wakePhrase = "hello evee"

        let start = Task { await store.updateHotMicState() }
        await fake.waitUntilStarting()
        await store.disableHotMic()
        await fake.releaseStart()
        await start.value

        let stopCount = await fake.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(store.hotMicState, .disabled)
        XCTAssertFalse(store.hotMicActive)
    }

    func testStartFailureCanRetryWithoutCreatingConcurrentListener() async {
        let fake = DelayedWakeListener()
        let store = AppStore(
            wakeListenerFactory: { fake },
            microphonePermissionProvider: { true },
            modelDownloadDefaults: nil
        )
        store.settings.hotMicEnabled = true
        store.settings.wakePhrase = "hello evee"

        let first = Task { await store.updateHotMicState() }
        await fake.waitUntilStarting()
        let repeated = Task { await store.updateHotMicState() }
        await fake.releaseStart(throwing: SyntheticWakeError.startFailed)
        await first.value
        await repeated.value

        let startCount = await fake.startCount
        XCTAssertEqual(startCount, 1)
        guard case .failed = store.hotMicState else {
            return XCTFail("Expected failed hot-mic state")
        }

        let retry = Task { await store.updateHotMicState() }
        await fake.waitUntilStarting(count: 2)
        await fake.releaseStart()
        await retry.value

        XCTAssertEqual(store.hotMicState, .active)
    }
}

private enum SyntheticWakeError: Error {
    case startFailed
}

private actor DelayedWakeListener: WakePhraseListening {
    nonisolated let transcripts: AsyncStream<String>
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init() {
        transcripts = AsyncStream { _ in }
    }

    func start(deviceUID: String?, lowLatency: Bool) async throws {
        startCount += 1
        let ready = startWaiters.filter { startCount >= $0.count }
        startWaiters.removeAll { startCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func stop() async {
        stopCount += 1
    }

    func waitUntilStarting(count: Int = 1) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func releaseStart(throwing error: Error? = nil) {
        if let error {
            startContinuation?.resume(throwing: error)
        } else {
            startContinuation?.resume()
        }
        startContinuation = nil
    }
}
