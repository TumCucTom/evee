@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

public enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case invalidFormat
    case notRecording
    case alreadyRecording
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is required."
        case .invalidFormat: "The selected microphone did not provide a usable audio format."
        case .notRecording: "No recording is active."
        case .alreadyRecording: "A recording is already active."
        case .writeFailed(let message): "The microphone recording could not be written: \(message)"
        }
    }
}

@MainActor
public final class MicrophoneRecorder: ObservableObject {
    @Published public private(set) var level: Float = 0
    @Published public private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private let writeErrors = AudioWriteErrorState()
    private var file: AVAudioFile?
    private var outputURL: URL?
    private let bufferRelay = AudioBufferRelay()
    private var levelMeter: MicrophoneLevelMeter?

    public init() {}

    public func setBufferHandler(_ handler: (@Sendable (CopiedAudioBuffer) -> Void)?) {
        bufferRelay.set(handler)
    }

    public static var isPermissionGranted: Bool {
        authorizationState == .granted
    }

    public static var authorizationState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func requestPermission() async -> Bool {
        if #available(macOS 14, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return false
    }

    public func start(at url: URL, deviceUID: String? = nil, lowLatency: Bool = false) async throws {
        guard !isRecording else { throw AudioCaptureError.alreadyRecording }
        guard await requestPermission() else { throw AudioCaptureError.microphoneDenied }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = engine.inputNode
        if let deviceUID, !deviceUID.isEmpty, let deviceID = AudioInputDevices.deviceID(forUID: deviceUID) {
            guard let audioUnit = input.audioUnit else { throw AudioCaptureError.invalidFormat }
            var selected = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selected,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw AudioCaptureError.invalidFormat }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.invalidFormat }

        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        let levelMeter = MicrophoneLevelMeter { [weak self] level in self?.level = level }
        levelMeter.start()
        self.levelMeter = levelMeter
        writeErrors.reset()
        let writeErrors = self.writeErrors
        let bufferRelay = self.bufferRelay
        input.installTap(onBus: 0, bufferSize: lowLatency ? 256 : 1_024, format: format) { buffer, _ in
            do {
                try output.write(from: buffer)
            } catch {
                writeErrors.record(error)
            }
            let channel = buffer.floatChannelData?[0]
            let count = Int(buffer.frameLength)
            guard let channel, count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += channel[index] * channel[index] }
            let rms = sqrt(sum / Float(count))
            levelMeter.offer(min(1, rms * 14))
            bufferRelay.publishCopy(of: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            file = output
            outputURL = url
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            await levelMeter.cancel()
            self.levelMeter = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func stop() async throws -> URL {
        guard isRecording, let outputURL else { throw AudioCaptureError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        self.outputURL = nil
        isRecording = false
        if let levelMeter { await levelMeter.finish() }
        self.levelMeter = nil
        level = 0
        if let writeError = writeErrors.take() {
            throw AudioCaptureError.writeFailed(writeError.localizedDescription)
        }
        return outputURL
    }
}

private final class AudioWriteErrorState: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if self.error == nil { self.error = error }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        error = nil
    }

    func take() -> Error? {
        lock.lock(); defer { lock.unlock() }
        defer { error = nil }
        return error
    }
}
