import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum SystemAudioRecorderError: LocalizedError, Sendable {
    case alreadyRecording
    case noDisplay
    case cannotEncode
    case captureStopped(String)
    case appendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "System-audio capture is already active."
        case .noDisplay: return "No display is available for system-audio capture."
        case .cannotEncode: return "System audio could not be encoded."
        case .captureStopped(let message): return "System-audio capture stopped unexpectedly: \(message)"
        case .appendFailed(let message): return "System audio could not be written: \(message)"
        }
    }
}

public struct SystemAudioCaptureSummary: Equatable, Sendable {
    public var outputURL: URL
    public var sampleCount: Int
    public var wroteAudio: Bool

    public init(outputURL: URL, sampleCount: Int, wroteAudio: Bool) {
        self.outputURL = outputURL
        self.sampleCount = sampleCount
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
    private var terminalError: Error?
    private var state: State = .idle

    public override init() {}

    public func start(at url: URL) async throws {
        let canStart = lock.withLock { () -> Bool in
            guard case .idle = state else { return false }
            state = .starting
            terminalError = nil
            sampleCount = 0
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

        let values = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?, URL?, Int, Error?) in
            defer {
                stream = nil
                writer = nil
                input = nil
                outputURL = nil
                startedSession = false
                sampleCount = 0
                terminalError = nil
                state = .idle
            }
            return (writer, input, outputURL, sampleCount, terminalError)
        }

        if let error = values.4 { throw error }
        if let error = stopError { throw error }
        guard let writer = values.0, let url = values.2 else { return nil }

        guard values.3 > 0, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return SystemAudioCaptureSummary(outputURL: url, sampleCount: 0, wroteAudio: false)
        }

        values.1?.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return SystemAudioCaptureSummary(outputURL: url, sampleCount: values.3, wroteAudio: true)
    }

    public func stop() async throws {
        _ = try await stopWithSummary()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.withLock {
            guard case .recording = state, terminalError == nil, let writer, let input else { return }
            if !startedSession {
                guard writer.startWriting() else {
                    terminalError = SystemAudioRecorderError.appendFailed(writer.error?.localizedDescription ?? "The encoder did not start.")
                    return
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                startedSession = true
            }
            guard input.isReadyForMoreMediaData else { return }
            if input.append(sampleBuffer) {
                sampleCount += 1
            } else {
                terminalError = SystemAudioRecorderError.appendFailed(writer.error?.localizedDescription ?? "The encoder rejected an audio sample.")
            }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            if case .stopping = state { return }
            terminalError = SystemAudioRecorderError.captureStopped(error.localizedDescription)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
