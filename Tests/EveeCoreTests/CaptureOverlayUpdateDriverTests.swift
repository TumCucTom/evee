import EveeCore
import XCTest

@MainActor
final class CaptureOverlayUpdateDriverTests: XCTestCase {
    func testRendererIsCreatedOnceMeterUpdatesAreBoundedAndPhaseIsImmediate() {
        let renderer = RendererSpy()
        let driver = CaptureOverlayUpdateDriver(renderer: renderer, minimumMeterInterval: 0.05)
        let startedAt = Date(timeIntervalSince1970: 1_786_617_000)

        driver.receive(snapshot(capture: .idle), at: 0)
        XCTAssertEqual(renderer.creationCount, 0)

        driver.receive(snapshot(capture: .recording(startedAt: startedAt, level: 0.1)), at: 1)
        driver.receive(snapshot(capture: .recording(startedAt: startedAt, level: 0.2)), at: 1.01)
        driver.receive(snapshot(capture: .recording(startedAt: startedAt, level: 0.3)), at: 1.02)
        driver.receive(snapshot(capture: .recording(startedAt: startedAt, level: 0.4)), at: 1.05)

        XCTAssertEqual(renderer.creationCount, 1)
        XCTAssertEqual(renderer.applied.map(\.level), [Double(Float(0.1)), Double(Float(0.4))])
        XCTAssertEqual(renderer.presentRepositionValues, [true])

        driver.receive(snapshot(capture: .transcribing), at: 1.051)
        XCTAssertEqual(renderer.applied.last?.phase, .processing)
        XCTAssertEqual(renderer.applied.count, 3, "phase changes must bypass the meter cadence")
        XCTAssertEqual(renderer.presentRepositionValues, [true, true])

        driver.receive(snapshot(capture: .idle), at: 1.052)
        XCTAssertEqual(renderer.hideCount, 1)
        driver.receive(snapshot(capture: .recording(startedAt: startedAt, level: 0.5)), at: 1.053)
        XCTAssertEqual(renderer.creationCount, 1)
        XCTAssertEqual(renderer.presentRepositionValues, [true, true, true])
    }

    private func snapshot(capture: CaptureState) -> CaptureOverlaySnapshot {
        CaptureOverlaySnapshot.make(
            status: SystemVoiceStatus.make(capture: capture, hotMic: .disabled, warnings: []),
            capture: capture
        )
    }
}

@MainActor
private final class RendererSpy: CaptureOverlayRendering {
    var creationCount = 0
    var applied: [CaptureOverlayPresentation] = []
    var presentRepositionValues: [Bool] = []
    var hideCount = 0

    func createOverlay() { creationCount += 1 }
    func apply(_ presentation: CaptureOverlayPresentation) { applied.append(presentation) }
    func presentOverlay(reposition: Bool) { presentRepositionValues.append(reposition) }
    func hideOverlay() { hideCount += 1 }
}
