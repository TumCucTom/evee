import XCTest
@testable import EveeCore

final class WorkspaceNavigationPresentationTests: XCTestCase {
    func testNavigationOrderIsStable() {
        XCTAssertEqual(
            WorkspaceNavigationPresentation.items.map(\.route),
            [.library, .meetings, .memos, .dictionary, .settings]
        )
    }

    func testNavigationMovementClampsAtFirstMiddleAndLastItems() {
        XCTAssertEqual(WorkspaceNavigationPresentation.move(from: .library, direction: .previous), .library)
        XCTAssertEqual(WorkspaceNavigationPresentation.move(from: .library, direction: .next), .meetings)
        XCTAssertEqual(WorkspaceNavigationPresentation.move(from: .memos, direction: .previous), .meetings)
        XCTAssertEqual(WorkspaceNavigationPresentation.move(from: .memos, direction: .next), .dictionary)
        XCTAssertEqual(WorkspaceNavigationPresentation.move(from: .settings, direction: .previous), .dictionary)
        XCTAssertEqual(WorkspaceNavigationPresentation.move(from: .settings, direction: .next), .settings)
    }

    func testEverySystemVoicePhaseHasNonColourStatusSemantics() {
        let cases: [(SystemVoiceStatus, SystemVoicePhase, String, String, Bool)] = [
            (.make(capture: .idle, hotMic: .disabled, warnings: []), .ready, "Ready", "circle", false),
            (.make(capture: .idle, hotMic: .starting, warnings: []), .wakeStarting, "Preparing to listen", "mic.badge.plus", false),
            (.make(capture: .idle, hotMic: .active, warnings: []), .wakeListening, "Listening", "ear", true),
            (.make(capture: .idle, hotMic: .stopping, warnings: []), .wakeStopping, "Stopping listening", "mic.slash", true),
            (.make(capture: .starting(kind: .dictation), hotMic: .disabled, warnings: []), .captureStarting, "Starting recording", "record.circle", false),
            (.make(capture: .recording(startedAt: .now, level: 0.4), hotMic: .disabled, warnings: []), .recording, "Recording", "record.circle.fill", true),
            (.make(capture: .transcribing, hotMic: .disabled, warnings: []), .processing, "Processing", "waveform.badge.magnifyingglass", false),
            (.make(capture: .delivering, hotMic: .disabled, warnings: []), .delivering, "Delivering", "paperplane", false),
            (.make(capture: .checkpointed("Recovery is available"), hotMic: .disabled, warnings: []), .protected, "Protected", "shield.checkered", false),
            (.make(capture: .failed("Capture error"), hotMic: .disabled, warnings: []), .failed, "Needs attention", "exclamationmark.triangle.fill", false),
        ]

        for (status, phase, title, symbolName, isMicrophoneOpen) in cases {
            let presentation = WorkspaceNavigationPresentation.status(for: status)
            XCTAssertEqual(presentation.phase, phase)
            XCTAssertEqual(presentation.title, title)
            XCTAssertEqual(presentation.symbolName, symbolName)
            XCTAssertEqual(presentation.isMicrophoneOpen, isMicrophoneOpen)
            XCTAssertEqual(presentation.warningTitle, nil)
        }
    }

    func testWarningUsesExplicitGenericSemanticsWithoutExposingFailureDetail() {
        let status = SystemVoiceStatus.make(
            capture: .checkpointed("Recovery is available"),
            hotMic: .disabled,
            warnings: [
                CaptureHealthWarning(channel: .system, reason: .failed("private device detail"))
            ]
        )

        let presentation = WorkspaceNavigationPresentation.status(for: status)

        XCTAssertTrue(presentation.hasWarning)
        XCTAssertEqual(presentation.warningTitle, "Audio warning")
        XCTAssertEqual(presentation.detail, "Open Evee to review the protected recovery.")
    }
}
