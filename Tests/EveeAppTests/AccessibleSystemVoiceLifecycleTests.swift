import AppKit
import EveeCore
import KeyboardShortcuts
import XCTest
@testable import EveeApp

@MainActor
final class AccessibleSystemVoiceLifecycleTests: XCTestCase {
    func testMicrophoneRemainsVisiblyOpenWhileSystemAudioStartIsSuspended() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-accessible-delayed-system-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        let systemStart = SuspendedVoidOperation()
        var microphoneURL: URL?
        var microphoneIsRecording = false
        let store = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            microphoneStarter: { url, _, _ in
                microphoneURL = url
                microphoneIsRecording = true
                try accessibleSyntheticSilentWAV().write(to: url)
            },
            microphoneStopper: {
                microphoneIsRecording = false
                return try XCTUnwrap(microphoneURL)
            },
            microphoneRecordingProbe: { microphoneIsRecording },
            systemAudioStarter: { url in
                try accessibleSyntheticSilentWAV().write(to: url)
                try await systemStart.run()
            },
            systemAudioStopper: {}
        )
        store.settings.meetingCaptureEnabled = true
        store.settings.liveMeetingTranscriptionEnabled = false

        let start = Task { @MainActor in await store.beginMeeting() }
        await systemStart.waitUntilCalled()

        XCTAssertEqual(store.systemVoiceStatus.phase, .captureStarting)
        XCTAssertTrue(store.systemVoiceStatus.isMicrophoneOpen)
        XCTAssertTrue(store.systemVoiceStatus.hudTitle.contains("Microphone open"))
        XCTAssertEqual(store.systemVoiceStatus.availableActions, [.discard])

        systemStart.succeed()
        await start.value
        XCTAssertEqual(store.systemVoiceStatus.phase, .recording)
        await store.cancelCapture()
    }

    func testStoppedCapturePublishesProcessingAndRejectsDiscardWhilePersistenceIsSuspended() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-accessible-suspended-persistence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        let persistence = SuspendedRecoveryPersistence()
        var microphoneURL: URL?
        var microphoneIsRecording = false
        let store = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            microphoneStarter: { url, _, _ in
                microphoneURL = url
                microphoneIsRecording = true
                try accessibleSyntheticSilentWAV().write(to: url)
            },
            microphoneStopper: {
                microphoneIsRecording = false
                return try XCTUnwrap(microphoneURL)
            },
            microphoneRecordingProbe: { microphoneIsRecording },
            recoveryTrackPersister: { library, captureID, kind, role, sourceURL, startedAt in
                try await persistence.persist(
                    library: library,
                    captureID: captureID,
                    kind: kind,
                    role: role,
                    sourceURL: sourceURL,
                    startedAt: startedAt
                )
            }
        )
        await store.beginMemo()
        XCTAssertEqual(store.systemVoiceStatus.phase, .recording)

        let finish = Task { @MainActor in await store.finishCapture() }
        await persistence.waitUntilCalled()
        let stoppedURL = try XCTUnwrap(microphoneURL)

        XCTAssertEqual(store.captureState, .transcribing)
        XCTAssertEqual(store.systemVoiceStatus.phase, .processing)
        XCTAssertFalse(store.systemVoiceStatus.isMicrophoneOpen)
        XCTAssertTrue(store.systemVoiceStatus.availableActions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stoppedURL.path))

        await store.handleCancelCaptureShortcut()
        await store.cancelCapture()
        XCTAssertEqual(store.captureState, .transcribing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stoppedURL.path))

        persistence.fail()
        await finish.value
        guard case .failed(let detail) = store.captureState else {
            return XCTFail("Persistence failure did not replace processing with protected failure state")
        }
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("kept for recovery"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stoppedURL.path))
        let recoveries = try await library.recoverableCaptures()
        XCTAssertTrue(recoveries.contains { recovery in
            recovery.tracks.contains(where: { $0.role == .microphone })
        })
    }

    func testMeetingHidesCaptureActionsWhileSystemAudioStopIsSuspended() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-accessible-delayed-system-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root)
        let systemStop = SuspendedVoidOperation()
        var microphoneURL: URL?
        var microphoneIsRecording = false
        var announcements: [String] = []
        let announcementCoordinator = AccessibilityAnnouncementCoordinator {
            announcements.append($0)
        }
        let store = AppStore(
            modelDownloadDefaults: nil,
            library: library,
            microphoneStarter: { url, _, _ in
                microphoneURL = url
                microphoneIsRecording = true
                try accessibleSyntheticSilentWAV().write(to: url)
            },
            microphoneStopper: {
                microphoneIsRecording = false
                return try XCTUnwrap(microphoneURL)
            },
            microphoneRecordingProbe: { microphoneIsRecording },
            systemAudioStarter: { url in
                try accessibleSyntheticSilentWAV().write(to: url)
            },
            systemAudioStopper: {
                try await systemStop.run()
            },
            recoveryTranscriberFactory: { _ in
                throw AccessibleSyntheticError.transcriptionFailed
            },
            accessibilityAnnouncements: announcementCoordinator
        )
        store.settings.meetingCaptureEnabled = true
        store.settings.liveMeetingTranscriptionEnabled = false
        await store.beginMeeting()
        XCTAssertEqual(store.systemVoiceStatus.phase, .recording)

        let finish = Task { @MainActor in await store.finishCapture() }
        await systemStop.waitUntilCalled()

        XCTAssertEqual(store.captureState, .transcribing)
        XCTAssertEqual(store.systemVoiceStatus.phase, .processing)
        XCTAssertTrue(store.systemVoiceStatus.availableActions.isEmpty)
        XCTAssertFalse(store.systemVoiceStatus.isMicrophoneOpen)
        XCTAssertTrue(store.systemVoiceStatus.hudTitle.localizedCaseInsensitiveContains("transcribing"))
        XCTAssertFalse(announcements.contains("Recording stopped. Transcribing locally."))

        systemStop.succeed()
        await finish.value
        XCTAssertEqual(systemStop.callCount, 1)
        XCTAssertTrue(announcements.contains("Recording stopped. Transcribing locally."))
    }

    func testCancelShortcutDefaultIsNonreservedAndDoesNotCollideWithCaptureShortcuts() {
        let expected = KeyboardShortcuts.Shortcut(
            .escape,
            modifiers: [.control, .option, .command]
        )

        XCTAssertEqual(KeyboardShortcuts.Name.cancelCapture.defaultShortcut, expected)
        XCTAssertNotEqual(KeyboardShortcuts.Name.pushToTalk.defaultShortcut, expected)
        XCTAssertNotEqual(KeyboardShortcuts.Name.transformSelection.defaultShortcut, expected)
        XCTAssertEqual(GlobalShortcutDefaults.cancelCaptureDescription, "Control–Option–Command–Escape")
    }

    func testPushToTalkDefaultDoesNotCollideWithFinderSearch() {
        let expected = KeyboardShortcuts.Shortcut(
            .space,
            modifiers: [.command, .shift]
        )
        let finderSearch = KeyboardShortcuts.Shortcut(
            .space,
            modifiers: [.command, .option]
        )

        XCTAssertEqual(KeyboardShortcuts.Name.pushToTalk.defaultShortcut, expected)
        XCTAssertNotEqual(KeyboardShortcuts.Name.pushToTalk.defaultShortcut, finderSearch)
    }
}

@MainActor
private final class SuspendedVoidOperation {
    private var continuation: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func run() async throws {
        callCount += 1
        guard callCount == 1 else {
            throw AccessibleSyntheticError.repeatedOperation
        }
        try await withCheckedThrowingContinuation {
            continuation = $0
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilCalled() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SuspendedRecoveryPersistence {
    private var continuation: CheckedContinuation<CaptureRecoveryManifest, Error>?
    private var waiter: CheckedContinuation<Void, Never>?

    func persist(
        library: LibraryStore,
        captureID: UUID,
        kind: WorkspaceRecordKind,
        role: AudioTrackRole,
        sourceURL: URL,
        startedAt: Date?
    ) async throws -> CaptureRecoveryManifest {
        try await withCheckedThrowingContinuation {
            continuation = $0
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilCalled() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func fail() {
        continuation?.resume(throwing: AccessibleSyntheticError.persistenceFailed)
        continuation = nil
    }
}

private enum AccessibleSyntheticError: LocalizedError {
    case persistenceFailed
    case repeatedOperation
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .persistenceFailed:
            "Synthetic recovery persistence failure."
        case .repeatedOperation:
            "Synthetic operation was invoked more than once."
        case .transcriptionFailed:
            "Synthetic transcription failure."
        }
    }
}

private func accessibleSyntheticSilentWAV() -> Data {
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
