import XCTest
@testable import EveeCore

final class SystemVoiceStatusTests: XCTestCase {
    func testWakeLifecycleKeepsOpenMicrophoneVisibleUntilCleanupCompletes() {
        let starting = SystemVoiceStatus.make(capture: .idle, hotMic: .starting, warnings: [])
        let listening = SystemVoiceStatus.make(capture: .idle, hotMic: .active, warnings: [])
        let stopping = SystemVoiceStatus.make(capture: .idle, hotMic: .stopping, warnings: [])

        XCTAssertEqual(starting.phase, .wakeStarting)
        XCTAssertFalse(starting.isMicrophoneOpen)
        XCTAssertEqual(listening.phase, .wakeListening)
        XCTAssertTrue(listening.isMicrophoneOpen)
        XCTAssertTrue(listening.menuTitle.contains("listening"))
        XCTAssertEqual(stopping.phase, .wakeStopping)
        XCTAssertTrue(stopping.isMicrophoneOpen)
    }

    func testRecordingPresentsHealthAndBothGlobalActions() {
        let status = SystemVoiceStatus.make(
            capture: .recording(startedAt: .now, level: 0),
            hotMic: .disabled,
            warnings: [
                CaptureHealthWarning(channel: .microphone, reason: .silence),
                CaptureHealthWarning(channel: .system, reason: .unavailable),
            ]
        )

        XCTAssertEqual(status.phase, .recording)
        XCTAssertTrue(status.isMicrophoneOpen)
        XCTAssertNotNil(status.hudWarning)
        XCTAssertTrue(status.menuTitle.contains("warning"))
        XCTAssertEqual(status.availableActions, [.stopAndTranscribe, .discard])
    }

    func testCaptureStartupDoesNotHideWakeMicrophoneCleanup() {
        let status = SystemVoiceStatus.make(
            capture: .starting(kind: .dictation),
            hotMic: .stopping,
            warnings: []
        )

        XCTAssertEqual(status.phase, .captureStarting)
        XCTAssertTrue(status.isMicrophoneOpen)
        XCTAssertTrue(status.hudTitle.contains("Microphone open"))
    }

    func testCaptureStartupKeepsRecorderOpenWhileSystemAudioStarts() {
        let status = SystemVoiceStatus.make(
            capture: .starting(kind: .meeting),
            hotMic: .disabled,
            captureMicrophone: .open,
            warnings: []
        )

        XCTAssertEqual(status.phase, .captureStarting)
        XCTAssertTrue(status.isMicrophoneOpen)
        XCTAssertTrue(status.hudTitle.contains("Microphone open"))
        XCTAssertEqual(status.availableActions, [.discard])
    }

    func testAwaitedRecorderStopRemainsOpenUntilCompletion() {
        let status = SystemVoiceStatus.make(
            capture: .recording(startedAt: .now, level: 0),
            hotMic: .disabled,
            captureMicrophone: .stopping,
            warnings: []
        )

        XCTAssertTrue(status.isMicrophoneOpen)
        XCTAssertTrue(status.hudTitle.contains("Microphone open"))
    }

    func testProcessingPresentationHidesActionsBeforeRecorderStopCompletes() {
        let status = SystemVoiceStatus.make(
            capture: .transcribing,
            hotMic: .disabled,
            captureMicrophone: .open,
            warnings: []
        )

        XCTAssertEqual(status.phase, .processing)
        XCTAssertTrue(status.availableActions.isEmpty)
        XCTAssertTrue(status.isMicrophoneOpen)
        XCTAssertTrue(status.hudTitle.contains("Stopping capture"))
    }

    func testCaptureStatusOverridesWakeAndMapsPostCapturePhases() {
        let processing = SystemVoiceStatus.make(capture: .transcribing, hotMic: .active, warnings: [])
        let delivering = SystemVoiceStatus.make(capture: .delivering, hotMic: .active, warnings: [])
        let failed = SystemVoiceStatus.make(capture: .failed("Capture error"), hotMic: .active, warnings: [])

        XCTAssertEqual(processing.phase, .processing)
        XCTAssertFalse(processing.isMicrophoneOpen)
        XCTAssertEqual(delivering.phase, .delivering)
        XCTAssertFalse(delivering.isMicrophoneOpen)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertFalse(failed.isMicrophoneOpen)
        XCTAssertTrue(failed.hudDetail.contains("Capture error"))
    }

    func testCheckpointRetainsProtectedRecoveryPresentation() {
        let status = SystemVoiceStatus.make(
            capture: .checkpointed("Recovery is available"),
            hotMic: .disabled,
            warnings: []
        )

        XCTAssertEqual(status.phase, .protected)
        XCTAssertFalse(status.isMicrophoneOpen)
        XCTAssertEqual(status.menuTitle, "Capture protected")
    }

    func testStopFailureDoesNotClaimTheMicrophoneClosed() {
        let status = SystemVoiceStatus.make(
            capture: .failed("Recorder did not stop"),
            hotMic: .disabled,
            captureMicrophone: .open,
            warnings: []
        )

        XCTAssertEqual(status.phase, .failed)
        XCTAssertTrue(status.isMicrophoneOpen)
        XCTAssertTrue(status.hudTitle.contains("Microphone open"))
    }
}
