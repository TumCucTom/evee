import XCTest
@testable import EveeCore

final class OnboardingPresentationTests: XCTestCase {
    func testMicrophoneStateSelectsRequestRecoveryAndGrantedCopy() {
        let request = OnboardingPresentation(microphone: .notDetermined, accessibility: .granted, model: .idle)
        XCTAssertEqual(request.focusTarget, .microphoneRequest)
        XCTAssertEqual(request.microphoneActionTitle, "Allow Microphone")

        let recovery = OnboardingPresentation(microphone: .denied, accessibility: .granted, model: .idle)
        XCTAssertEqual(recovery.focusTarget, .microphoneRecovery)
        XCTAssertEqual(recovery.microphoneActionTitle, "Open Microphone Settings")

        let granted = OnboardingPresentation(microphone: .granted, accessibility: .granted, model: .idle)
        XCTAssertEqual(granted.microphoneStatus, "Ready")
    }

    func testFirstIncompletePermissionReceivesFocus() {
        XCTAssertEqual(
            OnboardingPresentation(microphone: .granted, accessibility: .notDetermined, model: .idle).focusTarget,
            .accessibilityRequest
        )
        XCTAssertEqual(
            OnboardingPresentation(microphone: .granted, accessibility: .granted, model: .idle).focusTarget,
            .modelAction
        )
    }

    func testModelStatesExposeOneContextualActionAndStatus() {
        let idle = OnboardingPresentation(microphone: .granted, accessibility: .granted, model: .idle)
        XCTAssertEqual(idle.modelAction, .download)
        XCTAssertEqual(idle.modelActionTitle, "Download")

        let downloading = OnboardingPresentation(
            microphone: .granted,
            accessibility: .granted,
            model: .downloading(fraction: 0.42, status: "Downloading")
        )
        XCTAssertEqual(downloading.modelAction, .cancel)
        XCTAssertEqual(downloading.modelAccessibilityLabel, "Cancel local model download")
        XCTAssertEqual(downloading.modelAccessibilityValue, "42 percent, Downloading")

        let cancelling = OnboardingPresentation(microphone: .granted, accessibility: .granted, model: .cancelling)
        XCTAssertEqual(cancelling.modelAction, .none)
        XCTAssertEqual(cancelling.modelAccessibilityLabel, "Cancelling local model download")

        let failed = OnboardingPresentation(microphone: .granted, accessibility: .granted, model: .failed("Interrupted"))
        XCTAssertEqual(failed.modelAction, .retry)
        XCTAssertEqual(failed.modelActionTitle, "Retry")
        XCTAssertEqual(failed.modelAccessibilityValue, "Interrupted")

        let ready = OnboardingPresentation(microphone: .granted, accessibility: .granted, model: .ready)
        XCTAssertEqual(ready.modelAction, .none)
        XCTAssertEqual(ready.modelAccessibilityLabel, "Local model ready")
    }
}
