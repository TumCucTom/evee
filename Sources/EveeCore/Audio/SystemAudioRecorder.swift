import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 14, *)
public final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tumcuctom.evee.system-audio")
    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startedSession = false

    public override init() {}

    public func start(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Evee.ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display is available for system-audio capture."])
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "Evee.ScreenCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "System audio could not be encoded."])
        }
        writer.add(input)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        lock.withLock {
            self.writer = writer
            self.input = input
            self.stream = stream
            self.startedSession = false
        }
        try await stream.startCapture()
    }

    public func stop() async throws {
        let active = lock.withLock { stream }
        try await active?.stopCapture()
        let values = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?) in
            defer { stream = nil; writer = nil; input = nil; startedSession = false }
            return (writer, input)
        }
        guard let writer = values.0, writer.status == .writing else { return }
        values.1?.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.withLock {
            guard let writer, let input else { return }
            if !startedSession {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                startedSession = true
            }
            if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.stream = nil }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
