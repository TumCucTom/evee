import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import FluidAudio

public enum SystemAudioRecorderError: LocalizedError, Sendable {
    case alreadyRecording
    case noDisplay
    case cannotEncode
    case captureStopped(String)
    case appendFailed(String)
    case droppedSamples(Int)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "System-audio capture is already active."
        case .noDisplay: return "No display is available for system-audio capture."
        case .cannotEncode: return "System audio could not be encoded."
        case .captureStopped(let message): return "System-audio capture stopped unexpectedly: \(message)"
        case .appendFailed(let message): return "System audio could not be written: \(message)"
        case .droppedSamples(let count): return "System audio could not keep up and dropped \(count) audio sample buffer\(count == 1 ? "" : "s")."
        case .invalidOutput: return "System audio finished, but the resulting recording was not playable."
        }
    }
}

public struct SystemAudioCaptureSummary: Equatable, Sendable {
    public var outputURL: URL
    public var sampleCount: Int
    public var droppedSampleCount: Int
    public var byteCount: Int64
    public var duration: TimeInterval
    public var wroteAudio: Bool

    public init(
        outputURL: URL,
        sampleCount: Int,
        droppedSampleCount: Int = 0,
        byteCount: Int64 = 0,
        duration: TimeInterval = 0,
        wroteAudio: Bool
    ) {
        self.outputURL = outputURL
        self.sampleCount = sampleCount
        self.droppedSampleCount = droppedSampleCount
        self.byteCount = byteCount
        self.duration = duration
        self.wroteAudio = wroteAudio
    }
}

@available(macOS 14, *)
public final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private enum State {
        case idle
        case starting
        case recording
        case stopping
    }

    private let queue = DispatchQueue(label: "com.tumcuctom.evee.system-audio")
    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var outputURL: URL?
    private var startedSession = false
    private var sampleCount = 0
    private var droppedSampleCount = 0
    private var terminalError: Error?
    private var state: State = .idle
    private let bufferRelay = AudioBufferRelay()
    private let audioConverter = AudioConverter()

    public override init() {}

    public func setBufferHandler(_ handler: (@Sendable (CopiedAudioBuffer) -> Void)?) {
        bufferRelay.set(handler)
    }

    public func start(at url: URL) async throws {
        let canStart = lock.withLock { () -> Bool in
            guard case .idle = state else { return false }
            state = .starting
            terminalError = nil
            sampleCount = 0
            droppedSampleCount = 0
            return true
        }
        guard canStart else { throw SystemAudioRecorderError.alreadyRecording }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw SystemAudioRecorderError.noDisplay }

            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw SystemAudioRecorderError.cannotEncode }
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
                self.outputURL = url
                self.startedSession = false
            }
            try await stream.startCapture()
            lock.withLock { state = .recording }
        } catch {
            lock.withLock {
                writer?.cancelWriting()
                stream = nil
                writer = nil
                input = nil
                outputURL = nil
                startedSession = false
                state = .idle
            }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Stops capture and finalises the M4A. A capture containing no system-audio samples is
    /// successful but produces no file, allowing callers to keep a valid microphone track.
    @discardableResult
    public func stopWithSummary() async throws -> SystemAudioCaptureSummary? {
        let active = lock.withLock { () -> SCStream? in
            guard case .recording = state else { return nil }
            state = .stopping
            return stream
        }
        guard let active else { return nil }

        var stopError: Error?
        do { try await active.stopCapture() } catch { stopError = error }

        let values = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?, URL?, Int, Int, Error?) in
            defer {
                stream = nil
                writer = nil
                input = nil
                outputURL = nil
                startedSession = false
                sampleCount = 0
                droppedSampleCount = 0
                terminalError = nil
                state = .idle
            }
            return (writer, input, outputURL, sampleCount, droppedSampleCount, terminalError)
        }

        guard let writer = values.0, let url = values.2 else { return nil }

        guard values.3 > 0, writer.status == .writing else {
            let writerError = writer.error
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            if let error = values.5 { throw error }
            if let error = stopError { throw error }
            if let writerError { throw writerError }
            return SystemAudioCaptureSummary(
                outputURL: url,
                sampleCount: 0,
                droppedSampleCount: values.4,
                wroteAudio: false
            )
        }

        values.1?.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        let validation: (byteCount: Int64, duration: TimeInterval)
        do {
            validation = try await validateOutput(at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        // A capture/stream failure may still leave a useful, valid prefix. Keep that file
        // available to the caller, but report the degradation rather than claiming success.
        if let error = values.5 { throw error }
        if let error = stopError { throw error }
        return SystemAudioCaptureSummary(
            outputURL: url,
            sampleCount: values.3,
            droppedSampleCount: values.4,
            byteCount: validation.byteCount,
            duration: validation.duration,
            wroteAudio: true
        )
    }

    public func stop() async throws {
        if let summary = try await stopWithSummary(), summary.droppedSampleCount > 0 {
            throw SystemAudioRecorderError.droppedSamples(summary.droppedSampleCount)
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let appended = lock.withLock { () -> Bool in
            guard case .recording = state, terminalError == nil, let writer, let input else { return false }
            if !startedSession {
                guard writer.startWriting() else {
                    terminalError = SystemAudioRecorderError.appendFailed(writer.error?.localizedDescription ?? "The encoder did not start.")
                    return false
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                startedSession = true
            }
            guard input.isReadyForMoreMediaData else {
                droppedSampleCount += 1
                return false
            }
            if input.append(sampleBuffer) {
                sampleCount += 1
                return true
            } else {
                terminalError = SystemAudioRecorderError.appendFailed(writer.error?.localizedDescription ?? "The encoder rejected an audio sample.")
                return false
            }
        }
        if appended, let pcm = try? audioConverter.extractAVAudioPCMBuffer(from: sampleBuffer) {
            bufferRelay.publishCopy(of: pcm)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            if case .stopping = state { return }
            terminalError = SystemAudioRecorderError.captureStopped(error.localizedDescription)
        }
    }

    private func validateOutput(at url: URL) async throws -> (byteCount: Int64, duration: TimeInterval) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else { throw SystemAudioRecorderError.invalidOutput }

        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard playable, seconds.isFinite, seconds > 0 else {
            throw SystemAudioRecorderError.invalidOutput
        }
        return (byteCount, seconds)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
