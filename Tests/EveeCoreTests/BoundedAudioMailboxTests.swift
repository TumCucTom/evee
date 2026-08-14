@preconcurrency import AVFoundation
@_spi(Testing) @testable import EveeCore
import FluidAudio
import XCTest

final class BoundedAudioMailboxTests: XCTestCase {
    func testDetachWaitsForSnapshottedHandlerBeforeDrain() async throws {
        let relay = AudioBufferRelay()
        let mailbox = BoundedAudioMailbox<CopiedAudioBuffer>(capacity: 1)
        let handlerEntered = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let detachReturned = DispatchSemaphore(value: 0)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        source.frameLength = 1

        relay.set { copied in
            handlerEntered.signal()
            releaseHandler.wait()
            mailbox.send(copied)
        }
        DispatchQueue.global().async { relay.publishCopy(of: source) }
        XCTAssertEqual(handlerEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            relay.detachAndWait()
            detachReturned.signal()
        }
        XCTAssertEqual(detachReturned.wait(timeout: .now() + 0.05), .timedOut)

        releaseHandler.signal()
        XCTAssertEqual(detachReturned.wait(timeout: .now() + 1), .success)
        mailbox.close(mode: .drain)
        let retained = await mailbox.next()
        XCTAssertNotNil(retained)
    }

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

    func testSlowRecognizerKeepsEveeMailboxBoundedAndGracefulFinishForwardsFinalText() async throws {
        let recognizer = TestLiveAudioRecognizer(finalText: "Final flush")
        await recognizer.setAudioBlocked(true)
        let transcriber = LiveMeetingTranscriber(testingMicrophone: recognizer)
        try await transcriber.start(includeSystem: false)
        let copied = try makeCopiedBuffer()

        transcriber.acceptMicrophone(copied)
        while await recognizer.receivedBufferCount == 0 { await Task.yield() }
        for _ in 0..<100 { transcriber.acceptMicrophone(copied) }

        let metrics = transcriber.microphoneMailboxMetrics
        XCTAssertEqual(metrics.depth, 32)
        XCTAssertEqual(metrics.peakDepth, 32)
        XCTAssertGreaterThan(metrics.droppedCount, 0)

        let forwarded = Task {
            var updates: [LiveMeetingTranscriptUpdate] = []
            for await update in transcriber.updates { updates.append(update) }
            return updates
        }
        await recognizer.setAudioBlocked(false)
        await transcriber.stop()

        let updates = await forwarded.value
        XCTAssertEqual(updates.last?.text, "Final flush")
        XCTAssertEqual(updates.last?.isConfirmed, true)
        XCTAssertEqual(updates.last?.isFinal, true)
        let gracefulFinishCount = await recognizer.finishCount
        let gracefulCancelCount = await recognizer.cancelCount
        XCTAssertEqual(gracefulFinishCount, 1)
        XCTAssertEqual(gracefulCancelCount, 0)

        let cancelledRecognizer = TestLiveAudioRecognizer(finalText: "Should not finish")
        let cancelledTranscriber = LiveMeetingTranscriber(testingMicrophone: cancelledRecognizer)
        try await cancelledTranscriber.start(includeSystem: false)
        await cancelledTranscriber.stop(discardPendingAudio: true)
        let discardFinishCount = await cancelledRecognizer.finishCount
        let discardCancelCount = await cancelledRecognizer.cancelCount
        XCTAssertEqual(discardFinishCount, 0)
        XCTAssertEqual(discardCancelCount, 1)
    }

    private func drain<Element: Sendable>(_ mailbox: BoundedAudioMailbox<Element>) async -> [Element] {
        var values: [Element] = []
        while let value = await mailbox.next() { values.append(value) }
        return values
    }

    private func makeCopiedBuffer() throws -> CopiedAudioBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        source.frameLength = 1
        return try XCTUnwrap(CopiedAudioBuffer(copying: source))
    }
}

private actor TestLiveAudioRecognizer: LiveAudioRecognizing {
    nonisolated let transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>
    private nonisolated let continuation: AsyncStream<SlidingWindowTranscriptionUpdate>.Continuation
    private var audioWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockAudio = false
    private(set) var receivedBufferCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private let finalText: String

    init(finalText: String) {
        self.finalText = finalText
        let pair = AsyncStream<SlidingWindowTranscriptionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(4))
        transcriptionUpdates = pair.stream
        continuation = pair.continuation
    }

    func setAudioBlocked(_ blocked: Bool) {
        shouldBlockAudio = blocked
        guard !blocked else { return }
        let waiters = audioWaiters
        audioWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func streamAudio(_ buffer: AVAudioPCMBuffer) async {
        receivedBufferCount += 1
        if shouldBlockAudio {
            await withCheckedContinuation { audioWaiters.append($0) }
        }
    }

    func finish() async throws -> String {
        finishCount += 1
        continuation.finish()
        return finalText
    }

    func cancel() async {
        cancelCount += 1
        setAudioBlocked(false)
        continuation.finish()
    }
}
