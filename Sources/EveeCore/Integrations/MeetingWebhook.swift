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
    case sensitiveURLComponents

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid webhook URL with a host."
        case .insecureTransport: "Meeting webhooks require HTTPS. HTTP is allowed only for localhost development."
        case .embeddedCredentials: "Webhook URLs cannot contain usernames or passwords. Use the signing secret instead."
        case .sensitiveURLComponents: "Webhook URLs cannot contain query parameters or fragments. Use the signing secret instead."
        }
    }
}

public enum WebhookPayloadError: LocalizedError, Sendable {
    case empty
    case tooLarge
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .empty: "The webhook payload is empty."
        case .tooLarge: "The webhook payload is too large to queue safely."
        case .invalidJSON: "The webhook payload is not valid JSON."
        }
    }
}

public enum WebhookEndpointPolicy {
    public static func validate(_ destination: URL) throws {
        guard let scheme = destination.scheme?.lowercased(), let host = destination.host?.lowercased(), !host.isEmpty else {
            throw WebhookEndpointError.invalidURL
        }
        guard destination.user == nil, destination.password == nil else { throw WebhookEndpointError.embeddedCredentials }
        guard destination.query == nil, destination.fragment == nil else { throw WebhookEndpointError.sensitiveURLComponents }
        if scheme == "https" { return }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "http", loopback else { throw WebhookEndpointError.insecureTransport }
    }
}

public struct MeetingWebhook: Sendable {
    public static let maximumPayloadSize = 10 * 1_024 * 1_024
    public static let eventName = "meeting.completed"
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
        maxAttempts: Int = 3,
        payloadBody: Data? = nil,
        startingAttemptCount: Int = 0
    ) async throws -> WebhookDeliveryReceipt {
        try WebhookEndpointPolicy.validate(destination)
        let body: Data
        if let payloadBody {
            body = payloadBody
        } else {
            body = try Self.payload(for: record)
        }
        try Self.validatePayload(body)
        let attempts = max(1, min(maxAttempts, 5))
        var delivery = WebhookDelivery(
            id: deliveryID,
            destination: destination.absoluteString,
            attemptCount: startingAttemptCount,
            payloadBody: body
        )

        for attempt in 1...attempts {
            delivery.attemptCount = startingAttemptCount + attempt
            let attemptDate = Date.now
            delivery.lastAttemptAt = attemptDate
            do {
                var request = URLRequest(url: destination)
                request.httpMethod = "POST"
                request.httpBody = body
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(Self.eventName, forHTTPHeaderField: "X-Evee-Event")
                request.setValue(deliveryID.uuidString, forHTTPHeaderField: "X-Evee-Delivery-ID")
                request.setValue(deliveryID.uuidString, forHTTPHeaderField: "Idempotency-Key")
                let timestamp = ISO8601DateFormatter().string(from: attemptDate)
                request.setValue(timestamp, forHTTPHeaderField: "X-Evee-Delivery-Timestamp")

                if !secret.isEmpty {
                    request.setValue(Self.signature(
                        body: body,
                        secret: secret,
                        event: Self.eventName,
                        deliveryID: deliveryID,
                        timestamp: timestamp
                    ), forHTTPHeaderField: "X-Evee-Signature-256")
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
                    delivery.retryable = Self.isTransient(statusCode: http.statusCode)
                    delivery.nextAttemptAt = delivery.retryable ? Self.nextAttempt(after: delivery.attemptCount) : nil
                    delivery.lastError = "Webhook returned HTTP \(http.statusCode)."
                    throw WebhookDeliveryFailure(delivery: delivery)
                }

                let deliveredAt = Date.now
                return WebhookDeliveryReceipt(
                    deliveryID: deliveryID,
                    destination: destination,
                    attemptCount: delivery.attemptCount,
                    statusCode: http.statusCode,
                    deliveredAt: deliveredAt
                )
            } catch let failure as WebhookDeliveryFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                let retryable = Self.isTransient(error: error)
                delivery.lastError = Self.failureMessage(for: error)
                if attempt < attempts, retryable {
                    try await backoff(after: attempt)
                    continue
                }
                delivery.state = .failed
                delivery.retryable = retryable
                delivery.nextAttemptAt = retryable ? Self.nextAttempt(after: delivery.attemptCount) : nil
                throw WebhookDeliveryFailure(delivery: delivery)
            }
        }

        delivery.state = .failed
        delivery.retryable = true
        delivery.nextAttemptAt = Self.nextAttempt(after: delivery.attemptCount)
        delivery.lastError = delivery.lastError ?? "Webhook delivery exhausted all attempts."
        throw WebhookDeliveryFailure(delivery: delivery)
    }

    public static func signature(for body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }

    public static func signature(
        body: Data,
        secret: String,
        event: String,
        deliveryID: UUID,
        timestamp: String
    ) -> String {
        let input = canonicalSignatureInput(
            body: body,
            event: event,
            deliveryID: deliveryID,
            timestamp: timestamp
        )
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: input, using: key)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalSignatureInput(
        body: Data,
        event: String,
        deliveryID: UUID,
        timestamp: String
    ) -> Data {
        let bodyDigest = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }
            .joined()
        let fields = [
            ("event", event),
            ("timestamp", timestamp),
            ("delivery-id", deliveryID.uuidString),
            ("body-sha256", bodyDigest),
        ]
        var input = Data("evee-webhook-v1\n".utf8)
        for (name, value) in fields {
            input.append(Data("\(name):\(value.utf8.count)\n".utf8))
            input.append(Data(value.utf8))
            input.append(0x0A)
        }
        return input
    }

    public static func payload(for record: WorkspaceRecord) throws -> Data {
        var stable = record
        stable.webhookDeliveries = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stable)
    }

    public static func validatePayload(_ body: Data) throws {
        guard !body.isEmpty else { throw WebhookPayloadError.empty }
        guard body.count <= maximumPayloadSize else { throw WebhookPayloadError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: body),
              JSONSerialization.isValidJSONObject(object) else {
            throw WebhookPayloadError.invalidJSON
        }
    }

    private static func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isTransient(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func failureMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else { return "Webhook delivery failed before a response was received." }
        switch urlError.code {
        case .timedOut: return "Webhook delivery timed out."
        case .cancelled: return "Webhook delivery was cancelled."
        case .notConnectedToInternet: return "Webhook delivery is waiting for a network connection."
        case .cannotFindHost, .dnsLookupFailed: return "The webhook host could not be resolved."
        case .cannotConnectToHost, .networkConnectionLost: return "The webhook host could not be reached."
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return "The webhook connection could not be secured."
        default: return "Webhook delivery failed before a response was received."
        }
    }

    private static func nextAttempt(after attemptCount: Int) -> Date {
        let exponent = min(max(attemptCount, 1), 10)
        let seconds = min(TimeInterval(30 * (1 << (exponent - 1))), 21_600)
        return .now.addingTimeInterval(seconds)
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
        // Never follow redirects for signed POSTs. Some redirect status codes
        // rewrite the request as GET and could otherwise produce a false 2xx
        // delivery receipt without transmitting the signed body.
        completionHandler(nil)
    }
}
