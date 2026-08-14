import EveeCore
import XCTest
@testable import EveeApp

@MainActor
final class SpeechModelAvailabilityAppTests: XCTestCase {
    func testMacOS14BootstrapPersistsSafeFallbackAndKeepsDiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-model-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        var persisted = EveeSettings()
        persisted.model = .qwen3
        try await library.save(persisted)
        let availability = SpeechModelAvailability(
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)
        )
        let store = AppStore(
            modelDownloaderFactory: { _ in ImmediateReadyModelDownloader() },
            modelDownloadDefaults: nil,
            library: library,
            speechModelAvailability: availability
        )

        await store.bootstrap()

        XCTAssertEqual(store.settings.model, .parakeet)
        let persistedSettings = try await library.loadSettings()
        XCTAssertEqual(persistedSettings.model, .parakeet)
        XCTAssertTrue(store.statusMessage?.contains("Qwen3") == true)
    }

    func testMacOS14SaveRejectsQwenBeforePersisting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-model-save-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        try await library.save(EveeSettings())
        let availability = SpeechModelAvailability(
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)
        )
        let store = AppStore(modelDownloadDefaults: nil, library: library, speechModelAvailability: availability)
        store.settings.model = .qwen3

        await store.saveSettings()

        let persistedSettings = try await library.loadSettings()
        XCTAssertEqual(persistedSettings.model, .parakeet)
        XCTAssertTrue(store.statusMessage?.contains("macOS 15") == true)
    }
}

private actor ImmediateReadyModelDownloader: LocalModelDownloading {
    nonisolated var isDownloaded: Bool { false }
    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
    func load() async throws {}
}
