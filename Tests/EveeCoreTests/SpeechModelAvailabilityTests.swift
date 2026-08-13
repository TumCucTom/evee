@testable import EveeCore
import XCTest

final class SpeechModelAvailabilityTests: XCTestCase {
    func testQwenRequiresMacOS15AndFallsBackToParakeetOnMacOS14() {
        let macOS14 = SpeechModelAvailability(
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)
        )

        XCTAssertTrue(macOS14.isSupported(.parakeet))
        XCTAssertFalse(macOS14.isSupported(.qwen3))
        XCTAssertEqual(macOS14.safeSelection(for: .qwen3), .parakeet)
        XCTAssertNotNil(macOS14.unavailableReason(for: .qwen3))
    }

    func testQwenIsSupportedOnMacOS15() {
        let macOS15 = SpeechModelAvailability(
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )

        XCTAssertTrue(macOS15.isSupported(.qwen3))
        XCTAssertEqual(macOS15.safeSelection(for: .qwen3), .qwen3)
        XCTAssertNil(macOS15.unavailableReason(for: .qwen3))
    }
}
