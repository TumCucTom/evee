import XCTest
@testable import EveeCore

final class UpdateCheckerTests: XCTestCase {
    func testSemanticVersionComparison() {
        let checker = UpdateChecker()
        XCTAssertTrue(checker.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(checker.isNewer("v2.0.0", than: "1.99.99"))
        XCTAssertFalse(checker.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(checker.isNewer("1.1.9", than: "1.2.0"))
    }

    func testDiagnosticsReportStatesItsPrivacyBoundary() {
        let report = DiagnosticsReport(
            appVersion: "1.0.0",
            operatingSystem: "macOS",
            model: "Local",
            language: "en",
            recordCount: 2,
            recoveryCount: 0,
            microphonePermission: true,
            accessibilityPermission: true,
            systemAudioEnabled: false,
            liveMeetingEnabled: true,
            localAPIEnabled: false,
            webhookConfigured: false,
            inputDeviceSelected: false
        ).rendered()
        XCTAssertTrue(report.contains("Workspace records: 2"))
        XCTAssertTrue(report.contains("excludes transcript text"))
    }
}
