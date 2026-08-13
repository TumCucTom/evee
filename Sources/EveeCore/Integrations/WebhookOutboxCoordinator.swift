import Foundation

public struct WebhookDispatchToken: Hashable, Sendable {
    public let deliveryID: UUID
    public let generation: UInt64
}

public struct WebhookOutboxPreparationToken: Hashable, Sendable {
    public let generation: UInt64
    public let identifier: UInt64
}

public struct WebhookOutboxInstallationToken: Hashable, Sendable {
    public let generation: UInt64
    public let identifier: UInt64
}

public struct WebhookDeliveryReference: Hashable, Sendable {
    public let recordID: UUID
    public let deliveryID: UUID

    public init(recordID: UUID, deliveryID: UUID) {
        self.recordID = recordID
        self.deliveryID = deliveryID
    }
}

public struct WebhookManualRetryPreparation: Sendable {
    public let records: [WorkspaceRecord]
    public let deliveries: [WebhookDeliveryReference]
}

public enum WebhookOutboxPreparationDecision: Sendable {
    case commit([WorkspaceRecord])
    case cancel([WorkspaceRecord])
}

public struct WebhookOutboxPreparationPersistence: Sendable {
    public let decision: WebhookOutboxPreparationDecision
    public let preparation: WebhookOutboxPersistenceResult
    public let cancellation: WebhookOutboxPersistenceResult?
    public let installationToken: WebhookOutboxInstallationToken?
}

public struct WebhookOutboxInvalidation: Equatable, Sendable {
    public let generation: UInt64
    public let deliveryIDs: [UUID]
}

public struct WebhookOutboxPersistenceFailure: Equatable, Sendable {
    public let recordID: UUID
    public let message: String
}

public struct WebhookOutboxPersistenceResult: Equatable, Sendable {
    public let persistedRecordIDs: [UUID]
    public let failures: [WebhookOutboxPersistenceFailure]

    public func didPersist(recordID: UUID) -> Bool {
        persistedRecordIDs.contains(recordID)
    }
}

public struct WebhookOutboxPersistenceBatchError: LocalizedError, Sendable {
    public let failures: [WebhookOutboxPersistenceFailure]

    public init(failures: [WebhookOutboxPersistenceFailure]) {
        self.failures = failures
    }

    public var errorDescription: String? {
        let count = failures.count
        return "\(count) webhook outbox \(count == 1 ? "record" : "records") could not be saved."
    }
}

/// Synchronous generation and persistence boundary shared by AppStore and the
/// actor facade. Invalidation cancels registered tasks before returning, while
/// durable record writes remain an explicit async checkpoint.
public final class WebhookOutboxTransactions: @unchecked Sendable {
    private let lock = NSLock()
    private var integrationGeneration: UInt64 = 0
    private var preparationSequence: UInt64 = 0
    private var installationSequence: UInt64 = 0
    private var dispatchSequence: UInt64 = 0
    private var preparations: Set<WebhookOutboxPreparationToken> = []
    private var installations: Set<WebhookOutboxInstallationToken> = []
    private var activeDispatches: [UUID: WebhookDispatchToken] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func beginPreparation() -> WebhookOutboxPreparationToken {
        lock.lock()
        defer { lock.unlock() }
        preparationSequence &+= 1
        let token = WebhookOutboxPreparationToken(
            generation: integrationGeneration,
            identifier: preparationSequence
        )
        preparations.insert(token)
        return token
    }

    public func finalize(
        _ token: WebhookOutboxPreparationToken,
        records: [WorkspaceRecord],
        at date: Date = .now
    ) -> WebhookOutboxPreparationDecision {
        lock.lock()
        let isCurrent = token.generation == integrationGeneration && preparations.remove(token) != nil
        lock.unlock()
        if isCurrent { return .commit(records) }
        return .cancel(terminallyCancelledRecords(records, at: date))
    }

    public func abandon(_ token: WebhookOutboxPreparationToken) {
        lock.lock()
        preparations.remove(token)
        lock.unlock()
    }

    public func claimInstallation(
        _ token: WebhookOutboxInstallationToken?,
        records: [WorkspaceRecord],
        at date: Date = .now
    ) -> WebhookOutboxPreparationDecision {
        lock.lock()
        let isCurrent = token.map {
            $0.generation == integrationGeneration && installations.remove($0) != nil
        } ?? false
        lock.unlock()
        if isCurrent { return .commit(records) }
        return .cancel(terminallyCancelledRecords(records, at: date))
    }

    public func beginDispatch(
        deliveryID: UUID,
        requiringGeneration requiredGeneration: UInt64? = nil
    ) -> WebhookDispatchToken? {
        lock.lock()
        guard requiredGeneration == nil || requiredGeneration == integrationGeneration else {
            lock.unlock()
            return nil
        }
        let replaced = tasks.removeValue(forKey: deliveryID)
        dispatchSequence &+= 1
        let token = WebhookDispatchToken(deliveryID: deliveryID, generation: dispatchSequence)
        activeDispatches[deliveryID] = token
        lock.unlock()
        replaced?.cancel()
        return token
    }

    public func register(_ task: Task<Void, Never>, for token: WebhookDispatchToken) {
        lock.lock()
        guard activeDispatches[token.deliveryID] == token else {
            lock.unlock()
            task.cancel()
            return
        }
        let replaced = tasks.updateValue(task, forKey: token.deliveryID)
        lock.unlock()
        replaced?.cancel()
    }

    /// Registers ownership before the operation is allowed to run. This closes
    /// the gap where invalidation could otherwise miss a newly created task.
    public func startTask(
        for token: WebhookDispatchToken,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var iterator = start.stream.makeAsyncIterator()
            guard await iterator.next() != nil,
                  !Task.isCancelled,
                  self.mayCommit(token) else { return }
            await operation()
        }
        register(task, for: token)
        start.continuation.yield(())
        start.continuation.finish()
        return task
    }

    public func mayCommit(_ token: WebhookDispatchToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeDispatches[token.deliveryID] == token
    }

    public func finish(_ token: WebhookDispatchToken) {
        lock.lock()
        guard activeDispatches[token.deliveryID] == token else {
            lock.unlock()
            return
        }
        activeDispatches.removeValue(forKey: token.deliveryID)
        tasks.removeValue(forKey: token.deliveryID)
        lock.unlock()
    }

    @discardableResult
    public func invalidate() -> WebhookOutboxInvalidation {
        lock.lock()
        integrationGeneration &+= 1
        let generation = integrationGeneration
        let deliveryIDs = Set(activeDispatches.keys).union(tasks.keys)
            .sorted { $0.uuidString < $1.uuidString }
        let cancelledTasks = Array(tasks.values)
        preparations.removeAll(keepingCapacity: true)
        installations.removeAll(keepingCapacity: true)
        activeDispatches.removeAll(keepingCapacity: true)
        tasks.removeAll(keepingCapacity: true)
        lock.unlock()
        for task in cancelledTasks {
            task.cancel()
        }
        return WebhookOutboxInvalidation(generation: generation, deliveryIDs: deliveryIDs)
    }

    public func terminallyCancelledRecords(
        _ records: [WorkspaceRecord],
        at date: Date = .now
    ) -> [WorkspaceRecord] {
        records.compactMap { source in
            var record = source
            var changed = false
            for index in record.webhookDeliveries.indices where
                record.webhookDeliveries[index].state == .pending ||
                record.webhookDeliveries[index].state == .failed ||
                record.webhookDeliveries[index].requiresExplicitReplacement {
                record.webhookDeliveries[index].state = .cancelled
                record.webhookDeliveries[index].retryable = false
                record.webhookDeliveries[index].nextAttemptAt = nil
                record.webhookDeliveries[index].payloadBody = nil
                record.webhookDeliveries[index].requiresExplicitReplacement = false
                record.webhookDeliveries[index].lastError = "Webhook delivery was cancelled."
                changed = true
            }
            guard changed else { return nil }
            record.updatedAt = date
            return record
        }
    }

    public func prepareManualRetry(
        records: [WorkspaceRecord],
        destination: String,
        at date: Date = .now,
        makeDeliveryID: () -> UUID = UUID.init
    ) -> WebhookManualRetryPreparation {
        var preparedRecords: [WorkspaceRecord] = []
        var deliveries: [WebhookDeliveryReference] = []
        for source in records {
            var record = source
            var changed = false
            var replacements: [WebhookDelivery] = []
            for index in record.webhookDeliveries.indices where
                record.webhookDeliveries[index].destination == destination {
                let existing = record.webhookDeliveries[index]
                let ordinaryRetry = existing.retryable &&
                    (existing.state == .pending || existing.state == .failed)
                let replacementRetry = existing.requiresExplicitReplacement
                guard ordinaryRetry || replacementRetry else { continue }

                if let body = existing.payloadBody, MeetingWebhook.isCurrentPayload(body), !replacementRetry {
                    record.webhookDeliveries[index].state = .pending
                    record.webhookDeliveries[index].nextAttemptAt = nil
                    deliveries.append(WebhookDeliveryReference(
                        recordID: record.id,
                        deliveryID: existing.id
                    ))
                    changed = true
                    continue
                }

                record.webhookDeliveries[index].state = .cancelled
                record.webhookDeliveries[index].retryable = false
                record.webhookDeliveries[index].nextAttemptAt = nil
                record.webhookDeliveries[index].payloadBody = nil
                record.webhookDeliveries[index].requiresExplicitReplacement = false
                record.webhookDeliveries[index].lastError = "Legacy webhook payload was retired and replaced explicitly."
                guard let body = try? MeetingWebhook.payload(for: record) else {
                    changed = true
                    continue
                }
                let replacement = WebhookDelivery(
                    id: makeDeliveryID(),
                    destination: destination,
                    payloadBody: body
                )
                replacements.append(replacement)
                deliveries.append(WebhookDeliveryReference(
                    recordID: record.id,
                    deliveryID: replacement.id
                ))
                changed = true
            }
            if changed {
                record.webhookDeliveries.append(contentsOf: replacements)
                record.updatedAt = date
                preparedRecords.append(record)
            }
        }
        return WebhookManualRetryPreparation(records: preparedRecords, deliveries: deliveries)
    }

    /// Returns only rows whose immutable bytes use the current allowlisted
    /// payload contract. Legacy and missing bytes require an explicit
    /// replacement and are never spun by the automatic scheduler.
    public func automaticRetryDeliveries(
        records: [WorkspaceRecord],
        destination: String,
        at date: Date = .now
    ) -> [WebhookDeliveryReference] {
        records.flatMap { record in
            record.webhookDeliveries.compactMap { delivery in
                guard delivery.destination == destination,
                      delivery.retryable,
                      delivery.state == .pending ||
                        (delivery.state == .failed && (delivery.nextAttemptAt ?? .distantPast) <= date),
                      let body = delivery.payloadBody,
                      MeetingWebhook.isCurrentPayload(body) else { return nil }
                return WebhookDeliveryReference(recordID: record.id, deliveryID: delivery.id)
            }
        }
    }

    /// Migrates actionable rows that predate the versioned DTO (including rows
    /// with no immutable bytes) into a terminal audit row. The replacement is
    /// deliberately deferred to an explicit user retry, which creates a new
    /// delivery identifier and fresh allowlisted bytes.
    public func retireUnsupportedPayloads(
        records: [WorkspaceRecord],
        at date: Date = .now
    ) -> [WorkspaceRecord] {
        records.compactMap { source in
            var record = source
            var changed = false
            for index in record.webhookDeliveries.indices where
                record.webhookDeliveries[index].state == .pending ||
                record.webhookDeliveries[index].state == .failed {
                let body = record.webhookDeliveries[index].payloadBody
                guard body.map(MeetingWebhook.isCurrentPayload) != true else { continue }
                record.webhookDeliveries[index].state = .cancelled
                record.webhookDeliveries[index].retryable = false
                record.webhookDeliveries[index].nextAttemptAt = nil
                record.webhookDeliveries[index].payloadBody = nil
                record.webhookDeliveries[index].requiresExplicitReplacement = true
                record.webhookDeliveries[index].lastError = "This legacy webhook payload was retired. Choose Retry now to create a privacy-safe replacement."
                changed = true
            }
            guard changed else { return nil }
            record.updatedAt = date
            return record
        }
    }

    public func persistAll(
        _ records: [WorkspaceRecord],
        using persist: @escaping @Sendable (WorkspaceRecord) async throws -> Void
    ) async -> WebhookOutboxPersistenceResult {
        var persistedRecordIDs: [UUID] = []
        var failures: [WebhookOutboxPersistenceFailure] = []
        for record in records {
            do {
                try await persist(record)
                persistedRecordIDs.append(record.id)
            } catch {
                failures.append(WebhookOutboxPersistenceFailure(
                    recordID: record.id,
                    message: error.localizedDescription
                ))
            }
        }
        return WebhookOutboxPersistenceResult(
            persistedRecordIDs: persistedRecordIDs,
            failures: failures
        )
    }

    /// Persists a prepared snapshot, then validates its generation. If an
    /// invalidation won while persistence was suspended, the same owner clears
    /// payload bytes and persists terminal rows before returning.
    public func persistPreparation(
        _ token: WebhookOutboxPreparationToken,
        records: [WorkspaceRecord],
        using persist: @escaping @Sendable (WorkspaceRecord) async throws -> Void
    ) async -> WebhookOutboxPreparationPersistence {
        let preparation = await persistAll(records, using: persist)
        let (decision, installationToken) = finalizeForInstallation(token, records: records)
        switch decision {
        case .commit:
            return WebhookOutboxPreparationPersistence(
                decision: decision,
                preparation: preparation,
                cancellation: nil,
                installationToken: installationToken
            )
        case .cancel(let cancelledRecords):
            let cancellation = await persistAll(cancelledRecords, using: persist)
            return WebhookOutboxPreparationPersistence(
                decision: decision,
                preparation: preparation,
                cancellation: cancellation,
                installationToken: nil
            )
        }
    }

    private func finalizeForInstallation(
        _ token: WebhookOutboxPreparationToken,
        records: [WorkspaceRecord],
        at date: Date = .now
    ) -> (WebhookOutboxPreparationDecision, WebhookOutboxInstallationToken?) {
        lock.lock()
        let isCurrent = token.generation == integrationGeneration && preparations.remove(token) != nil
        let installationToken: WebhookOutboxInstallationToken?
        if isCurrent {
            installationSequence &+= 1
            let created = WebhookOutboxInstallationToken(
                generation: integrationGeneration,
                identifier: installationSequence
            )
            installations.insert(created)
            installationToken = created
        } else {
            installationToken = nil
        }
        lock.unlock()
        if isCurrent { return (.commit(records), installationToken) }
        return (.cancel(terminallyCancelledRecords(records, at: date)), nil)
    }
}

/// Owns the lifecycle of webhook dispatch tasks. A token remains current only
/// while it is the active token for its delivery identifier.
public actor WebhookOutboxCoordinator {
    private nonisolated let transactions: WebhookOutboxTransactions

    public init(transactions: WebhookOutboxTransactions = WebhookOutboxTransactions()) {
        self.transactions = transactions
    }

    public func begin(deliveryID: UUID) -> WebhookDispatchToken {
        transactions.beginDispatch(deliveryID: deliveryID)!
    }

    public func begin(
        deliveryID: UUID,
        requiringGeneration generation: UInt64
    ) -> WebhookDispatchToken? {
        transactions.beginDispatch(deliveryID: deliveryID, requiringGeneration: generation)
    }

    public func register(_ task: Task<Void, Never>, for token: WebhookDispatchToken) {
        transactions.register(task, for: token)
    }

    public func mayCommit(_ token: WebhookDispatchToken) -> Bool {
        transactions.mayCommit(token)
    }

    public func finish(_ token: WebhookDispatchToken) {
        transactions.finish(token)
    }

    public func cancelAll() -> [UUID] {
        transactions.invalidate().deliveryIDs
    }

    public nonisolated func invalidateSynchronously() -> WebhookOutboxInvalidation {
        transactions.invalidate()
    }
}
