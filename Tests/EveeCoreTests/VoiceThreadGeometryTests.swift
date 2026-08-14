import XCTest
@testable import EveeCore

final class VoiceThreadGeometryTests: XCTestCase {
    func testEveryModeHasDistinctDeterministicBoundedGeometry() {
        let samples: [(VoiceThreadMode, [Double])] = [
            (.idle, VoiceThreadGeometry.points(mode: .idle, level: 0)),
            (.listening, VoiceThreadGeometry.points(mode: .listening, level: 0.7)),
            (.processing, VoiceThreadGeometry.points(mode: .processing, level: 0)),
            (.resolved, VoiceThreadGeometry.points(mode: .resolved, level: 0)),
            (.warning, VoiceThreadGeometry.points(mode: .warning, level: 0)),
        ]

        for (mode, points) in samples {
            XCTAssertEqual(points.count, 9, "\(mode) must use the small fixed sample budget")
            XCTAssertTrue(points.allSatisfy { (-1.0...1.0).contains($0) })
            XCTAssertEqual(points, VoiceThreadGeometry.points(mode: mode, level: mode == .listening ? 0.7 : 0))
        }

        for firstIndex in samples.indices {
            for secondIndex in samples.indices where secondIndex > firstIndex {
                XCTAssertNotEqual(samples[firstIndex].1, samples[secondIndex].1)
            }
        }
    }

    func testListeningGeometryUsesOnlyFiniteBoundedMeasuredLevel() {
        XCTAssertEqual(
            VoiceThreadGeometry.points(mode: .listening, level: -1),
            VoiceThreadGeometry.points(mode: .listening, level: 0)
        )
        XCTAssertEqual(
            VoiceThreadGeometry.points(mode: .listening, level: 2),
            VoiceThreadGeometry.points(mode: .listening, level: 1)
        )
        XCTAssertEqual(
            VoiceThreadGeometry.points(mode: .listening, level: .nan),
            VoiceThreadGeometry.points(mode: .listening, level: 0)
        )
        XCTAssertTrue(VoiceThreadGeometry.points(mode: .listening, level: 0).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(
            VoiceThreadGeometry.points(mode: .listening, level: 1).map(abs).max() ?? 0,
            VoiceThreadGeometry.points(mode: .listening, level: 0.2).map(abs).max() ?? 0
        )
    }
}
