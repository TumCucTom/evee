import Foundation

public enum HotMicState: Equatable, Sendable {
    case disabled
    case starting
    case active
    case stopping
    case failed(message: String)
}

public struct HotMicStateMachine: Sendable {
    public private(set) var state: HotMicState = .disabled
    private var operation: LifecycleOperation?

    public init() {}

    public var isDisabled: Bool {
        state == .disabled
    }

    public mutating func beginStart() -> LifecycleOperation? {
        guard operation == nil, canStart else { return nil }

        let operation = LifecycleOperation()
        self.operation = operation
        state = .starting
        return operation
    }

    public mutating func disable() {
        operation = nil
        state = .disabled
    }

    @discardableResult
    public mutating func beginStop() -> Bool {
        operation = nil
        guard state != .disabled, state != .stopping else { return false }
        state = .stopping
        return true
    }

    @discardableResult
    public mutating func completeStop() -> Bool {
        guard state == .stopping else { return false }
        state = .disabled
        return true
    }

    public func isCurrent(_ operation: LifecycleOperation) -> Bool {
        self.operation == operation && state == .starting
    }

    public mutating func didStart(_ operation: LifecycleOperation) -> Bool {
        guard self.operation == operation, state == .starting else { return false }

        self.operation = nil
        state = .active
        return true
    }

    public mutating func fail(_ operation: LifecycleOperation, message: String) -> Bool {
        guard self.operation == operation, state == .starting else { return false }

        self.operation = nil
        state = .failed(message: message)
        return true
    }

    private var canStart: Bool {
        switch state {
        case .disabled, .failed:
            true
        case .starting, .active, .stopping:
            false
        }
    }
}
