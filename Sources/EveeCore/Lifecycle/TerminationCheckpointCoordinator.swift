import Foundation

/// The durable work that must finish before an active capture may allow normal
/// application termination.
@MainActor
public protocol CaptureCheckpointing: AnyObject {
    func checkpointForTermination() async throws
}

/// Compatibility for integrations installed before capture shutdown joined the
/// application termination checkpoint.
@MainActor
public protocol ApplicationTerminationCheckpoint: CaptureCheckpointing {
    func checkpointForApplicationTermination() async throws
}

public extension ApplicationTerminationCheckpoint {
    func checkpointForTermination() async throws {
        try await checkpointForApplicationTermination()
    }
}

/// Owns one durability operation. Concurrent callers join it, and a failed
/// result is replayed until the caller deliberately begins a retry.
public actor TerminationCheckpointCoordinator {
    private struct InFlight {
        var id: UInt64
        var task: Task<Void, Error>
    }

    private let checkpointer: any CaptureCheckpointing
    private var sequence: UInt64 = 0
    private var inFlight: InFlight?
    private var failedResult: Error?

    public init(checkpointer: any CaptureCheckpointing) {
        self.checkpointer = checkpointer
    }

    public func checkpoint() async throws {
        if let failedResult { throw failedResult }
        if let inFlight {
            try await inFlight.task.value
            return
        }

        sequence &+= 1
        let operationID = sequence
        let checkpointer = self.checkpointer
        let task = Task { @MainActor in
            try await checkpointer.checkpointForTermination()
        }
        inFlight = InFlight(id: operationID, task: task)

        do {
            try await task.value
            if inFlight?.id == operationID { inFlight = nil }
        } catch {
            if inFlight?.id == operationID {
                inFlight = nil
                failedResult = error
            }
            throw error
        }
    }

    public func retry() async throws {
        failedResult = nil
        try await checkpoint()
    }
}
