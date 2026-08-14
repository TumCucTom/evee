import Foundation

/// One retained, throttled consumer for high-rate audio levels. Producers only
/// overwrite a capacity-one mailbox and never create work items of their own.
@MainActor
public final class MicrophoneLevelMeter {
    private nonisolated let mailbox = BoundedAudioMailbox<Float>(capacity: 1)
    private let updateInterval: Duration
    private let publish: @MainActor @Sendable (Float) -> Void
    private var consumerTask: Task<Void, Never>?
    public private(set) var consumerStartCount = 0

    public init(
        updateInterval: Duration = .milliseconds(40),
        publish: @escaping @MainActor @Sendable (Float) -> Void
    ) {
        self.updateInterval = updateInterval
        self.publish = publish
    }

    public func start() {
        guard consumerTask == nil else { return }
        consumerStartCount += 1
        let mailbox = mailbox
        let updateInterval = updateInterval
        let publish = publish
        consumerTask = Task { @MainActor in
            while let level = await mailbox.next() {
                guard !Task.isCancelled else { break }
                publish(level)
                try? await Task.sleep(for: updateInterval)
            }
        }
    }

    public nonisolated func offer(_ level: Float) {
        mailbox.send(level)
    }

    public func finish() async {
        mailbox.close(mode: .drain)
        if let consumerTask { await consumerTask.value }
        consumerTask = nil
        publish(0)
    }

    public func cancel() async {
        mailbox.close(mode: .discard)
        consumerTask?.cancel()
        if let consumerTask { await consumerTask.value }
        consumerTask = nil
        publish(0)
    }

    public nonisolated var metrics: AudioMailboxMetrics { mailbox.metrics }
    public var isConsumerActive: Bool { consumerTask != nil }
}
