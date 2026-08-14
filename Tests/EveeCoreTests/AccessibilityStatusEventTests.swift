import XCTest
@testable import EveeCore

final class AccessibilityStatusEventTests: XCTestCase {
    func testRepeatedLifecycleEventsAndProgressBucketsAreDeduplicated() {
        var reducer = AccessibilityAnnouncementReducer()

        XCTAssertEqual(reducer.receive(.captureStarted), "Recording started.")
        XCTAssertNil(reducer.receive(.captureStarted))
        XCTAssertEqual(reducer.receive(.modelDownloadStarted), "Local model download started.")
        XCTAssertNil(reducer.receive(.modelDownloadProgress(0.09)))
        XCTAssertEqual(reducer.receive(.modelDownloadProgress(0.10)), "Local model download 10 percent.")
        XCTAssertNil(reducer.receive(.modelDownloadProgress(0.19)))
        XCTAssertEqual(reducer.receive(.modelDownloadProgress(0.31)), "Local model download 30 percent.")
        XCTAssertNil(reducer.receive(.modelDownloadProgress(0.20)))
    }

    func testNewDownloadResetsProgressMilestones() {
        var reducer = AccessibilityAnnouncementReducer()

        _ = reducer.receive(.modelDownloadStarted)
        XCTAssertEqual(reducer.receive(.modelDownloadProgress(0.10)), "Local model download 10 percent.")
        XCTAssertEqual(reducer.receive(.modelDownloadCancelled), "Local model download cancelled.")
        XCTAssertEqual(reducer.receive(.modelDownloadStarted), "Local model download started.")
        XCTAssertEqual(reducer.receive(.modelDownloadProgress(0.10)), "Local model download 10 percent.")
    }

    func testFailuresWarningsRecoveryAndRevocationRemainActionableAndPrivate() {
        var reducer = AccessibilityAnnouncementReducer()

        XCTAssertEqual(reducer.receive(.wakeListeningFailed("Wake error")), "Wake phrase listening needs attention. Open Evee for details.")
        XCTAssertEqual(reducer.receive(.captureFailed("Capture error")), "Capture needs attention. Open Evee for recovery options.")
        XCTAssertEqual(reducer.receive(.captureRecovered), "Interrupted capture recovered.")
        XCTAssertEqual(reducer.receive(.microphoneSilence), "No microphone signal has been detected. Check the selected input and mute switch.")
        XCTAssertEqual(reducer.receive(.channelFailed(.system, "Channel error")), "System audio needs attention. Open Evee for details.")
        XCTAssertEqual(reducer.receive(.webhookRevoked), "Meeting webhook access revoked.")
        XCTAssertEqual(reducer.receive(.helperRevoked), "Local helper access revoked.")
    }

    func testSilenceDeduplicationResetsOnlyAfterSignalRecovery() {
        var reducer = AccessibilityAnnouncementReducer()

        XCTAssertEqual(reducer.receive(.microphoneSilence), "No microphone signal has been detected. Check the selected input and mute switch.")
        XCTAssertNil(reducer.receive(.microphoneSignalRestored))
        XCTAssertEqual(reducer.receive(.microphoneSilence), "No microphone signal has been detected. Check the selected input and mute switch.")
        XCTAssertEqual(reducer.receive(.channelFailed(.system, "Channel error")), "System audio needs attention. Open Evee for details.")
        XCTAssertNil(reducer.receive(.microphoneSilence))
        XCTAssertNil(reducer.receive(.microphoneSignalRestored))
        XCTAssertEqual(reducer.receive(.microphoneSilence), "No microphone signal has been detected. Check the selected input and mute switch.")
        XCTAssertNil(reducer.receive(.microphoneSilence))
    }

    func testAnnouncementsNeverSpeakPathBearingFailureDetails() {
        let privateDetail = "/Users/alice/Library/Application Support/Evee/Recoveries/private.wav"
        var reducer = AccessibilityAnnouncementReducer()
        let messages = [
            reducer.receive(.wakeListeningFailed(privateDetail)),
            reducer.receive(.captureFailed(privateDetail)),
            reducer.receive(.channelFailed(.microphone, privateDetail)),
            reducer.receive(.modelDownloadFailed(privateDetail)),
            reducer.receive(.audioExportFailed(privateDetail)),
        ].compactMap { $0 }

        XCTAssertTrue(messages.allSatisfy { !$0.contains(privateDetail) && !$0.contains("/Users/") })
    }
}
