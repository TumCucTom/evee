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
        guard let copy = Self.copy(source) else { return }
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(copy)
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let sourceData = sourceBuffers[index].mData, let destinationData = destinationBuffers[index].mData else { continue }
            let byteCount = min(Int(sourceBuffers[index].mDataByteSize), Int(destinationBuffers[index].mDataByteSize))
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return copy
    }
}
