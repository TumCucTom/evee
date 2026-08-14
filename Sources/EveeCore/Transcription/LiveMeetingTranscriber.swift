@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public struct LiveMeetingTranscriptUpdate: Sendable, Identifiable {
    public var id: UUID
    public var channel: AudioTrackRole
    public var text: String
    public var isConfirmed: Bool
    public var isFinal: Bool
    public var confidence: Float
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        channel: AudioTrackRole,
        text: String,
        isConfirmed: Bool,
        isFinal: Bool = false,
        confidence: Float,
        timestamp: Date
    ) {
        self.id = id
        self.channel = channel
        self.text = text
        self.isConfirmed = isConfirmed
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

public protocol LiveAudioRecognizing: Actor {
    var transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate> { get }
    func streamAudio(_ buffer: AVAudioPCMBuffer) async
    func finish() async throws -> String
    func cancel() async
}

extension SlidingWindowAsrManager: LiveAudioRecognizing {}

public actor LiveMeetingTranscriber {
    public nonisolated let updates: AsyncStream<LiveMeetingTranscriptUpdate>
    private nonisolated let continuation: AsyncStream<LiveMeetingTranscriptUpdate>.Continuation
    private let session = SlidingWindowAsrSession()
    private nonisolated let microphoneMailbox = BoundedAudioMailbox<CopiedAudioBuffer>(capacity: 32)
    private nonisolated let systemMailbox = BoundedAudioMailbox<CopiedAudioBuffer>(capacity: 32)
    private let suppliedMicrophone: (any LiveAudioRecognizing)?
    private let suppliedSystem: (any LiveAudioRecognizing)?
    private var microphone: (any LiveAudioRecognizing)?
    private var system: (any LiveAudioRecognizing)?
    private var audioConsumerTasks: [Task<Void, Never>] = []
    private var updateTasks: [Task<Void, Never>] = []

    public init() {
        suppliedMicrophone = nil
        suppliedSystem = nil
        let pair = AsyncStream<LiveMeetingTranscriptUpdate>.makeStream(bufferingPolicy: .bufferingNewest(100))
        updates = pair.stream
        continuation = pair.continuation
    }

    @_spi(Testing)
    public init(
        testingMicrophone: any LiveAudioRecognizing,
        testingSystem: (any LiveAudioRecognizing)? = nil
    ) {
        suppliedMicrophone = testingMicrophone
        suppliedSystem = testingSystem
        let pair = AsyncStream<LiveMeetingTranscriptUpdate>.makeStream(bufferingPolicy: .bufferingNewest(100))
        updates = pair.stream
        continuation = pair.continuation
    }

    public nonisolated var microphoneMailboxMetrics: AudioMailboxMetrics {
        microphoneMailbox.metrics
    }

    public nonisolated var systemMailboxMetrics: AudioMailboxMetrics {
        systemMailbox.metrics
    }

    public func start(includeSystem: Bool) async throws {
        if let suppliedMicrophone {
            microphone = suppliedMicrophone
            if includeSystem { system = suppliedSystem }
        } else {
            microphone = try await session.createStream(source: .microphone, config: .streaming)
            if includeSystem { system = try await session.createStream(source: .system, config: .streaming) }
        }
        if let microphone {
            consumeAudio(from: microphoneMailbox, with: microphone)
            consumeUpdates(from: microphone, channel: .microphone)
        }
        if let system {
            consumeAudio(from: systemMailbox, with: system)
            consumeUpdates(from: system, channel: .system)
        }
    }

    public nonisolated func acceptMicrophone(_ buffer: CopiedAudioBuffer) {
        microphoneMailbox.send(buffer)
    }

    public nonisolated func acceptSystem(_ buffer: CopiedAudioBuffer) {
        systemMailbox.send(buffer)
    }

    public func stop(discardPendingAudio: Bool = false) async {
        let closeMode: BoundedAudioMailbox<CopiedAudioBuffer>.CloseMode = discardPendingAudio ? .discard : .drain
        microphoneMailbox.close(mode: closeMode)
        systemMailbox.close(mode: closeMode)
        for task in audioConsumerTasks { await task.value }
        audioConsumerTasks.removeAll()

        let microphoneFinal: String?
        let systemFinal: String?
        if discardPendingAudio {
            if let microphone { await microphone.cancel() }
            if let system { await system.cancel() }
            microphoneFinal = nil
            systemFinal = nil
        } else {
            microphoneFinal = if let microphone { try? await microphone.finish() } else { nil }
            systemFinal = if let system { try? await system.finish() } else { nil }
        }
        updateTasks.forEach { $0.cancel() }
        for task in updateTasks { await task.value }
        updateTasks.removeAll()
        if !discardPendingAudio {
            yieldFinal(microphoneFinal, channel: .microphone)
            yieldFinal(systemFinal, channel: .system)
        }
        continuation.finish()
        await session.cleanup()
        self.microphone = nil
        self.system = nil
    }

    private func consumeAudio(
        from mailbox: BoundedAudioMailbox<CopiedAudioBuffer>,
        with manager: any LiveAudioRecognizing
    ) {
        audioConsumerTasks.append(Task {
            while let copied = await mailbox.next() {
                await manager.streamAudio(copied.buffer)
            }
        })
    }

    private func consumeUpdates(from manager: any LiveAudioRecognizing, channel: AudioTrackRole) {
        let continuation = self.continuation
        updateTasks.append(Task {
            for await update in await manager.transcriptionUpdates {
                guard !Task.isCancelled else { return }
                let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                continuation.yield(LiveMeetingTranscriptUpdate(
                    channel: channel,
                    text: text,
                    isConfirmed: update.isConfirmed,
                    confidence: update.confidence,
                    timestamp: update.timestamp
                ))
            }
        })
    }

    private func yieldFinal(_ text: String?, channel: AudioTrackRole) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        // FluidAudio returns the complete text without an aggregate confidence.
        continuation.yield(LiveMeetingTranscriptUpdate(
            channel: channel,
            text: text,
            isConfirmed: true,
            isFinal: true,
            confidence: 0,
            timestamp: .now
        ))
    }
}
