import Foundation
import Network

public struct LocalAPICredentials: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum LocalAPIServerError: LocalizedError, Sendable {
    case invalidPort(UInt16)
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "The local API port is invalid: \(port)."
        case .listenerFailed(let message): return "The local API could not start: \(message)"
        }
    }
}

public final class LocalAPIServer: @unchecked Sendable {
    private let store: LibraryStore
    private let secretStore: KeychainSecretStore
    private let queue = DispatchQueue(label: "com.tumcuctom.evee.api")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var token = ""
    private var currentCredentials: LocalAPICredentials?

    public init(store: LibraryStore = .shared, secretStore: KeychainSecretStore = KeychainSecretStore()) {
        self.store = store
        self.secretStore = secretStore
    }

    /// Backwards-compatible entry point used by the app.
    public func start(port: UInt16) async throws -> String {
        try await startWithCredentials(port: port).token
    }

    /// Starts a truly loopback-bound listener and returns everything needed to configure a client.
    public func startWithCredentials(port: UInt16) async throws -> LocalAPICredentials {
        stop()
        guard port > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else { throw LocalAPIServerError.invalidPort(port) }
        let tokenValue = try await loadOrCreateToken()
        stateLock.withLock { token = tokenValue }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        stateLock.withLock { self.listener = listener }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    if let self, let listener {
                        self.stateLock.withLock {
                            if self.listener === listener { self.listener = nil }
                        }
                    }
                    continuation.resume(throwing: LocalAPIServerError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    if let self, let listener {
                        self.stateLock.withLock {
                            if self.listener === listener { self.listener = nil }
                        }
                    }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        let activePort = listener.port?.rawValue ?? port
        let credentials = LocalAPICredentials(
            baseURL: URL(string: "http://127.0.0.1:\(activePort)")!,
            token: tokenValue
        )
        stateLock.withLock { currentCredentials = credentials }
        return credentials
    }

    public func credentials() -> LocalAPICredentials? {
        stateLock.withLock { currentCredentials }
    }

    public func stop() {
        stateLock.withLock {
            listener?.cancel()
            listener = nil
            currentCredentials = nil
        }
    }

    /// Replaces the bearer token without exposing a stale-token window. The
    /// listener keeps running and all subsequent requests use the new value.
    @discardableResult
    public func rotateToken() throws -> LocalAPICredentials? {
        let value = try KeychainSecretStore.randomToken()
        try secretStore.set(value, for: KeychainSecretStore.localAPITokenAccount)
        return stateLock.withLock {
            token = value
            guard var credentials = currentCredentials else { return nil }
            credentials.token = value
            currentCredentials = credentials
            return credentials
        }
    }

    /// Revokes the credential and closes the listener. Enabling the API again
    /// creates a fresh token; a revoked token is never silently reused.
    public func revokeToken() throws {
        stop()
        stateLock.withLock { token = "" }
        try secretStore.delete(KeychainSecretStore.localAPITokenAccount)
    }

    private func accept(_ connection: NWConnection) {
        // Defence in depth. The listener itself is already bound to 127.0.0.1.
        if case .hostPort(let host, _) = connection.endpoint {
            let peer = String(describing: host).lowercased()
            guard peer == "127.0.0.1" || peer == "::1" || peer == "localhost" else {
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil { connection.cancel(); return }
            var requestData = accumulated
            if let data { requestData.append(data) }
            guard requestData.count <= 128 * 1_024 else {
                self.send(status: 431, json: ["error": "Request headers are too large"], on: connection)
                return
            }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard let request = String(data: requestData, encoding: .utf8) else {
                    self.send(status: 400, json: ["error": "Request is not valid UTF-8"], on: connection)
                    return
                }
                Task { await self.respond(to: request, on: connection) }
            } else if isComplete {
                self.send(status: 400, json: ["error": "Incomplete request"], on: connection)
            } else {
                self.receiveRequest(on: connection, accumulated: requestData)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) async {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            send(status: 400, json: ["error": "Malformed request"], on: connection)
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let authorization = headers["authorization"]?.split(separator: " ", maxSplits: 1).map(String.init) ?? []
        let suppliedToken = authorization.count == 2 && authorization[0].caseInsensitiveCompare("Bearer") == .orderedSame
            ? authorization[1]
            : ""
        let expectedToken = stateLock.withLock { token }
        guard constantTimeEqual(suppliedToken, expectedToken) else {
            send(status: 401, json: ["error": "Unauthorised"], on: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard method == "GET" else {
            send(status: 405, json: ["error": "Read-only API"], on: connection)
            return
        }

        do {
            if target == "/health" {
                send(status: 200, json: ["status": "ok"], on: connection)
            } else if target.hasPrefix("/v1/records/") {
                let rawID = target.replacingOccurrences(of: "/v1/records/", with: "").split(separator: "?")[0]
                guard let id = UUID(uuidString: String(rawID)), let record = try await store.record(id: id) else {
                    send(status: 404, json: ["error": "Record not found"], on: connection)
                    return
                }
                send(status: 200, encodable: record, on: connection)
            } else if target.hasPrefix("/v1/records") {
                let components = URLComponents(string: "http://localhost\(target)")
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                let kind = components?.queryItems?.first(where: { $0.name == "kind" })?.value.flatMap(WorkspaceRecordKind.init(rawValue:))
                let limit = components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50
                send(status: 200, encodable: try await store.search(query, kind: kind, limit: limit), on: connection)
            } else if target == "/v1/recovery" {
                send(status: 200, encodable: try await store.recoverableCaptures(), on: connection)
            } else {
                send(status: 404, json: ["error": "Not found"], on: connection)
            }
        } catch {
            send(status: 500, json: ["error": error.localizedDescription], on: connection)
        }
    }

    private func send(status: Int, json: [String: String], on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        send(status: status, body: data, on: connection)
    }

    private func send<T: Encodable>(status: Int, encodable: T, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        send(status: status, body: (try? encoder.encode(encodable)) ?? Data("{}".utf8), on: connection)
    }

    private func send(status: Int, body: Data, on connection: NWConnection) {
        let reasons = [
            200: "OK", 400: "Bad Request", 401: "Unauthorised", 404: "Not Found",
            405: "Method Not Allowed", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
        ]
        let header = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func loadOrCreateToken() async throws -> String {
        if let value = try secretStore.string(for: KeychainSecretStore.localAPITokenAccount), !value.isEmpty {
            return value
        }

        // One-time migration from the private token file used by early builds.
        try await store.prepare()
        let url = store.rootURL.appendingPathComponent("api.token")
        if let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            try secretStore.set(value, for: KeychainSecretStore.localAPITokenAccount)
            try FileManager.default.removeItem(at: url)
            return value
        }
        let value = try KeychainSecretStore.randomToken()
        try secretStore.set(value, for: KeychainSecretStore.localAPITokenAccount)
        return value
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
