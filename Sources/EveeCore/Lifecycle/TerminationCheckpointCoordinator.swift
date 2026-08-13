import Foundation

/// The durable work that must finish before an active capture may allow normal
/// application termination.
@MainActor
public protocol CaptureCheckpointing: AnyObject {
    var terminationWorkGeneration: UInt64 { get }
    @discardableResult func prepareForTerminationCheckpoint() -> UInt64
    func checkpointForTermination() async throws
}

public extension CaptureCheckpointing {
    var terminationWorkGeneration: UInt64 { 0 }
    func prepareForTerminationCheckpoint() -> UInt64 { terminationWorkGeneration }
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

/// Retains an operation that can cross a termination request. The quit path
/// joins the exact task that started the work; it never starts a duplicate.
public actor TerminationOwnedOperation<Value: Sendable> {
    private struct InFlight {
        var id: UInt64
        var task: Task<Value, Error>
    }

    private var sequence: UInt64 = 0
    private var inFlight: InFlight?

    public init() {}

    @discardableResult
    public func begin(
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, Error> {
        if let inFlight { return inFlight.task }
        sequence &+= 1
        let id = sequence
        let task = Task { try await operation() }
        inFlight = InFlight(id: id, task: task)
        return task
    }

    public func join() async throws -> Value? {
        guard let operation = inFlight else { return nil }
        do {
            let value = try await operation.task.value
            if inFlight?.id == operation.id { inFlight = nil }
            return value
        } catch {
            if inFlight?.id == operation.id { inFlight = nil }
            throw error
        }
    }

    public func cancelAndJoin() async throws -> Value? {
        cancel()
        return try await join()
    }

    public func cancel() {
        inFlight?.task.cancel()
    }

    public var isActive: Bool { inFlight != nil }
}

/// Synchronous admission gate shared by capture and recovery entry points.
/// Starting work advances the generation used by the termination reply owner;
/// a prepared checkpoint closes admission before any caller can suspend.
public struct TerminationWorkGate: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isCheckpointActive = false

    public init() {}

    public mutating func prepareCheckpoint() -> UInt64 {
        if !isCheckpointActive {
            isCheckpointActive = true
            generation &+= 1
        }
        return generation
    }

    public mutating func beginWork() -> Bool {
        guard !isCheckpointActive else { return false }
        generation &+= 1
        return true
    }

    /// A failed quit keeps the app open, so recovery actions must become
    /// available again. A later quit prepares a fresh generation.
    public mutating func resumeAfterCheckpointFailure() {
        isCheckpointActive = false
    }
}
