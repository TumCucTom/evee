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
    private var audioMailbox: BoundedAudioMailbox<CopiedAudioBuffer>?
    private var audioConsumerTask: Task<Void, Never>?
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
        let mailbox = BoundedAudioMailbox<CopiedAudioBuffer>(capacity: 32)
        let audioConsumerTask = Task {
            while let copied = await mailbox.next() {
                await manager.streamAudio(copied.buffer)
            }
        }
        relay.set { mailbox.send($0) }
        let relay = self.relay
        input.installTap(onBus: 0, bufferSize: lowLatency ? 256 : 1_024, format: format) { buffer, _ in
            relay.publishCopy(of: buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            self.manager = manager
            audioMailbox = mailbox
            self.audioConsumerTask = audioConsumerTask
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
            relay.detachAndWait()
            mailbox.close(mode: .discard)
            await audioConsumerTask.value
            await session.cleanup()
            throw error
        }
    }

    public func stop() async {
        guard isRunning || manager != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        relay.detachAndWait()
        audioMailbox?.close(mode: .discard)
        if let audioConsumerTask { await audioConsumerTask.value }
        if let manager { await manager.cancel() }
        updateTask?.cancel()
        if let updateTask { await updateTask.value }
        updateTask = nil
        audioConsumerTask = nil
        audioMailbox = nil
        await session.cleanup()
        manager = nil
        isRunning = false
    }
}
