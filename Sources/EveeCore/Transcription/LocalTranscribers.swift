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
    func unload()
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
        try await load()
        guard let manager = lock.withLock({ manager }) else { throw TranscriptionError.modelUnavailable }
        let hint = normalizedLanguage(languageCode).flatMap(Language.init(rawValue:))
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(fileURL, decoderState: &decoderState, language: hint)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyResult }
        return text
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
        try await load()
        guard let manager = lock.withLock({ manager }) else { throw TranscriptionError.modelUnavailable }
        let samples = try AudioSamples.mono16k(from: fileURL)
        let text = try await manager.transcribe(audioSamples: samples, language: normalizedLanguage(languageCode))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyResult }
        return text
    }

    public func unload() { lock.withLock { manager = nil } }
}

private func normalizedLanguage(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.lowercased() != "auto" else { return nil }
    return value.lowercased()
}

private enum AudioSamples {
    static func mono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw AudioCaptureError.invalidFormat }

        let ratio = 16_000 / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(max(16_000, Double(file.length) * ratio + 1))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw AudioCaptureError.invalidFormat }
        var read = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if read { status.pointee = .endOfStream; return nil }
            read = true
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            do { try file.read(into: input); status.pointee = .haveData; return input }
            catch { status.pointee = .noDataNow; return nil }
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0] else { throw AudioCaptureError.invalidFormat }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
