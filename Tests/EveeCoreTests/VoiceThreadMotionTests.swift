import XCTest
@testable import EveeCore

final class VoiceThreadMotionTests: XCTestCase {
    func testTravellingHighlightExistsOnlyForProcessing() {
        for mode in [VoiceThreadMode.idle, .listening, .resolved, .warning] {
            let motion = VoiceThreadProcessingMotion.make(mode: mode, reduceMotion: false)
            XCTAssertFalse(motion.showsHighlight)
            XCTAssertFalse(motion.animatesHighlight)
        }

        let processing = VoiceThreadProcessingMotion.make(mode: .processing, reduceMotion: false)
        XCTAssertTrue(processing.showsHighlight)
        XCTAssertTrue(processing.animatesHighlight)
        XCTAssertEqual(processing.startProgress, 0)
        XCTAssertEqual(processing.endProgress, 1)
    }

    func testReduceMotionKeepsProcessingHighlightStaticAndBounded() {
        let motion = VoiceThreadProcessingMotion.make(mode: .processing, reduceMotion: true)

        XCTAssertTrue(motion.showsHighlight)
        XCTAssertFalse(motion.animatesHighlight)
        XCTAssertEqual(motion.startProgress, 0.5)
        XCTAssertEqual(motion.endProgress, 0.5)
        XCTAssertTrue((0...1).contains(motion.startProgress))
        XCTAssertTrue((0...1).contains(motion.endProgress))
    }
}
