import Foundation
import XCTest
@testable import EveeCore

private final class SuspendedWebhookURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var suspended: SuspendedWebhookURLProtocol?
    private static var capturedRequest: URLRequest?
    private static var startedHandler: (@Sendable (URLRequest) -> Void)?

    static func prepare(started: @escaping @Sendable (URLRequest) -> Void) {
        lock.lock()
        suspended = nil
        capturedRequest = nil
        startedHandler = started
        lock.unlock()
    }

    static func release(statusCode: Int = 200) {
        lock.lock()
        let current = suspended
        suspended = nil
        capturedRequest = nil
        startedHandler = nil
        lock.unlock()
        guard let current,
              let response = HTTPURLResponse(
                url: current.request.url!,
                statusCode: statusCode,
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
        // The synthetic response is deliberately released after cancellation
        // so the test can exercise a late transport callback without a network.
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

final class WebhookOutboxTests: XCTestCase {
    func testQueuePersistenceInvalidatedBeforeFinalizeBecomesTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let transactions = WebhookOutboxTransactions()
        var record = WorkspaceRecord(kind: .meeting, title: "Queue race", text: "Synthetic")
        let delivery = WebhookDelivery(
            destination: "https://example.invalid/webhook",
            payloadBody: Data("{\"queued\":true}".utf8)
        )
        record.webhookDeliveries = [delivery]
        let token = transactions.beginPreparation()
        let attempts = LockedValues<UUID>()

        let transaction = await transactions.persistPreparation(token, records: [record]) { proposed in
            attempts.append(proposed.id)
            try await store.upsert(proposed)
            if attempts.values.count == 1 { _ = transactions.invalidate() }
        }
        guard case .cancel = transaction.decision else {
            return XCTFail("Invalidated queue preparation committed")
        }

        XCTAssertTrue(transaction.cancellation?.failures.isEmpty == true)
        XCTAssertEqual(attempts.values, [record.id, record.id])
        let stored = try await store.record(id: record.id)
        let persisted = try XCTUnwrap(stored)
        let persistedDelivery = try XCTUnwrap(persisted.webhookDeliveries.first)
        XCTAssertEqual(persistedDelivery.state, .cancelled)
        XCTAssertNil(persistedDelivery.payloadBody)
        XCTAssertFalse(persistedDelivery.retryable)
    }

    func testManualRetryInvalidatedDuringPersistenceCannotReviveCancelledRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let transactions = WebhookOutboxTransactions()
        let destination = "https://example.invalid/webhook"
        var record = WorkspaceRecord(kind: .meeting, title: "Retry race", text: "Synthetic")
        record.webhookDeliveries = [WebhookDelivery(
            destination: destination,
            state: .failed,
            attemptCount: 1,
            payloadBody: Data("{\"retry\":true}".utf8),
            retryable: true,
            nextAttemptAt: .now
        )]
        try await store.upsert(record)
        let token = transactions.beginPreparation()
        let retry = transactions.prepareManualRetry(records: [record], destination: destination)
        let attempts = LockedValues<UUID>()

        let transaction = await transactions.persistPreparation(token, records: retry.records) { proposed in
            attempts.append(proposed.id)
            try await store.upsert(proposed)
            if attempts.values.count == 1 { _ = transactions.invalidate() }
        }
        guard case .cancel = transaction.decision else {
            return XCTFail("Invalidated manual retry committed")
        }
        XCTAssertTrue(transaction.cancellation?.failures.isEmpty == true)
        XCTAssertEqual(attempts.values, [record.id, record.id])

        let stored = try await store.record(id: record.id)
        let persisted = try XCTUnwrap(stored)
        let persistedDelivery = try XCTUnwrap(persisted.webhookDeliveries.first)
        XCTAssertEqual(persistedDelivery.state, .cancelled)
        XCTAssertNil(persistedDelivery.payloadBody)
        XCTAssertFalse(persistedDelivery.retryable)
    }

    func testBatchPersistenceAttemptsRecordsAfterFailure() async {
        let transactions = WebhookOutboxTransactions()
        let records = [
            WorkspaceRecord(kind: .meeting, title: "First", text: "Synthetic"),
            WorkspaceRecord(kind: .meeting, title: "Second", text: "Synthetic"),
            WorkspaceRecord(kind: .meeting, title: "Third", text: "Synthetic"),
        ]
        let attempted = LockedValues<UUID>()

        let result = await transactions.persistAll(records) { record in
            attempted.append(record.id)
            if record.id == records[1].id { throw SyntheticWebhookTestError.rejected }
        }

        XCTAssertEqual(attempted.values, records.map(\.id))
        XCTAssertEqual(result.persistedRecordIDs, [records[0].id, records[2].id])
        XCTAssertEqual(result.failures.map(\.recordID), [records[1].id])
    }

    func testTerminationInvalidationSynchronouslyCancelsTasksAndPreparations() {
        let transactions = WebhookOutboxTransactions()
        let preparation = transactions.beginPreparation()
        let deliveryID = UUID()
        let dispatch = try! XCTUnwrap(transactions.beginDispatch(deliveryID: deliveryID))
        let task = transactions.startTask(for: dispatch) {
            try? await Task.sleep(for: .seconds(30))
        }

        let invalidation = transactions.invalidate()
        let decision = transactions.finalize(
            preparation,
            records: [WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Local")]
        )

        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(transactions.mayCommit(dispatch))
        XCTAssertNil(transactions.beginDispatch(
            deliveryID: UUID(),
            requiringGeneration: preparation.generation
        ))
        XCTAssertEqual(invalidation.deliveryIDs, [deliveryID])
        guard case .cancel = decision else {
            return XCTFail("Invalidated preparation committed")
        }
    }

    func testLateSuspendedResponseCannotOverwriteTerminalCancellation() async throws {
        let body = Data("{\"meeting\":\"synthetic\"}".utf8)
        let deliveryID = UUID(uuidString: "19CF6CE4-3841-4CF7-9888-679CC63B3364")!
        let destination = URL(string: "https://example.invalid/webhook")!
        let coordinator = WebhookOutboxCoordinator()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        var storedRecord = WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Local test")
        storedRecord.webhookDeliveries = [WebhookDelivery(
            id: deliveryID,
            destination: destination.absoluteString,
            payloadBody: body,
            nextAttemptAt: Date(timeIntervalSince1970: 1_786_616_100)
        )]
        try await store.upsert(storedRecord)
        let requestStarted = expectation(description: "synthetic webhook request suspended")
        let capturedRequest = LockIsolated<URLRequest?>(nil)
        SuspendedWebhookURLProtocol.prepare { request in
            capturedRequest.withValue { $0 = request }
            requestStarted.fulfill()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedWebhookURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let token = await coordinator.begin(deliveryID: deliveryID)
        let task = Task<Void, Never> {
            do {
                _ = try await MeetingWebhook(session: session).sendWithStatus(
                    record: storedRecord,
                    destination: destination,
                    secret: "synthetic-secret",
                    deliveryID: deliveryID,
                    maxAttempts: 1,
                    payloadBody: body
                )
                if await coordinator.mayCommit(token),
                   var current = try await store.record(id: storedRecord.id),
                   let index = current.webhookDeliveries.firstIndex(where: { $0.id == deliveryID }) {
                    current.webhookDeliveries[index].state = .delivered
                    current.webhookDeliveries[index].retryable = false
                    current.webhookDeliveries[index].payloadBody = nil
                    try await store.upsert(current)
                }
            } catch {
                if await coordinator.mayCommit(token),
                   var current = try? await store.record(id: storedRecord.id),
                   let index = current.webhookDeliveries.firstIndex(where: { $0.id == deliveryID }) {
                    current.webhookDeliveries[index].state = .failed
                    try? await store.upsert(current)
                }
            }
            await coordinator.finish(token)
        }
        await coordinator.register(task, for: token)
        await fulfillment(of: [requestStarted], timeout: 2)

        let request = try XCTUnwrap(capturedRequest.value)
        let transmittedBody = try XCTUnwrap(request.httpBody)
        let event = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Evee-Event"))
        let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Evee-Delivery-Timestamp"))
        XCTAssertEqual(transmittedBody, body)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Evee-Signature-256"),
            MeetingWebhook.signature(
                body: transmittedBody,
                secret: "synthetic-secret",
                event: event,
                deliveryID: deliveryID,
                timestamp: timestamp
            )
        )

        let cancelled = await coordinator.cancelAll()
        XCTAssertEqual(cancelled, [deliveryID])
        let persistedBeforeCancellation = try await store.record(id: storedRecord.id)
        var cancelledRecord = try XCTUnwrap(persistedBeforeCancellation)
        let cancelledIndex = try XCTUnwrap(cancelledRecord.webhookDeliveries.firstIndex(where: { $0.id == deliveryID }))
        cancelledRecord.webhookDeliveries[cancelledIndex].state = .cancelled
        cancelledRecord.webhookDeliveries[cancelledIndex].retryable = false
        cancelledRecord.webhookDeliveries[cancelledIndex].nextAttemptAt = nil
        cancelledRecord.webhookDeliveries[cancelledIndex].payloadBody = nil
        try await store.upsert(cancelledRecord)
        SuspendedWebhookURLProtocol.release()
        await task.value

        let persistedAfterLateResponse = try await store.record(id: storedRecord.id)
        let finalRecord = try XCTUnwrap(persistedAfterLateResponse)
        let final = try XCTUnwrap(finalRecord.webhookDeliveries.first(where: { $0.id == deliveryID }))
        XCTAssertEqual(final.state, .cancelled)
        XCTAssertFalse(final.retryable)
        XCTAssertNil(final.nextAttemptAt)
        XCTAssertNil(final.payloadBody)
    }
}

private enum SyntheticWebhookTestError: Error {
    case rejected
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

private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ operation: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation(&storage)
    }
}
