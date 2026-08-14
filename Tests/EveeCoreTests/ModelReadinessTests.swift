@testable import EveeCore
import XCTest

final class ModelReadinessTests: XCTestCase {
    func testShallowPresentInvalidModelRepairsOnceThenValidates() async throws {
        let provider = InvalidThenRepairableModelProvider()

        await XCTAssertThrowsErrorAsync {
            try await LocalModelReadiness.prepare(provider, mode: .validateExisting) { _ in }
        }
        try await LocalModelReadiness.prepare(provider, mode: .downloadOrRepair) { _ in }

        let counts = await provider.counts
        XCTAssertEqual(counts.downloads, 1)
        XCTAssertEqual(counts.loads, 2)
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

private enum SyntheticModelReadinessError: Error { case invalidCache }

private actor InvalidThenRepairableModelProvider: LocalModelDownloading {
    nonisolated var isDownloaded: Bool { true }
    private var repaired = false
    private var downloadCount = 0
    private var loadCount = 0

    var counts: (downloads: Int, loads: Int) { (downloadCount, loadCount) }

    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        downloadCount += 1
        repaired = true
    }

    func load() async throws {
        loadCount += 1
        if !repaired { throw SyntheticModelReadinessError.invalidCache }
    }
}
