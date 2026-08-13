import Foundation

public struct WebhookDispatchToken: Hashable, Sendable {
    public let deliveryID: UUID
    public let generation: UInt64
}

/// Owns the lifecycle of webhook dispatch tasks. A token remains current only
/// while it is the active token for its delivery identifier.
public actor WebhookOutboxCoordinator {
    private var generation: UInt64 = 0
    private var activeTokens: [UUID: WebhookDispatchToken] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func begin(deliveryID: UUID) -> WebhookDispatchToken {
        tasks.removeValue(forKey: deliveryID)?.cancel()
        generation &+= 1
        let token = WebhookDispatchToken(deliveryID: deliveryID, generation: generation)
        activeTokens[deliveryID] = token
        return token
    }

    public func register(_ task: Task<Void, Never>, for token: WebhookDispatchToken) {
        guard activeTokens[token.deliveryID] == token else {
            task.cancel()
            return
        }
        tasks[token.deliveryID]?.cancel()
        tasks[token.deliveryID] = task
    }

    public func mayCommit(_ token: WebhookDispatchToken) -> Bool {
        activeTokens[token.deliveryID] == token
    }

    public func finish(_ token: WebhookDispatchToken) {
        guard activeTokens[token.deliveryID] == token else { return }
        activeTokens.removeValue(forKey: token.deliveryID)
        tasks.removeValue(forKey: token.deliveryID)
    }

    public func cancelAll() -> [UUID] {
        generation &+= 1
        let deliveryIDs = Set(activeTokens.keys).union(tasks.keys)
            .sorted { $0.uuidString < $1.uuidString }
        for task in tasks.values {
            task.cancel()
        }
        activeTokens.removeAll(keepingCapacity: true)
        tasks.removeAll(keepingCapacity: true)
        return deliveryIDs
    }
}
