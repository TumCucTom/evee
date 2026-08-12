@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public struct LiveMeetingTranscriptUpdate: Sendable, Identifiable {
    public var id: UUID
    public var channel: AudioTrackRole
    public var text: String
    public var isConfirmed: Bool
    public var confidence: Float
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        channel: AudioTrackRole,
        text: String,
        isConfirmed: Bool,
        confidence: Float,
        timestamp: Date
    ) {
        self.id = id
        self.channel = channel
        self.text = text
        self.isConfirmed = isConfirmed
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

public actor LiveMeetingTranscriber {
    public nonisolated let updates: AsyncStream<LiveMeetingTranscriptUpdate>
    private nonisolated let continuation: AsyncStream<LiveMeetingTranscriptUpdate>.Continuation
    private let session = SlidingWindowAsrSession()
    private var microphone: SlidingWindowAsrManager?
    private var system: SlidingWindowAsrManager?
    private var updateTasks: [Task<Void, Never>] = []

    public init() {
        let pair = AsyncStream<LiveMeetingTranscriptUpdate>.makeStream(bufferingPolicy: .bufferingNewest(100))
        updates = pair.stream
        continuation = pair.continuation
    }

    public func start(includeSystem: Bool) async throws {
        microphone = try await session.createStream(source: .microphone, config: .streaming)
        if includeSystem { system = try await session.createStream(source: .system, config: .streaming) }
        if let microphone { consume(microphone, channel: .microphone) }
        if let system { consume(system, channel: .system) }
    }

    public func acceptMicrophone(_ buffer: AVAudioPCMBuffer) async {
        await microphone?.streamAudio(buffer)
    }

    public func acceptSystem(_ buffer: AVAudioPCMBuffer) async {
        await system?.streamAudio(buffer)
    }

    public func stop() async {
        if let microphone { _ = try? await microphone.finish() }
        if let system { _ = try? await system.finish() }
        updateTasks.forEach { $0.cancel() }
        updateTasks.removeAll()
        await session.cleanup()
        self.microphone = nil
        self.system = nil
    }

    private func consume(_ manager: SlidingWindowAsrManager, channel: AudioTrackRole) {
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
}
