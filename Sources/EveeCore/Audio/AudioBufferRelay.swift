@preconcurrency import AVFoundation
import Foundation

final class AudioBufferRelay: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void
    private let lock = NSLock()
    private var handler: Handler?

    func set(_ handler: Handler?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    func publishCopy(of source: AVAudioPCMBuffer) {
        guard let copy = CopiedAudioBuffer(copying: source) else { return }
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(copy.buffer)
    }
}
