@_spi(Testing) import EveeCore
import Darwin
import Foundation
import Network

private enum CoreCheckError: Error {
    case assertionFailed(String)
    case connectionFailed(String)
    case listenerFailed(String)
    case timedOut
}

private enum SyntheticSecretStoreError: Error {
    case deletionFailed
}

private enum SyntheticWebhookPersistenceError: Error {
    case rejected
}

private enum SyntheticMCPPersistenceError: Error {
    case rejected
    case restoreRejected
}

private final class BlockingSecretStore: LocalAPISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let enteredRead = DispatchSemaphore(value: 0)
    private let releaseRead = DispatchSemaphore(value: 0)
    private var value: String?
    private let failsDeletion: Bool

    init(value: String?, failsDeletion: Bool = false) {
        self.value = value
        self.failsDeletion = failsDeletion
    }

    func string(for account: String) throws -> String? {
        enteredRead.signal()
        releaseRead.wait()
        return lock.withLock { value }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock { self.value = value }
    }

    func delete(_ account: String) throws {
        if failsDeletion { throw SyntheticSecretStoreError.deletionFailed }
        lock.withLock { value = nil }
    }

    func waitForRead() -> Bool {
        enteredRead.wait(timeout: .now() + 2) == .success
    }

    func resumeRead() {
        releaseRead.signal()
    }
}

private final class MemorySecretStore: LocalAPISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private let failsDeletion: Bool

    init(value: String?, failsDeletion: Bool = false) {
        self.value = value
        self.failsDeletion = failsDeletion
    }

    func string(for account: String) throws -> String? {
        lock.withLock { value }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock { self.value = value }
    }

    func delete(_ account: String) throws {
        if failsDeletion { throw SyntheticSecretStoreError.deletionFailed }
        lock.withLock { value = nil }
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class SuspendedCoreCheckURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var suspended: SuspendedCoreCheckURLProtocol?
    private static var capturedRequest: URLRequest?
    private static var startedHandler: (@Sendable (URLRequest) -> Void)?

    static func prepare(started: @escaping @Sendable (URLRequest) -> Void) {
        lock.lock()
        suspended = nil
        capturedRequest = nil
        startedHandler = started
        lock.unlock()
    }

    static func release() {
        lock.lock()
        let current = suspended
        suspended = nil
        capturedRequest = nil
        startedHandler = nil
        lock.unlock()
        guard let current,
              let response = HTTPURLResponse(
                url: current.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else { return }
        current.client?.urlProtocol(current, didReceive: response, cacheStoragePolicy: .notAllowed)
        current.client?.urlProtocol(current, didLoad: Data("{}".utf8))
        current.client?.urlProtocolDidFinishLoading(current)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        capturedRequest = requestWithReadableBody(request)
        lock.unlock()
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.suspended = self
        let handler = Self.startedHandler
        let captured = Self.capturedRequest ?? request
        Self.lock.unlock()
        handler?(captured)
    }

    override func stopLoading() {
        // The response is released after task cancellation to exercise a stale
        // local transport callback without opening an external connection.
    }

    private static func requestWithReadableBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        var captured = request
        captured.httpBody = body
        return captured
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CoreCheckError.assertionFailed(message) }
}

private func checkWebhookGeneration() async throws {
    let deliveryID = UUID(uuidString: "75B09B72-BC3F-4939-9F81-E6B7C814A552")!
    let coordinator = WebhookOutboxCoordinator()
    let token = await coordinator.begin(deliveryID: deliveryID)
    let task = Task<Void, Never> {
        try? await Task.sleep(for: .seconds(30))
    }
    await coordinator.register(task, for: token)

    let activeBeforeCancellation = await coordinator.mayCommit(token)
    let cancelled = await coordinator.cancelAll()
    let activeAfterCancellation = await coordinator.mayCommit(token)

    try require(activeBeforeCancellation, "registered webhook dispatch was not allowed to commit")
    try require(cancelled == [deliveryID], "webhook cancellation did not return the active delivery")
    try require(!activeAfterCancellation, "cancelled webhook dispatch remained able to commit")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(rootURL: root)
    let body = Data("{\"meeting\":\"synthetic\"}".utf8)
    let suspendedDeliveryID = UUID(uuidString: "19CF6CE4-3841-4CF7-9888-679CC63B3364")!
    let destination = URL(string: "https://example.invalid/webhook")!
    var storedRecord = WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Local test")
    storedRecord.webhookDeliveries = [WebhookDelivery(
        id: suspendedDeliveryID,
        destination: destination.absoluteString,
        payloadBody: body,
        nextAttemptAt: Date(timeIntervalSince1970: 1_786_616_100)
    )]
    try await store.upsert(storedRecord)

    let started = AsyncStream<URLRequest>.makeStream()
    SuspendedCoreCheckURLProtocol.prepare { request in
        started.continuation.yield(request)
        started.continuation.finish()
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SuspendedCoreCheckURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let suspendedCoordinator = WebhookOutboxCoordinator()
    let suspendedToken = await suspendedCoordinator.begin(deliveryID: suspendedDeliveryID)
    let suspendedTask = Task<Void, Never> {
        do {
            _ = try await MeetingWebhook(session: session).sendWithStatus(
                record: storedRecord,
                destination: destination,
                secret: "synthetic-secret",
                deliveryID: suspendedDeliveryID,
                maxAttempts: 1,
                payloadBody: body
            )
            if await suspendedCoordinator.mayCommit(suspendedToken),
               var current = try await store.record(id: storedRecord.id),
               let index = current.webhookDeliveries.firstIndex(where: { $0.id == suspendedDeliveryID }) {
                current.webhookDeliveries[index].state = .delivered
                try await store.upsert(current)
            }
        } catch {
            if await suspendedCoordinator.mayCommit(suspendedToken),
               var current = try? await store.record(id: storedRecord.id),
               let index = current.webhookDeliveries.firstIndex(where: { $0.id == suspendedDeliveryID }) {
                current.webhookDeliveries[index].state = .failed
                try? await store.upsert(current)
            }
        }
        await suspendedCoordinator.finish(suspendedToken)
    }
    await suspendedCoordinator.register(suspendedTask, for: suspendedToken)

    let request = try await withTimeout(seconds: 2, onTimeout: { session.invalidateAndCancel() }) {
        var iterator = started.stream.makeAsyncIterator()
        guard let request = await iterator.next() else { throw CoreCheckError.timedOut }
        return request
    }
    try require(request.httpBody == body, "webhook transport did not send the stored payload bytes")

    _ = await suspendedCoordinator.cancelAll()
    let persistedBeforeCancellation = try await store.record(id: storedRecord.id)
    guard var cancelledRecord = persistedBeforeCancellation,
          let cancelledIndex = cancelledRecord.webhookDeliveries.firstIndex(where: { $0.id == suspendedDeliveryID }) else {
        throw CoreCheckError.assertionFailed("synthetic webhook row was not stored")
    }
    cancelledRecord.webhookDeliveries[cancelledIndex].state = .cancelled
    cancelledRecord.webhookDeliveries[cancelledIndex].retryable = false
    cancelledRecord.webhookDeliveries[cancelledIndex].nextAttemptAt = nil
    cancelledRecord.webhookDeliveries[cancelledIndex].payloadBody = nil
    try await store.upsert(cancelledRecord)
    SuspendedCoreCheckURLProtocol.release()
    await suspendedTask.value

    let persistedAfterLateResponse = try await store.record(id: storedRecord.id)
    guard let final = persistedAfterLateResponse?.webhookDeliveries.first(where: { $0.id == suspendedDeliveryID }) else {
        throw CoreCheckError.assertionFailed("synthetic webhook row disappeared")
    }
    try require(final.state == .cancelled, "late webhook response replaced terminal cancellation")
    try require(!final.retryable && final.nextAttemptAt == nil, "cancelled webhook remained retryable")
    try require(final.payloadBody == nil, "cancelled webhook retained payload bytes")
    print("webhook-generation: passed")
}

private func checkWebhookSignature() throws {
    let body = Data("{\"meeting\":\"synthetic\"}".utf8)
    let deliveryID = UUID(uuidString: "D5881780-29A4-4D3A-84A6-3FB7DD77CA94")!
    let timestamp = "2026-08-13T10:15:00Z"
    let first = MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: deliveryID,
        timestamp: timestamp
    )

    try require(first != MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: UUID(uuidString: "3E165D7B-D650-420D-9537-B86CB074074C")!,
        timestamp: timestamp
    ), "webhook signature omitted the delivery identifier")
    try require(first != MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.updated",
        deliveryID: deliveryID,
        timestamp: timestamp
    ), "webhook signature omitted the event")
    try require(first != MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: deliveryID,
        timestamp: "2026-08-13T10:15:01Z"
    ), "webhook signature omitted the timestamp")
    try require(first != MeetingWebhook.signature(
        body: Data("{\"meeting\":\"changed\"}".utf8),
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: deliveryID,
        timestamp: timestamp
    ), "webhook signature omitted the body")
    print("webhook-signature: passed")
}

private func checkWebhookTransactions() async throws {
    let queueRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: queueRoot) }
    let queueStore = LibraryStore(rootURL: queueRoot)
    let queueTransactions = WebhookOutboxTransactions()
    var queuedRecord = WorkspaceRecord(kind: .meeting, title: "Queue race", text: "Synthetic")
    let queuedDelivery = WebhookDelivery(
        id: UUID(uuidString: "57CBE526-0514-48B0-9C18-42EE74653CA5")!,
        destination: "https://example.invalid/webhook",
        payloadBody: Data("{\"queued\":true}".utf8)
    )
    queuedRecord.webhookDeliveries = [queuedDelivery]
    let queueToken = queueTransactions.beginPreparation()
    let queueAttempts = LockedValues<UUID>()
    let queueTransaction = await queueTransactions.persistPreparation(
        queueToken,
        records: [queuedRecord]
    ) { record in
        queueAttempts.append(record.id)
        try await queueStore.upsert(record)
        if queueAttempts.values.count == 1 { _ = queueTransactions.invalidate() }
    }
    guard case .cancel = queueTransaction.decision else {
        throw CoreCheckError.assertionFailed("invalidated queue preparation committed")
    }
    try require(queueTransaction.cancellation?.failures.isEmpty == true, "queue cancellation compensation failed")
    try require(queueAttempts.values == [queuedRecord.id, queuedRecord.id], "queue cancellation compensation was not persisted")
    let storedQueue = try await queueStore.record(id: queuedRecord.id)
    let storedQueueDelivery = storedQueue?.webhookDeliveries.first(where: { $0.id == queuedDelivery.id })
    try require(storedQueueDelivery?.state == .cancelled, "queue race left a pending delivery")
    try require(storedQueueDelivery?.payloadBody == nil, "queue race retained payload bytes")

    let queueInstallRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: queueInstallRoot) }
    let queueInstallStore = LibraryStore(rootURL: queueInstallRoot)
    let queueInstallTransactions = WebhookOutboxTransactions()
    let queueInstallToken = queueInstallTransactions.beginPreparation()
    let queueInstallTransaction = await queueInstallTransactions.persistPreparation(
        queueInstallToken,
        records: [queuedRecord]
    ) { record in
        try await queueInstallStore.upsert(record)
    }
    guard case .commit = queueInstallTransaction.decision else {
        throw CoreCheckError.assertionFailed("current queue preparation did not commit")
    }
    _ = queueInstallTransactions.invalidate()
    let queueInstallation = queueInstallTransactions.claimInstallation(
        queueInstallTransaction.installationToken,
        records: [queuedRecord]
    )
    guard case .cancel(let cancelledQueueInstallation) = queueInstallation else {
        throw CoreCheckError.assertionFailed("invalidated queue installation was accepted")
    }
    _ = await queueInstallTransactions.persistAll(cancelledQueueInstallation) { record in
        try await queueInstallStore.upsert(record)
    }
    let storedQueueInstallation = try await queueInstallStore.record(id: queuedRecord.id)
    let storedQueueInstallationDelivery = storedQueueInstallation?.webhookDeliveries.first
    try require(storedQueueInstallationDelivery?.state == .cancelled, "queue installation race left a pending delivery")
    try require(storedQueueInstallationDelivery?.payloadBody == nil, "queue installation race retained payload bytes")
    try require(storedQueueInstallationDelivery?.retryable == false, "queue installation race remained retryable")
    try require(storedQueueInstallationDelivery?.nextAttemptAt == nil, "queue installation race retained retry timing")

    let retryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: retryRoot) }
    let retryStore = LibraryStore(rootURL: retryRoot)
    let retryTransactions = WebhookOutboxTransactions()
    let retryDeliveryID = UUID(uuidString: "546290F6-C799-4967-AC9C-B6CAF86726D7")!
    let destination = "https://example.invalid/webhook"
    var failedRecord = WorkspaceRecord(kind: .meeting, title: "Retry race", text: "Synthetic")
    failedRecord.webhookDeliveries = [WebhookDelivery(
        id: retryDeliveryID,
        destination: destination,
        state: .failed,
        attemptCount: 1,
        payloadBody: Data("{\"retry\":true}".utf8),
        retryable: true,
        nextAttemptAt: .now
    )]
    try await retryStore.upsert(failedRecord)
    let retryToken = retryTransactions.beginPreparation()
    let retryPreparation = retryTransactions.prepareManualRetry(
        records: [failedRecord],
        destination: destination,
        at: Date(timeIntervalSince1970: 1_786_616_200)
    )
    let retryAttempts = LockedValues<UUID>()
    let retryTransaction = await retryTransactions.persistPreparation(
        retryToken,
        records: retryPreparation.records
    ) { record in
        retryAttempts.append(record.id)
        try await retryStore.upsert(record)
        if retryAttempts.values.count == 1 { _ = retryTransactions.invalidate() }
    }
    guard case .cancel = retryTransaction.decision else {
        throw CoreCheckError.assertionFailed("invalidated manual retry committed")
    }
    try require(retryTransaction.cancellation?.failures.isEmpty == true, "manual retry cancellation compensation failed")
    try require(retryAttempts.values == [failedRecord.id, failedRecord.id], "manual retry cancellation compensation was not persisted")
    let storedRetry = try await retryStore.record(id: failedRecord.id)
    let storedRetryDelivery = storedRetry?.webhookDeliveries.first(where: { $0.id == retryDeliveryID })
    try require(storedRetryDelivery?.state == .cancelled, "manual retry race revived a cancelled delivery")
    try require(storedRetryDelivery?.payloadBody == nil, "manual retry race retained payload bytes")

    let retryInstallRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: retryInstallRoot) }
    let retryInstallStore = LibraryStore(rootURL: retryInstallRoot)
    try await retryInstallStore.upsert(failedRecord)
    let retryInstallTransactions = WebhookOutboxTransactions()
    let retryInstallToken = retryInstallTransactions.beginPreparation()
    let retryInstallPreparation = retryInstallTransactions.prepareManualRetry(
        records: [failedRecord],
        destination: destination
    )
    let retryInstallTransaction = await retryInstallTransactions.persistPreparation(
        retryInstallToken,
        records: retryInstallPreparation.records
    ) { record in
        try await retryInstallStore.upsert(record)
    }
    guard case .commit = retryInstallTransaction.decision else {
        throw CoreCheckError.assertionFailed("current manual retry preparation did not commit")
    }
    _ = retryInstallTransactions.invalidate()
    let retryInstallation = retryInstallTransactions.claimInstallation(
        retryInstallTransaction.installationToken,
        records: retryInstallPreparation.records
    )
    guard case .cancel(let cancelledRetryInstallation) = retryInstallation else {
        throw CoreCheckError.assertionFailed("invalidated manual retry installation was accepted")
    }
    _ = await retryInstallTransactions.persistAll(cancelledRetryInstallation) { record in
        try await retryInstallStore.upsert(record)
    }
    let storedRetryInstallation = try await retryInstallStore.record(id: failedRecord.id)
    let storedRetryInstallationDelivery = storedRetryInstallation?.webhookDeliveries.first
    try require(storedRetryInstallationDelivery?.state == .cancelled, "manual retry installation race revived a pending delivery")
    try require(storedRetryInstallationDelivery?.payloadBody == nil, "manual retry installation race retained payload bytes")
    try require(storedRetryInstallationDelivery?.retryable == false, "manual retry installation race remained retryable")
    try require(storedRetryInstallationDelivery?.nextAttemptAt == nil, "manual retry installation race retained retry timing")

    let partialTransactions = WebhookOutboxTransactions()
    let partialRecords = [
        WorkspaceRecord(id: UUID(uuidString: "EE6C5238-D656-4591-9496-4AFBFC27CC8B")!, kind: .meeting, title: "First", text: "Synthetic"),
        WorkspaceRecord(id: UUID(uuidString: "73DF5302-12BE-45D6-B7D8-7973394654DE")!, kind: .meeting, title: "Second", text: "Synthetic"),
        WorkspaceRecord(id: UUID(uuidString: "AF38DCD7-E785-42F0-B646-97425F20C66E")!, kind: .meeting, title: "Third", text: "Synthetic"),
    ]
    let attempted = LockedValues<UUID>()
    let partialResult = await partialTransactions.persistAll(partialRecords) { record in
        attempted.append(record.id)
        if record.id == partialRecords[1].id { throw SyntheticWebhookPersistenceError.rejected }
    }
    try require(attempted.values == partialRecords.map(\.id), "batch persistence stopped before later records")
    try require(partialResult.persistedRecordIDs == [partialRecords[0].id, partialRecords[2].id], "batch persistence reported the wrong successes")
    try require(partialResult.failures.map(\.recordID) == [partialRecords[1].id], "batch persistence reported the wrong failure")

    let terminationTransactions = WebhookOutboxTransactions()
    let preparation = terminationTransactions.beginPreparation()
    let terminationDeliveryID = UUID(uuidString: "FEABF695-DAD7-4FC5-95B5-F5653C9A2D5E")!
    guard let dispatch = terminationTransactions.beginDispatch(deliveryID: terminationDeliveryID) else {
        throw CoreCheckError.assertionFailed("termination dispatch did not start")
    }
    let activeTask = terminationTransactions.startTask(for: dispatch) {
        try? await Task.sleep(for: .seconds(30))
    }
    let invalidation = terminationTransactions.invalidate()
    let preparationDecision = terminationTransactions.finalize(preparation, records: [failedRecord])
    try require(activeTask.isCancelled, "synchronous termination invalidation left the task active")
    try require(!terminationTransactions.mayCommit(dispatch), "termination invalidation left the dispatch current")
    try require(
        terminationTransactions.beginDispatch(
            deliveryID: UUID(),
            requiringGeneration: preparation.generation
        ) == nil,
        "termination invalidation allowed stale work to start"
    )
    guard case .cancel = preparationDecision else {
        throw CoreCheckError.assertionFailed("termination invalidation left the preparation current")
    }
    try require(invalidation.deliveryIDs == [terminationDeliveryID], "termination invalidation omitted the active delivery")
    print("webhook-transactions: passed")
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    onTimeout: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw CoreCheckError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func availablePort() throws -> UInt16 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CoreCheckError.listenerFailed(String(cString: strerror(errno))) }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw CoreCheckError.listenerFailed(String(cString: strerror(errno))) }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else { throw CoreCheckError.listenerFailed(String(cString: strerror(errno))) }
    return UInt16(bigEndian: address.sin_port)
}

private func connect(to credentials: LocalAPICredentials, label: String) async throws -> NWConnection {
    let port = NWEndpoint.Port(rawValue: UInt16(credentials.baseURL.port!))!
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    let queue = DispatchQueue(label: label)
    try await withCheckedThrowingContinuation { continuation in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                continuation.resume()
            case .failed(let error):
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: CoreCheckError.connectionFailed(error.localizedDescription))
            case .cancelled:
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: CoreCheckError.connectionFailed("Cancelled before ready"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    return connection
}

private func send(_ data: Data, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: CoreCheckError.connectionFailed(error.localizedDescription))
            } else {
                continuation.resume()
            }
        })
    }
}

private func sendBestEffort(_ data: Data, on connection: NWConnection) async {
    await withCheckedContinuation { continuation in
        connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
    }
}

private func receiveAll(on connection: NWConnection, accumulated: Data = Data()) async -> Data {
    await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, isComplete, error in
            var received = accumulated
            if let data { received.append(data) }
            if isComplete || error != nil {
                continuation.resume(returning: received)
            } else {
                Task { continuation.resume(returning: await receiveAll(on: connection, accumulated: received)) }
            }
        }
    }
}

private func makeSyntheticServer() async throws -> (LocalAPIServer, LocalAPICredentials, URL, LibraryStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-check-\(UUID().uuidString)", isDirectory: true)
    let store = LibraryStore(rootURL: root)
    let secretStore = KeychainSecretStore(service: "com.tumcuctom.evee.core-checks.synthetic")
    try? secretStore.delete(KeychainSecretStore.localAPITokenAccount)
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    let credentials = try await server.startWithCredentials(port: try availablePort())
    return (server, credentials, root, store)
}

private func checkContextPolicy() {
    let ordinary = ContextCollectionPolicy.ordinaryDictation(
        retainMetadata: false,
        captureVisibleText: false
    )
    precondition(ordinary.collectsDeliveryIdentity)
    precondition(!ordinary.collectsSelectedText)
    precondition(!ordinary.collectsWindowMetadata)
    precondition(!ordinary.collectsVisibleText)

    let transform = ContextCollectionPolicy.selectionTransformation(retainMetadata: false)
    precondition(transform.collectsSelectedText)

    print("context-policy: passed")
}

private func checkPublicRecord() throws {
    let privateRecord = WorkspaceRecord(
        kind: .meeting,
        title: "Synthetic",
        text: "Visible",
        rawText: "Private raw",
        audioRelativePath: "Audio/private.caf",
        recoverySourceID: UUID()
    )
    let encoded = try JSONEncoder().encode(PublicWorkspaceRecord(privateRecord))
    let json = String(decoding: encoded, as: UTF8.self)
    precondition(!json.contains("private.caf"))
    precondition(!json.contains("Private raw"))
    precondition(!json.contains("recoverySourceID"))
    precondition(!json.contains("webhookDeliveries"))
    precondition(!json.contains("context"))

    print("public-record: passed")
}

private func checkAPIRevocation() async throws {
    let (server, credentials, root, store) = try await makeSyntheticServer()
    defer {
        try? server.revokeToken()
        try? FileManager.default.removeItem(at: root)
    }
    let record = WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Visible")
    try await store.upsert(record)
    let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.revoke")
    defer { connection.cancel() }

    let firstFragment = "GET /v1/records/\(record.id.uuidString) HTTP/1.1\r\nAuthorization: Bearer "
    try await send(Data(firstFragment.utf8), on: connection)
    try await Task.sleep(nanoseconds: 100_000_000)
    server.stop()
    await sendBestEffort(Data("\(credentials.token)\r\n\r\n".utf8), on: connection)

    let response = try await withTimeout(seconds: 2, onTimeout: { connection.cancel() }) {
        await receiveAll(on: connection)
    }
    precondition(!String(decoding: response, as: UTF8.self).contains("Visible"))

    print("api-revoke: passed")
}

private func checkAPIRotation() async throws {
    let (server, credentials, root, _) = try await makeSyntheticServer()
    defer {
        try? server.revokeToken()
        try? FileManager.default.removeItem(at: root)
    }

    let stale = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.rotate.stale")
    defer { stale.cancel() }
    try await send(Data("GET /health HTTP/1.1\r\nAuthorization: Bearer ".utf8), on: stale)
    let rotated = try server.rotateToken()!
    await sendBestEffort(Data("\(credentials.token)\r\n\r\n".utf8), on: stale)
    let staleResponse = try await withTimeout(seconds: 2, onTimeout: { stale.cancel() }) {
        await receiveAll(on: stale)
    }
    precondition(!String(decoding: staleResponse, as: UTF8.self).contains("ok"))

    let fresh = try await connect(to: rotated, label: "com.tumcuctom.evee.core-checks.rotate.fresh")
    defer { fresh.cancel() }
    let request = "GET /health HTTP/1.1\r\nAuthorization: Bearer \(rotated.token)\r\n\r\n"
    try await send(Data(request.utf8), on: fresh)
    let freshResponse = try await withTimeout(seconds: 2, onTimeout: { fresh.cancel() }) {
        await receiveAll(on: fresh)
    }
    precondition(String(decoding: freshResponse, as: UTF8.self).contains("\"status\":\"ok\""))

    print("api-rotate: passed")
}

private func checkAPILimits() async throws {
    let (server, credentials, root, _) = try await makeSyntheticServer()
    defer {
        try? server.revokeToken()
        try? FileManager.default.removeItem(at: root)
    }

    let timeoutConnection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.timeout")
    try await send(Data("GET /health HTTP/1.1\r\nAuthorization: Bearer ".utf8), on: timeoutConnection)
    let timeoutStartedAt = Date()
    _ = try await withTimeout(seconds: 7, onTimeout: { timeoutConnection.cancel() }) {
        await receiveAll(on: timeoutConnection)
    }
    precondition(Date().timeIntervalSince(timeoutStartedAt) >= 4.5)
    timeoutConnection.cancel()

    var retainedConnections: [NWConnection] = []
    defer { retainedConnections.forEach { $0.cancel() } }
    for index in 0..<32 {
        let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.cap.\(index)")
        try await send(Data("GET /health HTTP/1.1\r\nX-Fragment: \(index)".utf8), on: connection)
        retainedConnections.append(connection)
    }

    let excess = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.cap.excess")
    defer { excess.cancel() }
    let response = try await withTimeout(seconds: 2, onTimeout: { excess.cancel() }) {
        await receiveAll(on: excess)
    }
    precondition(response.isEmpty)

    let lastRetained = retainedConnections[31]
    try await send(Data("\r\n\r\n".utf8), on: lastRetained)
    let retainedResponse = try await withTimeout(seconds: 2, onTimeout: { lastRetained.cancel() }) {
        await receiveAll(on: lastRetained)
    }
    precondition(String(decoding: retainedResponse, as: UTF8.self).contains("401 Unauthorised"))

    let oversized = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.oversized")
    defer { oversized.cancel() }
    let oversizedHeader = "GET /health HTTP/1.1\r\nX-Fill: " + String(repeating: "x", count: 129 * 1_024)
    await sendBestEffort(Data(oversizedHeader.utf8), on: oversized)
    let oversizedResponse = try await withTimeout(seconds: 2, onTimeout: { oversized.cancel() }) {
        await receiveAll(on: oversized)
    }
    precondition(String(decoding: oversizedResponse, as: UTF8.self).contains("431 Request Header Fields Too Large"))

    print("api-limits: passed")
}

private func checkAPIStartRaces() async throws {
    for action in ["cancel", "stop", "revoke"] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-api-start-race-\(UUID().uuidString)", isDirectory: true)
        let store = LibraryStore(rootURL: root)
        let secretStore = BlockingSecretStore(value: "old-token")
        let server = LocalAPIServer(store: store, secretStore: secretStore)
        let port = try availablePort()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let startTask = Task { try await server.startWithCredentials(port: port) }
        let didEnterRead = await Task.detached { secretStore.waitForRead() }.value
        try require(didEnterRead, "start did not reach credential loading")

        var revokeTask: Task<Void, Error>?
        switch action {
        case "cancel":
            startTask.cancel()
        case "stop":
            server.stop()
        default:
            revokeTask = Task.detached { try server.revokeToken() }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        secretStore.resumeRead()

        let startResult = await startTask.result
        if let revokeTask { _ = try await revokeTask.value }
        if case .success = startResult {
            throw CoreCheckError.assertionFailed("\(action) allowed an in-flight start to publish credentials")
        }
        try require(server.credentials() == nil, "\(action) left credentials active")
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-start-superseded-\(UUID().uuidString)", isDirectory: true)
    let store = LibraryStore(rootURL: root)
    let secretStore = BlockingSecretStore(value: "old-token")
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let firstStart = Task { try await server.startWithCredentials(port: try availablePort()) }
    let firstReadStarted = await Task.detached { secretStore.waitForRead() }.value
    try require(firstReadStarted, "first start did not reach credential loading")
    let secondStart = Task { try await server.startWithCredentials(port: try availablePort()) }
    try await Task.sleep(nanoseconds: 100_000_000)
    secretStore.resumeRead()
    let firstResult = await firstStart.result
    let secondReadStarted = await Task.detached { secretStore.waitForRead() }.value
    try require(secondReadStarted, "second start did not reach credential loading")
    secretStore.resumeRead()
    let secondResult = await secondStart.result
    if case .success = firstResult {
        throw CoreCheckError.assertionFailed("a superseded start published credentials")
    }
    if case .failure(let error) = secondResult { throw error }

    print("api-start-races: passed")
}

private func checkAPIRevocationPersistence() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-revoke-persistence-\(UUID().uuidString)", isDirectory: true)
    let store = LibraryStore(rootURL: root)
    let oldToken = "old-revoked-token"
    let secretStore = MemorySecretStore(value: oldToken, failsDeletion: true)
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    _ = try await server.startWithCredentials(port: try availablePort())
    do {
        try server.revokeToken()
        throw CoreCheckError.assertionFailed("synthetic deletion failure was not surfaced")
    } catch SyntheticSecretStoreError.deletionFailed {
        // Expected: the durable token must still have been replaced first.
    }

    let restarted = LocalAPIServer(store: store, secretStore: secretStore)
    defer { restarted.stop() }
    let credentials = try await restarted.startWithCredentials(port: try availablePort())
    try require(credentials.token != oldToken, "failed deletion allowed the revoked token to be reused")

    let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.revoke-persistence")
    defer { connection.cancel() }
    let request = "GET /health HTTP/1.1\r\nAuthorization: Bearer \(oldToken)\r\n\r\n"
    try await send(Data(request.utf8), on: connection)
    let response = try await withTimeout(seconds: 2, onTimeout: { connection.cancel() }) {
        await receiveAll(on: connection)
    }
    try require(String(decoding: response, as: UTF8.self).contains("401 Unauthorised"), "old token was accepted")

    print("api-revoke-persistence: passed")
}

private func checkAPIPublicErrors() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-error-\(UUID().uuidString)")
    try Data("synthetic obstruction".utf8).write(to: root)
    let store = LibraryStore(rootURL: root)
    let secretStore = MemorySecretStore(value: "synthetic-token")
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let credentials = try await server.startWithCredentials(port: try availablePort())
    let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.public-error")
    defer { connection.cancel() }
    let request = "GET /v1/records?q=synthetic HTTP/1.1\r\nAuthorization: Bearer \(credentials.token)\r\n\r\n"
    try await send(Data(request.utf8), on: connection)
    let response = try await withTimeout(seconds: 2, onTimeout: { connection.cancel() }) {
        await receiveAll(on: connection)
    }
    let responseText = String(decoding: response, as: UTF8.self)
    try require(responseText.contains("\"error\":\"Internal server error\""), "500 response did not use fixed public text")
    try require(!responseText.contains(root.path), "500 response exposed a storage path")

    print("api-public-errors: passed")
}

private func checkMCPPublicOutput() async throws {
    let syntheticHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-mcp-output-\(UUID().uuidString)", isDirectory: true)
    let libraryRoot = syntheticHome
        .appendingPathComponent("Library/Application Support/Evee", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: syntheticHome) }

    let visibleText = String(repeating: "a", count: 110)
        + " boundary "
        + String(repeating: "b", count: 180)
    let record = WorkspaceRecord(
        kind: .meeting,
        title: "Synthetic MCP",
        text: visibleText,
        rawText: "Private raw",
        audioRelativePath: "Audio/private.caf",
        notes: "Allowed notes outside snippet",
        recoverySourceID: UUID(),
        context: WorkspaceContext(selectedText: "Private selection")
    )
    let library = LibraryStore(rootURL: libraryRoot)
    var settings = EveeSettings()
    settings.mcpEnabled = true
    try await library.save(settings)
    try await library.upsert(record)

    let executable = Bundle.main.executableURL!
        .deletingLastPathComponent()
        .appendingPathComponent("evee-mcp")
    try require(FileManager.default.isExecutableFile(atPath: executable.path), "build evee-mcp before running mcp-public-output")

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["CFFIXED_USER_HOME"] = syntheticHome.path
    process.environment = environment
    try process.run()

    let request: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": [
            "name": "search",
            "arguments": ["query": "boundary", "limit": 5],
        ],
    ]
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
    try input.fileHandleForWriting.close()
    let responseData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "evee-mcp failed: \(String(decoding: errorData, as: UTF8.self))")

    let response = try JSONSerialization.jsonObject(with: responseData) as! [String: Any]
    let result = response["result"] as! [String: Any]
    let content = result["content"] as! [[String: Any]]
    let publicText = content[0]["text"] as! String
    let hits = try JSONSerialization.jsonObject(with: Data(publicText.utf8)) as! [[String: Any]]
    try require(hits.count == 1, "MCP search did not return the synthetic record")
    let hit = hits[0]
    let publicRecord = hit["record"] as! [String: Any]
    let snippet = hit["snippet"] as! String

    for forbidden in ["rawText", "audioRelativePath", "audioTracks", "recoverySourceID", "webhookDeliveries", "operation", "context"] {
        try require(publicRecord[forbidden] == nil, "MCP output exposed \(forbidden)")
    }
    try require(publicRecord["text"] as? String == visibleText, "MCP output omitted requested record text")
    try require(snippet.contains("boundary"), "MCP snippet omitted the query boundary")
    try require(snippet.count <= 248, "MCP snippet exceeded its public boundary")
    try require(!snippet.contains("Allowed notes outside snippet"), "MCP snippet crossed its query boundary")
    try require(!publicText.contains("Private raw") && !publicText.contains("private.caf") && !publicText.contains("Private selection"), "MCP output exposed private persistence data")

    print("mcp-public-output: passed")
}

private func readMCPResponse(from handle: FileHandle) throws -> [String: Any] {
    let data = handle.availableData
    try require(!data.isEmpty, "evee-mcp closed without a response")
    let line: Data
    if let newline = data.firstIndex(of: 0x0A) {
        line = data.subdata(in: data.startIndex..<newline)
    } else {
        line = data
    }
    guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw CoreCheckError.assertionFailed("evee-mcp returned a non-object response")
    }
    return response
}

private func writeMCPRequest(_ request: [String: Any], to handle: FileHandle) throws {
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
}

private func checkMCPRevocation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-mcp-revocation-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
    let codexConfiguration = codexDirectory.appendingPathComponent("config.toml")
    let jsonConfiguration = root.appendingPathComponent("client/config.json")
    let executable = root.appendingPathComponent("Helpers/evee-mcp")
    defer { try? FileManager.default.removeItem(at: root) }

    let legacy = try JSONDecoder().decode(EveeSettings.self, from: Data("{}".utf8))
    try require(!legacy.mcpEnabled, "legacy settings enabled local helper access")

    try FileManager.default.createDirectory(at: jsonConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"display\":\"compact\",\"mcpServers\":{\"evee\":{\"command\":\"old\"},\"other\":{\"command\":\"other\"}}}".utf8).write(to: jsonConfiguration)
    let removal = try MCPRegistration.removeConfiguration(at: jsonConfiguration)
    try require(removal.removedRegistration, "JSON Evee registration was not removed")
    let jsonRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonConfiguration)) as! [String: Any]
    let servers = jsonRoot["mcpServers"] as! [String: Any]
    try require(servers["evee"] == nil, "JSON Evee registration remained")
    try require(servers["other"] != nil && jsonRoot["display"] as? String == "compact", "JSON removal changed unrelated configuration")

    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let noClients = MCPRegistration.detectedClients(fileManager: .default, homeURL: home, applicationSupportURL: support)
    try require(noClients.isEmpty, "empty synthetic home detected a fallback MCP client")
    let noWrites = try MCPRegistration.writeDetectedClientConfigurations(fileManager: .default, homeURL: home, applicationSupportURL: support)
    try require(noWrites.isEmpty, "empty synthetic home produced fallback registration results")
    try require(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Claude/claude_desktop_config.json").path), "fallback Claude configuration was written")

    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let originalCodex = "model = \"gpt-test\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"
    try Data(originalCodex.utf8).write(to: codexConfiguration)
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let registrationRoot = support.appendingPathComponent("Evee", isDirectory: true)
    let selectedConfiguration = home.appendingPathComponent(".selected/mcp.json")
    let manualConfiguration = home.appendingPathComponent(".manual/mcp.json")
    try FileManager.default.createDirectory(at: selectedConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: manualConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let selectedOriginal = Data("{\"theme\":\"dark\",\"mcpServers\":{\"evee\":{\"command\":\"prior\",\"args\":[\"keep\"]},\"other\":{\"command\":\"other\"}}}".utf8)
    let manualOriginal = Data("{\"mcpServers\":{\"evee\":{\"command\":\"manual\"}}}".utf8)
    try selectedOriginal.write(to: selectedConfiguration)
    try manualOriginal.write(to: manualConfiguration)
    var accessSettings = EveeSettings()
    let ownedResults = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Selected", configurationURL: selectedConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { settings in
            try require(settings.mcpEnabled, "enable persisted disabled authorization")
        }
    )
    try require(ownedResults.count == 1 && ownedResults[0].replacedExistingRegistration, "selected pre-existing registration was not recorded")
    accessSettings.mcpEnabled = true
    let ownedRevocation = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { settings in
            try require(!settings.mcpEnabled, "revoke did not persist fail-closed authorization first")
        }
    )
    try require(ownedRevocation.cleanupFailures.isEmpty, "selected registration cleanup failed")
    let selectedRestored = try Data(contentsOf: selectedConfiguration)
    let manualRestored = try Data(contentsOf: manualConfiguration)
    try require(selectedRestored == selectedOriginal, "selected pre-existing registration was not restored exactly")
    try require(manualRestored == manualOriginal, "unselected markerless registration was changed")
    try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "owned manifest remained after successful revoke")

    let failedSaveConfiguration = home.appendingPathComponent(".save-failure/new/client.json")
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Save failure", configurationURL: failedSaveConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { settings in
                if settings.mcpEnabled { throw SyntheticMCPPersistenceError.rejected }
            }
        )
        throw CoreCheckError.assertionFailed("enable settings save failure was ignored")
    } catch SyntheticMCPPersistenceError.rejected {
        // Expected.
    }
    try require(!FileManager.default.fileExists(atPath: failedSaveConfiguration.path), "enable save failure left a registration")
    try require(!FileManager.default.fileExists(atPath: failedSaveConfiguration.deletingLastPathComponent().path), "enable rollback left a transaction-created directory")

    let failedRestoreConfiguration = home.appendingPathComponent(".restore-failure/new/client.json")
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Restore failure", configurationURL: failedRestoreConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { settings in
                if settings.mcpEnabled { throw SyntheticMCPPersistenceError.rejected }
            },
            testing: MCPRegistrationTesting(beforeRestore: { _ in throw SyntheticMCPPersistenceError.restoreRejected })
        )
        throw CoreCheckError.assertionFailed("injected rollback failure was ignored")
    } catch MCPOwnedRegistrationError.rollbackFailed(_, let failures) {
        try require(failures.count == 1 && failures[0].contains(failedRestoreConfiguration.path), "rollback did not aggregate the restore failure")
    }
    try require(FileManager.default.fileExists(atPath: failedRestoreConfiguration.path), "failed rollback was reported without its unrestored file")
    var rollbackCleanupSettings = EveeSettings()
    rollbackCleanupSettings.mcpEnabled = true
    let rollbackCleanup = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: rollbackCleanupSettings,
        saveSettings: { _ in }
    )
    try require(rollbackCleanup.cleanupFailures.isEmpty, "a later revoke could not finish an injected failed rollback")
    try require(!FileManager.default.fileExists(atPath: failedRestoreConfiguration.deletingLastPathComponent().path), "later cleanup left a transaction-created directory")

    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Selected", configurationURL: selectedConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    do {
        _ = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: accessSettings,
            saveSettings: { _ in throw SyntheticMCPPersistenceError.rejected }
        )
        throw CoreCheckError.assertionFailed("disable settings save failure was ignored")
    } catch SyntheticMCPPersistenceError.rejected {
        // Expected.
    }
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "failed disable discarded ownership manifest")
    let stillRegisteredRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: selectedConfiguration)) as! [String: Any]
    let stillRegisteredServers = stillRegisteredRoot["mcpServers"] as! [String: Any]
    let stillRegisteredEvee = stillRegisteredServers["evee"] as! [String: Any]
    try require(stillRegisteredEvee["command"] as? String == executable.path, "failed disable cleaned registration despite remaining enabled")
    _ = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )

    let metadataDirectory = home.appendingPathComponent(".metadata", isDirectory: true)
    let metadataTarget = metadataDirectory.appendingPathComponent("actual.json")
    let metadataLink = metadataDirectory.appendingPathComponent("linked.json")
    try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
    let metadataOriginal = Data("{\"mcpServers\":{\"other\":{\"command\":\"other\"}}}".utf8)
    try metadataOriginal.write(to: metadataTarget)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: metadataTarget.path)
    let metadataAttributeName = "user.evee.core-check"
    let metadataAttributeValue = Data("preserved".utf8)
    let metadataAttributeWrite = metadataAttributeValue.withUnsafeBytes {
        setxattr(metadataTarget.path, metadataAttributeName, $0.baseAddress, metadataAttributeValue.count, 0, 0)
    }
    try require(metadataAttributeWrite == 0, "test could not set synthetic configuration metadata")
    try FileManager.default.createSymbolicLink(atPath: metadataLink.path, withDestinationPath: "actual.json")
    let targetAttributes = try FileManager.default.attributesOfItem(atPath: metadataTarget.path)
    let targetInode = targetAttributes[.systemFileNumber] as? NSNumber
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Linked", configurationURL: metadataLink)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    _ = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )
    let restoredAttributes = try FileManager.default.attributesOfItem(atPath: metadataTarget.path)
    try require((restoredAttributes[.systemFileNumber] as? NSNumber) == targetInode, "registration replaced the existing target file identity")
    try require((restoredAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, "registration did not restore the target mode")
    let restoredLinkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: metadataLink.path)
    let restoredMetadata = try Data(contentsOf: metadataTarget)
    let restoredAttributeSize = getxattr(metadataTarget.path, metadataAttributeName, nil, 0, 0, 0)
    var restoredAttribute = Data(count: max(0, restoredAttributeSize))
    let restoredAttributeCapacity = restoredAttribute.count
    let restoredAttributeRead = restoredAttribute.withUnsafeMutableBytes {
        getxattr(metadataTarget.path, metadataAttributeName, $0.baseAddress, restoredAttributeCapacity, 0, 0)
    }
    try require(restoredLinkDestination == "actual.json", "registration replaced or changed the configuration symlink")
    try require(restoredMetadata == metadataOriginal, "symlink target content was not restored")
    try require(restoredAttributeRead == metadataAttributeValue.count && restoredAttribute == metadataAttributeValue, "registration did not preserve target extended attributes")

    let escapedTarget = root.appendingPathComponent("outside-home.json")
    let escapedLink = metadataDirectory.appendingPathComponent("escaped.json")
    let escapedOriginal = Data("{\"outside\":true}".utf8)
    try escapedOriginal.write(to: escapedTarget)
    try FileManager.default.createSymbolicLink(atPath: escapedLink.path, withDestinationPath: escapedTarget.path)
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Escaped", configurationURL: escapedLink)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in }
        )
        throw CoreCheckError.assertionFailed("registration accepted a symlink escaping the approved configuration root")
    } catch MCPOwnedRegistrationError.unsafeConfiguration {
        // Expected.
    }
    let escapedRestored = try Data(contentsOf: escapedTarget)
    try require(escapedRestored == escapedOriginal, "rejected symlink escape changed its target")

    let partialGood = metadataDirectory.appendingPathComponent("partial-good.json")
    let partialTarget = metadataDirectory.appendingPathComponent("partial-target.json")
    let partialAlternate = metadataDirectory.appendingPathComponent("partial-alternate.json")
    let partialLink = metadataDirectory.appendingPathComponent("partial-link.json")
    let partialGoodOriginal = Data("{\"keep\":\"good\"}".utf8)
    let partialTargetOriginal = Data("{\"keep\":\"linked\"}".utf8)
    try partialGoodOriginal.write(to: partialGood)
    try partialTargetOriginal.write(to: partialTarget)
    try Data("{\"keep\":\"alternate\"}".utf8).write(to: partialAlternate)
    try FileManager.default.createSymbolicLink(atPath: partialLink.path, withDestinationPath: "partial-target.json")
    _ = try await MCPOwnedRegistration.enable(
        clients: [
            MCPClientConfiguration(name: "Partial good", configurationURL: partialGood),
            MCPClientConfiguration(name: "Partial linked", configurationURL: partialLink),
        ],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    try FileManager.default.removeItem(at: partialLink)
    try FileManager.default.createSymbolicLink(atPath: partialLink.path, withDestinationPath: "partial-alternate.json")
    let partialOutcome = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { settings in
            try require(!settings.mcpEnabled, "partial cleanup ran before fail-closed persistence")
        }
    )
    try require(partialOutcome.removals.count == 1 && partialOutcome.cleanupFailures.count == 1, "partial cleanup did not accurately separate restored and failed targets")
    let partialGoodRestored = try Data(contentsOf: partialGood)
    try require(partialGoodRestored == partialGoodOriginal, "partial revoke did not restore its safe target")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "partial cleanup discarded the remaining ownership snapshot")
    try FileManager.default.removeItem(at: partialLink)
    try FileManager.default.createSymbolicLink(atPath: partialLink.path, withDestinationPath: "partial-target.json")
    var alreadyDisabled = accessSettings
    alreadyDisabled.mcpEnabled = false
    let completedPartialCleanup = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: alreadyDisabled,
        saveSettings: { _ in }
    )
    try require(completedPartialCleanup.cleanupFailures.isEmpty, "retry did not complete partial cleanup")
    let partialTargetRestored = try Data(contentsOf: partialTarget)
    try require(partialTargetRestored == partialTargetOriginal, "retry did not restore the previously unsafe target")

    let firstTransactionalConfiguration = root.appendingPathComponent("transaction/first.json")
    let secondTransactionalConfiguration = root.appendingPathComponent("transaction/second.json")
    try FileManager.default.createDirectory(at: firstTransactionalConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstTransactionalConfiguration.deletingLastPathComponent().path)
    let originalFirstConfiguration = Data("{\"keep\":true,\"mcpServers\":{\"other\":{\"command\":\"other\"}}}".utf8)
    let originalSecondConfiguration = Data("[]".utf8)
    try originalFirstConfiguration.write(to: firstTransactionalConfiguration)
    try originalSecondConfiguration.write(to: secondTransactionalConfiguration)
    do {
        _ = try MCPRegistration.writeConfigurations(
            for: [
                MCPClientConfiguration(name: "First", configurationURL: firstTransactionalConfiguration),
                MCPClientConfiguration(name: "Second", configurationURL: secondTransactionalConfiguration),
            ],
            executableURL: executable
        )
        throw CoreCheckError.assertionFailed("invalid later client configuration did not fail registration")
    } catch MCPRegistrationError.invalidConfiguration {
        // Expected.
    }
    let restoredFirstConfiguration = try Data(contentsOf: firstTransactionalConfiguration)
    let restoredSecondConfiguration = try Data(contentsOf: secondTransactionalConfiguration)
    try require(restoredFirstConfiguration == originalFirstConfiguration, "failed registration did not restore an earlier client exactly")
    try require(restoredSecondConfiguration == originalSecondConfiguration, "failed registration changed the rejecting client")
    let transactionDirectoryPermissions = try FileManager.default.attributesOfItem(atPath: firstTransactionalConfiguration.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    try require(transactionDirectoryPermissions?.intValue == 0o755, "registration changed permissions on an existing client directory")

    let codexClients = MCPRegistration.detectedClients(fileManager: .default, homeURL: home, applicationSupportURL: support)
    try require(codexClients.map(\.name) == ["Codex"], "Codex configuration was not detected exactly")
    _ = try MCPRegistration.writeConfiguration(at: codexConfiguration, executableURL: executable)
    let registeredCodex = try String(contentsOf: codexConfiguration)
    try require(registeredCodex.contains("[mcp_servers.evee]"), "Codex Evee table was not registered")
    let codexRemoval = try MCPRegistration.removeConfiguration(at: codexConfiguration)
    try require(codexRemoval.removedRegistration, "Codex Evee table was not removed")
    let restoredCodex = try String(contentsOf: codexConfiguration)
    try require(restoredCodex == originalCodex, "Codex round trip changed unrelated configuration")

    let packagedHelper = Bundle.main.executableURL!
        .deletingLastPathComponent()
        .appendingPathComponent("evee-mcp")
    try require(FileManager.default.isExecutableFile(atPath: packagedHelper.path), "build evee-mcp before running mcp-revocation")
    let libraryRoot = support.appendingPathComponent("Evee", isDirectory: true)
    let library = LibraryStore(rootURL: libraryRoot)
    var enabled = EveeSettings()
    enabled.mcpEnabled = true
    try await library.save(enabled)
    try await library.upsert(WorkspaceRecord(kind: .memo, title: "Synthetic private workspace", text: "revocation sentinel"))

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = packagedHelper
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["CFFIXED_USER_HOME"] = home.path
    process.environment = environment
    try process.run()
    try writeMCPRequest(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]], to: input.fileHandleForWriting)
    let initialized = try readMCPResponse(from: output.fileHandleForReading)
    try require(initialized["error"] == nil, "enabled helper rejected initialize")

    let invalidCalls: [(Int, String, [String: Any])] = [
        (2, "search", ["query": "revocation", "kind": "unknown"]),
        (3, "recent_activity", ["since": "not-a-date"]),
        (4, "recent_activity", ["limit": 0]),
        (5, "get_memo", ["id": "not-a-uuid"]),
    ]
    for (identifier, name, arguments) in invalidCalls {
        try writeMCPRequest([
            "jsonrpc": "2.0",
            "id": identifier,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ], to: input.fileHandleForWriting)
        let response = try readMCPResponse(from: output.fileHandleForReading)
        let invalidError = response["error"] as? [String: Any]
        try require(invalidError?["code"] as? Int == -32602, "malformed \(name) arguments did not return invalid parameters")
        let responseText = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        try require(!responseText.contains("revocation sentinel"), "malformed \(name) arguments broadened into workspace data")
    }

    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "evee-mcp failed: \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

    let leaseAcquired = root.appendingPathComponent("lease-acquired")
    let releaseLease = root.appendingPathComponent("release-lease")
    let revokeReturned = root.appendingPathComponent("revoke-returned")
    let raceProcess = Process()
    let raceInput = Pipe()
    let raceOutput = Pipe()
    let raceErrors = Pipe()
    raceProcess.executableURL = packagedHelper
    raceProcess.standardInput = raceInput
    raceProcess.standardOutput = raceOutput
    raceProcess.standardError = raceErrors
    environment["EVEE_MCP_TEST_LEASE_ACQUIRED_PATH"] = leaseAcquired.path
    environment["EVEE_MCP_TEST_LEASE_RELEASE_PATH"] = releaseLease.path
    raceProcess.environment = environment
    try raceProcess.run()
    try writeMCPRequest([
        "jsonrpc": "2.0",
        "id": 6,
        "method": "tools/call",
        "params": ["name": "search", "arguments": ["query": "revocation"]],
    ], to: raceInput.fileHandleForWriting)
    let leaseDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: leaseAcquired.path), Date() < leaseDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try require(FileManager.default.fileExists(atPath: leaseAcquired.path), "helper did not acquire its workspace read lease")
    let revokeTask = Task {
        let outcome = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [home],
            storageRootURL: libraryRoot,
            settings: enabled,
            saveSettings: { settings in try await library.save(settings) }
        )
        try Data().write(to: revokeReturned)
        return outcome
    }
    try await Task.sleep(for: .milliseconds(150))
    try require(!FileManager.default.fileExists(atPath: revokeReturned.path), "revoke returned while an earlier workspace read lease was suspended")
    try Data().write(to: releaseLease)
    let preRevokeRead = try readMCPResponse(from: raceOutput.fileHandleForReading)
    let preRevokeText = String(decoding: try JSONSerialization.data(withJSONObject: preRevokeRead), as: UTF8.self)
    try require(preRevokeText.contains("revocation sentinel"), "the read that began before revoke acquired exclusivity did not complete")
    let raceRevocation = try await revokeTask.value
    try require(raceRevocation.cleanupFailures.isEmpty, "authorization-only revoke reported cleanup failures")
    try require(FileManager.default.fileExists(atPath: revokeReturned.path), "revoke did not return after the earlier read released its lease")

    try writeMCPRequest([
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/call",
        "params": ["name": "search", "arguments": ["query": "revocation"]],
    ], to: raceInput.fileHandleForWriting)
    let revoked = try readMCPResponse(from: raceOutput.fileHandleForReading)
    let error = revoked["error"] as? [String: Any]
    try require(error?["code"] as? Int == -32001, "revoked helper did not return the access-disabled error")
    try require((error?["message"] as? String)?.localizedCaseInsensitiveContains("enable local helper access in Evee") == true, "revoked helper error did not explain how to enable access")
    let revokedResponse = String(decoding: try JSONSerialization.data(withJSONObject: revoked), as: UTF8.self)
    try require(!revokedResponse.contains("revocation sentinel"), "revoked helper exposed workspace data")
    try raceInput.fileHandleForWriting.close()
    raceProcess.waitUntilExit()
    try require(raceProcess.terminationStatus == 0, "evee-mcp race process failed: \(String(decoding: raceErrors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

    let disabledProcess = Process()
    let disabledInput = Pipe()
    let disabledOutput = Pipe()
    disabledProcess.executableURL = packagedHelper
    disabledProcess.standardInput = disabledInput
    disabledProcess.standardOutput = disabledOutput
    disabledProcess.standardError = Pipe()
    disabledProcess.environment = environment
    try disabledProcess.run()
    try writeMCPRequest(["jsonrpc": "2.0", "id": 8, "method": "initialize", "params": [:]], to: disabledInput.fileHandleForWriting)
    try disabledInput.fileHandleForWriting.close()
    let disabledInitialize = try readMCPResponse(from: disabledOutput.fileHandleForReading)
    disabledProcess.waitUntilExit()
    let disabledError = disabledInitialize["error"] as? [String: Any]
    try require(disabledError?["code"] as? Int == -32001, "disabled helper accepted initialize")

    print("mcp-revocation: passed")
}

let arguments = CommandLine.arguments.dropFirst()
if arguments == ["--filter", "context-policy"] {
    checkContextPolicy()
} else if arguments == ["--filter", "public-record"] {
    try checkPublicRecord()
} else if arguments == ["--filter", "api-revoke"] {
    try await checkAPIRevocation()
} else if arguments == ["--filter", "api-rotate"] {
    try await checkAPIRotation()
} else if arguments == ["--filter", "api-limits"] {
    try await checkAPILimits()
} else if arguments == ["--filter", "api-start-races"] {
    try await checkAPIStartRaces()
} else if arguments == ["--filter", "api-revoke-persistence"] {
    try await checkAPIRevocationPersistence()
} else if arguments == ["--filter", "api-public-errors"] {
    try await checkAPIPublicErrors()
} else if arguments == ["--filter", "mcp-public-output"] {
    try await checkMCPPublicOutput()
} else if arguments == ["--filter", "mcp-revocation"] {
    try await checkMCPRevocation()
} else if arguments == ["--filter", "webhook-generation"] {
    try await checkWebhookGeneration()
} else if arguments == ["--filter", "webhook-signature"] {
    try checkWebhookSignature()
} else if arguments == ["--filter", "webhook-transactions"] {
    try await checkWebhookTransactions()
} else {
    fputs("usage: evee-core-checks --filter <context-policy|public-record|api-revoke|api-rotate|api-limits|api-start-races|api-revoke-persistence|api-public-errors|mcp-public-output|mcp-revocation|webhook-generation|webhook-signature|webhook-transactions>\n", stderr)
    exit(EXIT_FAILURE)
}
