import Foundation

public enum ApplicationTerminationDecision: Equatable, Sendable {
    case terminateNow
    case terminateLater
    case terminateCancel
}

public struct ApplicationTerminationDeadlineError: LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Evee is still saving the active capture. The app stayed open; wait for recovery to finish, then quit again."
    }
}

public struct ApplicationTerminationPlanError: LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct ApplicationTerminationWorkChangedError: LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Evee detected new capture work while saving for quit. The app stayed open; quit again after the current recovery checkpoint finishes."
    }
}

/// The single owner of an AppKit termination reply. Durability continues after
/// a deadline so a late file/manifest write is preserved, while the expired
/// reply operation can never answer AppKit a second time.
@MainActor
public final class ApplicationTerminationCoordinator {
    private let deadline: Duration
    private var sequence: UInt64 = 0
    private var replyOperation: UInt64?
    private var deadlineTask: Task<Void, Never>?
    private var durability: TerminationCheckpointCoordinator?
    private var durabilityOwner: ObjectIdentifier?
    private var retryFailedDurability = false
    private var durabilitySucceeded = false
    private var checkpointedGeneration: UInt64?

    public init(deadline: Duration = .seconds(15)) {
        self.deadline = deadline
    }

    @discardableResult
    public func requestTermination(
        plan: CaptureShutdownPlan,
        checkpoint: any CaptureCheckpointing,
        reply: @escaping @MainActor (Bool) -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) -> ApplicationTerminationDecision {
        switch plan {
        case .terminateImmediately:
            return .terminateNow
        case .cancelTermination(let message):
            reportFailure(ApplicationTerminationPlanError(message: message))
            return .terminateCancel
        case .cancelStartAndCheckpoint,
             .stopWritersAndCheckpoint,
             .awaitDurableCommitOrCheckpoint,
             .invalidateDeliveryAndAwaitCommit,
             .awaitCancellationCleanup:
            break
        }

        let preparedGeneration = checkpoint.prepareForTerminationCheckpoint()
        if durabilitySucceeded, checkpointedGeneration == preparedGeneration { return .terminateNow }
        if replyOperation != nil { return .terminateLater }

        let owner = ObjectIdentifier(checkpoint)
        if durabilityOwner != owner {
            durabilityOwner = owner
            durability = TerminationCheckpointCoordinator(checkpointer: checkpoint)
            retryFailedDurability = false
            durabilitySucceeded = false
            checkpointedGeneration = nil
        }
        guard let durability else { return .terminateCancel }

        sequence &+= 1
        let operationID = sequence
        let operationGeneration = preparedGeneration
        replyOperation = operationID
        let retry = retryFailedDurability
        retryFailedDurability = false

        Task { @MainActor [weak self] in
            do {
                if retry {
                    try await durability.retry()
                } else {
                    try await durability.checkpoint()
                }
                self?.finish(
                    operationID: operationID,
                    operationGeneration: operationGeneration,
                    currentGeneration: checkpoint.terminationWorkGeneration,
                    result: .success(()),
                    reply: reply,
                    reportFailure: reportFailure
                )
            } catch {
                self?.finish(
                    operationID: operationID,
                    operationGeneration: operationGeneration,
                    currentGeneration: checkpoint.terminationWorkGeneration,
                    result: .failure(error),
                    reply: reply,
                    reportFailure: reportFailure
                )
            }
        }
        deadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.deadline ?? .seconds(15))
            } catch {
                return
            }
            self?.expire(operationID: operationID, reply: reply, reportFailure: reportFailure)
        }
        return .terminateLater
    }

    /// Backwards-compatible entry point for the previously installed webhook
    /// checkpoint. It remains terminate-later so persistence is not regressed.
    @discardableResult
    public func requestTermination(
        checkpoint: any ApplicationTerminationCheckpoint,
        reply: @escaping @MainActor (Bool) -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) -> ApplicationTerminationDecision {
        requestTermination(
            plan: .invalidateDeliveryAndAwaitCommit,
            checkpoint: checkpoint,
            reply: reply,
            reportFailure: reportFailure
        )
    }

    private func finish(
        operationID: UInt64,
        operationGeneration: UInt64,
        currentGeneration: UInt64,
        result: Result<Void, Error>,
        reply: @escaping @MainActor (Bool) -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) {
        let validatedResult: Result<Void, Error>
        switch result {
        case .success:
            durabilitySucceeded = operationGeneration == currentGeneration
            checkpointedGeneration = durabilitySucceeded ? operationGeneration : nil
            validatedResult = durabilitySucceeded
                ? .success(())
                : .failure(ApplicationTerminationWorkChangedError())
        case .failure:
            retryFailedDurability = true
            validatedResult = result
        }

        guard replyOperation == operationID else { return }
        replyOperation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        switch validatedResult {
        case .success:
            reply(true)
        case .failure(let error):
            reportFailure(error)
            reply(false)
        }
    }

    private func expire(
        operationID: UInt64,
        reply: @escaping @MainActor (Bool) -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard replyOperation == operationID else { return }
        replyOperation = nil
        deadlineTask = nil
        let error = ApplicationTerminationDeadlineError()
        reportFailure(error)
        reply(false)
    }
}
