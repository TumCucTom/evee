import CryptoKit
import Foundation

public struct WebhookDeliveryReceipt: Codable, Equatable, Sendable {
    public var deliveryID: UUID
    public var destination: URL
    public var attemptCount: Int
    public var statusCode: Int
    public var deliveredAt: Date

    public init(deliveryID: UUID, destination: URL, attemptCount: Int, statusCode: Int, deliveredAt: Date) {
        self.deliveryID = deliveryID
        self.destination = destination
        self.attemptCount = attemptCount
        self.statusCode = statusCode
        self.deliveredAt = deliveredAt
    }
}

public struct WebhookDeliveryFailure: LocalizedError, Sendable {
    public var delivery: WebhookDelivery

    public var errorDescription: String? {
        delivery.lastError ?? "The meeting webhook could not be delivered."
    }
}

public enum WebhookEndpointError: LocalizedError, Sendable {
    case invalidURL
    case insecureTransport
    case embeddedCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid webhook URL with a host."
        case .insecureTransport: "Meeting webhooks require HTTPS. HTTP is allowed only for localhost development."
        case .embeddedCredentials: "Webhook URLs cannot contain usernames or passwords. Use the signing secret instead."
        }
    }
}

public enum WebhookEndpointPolicy {
    public static func validate(_ destination: URL) throws {
        guard let scheme = destination.scheme?.lowercased(), let host = destination.host?.lowercased(), !host.isEmpty else {
            throw WebhookEndpointError.invalidURL
        }
        guard destination.user == nil, destination.password == nil else { throw WebhookEndpointError.embeddedCredentials }
        if scheme == "https" { return }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "http", loopback else { throw WebhookEndpointError.insecureTransport }
    }
}

public struct MeetingWebhook: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Compatibility entry point. Retries transient failures and throws a failure carrying
    /// replay-safe delivery metadata when all attempts are exhausted.
    public func send(record: WorkspaceRecord, destination: URL, secret: String) async throws {
        _ = try await sendWithStatus(record: record, destination: destination, secret: secret)
    }

    @discardableResult
    public func sendWithStatus(
        record: WorkspaceRecord,
        destination: URL,
        secret: String,
        deliveryID: UUID = UUID(),
        maxAttempts: Int = 3
    ) async throws -> WebhookDeliveryReceipt {
        try WebhookEndpointPolicy.validate(destination)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(record)
        let attempts = max(1, min(maxAttempts, 5))
        var delivery = WebhookDelivery(id: deliveryID, destination: destination.absoluteString)

        for attempt in 1...attempts {
            delivery.attemptCount = attempt
            delivery.lastAttemptAt = .now
            do {
                var request = URLRequest(url: destination)
                request.httpMethod = "POST"
                request.httpBody = body
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("meeting.completed", forHTTPHeaderField: "X-Evee-Event")
                request.setValue(deliveryID.uuidString, forHTTPHeaderField: "X-Evee-Delivery-ID")
                request.setValue(deliveryID.uuidString, forHTTPHeaderField: "Idempotency-Key")
                request.setValue(ISO8601DateFormatter().string(from: delivery.lastAttemptAt!), forHTTPHeaderField: "X-Evee-Delivery-Timestamp")

                if !secret.isEmpty {
                    request.setValue(Self.signature(for: body, secret: secret), forHTTPHeaderField: "X-Evee-Signature-256")
                }

                let (_, response) = try await session.data(for: request, delegate: SafeWebhookRedirectDelegate())
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                delivery.responseStatusCode = http.statusCode
                guard (200..<300).contains(http.statusCode) else {
                    if attempt < attempts, Self.isTransient(statusCode: http.statusCode) {
                        try await backoff(after: attempt)
                        continue
                    }
                    delivery.state = .failed
                    delivery.lastError = "Webhook returned HTTP \(http.statusCode)."
                    throw WebhookDeliveryFailure(delivery: delivery)
                }

                let deliveredAt = Date.now
                return WebhookDeliveryReceipt(
                    deliveryID: deliveryID,
                    destination: destination,
                    attemptCount: attempt,
                    statusCode: http.statusCode,
                    deliveredAt: deliveredAt
                )
            } catch let failure as WebhookDeliveryFailure {
                throw failure
            } catch {
                delivery.lastError = error.localizedDescription
                if attempt < attempts {
                    try await backoff(after: attempt)
                    continue
                }
                delivery.state = .failed
                throw WebhookDeliveryFailure(delivery: delivery)
            }
        }

        delivery.state = .failed
        delivery.lastError = delivery.lastError ?? "Webhook delivery exhausted all attempts."
        throw WebhookDeliveryFailure(delivery: delivery)
    }

    public static func signature(for body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }

    private static func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func backoff(after attempt: Int) async throws {
        let milliseconds = UInt64(min(250 * (1 << (attempt - 1)), 2_000))
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

private final class SafeWebhookRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            try WebhookEndpointPolicy.validate(request.url ?? URL(fileURLWithPath: "/"))
            completionHandler(request)
        } catch {
            completionHandler(nil)
        }
    }
}
