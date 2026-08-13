import Foundation

/// The smallest durable checkpoint contract required before AppKit may allow
/// normal termination. Capture lifecycle work can compose additional steps
/// behind this interface without changing the application delegate.
@MainActor
public protocol ApplicationTerminationCheckpoint: AnyObject {
    func checkpointForApplicationTermination() async throws
}

public enum ApplicationTerminationDecision: Equatable, Sendable {
    case terminateLater
}

/// Joins repeated quit requests to one checkpoint task and emits one AppKit
/// reply for that attempt. A failed attempt resets so a later user quit can
/// retry after the actionable problem is resolved.
@MainActor
public final class ApplicationTerminationCoordinator {
    private enum State {
        case idle
        case checkpointing(UInt64)
        case allowed
    }

    private var state: State = .idle
    private var sequence: UInt64 = 0
    private var task: Task<Void, Never>?

    public init() {}

    @discardableResult
    public func requestTermination(
        checkpoint: any ApplicationTerminationCheckpoint,
        reply: @escaping @MainActor (Bool) -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) -> ApplicationTerminationDecision {
        switch state {
        case .checkpointing, .allowed:
            return .terminateLater
        case .idle:
            break
        }

        sequence &+= 1
        let attempt = sequence
        state = .checkpointing(attempt)
        task = Task { @MainActor [self] in
            do {
                try await checkpoint.checkpointForApplicationTermination()
                finish(attempt: attempt, result: .success(()), reply: reply, reportFailure: reportFailure)
            } catch {
                finish(attempt: attempt, result: .failure(error), reply: reply, reportFailure: reportFailure)
            }
        }
        return .terminateLater
    }

    private func finish(
        attempt: UInt64,
        result: Result<Void, Error>,
        reply: @escaping @MainActor (Bool) -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard case .checkpointing(attempt) = state else { return }
        task = nil
        switch result {
        case .success:
            state = .allowed
            reply(true)
        case .failure(let error):
            state = .idle
            reportFailure(error)
            reply(false)
        }
    }
}
