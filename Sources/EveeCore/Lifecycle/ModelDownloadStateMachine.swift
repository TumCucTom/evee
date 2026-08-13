import Foundation

public struct LifecycleOperation: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum ModelDownloadState: Equatable, Sendable {
    case idle
    case downloading(model: SpeechModel, progress: ModelProgress?)
    case ready(model: SpeechModel)
    case failed(model: SpeechModel, message: String)
}

public struct ModelDownloadStateMachine: Sendable {
    public private(set) var state: ModelDownloadState = .idle
    private var operation: LifecycleOperation?

    public init() {}

    public var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    public mutating func begin(model: SpeechModel) -> LifecycleOperation? {
        guard operation == nil else { return nil }
        guard isIdle || isFailed else { return nil }

        let operation = LifecycleOperation()
        self.operation = operation
        state = .downloading(model: model, progress: nil)
        return operation
    }

    public mutating func cancel(_ operation: LifecycleOperation) {
        guard self.operation == operation else { return }
        self.operation = nil
        state = .idle
    }

    public mutating func update(_ operation: LifecycleOperation, progress: ModelProgress) -> Bool {
        guard self.operation == operation,
              case .downloading(let model, _) = state else { return false }

        state = .downloading(model: model, progress: progress)
        return true
    }

    public mutating func complete(_ operation: LifecycleOperation) -> Bool {
        guard self.operation == operation,
              case .downloading(let model, _) = state else { return false }

        self.operation = nil
        state = .ready(model: model)
        return true
    }

    public mutating func fail(_ operation: LifecycleOperation, message: String) -> Bool {
        guard self.operation == operation,
              case .downloading(let model, _) = state else { return false }

        self.operation = nil
        state = .failed(model: model, message: message)
        return true
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
