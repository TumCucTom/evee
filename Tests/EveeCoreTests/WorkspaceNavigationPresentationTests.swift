import XCTest
@testable import EveeCore

final class WorkspaceNavigationPresentationTests: XCTestCase {
    func testNavigationOrderAndStatusDoNotDependOnColour() {
        XCTAssertEqual(
            WorkspaceNavigationPresentation.items.map(\.route),
            [.library, .meetings, .memos, .dictionary, .settings]
        )
        let recording = WorkspaceNavigationPresentation.status(
            for: SystemVoiceStatus.make(
                capture: .recording(startedAt: .now, level: 0.4),
                hotMic: .disabled,
                warnings: []
            )
        )
        XCTAssertEqual(recording.title, "Recording")
        XCTAssertEqual(recording.symbolName, "record.circle.fill")
        XCTAssertTrue(recording.isMicrophoneOpen)
    }
}
