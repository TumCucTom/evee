@testable import EveeCore
import XCTest

@MainActor
final class MicrophoneLevelMeterTests: XCTestCase {
    func testHighRateLevelsStayCapacityOneUseOneConsumerAndFinishAtZero() async {
        var received: [Float] = []
        let meter = MicrophoneLevelMeter(updateInterval: .milliseconds(1)) {
            received.append($0)
        }
        meter.start()

        for value in 0..<10_000 {
            meter.offer(Float(value) / 10_000)
        }
        XCTAssertLessThanOrEqual(meter.metrics.depth, 1)
        XCTAssertEqual(meter.metrics.peakDepth, 1)
        XCTAssertGreaterThan(meter.metrics.droppedCount, 0)
        XCTAssertEqual(meter.consumerStartCount, 1)

        await meter.finish()

        XCTAssertFalse(meter.isConsumerActive)
        XCTAssertEqual(received.last, 0)
    }
}
