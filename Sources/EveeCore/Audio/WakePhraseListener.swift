@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import FluidAudio
import Foundation

public actor WakePhraseListener: WakePhraseListening {
    public nonisolated let transcripts: AsyncStream<String>
    private nonisolated let continuation: AsyncStream<String>.Continuation
    private let engine = AVAudioEngine()
    private let relay = AudioBufferRelay()
    private let session = SlidingWindowAsrSession()
    private var manager: SlidingWindowAsrManager?
    private var updateTask: Task<Void, Never>?
    private var isRunning = false

    public init() {
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(20))
        transcripts = pair.stream
        continuation = pair.continuation
    }

    public func start(deviceUID: String? = nil, lowLatency: Bool = true) async throws {
        guard !isRunning else { return }
        let manager = try await session.createStream(source: .microphone, config: .streaming)
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
        relay.set { [weak manager] buffer in Task { await manager?.streamAudio(buffer) } }
        let relay = self.relay
        input.installTap(onBus: 0, bufferSize: lowLatency ? 256 : 1_024, format: format) { buffer, _ in
            relay.publishCopy(of: buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            self.manager = manager
            isRunning = true
            let continuation = self.continuation
            updateTask = Task {
                for await update in await manager.transcriptionUpdates {
                    guard !Task.isCancelled else { return }
                    let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { continuation.yield(text) }
                }
            }
        } catch {
            input.removeTap(onBus: 0)
            relay.set(nil)
            await session.cleanup()
            throw error
        }
    }

    public func stop() async {
        guard isRunning || manager != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        relay.set(nil)
        if let manager { _ = try? await manager.finish() }
        updateTask?.cancel()
        updateTask = nil
        await session.cleanup()
        manager = nil
        isRunning = false
    }
}
