import CryptoKit
import Foundation

public struct MeetingWebhook: Sendable {
    public init() {}

    public func send(record: WorkspaceRecord, destination: URL, secret: String) async throws {
        var request = URLRequest(url: destination)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(record)
        request.httpBody = body

        if !secret.isEmpty {
            let key = SymmetricKey(data: Data(secret.utf8))
            let signature = HMAC<SHA256>.authenticationCode(for: body, using: key)
            request.setValue(Data(signature).map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-Evee-Signature-256")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
