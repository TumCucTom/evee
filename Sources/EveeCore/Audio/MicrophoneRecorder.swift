@preconcurrency import AVFoundation
import Foundation

public enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case invalidFormat
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is required."
        case .invalidFormat: "The selected microphone did not provide a usable audio format."
        case .notRecording: "No recording is active."
        }
    }
}

@MainActor
public final class MicrophoneRecorder: ObservableObject {
    @Published public private(set) var level: Float = 0
    @Published public private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var outputURL: URL?

    public init() {}

    public func requestPermission() async -> Bool {
        if #available(macOS 14, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return false
    }

    public func start(at url: URL) async throws {
        guard await requestPermission() else { throw AudioCaptureError.microphoneDenied }
        guard !isRecording else { return }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.invalidFormat }

        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            try? output.write(from: buffer)
            let channel = buffer.floatChannelData?[0]
            let count = Int(buffer.frameLength)
            guard let channel, count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += channel[index] * channel[index] }
            let rms = sqrt(sum / Float(count))
            Task { @MainActor in self?.level = min(1, rms * 14) }
        }

        engine.prepare()
        try engine.start()
        file = output
        outputURL = url
        isRecording = true
    }

    public func stop() throws -> URL {
        guard isRecording, let outputURL else { throw AudioCaptureError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        self.outputURL = nil
        level = 0
        isRecording = false
        return outputURL
    }
}
