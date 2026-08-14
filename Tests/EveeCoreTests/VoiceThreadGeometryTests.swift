import XCTest
@testable import EveeCore

final class VoiceThreadGeometryTests: XCTestCase {
    func testGeometryIsDeterministicBoundedAndSymmetric() {
        let quiet = VoiceThreadGeometry.points(level: 0, count: 9)
        let active = VoiceThreadGeometry.points(level: 1, count: 9)
        XCTAssertEqual(quiet.count, 9)
        XCTAssertEqual(active.count, 9)
        XCTAssertEqual(active, Array(active.reversed()))
        XCTAssertEqual(active.first, active.last)
        XCTAssertTrue(active.allSatisfy { (-1.0...1.0).contains($0) })
        XCTAssertGreaterThan(active.map(abs).max() ?? 0, quiet.map(abs).max() ?? 0)
        XCTAssertEqual(active, VoiceThreadGeometry.points(level: 1, count: 9))
    }

    func testGeometryClampsLevelAndNormalizesEvenCountsToOdd() {
        XCTAssertEqual(
            VoiceThreadGeometry.points(level: -1, count: 8),
            VoiceThreadGeometry.points(level: 0, count: 8)
        )
        XCTAssertEqual(
            VoiceThreadGeometry.points(level: 2, count: 8),
            VoiceThreadGeometry.points(level: 1, count: 8)
        )
        XCTAssertEqual(VoiceThreadGeometry.points(level: 1, count: 8).count, 9)
    }
}
