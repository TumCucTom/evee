import EveeCore
import XCTest

final class GlobalVoicePresentationTests: XCTestCase {
    func testMenuBarAccessibilityNamesPhaseMicrophoneAndWarningWithoutDetail() {
        let privateDetail = "/Users/alice/private.wav"
        let status = SystemVoiceStatus.make(
            capture: .recording(startedAt: .now, level: 0.3),
            hotMic: .disabled,
            warnings: [CaptureHealthWarning(channel: .system, reason: .failed(privateDetail))]
        )
        let presentation = MenuBarVoicePresentation.make(status: status)

        for label in [presentation.closedAccessibilityLabel, presentation.openAccessibilityLabel] {
            XCTAssertTrue(label.contains("Recording"))
            XCTAssertTrue(label.contains("Microphone open"))
            XCTAssertTrue(label.contains("Audio warning"))
            XCTAssertFalse(label.contains(privateDetail))
        }
    }

    func testHUDAccessibilitySpeaksMicrophoneOpenExactlyOnce() {
        let capture = CaptureState.recording(startedAt: .now, level: 0.3)
        let snapshot = CaptureOverlaySnapshot.make(
            status: .make(capture: capture, hotMic: .disabled, warnings: []),
            capture: capture
        )
        let label = CaptureOverlayPresentation.make(snapshot: snapshot).accessibilityLabel

        XCTAssertEqual(label.components(separatedBy: "Microphone open").count - 1, 1)
    }
}
