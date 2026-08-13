import Foundation

public enum CaptureLifecycleSnapshot: Equatable, Sendable {
    case idle
    case starting(kind: WorkspaceRecordKind, recoveryID: UUID?)
    case recording(kind: WorkspaceRecordKind, recoveryID: UUID?)
    case finishing(recoveryID: UUID?)
    case delivering
    case cancelling
    case failed
}

public enum CaptureShutdownPlan: Equatable, Sendable {
    case terminateImmediately
    case cancelStartAndCheckpoint
    case stopWritersAndCheckpoint(kind: WorkspaceRecordKind, recoveryID: UUID)
    case awaitDurableCommitOrCheckpoint(recoveryID: UUID)
    case invalidateDeliveryAndAwaitCommit
    case awaitCancellationCleanup
    case cancelTermination(message: String)

    public static func make(for snapshot: CaptureLifecycleSnapshot) -> CaptureShutdownPlan {
        switch snapshot {
        case .idle, .failed:
            return .terminateImmediately
        case .starting(_, let recoveryID):
            guard recoveryID != nil else { return .cancelTermination(message: unsafeTerminationMessage) }
            return .cancelStartAndCheckpoint
        case .recording(let kind, let recoveryID):
            guard let recoveryID else { return .cancelTermination(message: unsafeTerminationMessage) }
            return .stopWritersAndCheckpoint(kind: kind, recoveryID: recoveryID)
        case .finishing(let recoveryID):
            guard let recoveryID else { return .cancelTermination(message: unsafeTerminationMessage) }
            return .awaitDurableCommitOrCheckpoint(recoveryID: recoveryID)
        case .delivering:
            return .invalidateDeliveryAndAwaitCommit
        case .cancelling:
            return .awaitCancellationCleanup
        }
    }

    private static let unsafeTerminationMessage = "Cannot terminate while an active capture has no recovery identifier."
}
