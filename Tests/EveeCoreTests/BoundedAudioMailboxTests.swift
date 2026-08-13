import AVFoundation
@testable import EveeCore
import XCTest

final class BoundedAudioMailboxTests: XCTestCase {
    func testCapacityOneRetainsNewestValue() async {
        let mailbox = BoundedAudioMailbox<Int>(capacity: 1)

        mailbox.send(1)
        mailbox.send(2)
        mailbox.close(mode: .drain)

        let retained = await mailbox.next()
        let finished = await mailbox.next()
        XCTAssertEqual(retained, 2)
        XCTAssertNil(finished)
        XCTAssertEqual(mailbox.depth, 0)
        XCTAssertEqual(mailbox.peakDepth, 1)
        XCTAssertEqual(mailbox.droppedCount, 1)
    }

    func testFullMailboxRetainsNewestValuesInOrder() async {
        let mailbox = BoundedAudioMailbox<Int>(capacity: 3)

        for value in 0..<5 { mailbox.send(value) }
        mailbox.close(mode: .drain)

        let retained = await drain(mailbox)
        XCTAssertEqual(retained, [2, 3, 4])
        XCTAssertEqual(mailbox.peakDepth, 3)
        XCTAssertEqual(mailbox.droppedCount, 2)
    }

    func testSendAwakensSuspendedConsumer() async {
        let mailbox = BoundedAudioMailbox<Int>(capacity: 1)
        let consumer = Task { await mailbox.next() }
        try? await Task.sleep(for: .milliseconds(20))

        mailbox.send(42)

        let received = await consumer.value
        XCTAssertEqual(received, 42)
        XCTAssertEqual(mailbox.depth, 0)
        mailbox.close(mode: .discard)
    }

    func testCloseAwakensSuspendedConsumerWithNil() async {
        let mailbox = BoundedAudioMailbox<Int>(capacity: 1)
        let consumer = Task { await mailbox.next() }
        try? await Task.sleep(for: .milliseconds(20))

        mailbox.close(mode: .drain)

        let received = await consumer.value
        XCTAssertNil(received)
    }

    func testDrainCloseDeliversBufferedValuesBeforeNil() async {
        let mailbox = BoundedAudioMailbox<Int>(capacity: 3)
        mailbox.send(10)
        mailbox.send(11)

        mailbox.close(mode: .drain)

        let first = await mailbox.next()
        let second = await mailbox.next()
        let finished = await mailbox.next()
        XCTAssertEqual(first, 10)
        XCTAssertEqual(second, 11)
        XCTAssertNil(finished)
    }

    func testDiscardCloseDropsBufferedValues() async {
        let mailbox = BoundedAudioMailbox<Int>(capacity: 3)
        mailbox.send(10)
        mailbox.send(11)

        mailbox.close(mode: .discard)

        XCTAssertEqual(mailbox.depth, 0)
        let received = await mailbox.next()
        XCTAssertNil(received)
    }

    func testRepeatedCloseKeepsFirstCloseMode() async {
        let draining = BoundedAudioMailbox<Int>(capacity: 2)
        draining.send(1)
        draining.close(mode: .drain)
        draining.close(mode: .discard)
        let retained = await draining.next()
        let drained = await draining.next()
        XCTAssertEqual(retained, 1)
        XCTAssertNil(drained)

        let discarding = BoundedAudioMailbox<Int>(capacity: 2)
        discarding.send(1)
        discarding.close(mode: .discard)
        discarding.close(mode: .drain)
        let discarded = await discarding.next()
        XCTAssertNil(discarded)
    }

    func testConcurrentProducersKeepDepthBounded() async {
        let mailbox = BoundedAudioMailbox<Int>(capacity: 8)

        DispatchQueue.concurrentPerform(iterations: 1_000) { mailbox.send($0) }

        XCTAssertEqual(mailbox.depth, 8)
        XCTAssertEqual(mailbox.peakDepth, 8)
        XCTAssertEqual(mailbox.droppedCount, 992)
        mailbox.close(mode: .discard)
    }

    func testCopiedAudioBufferOwnsIndependentPCMBytes() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        source.frameLength = 2
        let sourceSamples = try XCTUnwrap(source.floatChannelData?[0])
        sourceSamples[0] = 0.25
        sourceSamples[1] = -0.5

        let copied = try XCTUnwrap(CopiedAudioBuffer(copying: source))
        sourceSamples[0] = 1
        sourceSamples[1] = 1

        let copiedSamples = try XCTUnwrap(copied.buffer.floatChannelData?[0])
        XCTAssertEqual(copiedSamples[0], 0.25)
        XCTAssertEqual(copiedSamples[1], -0.5)
    }

    private func drain<Element: Sendable>(_ mailbox: BoundedAudioMailbox<Element>) async -> [Element] {
        var values: [Element] = []
        while let value = await mailbox.next() { values.append(value) }
        return values
    }
}
