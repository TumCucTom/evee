import EveeCore
import XCTest
@testable import EveeApp

@MainActor
final class ModelDownloadLifecycleTests: XCTestCase {
    func testRepeatedStartIsSingleFlightAndCancellationRejectsLateCompletion() async {
        let fake = DelayedModelDownloader()
        let store = AppStore(modelDownloaderFactory: { _ in fake }, modelDownloadDefaults: nil)

        store.startModelDownload()
        store.startModelDownload()
        await fake.waitUntilStarted(count: 1)

        let startCount = await fake.startCount
        XCTAssertEqual(startCount, 1)
        store.cancelModelDownload()
        await fake.finish()
        await Task.yield()

        XCTAssertEqual(store.modelDownloadState, .idle)
    }

    func testRetryStartsOneNewOperationAndPublishesReady() async {
        let fake = DelayedModelDownloader()
        let store = AppStore(modelDownloaderFactory: { _ in fake }, modelDownloadDefaults: nil)

        store.startModelDownload()
        await fake.waitUntilStarted(count: 1)
        store.cancelModelDownload()
        await fake.finish()
        await Task.yield()

        store.startModelDownload()
        store.startModelDownload()
        await fake.waitUntilStarted(count: 2)
        let startCount = await fake.startCount
        XCTAssertEqual(startCount, 2)
        await fake.finish()
        await waitUntil { store.modelDownloadState == .ready(model: .parakeet) }

        XCTAssertEqual(store.modelDownloadState, .ready(model: .parakeet))
    }

    func testSelectingUndownloadedModelAfterReadyModelStartsSelectedModelOnce() async {
        let cachedA = DelayedModelDownloader(isDownloaded: true)
        let selectedB = DelayedModelDownloader()
        let store = AppStore(
            modelDownloaderFactory: { model in
                switch model {
                case .parakeet: cachedA
                case .qwen3: selectedB
                }
            },
            modelDownloadDefaults: nil
        )

        store.settings.model = .parakeet
        store.startModelDownload()
        await waitUntil { store.modelDownloadState == .ready(model: .parakeet) }

        store.settings.model = .qwen3
        store.startModelDownload()
        store.startModelDownload()
        await selectedB.waitUntilStarted(count: 1)

        let selectedBStartCount = await selectedB.startCount
        let cachedADownloadCount = await cachedA.startCount
        XCTAssertEqual(selectedBStartCount, 1)
        XCTAssertEqual(cachedADownloadCount, 0)
        let selectedBProgress = ModelProgress(fraction: 0.25, status: "Synthetic progress")
        await waitUntil {
            store.modelDownloadState == .downloading(model: .qwen3, progress: selectedBProgress)
        }
        XCTAssertEqual(store.modelDownloadState, .downloading(model: .qwen3, progress: selectedBProgress))

        await selectedB.finish()
        await waitUntil { store.modelDownloadState == .ready(model: .qwen3) }
        XCTAssertEqual(store.modelDownloadState, .ready(model: .qwen3))
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

private actor DelayedModelDownloader: LocalModelDownloading {
    nonisolated let isDownloaded: Bool
    private(set) var startCount = 0
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(isDownloaded: Bool = false) {
        self.isDownloaded = isDownloaded
    }

    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        startCount += 1
        progress(ModelProgress(fraction: 0.25, status: "Synthetic progress"))
        let ready = startWaiters.filter { startCount >= $0.count }
        startWaiters.removeAll { startCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        try await withCheckedThrowingContinuation { continuation in
            downloadContinuation = continuation
        }
    }

    func load() async throws {}

    func waitUntilStarted(count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func finish() {
        downloadContinuation?.resume()
        downloadContinuation = nil
    }
}
