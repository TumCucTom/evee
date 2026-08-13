@preconcurrency import AVFoundation
import Foundation

@_spi(Testing)
public final class AudioBufferRelay: @unchecked Sendable {
    public typealias Handler = @Sendable (CopiedAudioBuffer) -> Void
    private let condition = NSCondition()
    private var handler: Handler?
    private var inFlightHandlerCount = 0

    public init() {}

    public func set(_ handler: Handler?) {
        if handler == nil {
            detachAndWait()
            return
        }
        condition.lock(); defer { condition.unlock() }
        self.handler = handler
    }

    /// Detaches the producer and waits for handlers that already took a snapshot.
    public func detachAndWait() {
        condition.lock()
        handler = nil
        while inFlightHandlerCount > 0 { condition.wait() }
        condition.unlock()
    }

    public func publishCopy(of source: AVAudioPCMBuffer) {
        guard let copy = CopiedAudioBuffer(copying: source) else { return }
        condition.lock()
        guard let handler else {
            condition.unlock()
            return
        }
        inFlightHandlerCount += 1
        condition.unlock()

        handler(copy)

        condition.lock()
        inFlightHandlerCount -= 1
        if inFlightHandlerCount == 0 { condition.broadcast() }
        condition.unlock()
    }
}
