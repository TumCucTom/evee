import AVFoundation
import FluidAudio
import Foundation

public struct ModelProgress: Sendable {
    public var fraction: Double
    public var status: String

    public init(fraction: Double, status: String) {
        self.fraction = fraction
        self.status = status
    }
}

public protocol LocalTranscriber: AnyObject, Sendable {
    var model: SpeechModel { get }
    var isDownloaded: Bool { get }
    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws
    func load() async throws
    func transcribe(fileURL: URL, languageCode: String?) async throws -> String
    func transcribeDetailed(fileURL: URL, languageCode: String?) async throws -> LocalTranscript
    func unload()
}

public extension LocalTranscriber {
    func transcribeDetailed(fileURL: URL, languageCode: String?) async throws -> LocalTranscript {
        let text = try await transcribe(fileURL: fileURL, languageCode: languageCode)
        let asset = AVURLAsset(url: fileURL)
        let duration = max(0, try await asset.load(.duration).seconds)
        return LocalTranscript(
            text: text,
            duration: duration,
            segments: [LocalTranscriptSegment(
                start: 0,
                end: duration,
                text: text,
                timingSource: .trackEstimate
            )]
        )
    }
}

public enum TranscriptionError: LocalizedError {
    case modelNotDownloaded
    case modelUnavailable
    case unsupportedOperatingSystem
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: "Download the selected local speech model first."
        case .modelUnavailable: "The selected local model could not be loaded."
        case .unsupportedOperatingSystem: "Qwen3 ASR requires macOS 15 or newer."
        case .emptyResult: "No speech was recognised."
        }
    }
}

public enum TranscriberFactory {
    public static func make(_ model: SpeechModel) throws -> any LocalTranscriber {
        switch model {
        case .parakeet:
            return ParakeetTranscriber()
        case .qwen3:
            guard #available(macOS 15, *) else { throw TranscriptionError.unsupportedOperatingSystem }
            return QwenTranscriber()
        }
    }
}

public final class ParakeetTranscriber: LocalTranscriber, @unchecked Sendable {
    public let model = SpeechModel.parakeet
    private let lock = NSLock()
    private var manager: AsrManager?

    public init() {}

    public var isDownloaded: Bool {
        let directory = AsrModels.defaultCacheDirectory(for: .v3)
        let required = ModelNames.ASR.requiredModelsV3(precision: .int8)
            .union([ModelNames.ASR.vocabularyFile])
        return required.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    public func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        progress(ModelProgress(fraction: 0, status: "Connecting…"))
        let parent = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        try await DownloadUtils.downloadRepo(.parakeetV3, to: parent, variant: ParakeetEncoderPrecision.int8.rawValue) { update in
            progress(ModelProgress(fraction: min(1, max(0, update.fractionCompleted)), status: "Downloading Parakeet…"))
        }
        progress(ModelProgress(fraction: 1, status: "Ready"))
    }

    public func load() async throws {
        guard isDownloaded else { throw TranscriptionError.modelNotDownloaded }
        if lock.withLock({ manager != nil }) { return }
        let models = try await AsrModels.loadFromCache(version: .v3)
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        lock.withLock { manager = loaded }
    }

    public func transcribe(fileURL: URL, languageCode: String?) async throws -> String {
        try await transcribeDetailed(fileURL: fileURL, languageCode: languageCode).text
    }

    public func transcribeDetailed(fileURL: URL, languageCode: String?) async throws -> LocalTranscript {
        try await load()
        guard let manager = lock.withLock({ manager }) else { throw TranscriptionError.modelUnavailable }
        let hint = normalizedLanguage(languageCode).flatMap(Language.init(rawValue:))
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(fileURL, decoderState: &decoderState, language: hint)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyResult }
        let timings = (result.tokenTimings ?? []).map {
            TranscriptTokenTiming(
                token: $0.token,
                start: TimeInterval($0.startTime),
                end: TimeInterval($0.endTime),
                confidence: $0.confidence
            )
        }
        let duration = TimeInterval(result.duration)
        let segments = TokenTimingSegmenter().segments(
            transcriptText: text,
            duration: duration,
            timings: timings
        )
        return LocalTranscript(text: text, duration: duration, segments: segments)
    }

    public func unload() { lock.withLock { manager = nil } }
}

@available(macOS 15, *)
public final class QwenTranscriber: LocalTranscriber, @unchecked Sendable {
    public let model = SpeechModel.qwen3
    private let lock = NSLock()
    private var manager: Qwen3AsrManager?

    public init() {}

    public var isDownloaded: Bool {
        let directory = Qwen3AsrModels.defaultCacheDirectory()
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelNames.Qwen3ASR.audioEncoderFile).path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelNames.Qwen3ASR.decoderStatefulFile).path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelNames.Qwen3ASR.embeddingsFile).path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocab.json").path)
    }

    public func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        progress(ModelProgress(fraction: 0, status: "Connecting…"))
        _ = try await Qwen3AsrModels.download(variant: .f32) { update in
            progress(ModelProgress(fraction: min(1, max(0, update.fractionCompleted)), status: "Downloading Qwen3 ASR…"))
        }
        progress(ModelProgress(fraction: 1, status: "Ready"))
    }

    public func load() async throws {
        guard isDownloaded else { throw TranscriptionError.modelNotDownloaded }
        if lock.withLock({ manager != nil }) { return }
        let loaded = Qwen3AsrManager()
        try await loaded.loadModels(from: Qwen3AsrModels.defaultCacheDirectory())
        lock.withLock { manager = loaded }
    }

    public func transcribe(fileURL: URL, languageCode: String?) async throws -> String {
        try await transcribeDetailed(fileURL: fileURL, languageCode: languageCode).text
    }

    public func transcribeDetailed(fileURL: URL, languageCode: String?) async throws -> LocalTranscript {
        try await load()
        guard let manager = lock.withLock({ manager }) else { throw TranscriptionError.modelUnavailable }
        let reader = try AudioSampleChunkReader(url: fileURL)
        let language = normalizedLanguage(languageCode)
        var transcripts: [String] = []
        var segments: [LocalTranscriptSegment] = []
        while let chunk = try reader.nextTimed() {
            try Task.checkCancellation()
            let text = try await manager.transcribe(audioSamples: chunk.samples, language: language)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                transcripts.append(text)
                segments.append(LocalTranscriptSegment(
                    start: chunk.start,
                    end: chunk.end,
                    text: text,
                    timingSource: .audioChunk
                ))
            }
        }
        let combined = transcripts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else { throw TranscriptionError.emptyResult }
        return LocalTranscript(text: combined, duration: reader.duration, segments: segments)
    }

    public func unload() { lock.withLock { manager = nil } }
}

private func normalizedLanguage(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.lowercased() != "auto" else { return nil }
    return value.lowercased()
}

/// Incrementally converts source audio to bounded mono 16 kHz chunks. Qwen's public
/// transcription API accepts an in-memory sample array, so bounding each call prevents a
/// long meeting from allocating the entire recording (and a second full-size copy) at once.
final class AudioSampleChunkReader {
    static let defaultChunkDuration: TimeInterval = 25

    private let file: AVAudioFile
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let sourceFramesPerChunk: AVAudioFrameCount

    var duration: TimeInterval {
        guard sourceFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / sourceFormat.sampleRate
    }

    init(url: URL, chunkDuration: TimeInterval = defaultChunkDuration) throws {
        guard chunkDuration.isFinite, chunkDuration > 0,
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
              ) else {
            throw AudioCaptureError.invalidFormat
        }
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard source.sampleRate > 0, source.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }
        let requestedFrames = ceil(source.sampleRate * chunkDuration)
        guard requestedFrames > 0, requestedFrames <= Double(UInt32.max) else {
            throw AudioCaptureError.invalidFormat
        }
        self.file = file
        self.sourceFormat = source
        self.targetFormat = target
        self.sourceFramesPerChunk = AVAudioFrameCount(requestedFrames)
    }

    func next() throws -> [Float]? {
        try nextTimed()?.samples
    }

    func nextTimed() throws -> AudioSampleChunk? {
        guard file.framePosition < file.length else { return nil }
        let sourceStartFrame = file.framePosition
        let remaining = file.length - file.framePosition
        let inputCapacity = AVAudioFrameCount(min(Int64(sourceFramesPerChunk), remaining))
        guard inputCapacity > 0,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
            throw AudioCaptureError.invalidFormat
        }
        try file.read(into: input, frameCount: inputCapacity)
        guard input.frameLength > 0 else { return nil }

        let outputFrames = ceil(Double(input.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 32
        guard outputFrames > 0, outputFrames <= Double(UInt32.max),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(outputFrames)
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioCaptureError.invalidFormat
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            throw AudioCaptureError.invalidFormat
        }
        return AudioSampleChunk(
            samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))),
            start: Double(sourceStartFrame) / sourceFormat.sampleRate,
            end: Double(file.framePosition) / sourceFormat.sampleRate
        )
    }
}

struct AudioSampleChunk {
    var samples: [Float]
    var start: TimeInterval
    var end: TimeInterval
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
