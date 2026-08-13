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
    private let secretStore: any LocalAPISecretStore
    private let queue = DispatchQueue(label: "com.tumcuctom.evee.api")
    private let stateLock = NSLock()
    private let credentialLock = NSLock()
    private var listener: NWListener?
    private var token = ""
    private var currentCredentials: LocalAPICredentials?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pendingHeaders: Set<ObjectIdentifier> = []
    private var accessGeneration: UInt64 = 0
    private var revocationInProgress = false
    private let maximumConnections = 32
    private let headerDeadline: TimeInterval = 5

    public init(store: LibraryStore = .shared, secretStore: any LocalAPISecretStore = KeychainSecretStore()) {
        self.store = store
        self.secretStore = secretStore
    }

    /// Backwards-compatible entry point used by the app.
    public func start(port: UInt16) async throws -> String {
        try await startWithCredentials(port: port).token
    }

    /// Starts a truly loopback-bound listener and returns everything needed to configure a client.
    public func startWithCredentials(port: UInt16) async throws -> LocalAPICredentials {
        guard let generation = reserveStart() else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await startOwned(port: port, generation: generation)
        } onCancel: {
            self.cancelAccess(ifOwnedBy: generation)
        }
    }

    private func startOwned(port: UInt16, generation: UInt64) async throws -> LocalAPICredentials {
        guard port > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            cancelAccess(ifOwnedBy: generation)
            throw LocalAPIServerError.invalidPort(port)
        }

        do {
            try Task.checkCancellation()
            let tokenValue = try await loadOrCreateToken()
            try Task.checkCancellation()
            guard ownsAccess(generation) else { throw CancellationError() }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
            let listener = try NWListener(using: parameters)
            guard install(listener: listener, token: tokenValue, generation: generation) else {
                listener.cancel()
                throw CancellationError()
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener else {
                    connection.cancel()
                    return
                }
                self.accept(connection, listener: listener)
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    switch state {
                    case .ready:
                        listener?.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        listener?.stateUpdateHandler = nil
                        if let self { self.cancelAccess(ifOwnedBy: generation) }
                        continuation.resume(throwing: LocalAPIServerError.listenerFailed(error.localizedDescription))
                    case .cancelled:
                        listener?.stateUpdateHandler = nil
                        if let self { self.cancelAccess(ifOwnedBy: generation) }
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }

            try Task.checkCancellation()
            let activePort = listener.port?.rawValue ?? port
            let credentials = LocalAPICredentials(
                baseURL: URL(string: "http://127.0.0.1:\(activePort)")!,
                token: tokenValue
            )
            let isCurrent = stateLock.withLock {
                guard self.listener === listener, accessGeneration == generation else { return false }
                currentCredentials = credentials
                return true
            }
            guard isCurrent else { throw CancellationError() }
            return credentials
        } catch {
            cancelAccess(ifOwnedBy: generation)
            throw error
        }
    }

    private func reserveStart() -> UInt64? {
        let reserved = stateLock.withLock { () -> (UInt64, NWListener?, [NWConnection])? in
            guard !revocationInProgress else { return nil }
            accessGeneration &+= 1
            let generation = accessGeneration
            let detachedListener = listener
            let detachedConnections = Array(connections.values)
            listener = nil
            connections.removeAll()
            pendingHeaders.removeAll()
            token = ""
            currentCredentials = nil
            return (generation, detachedListener, detachedConnections)
        }
        reserved?.1?.cancel()
        reserved?.2.forEach { $0.cancel() }
        return reserved?.0
    }

    private func install(listener: NWListener, token: String, generation: UInt64) -> Bool {
        stateLock.withLock {
            guard accessGeneration == generation, self.listener == nil else { return false }
            self.listener = listener
            self.token = token
            return true
        }
    }

    private func ownsAccess(_ generation: UInt64) -> Bool {
        stateLock.withLock { accessGeneration == generation }
    }

    private func cancelAccess(ifOwnedBy generation: UInt64) {
        let detached = stateLock.withLock { () -> (NWListener?, [NWConnection])? in
            guard accessGeneration == generation else { return nil }
            accessGeneration &+= 1
            let detachedListener = listener
            let detachedConnections = Array(connections.values)
            listener = nil
            connections.removeAll()
            pendingHeaders.removeAll()
            token = ""
            currentCredentials = nil
            return (detachedListener, detachedConnections)
        }
        detached?.0?.cancel()
        detached?.1.forEach { $0.cancel() }
    }

    public func credentials() -> LocalAPICredentials? {
        stateLock.withLock { currentCredentials }
    }

    public func stop() {
        let detached = stateLock.withLock { () -> (NWListener?, [NWConnection]) in
            accessGeneration &+= 1
            let detachedListener = listener
            let detachedConnections = Array(connections.values)
            listener = nil
            connections.removeAll()
            pendingHeaders.removeAll()
            token = ""
            currentCredentials = nil
            return (detachedListener, detachedConnections)
        }
        detached.0?.cancel()
        detached.1.forEach { $0.cancel() }
    }

    /// Replaces the bearer token without exposing a stale-token window. The
    /// listener keeps running and all subsequent requests use the new value.
    @discardableResult
    public func rotateToken() throws -> LocalAPICredentials? {
        let value = try KeychainSecretStore.randomToken()
        try credentialLock.withLock {
            try secretStore.set(value, for: KeychainSecretStore.localAPITokenAccount)
        }
        let rotated = stateLock.withLock { () -> (LocalAPICredentials?, [NWConnection]) in
            accessGeneration &+= 1
            let detachedConnections = Array(connections.values)
            connections.removeAll()
            pendingHeaders.removeAll()
            token = value
            guard var credentials = currentCredentials else { return (nil, detachedConnections) }
            credentials.token = value
            currentCredentials = credentials
            return (credentials, detachedConnections)
        }
        rotated.1.forEach { $0.cancel() }
        return rotated.0
    }

    /// Revokes the credential and closes the listener. Enabling the API again
    /// creates a fresh token; a revoked token is never silently reused.
    public func revokeToken() throws {
        beginRevocation()
        defer { endRevocation() }
        let replacement = try KeychainSecretStore.randomToken()
        try credentialLock.withLock {
            try secretStore.set(replacement, for: KeychainSecretStore.localAPITokenAccount)
            try secretStore.delete(KeychainSecretStore.localAPITokenAccount)
        }
    }

    private func beginRevocation() {
        let detached = stateLock.withLock { () -> (NWListener?, [NWConnection]) in
            revocationInProgress = true
            accessGeneration &+= 1
            let detachedListener = listener
            let detachedConnections = Array(connections.values)
            listener = nil
            connections.removeAll()
            pendingHeaders.removeAll()
            token = ""
            currentCredentials = nil
            return (detachedListener, detachedConnections)
        }
        detached.0?.cancel()
        detached.1.forEach { $0.cancel() }
    }

    private func endRevocation() {
        stateLock.withLock { revocationInProgress = false }
    }

    private func accept(_ connection: NWConnection, listener: NWListener) {
        // Defence in depth. The listener itself is already bound to 127.0.0.1.
        if case .hostPort(let host, _) = connection.endpoint {
            let peer = String(describing: host).lowercased()
            guard peer == "127.0.0.1" || peer == "::1" || peer == "localhost" else {
                connection.cancel()
                return
            }
        }
        let identifier = ObjectIdentifier(connection)
        let generation = stateLock.withLock { () -> UInt64? in
            guard self.listener === listener, connections.count < maximumConnections else {
                return nil
            }
            connections[identifier] = connection
            pendingHeaders.insert(identifier)
            return accessGeneration
        }
        guard let generation else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.isActive(connection, generation: generation) else { return }
            if case .failed = state { self.finish(connection, generation: generation) }
            if case .cancelled = state { self.finish(connection, generation: generation) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + headerDeadline) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.expireHeader(on: connection, generation: generation)
        }
        receiveRequest(on: connection, accumulated: Data(), generation: generation)
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data, generation: UInt64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            guard self.isActive(connection, generation: generation) else { connection.cancel(); return }
            if error != nil {
                self.finish(connection, generation: generation)
                return
            }
            var requestData = accumulated
            if let data { requestData.append(data) }
            guard requestData.count <= 128 * 1_024 else {
                self.send(status: 431, json: ["error": "Request headers are too large"], on: connection, generation: generation)
                return
            }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard self.completeHeader(on: connection, generation: generation) else {
                    connection.cancel()
                    return
                }
                guard let request = String(data: requestData, encoding: .utf8) else {
                    self.send(status: 400, json: ["error": "Request is not valid UTF-8"], on: connection, generation: generation)
                    return
                }
                Task {
                    guard self.isActive(connection, generation: generation) else { return }
                    await self.respond(to: request, on: connection, generation: generation)
                }
            } else if isComplete {
                self.send(status: 400, json: ["error": "Incomplete request"], on: connection, generation: generation)
            } else {
                self.receiveRequest(on: connection, accumulated: requestData, generation: generation)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection, generation: UInt64) async {
        guard isActive(connection, generation: generation) else { return }
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            send(status: 400, json: ["error": "Malformed request"], on: connection, generation: generation)
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
        guard let expectedToken = activeToken(for: connection, generation: generation) else { return }
        guard constantTimeEqual(suppliedToken, expectedToken) else {
            send(status: 401, json: ["error": "Unauthorised"], on: connection, generation: generation)
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard method == "GET" else {
            send(status: 405, json: ["error": "Read-only API"], on: connection, generation: generation)
            return
        }

        do {
            if target == "/health" {
                send(status: 200, json: ["status": "ok"], on: connection, generation: generation)
            } else if target.hasPrefix("/v1/records/") {
                let rawID = target.replacingOccurrences(of: "/v1/records/", with: "").split(separator: "?")[0]
                guard isActive(connection, generation: generation) else { return }
                guard let id = UUID(uuidString: String(rawID)), let record = try await store.record(id: id) else {
                    send(status: 404, json: ["error": "Record not found"], on: connection, generation: generation)
                    return
                }
                guard isActive(connection, generation: generation) else { return }
                send(status: 200, encodable: PublicWorkspaceRecord(record), on: connection, generation: generation)
            } else if target.hasPrefix("/v1/records") {
                let components = URLComponents(string: "http://localhost\(target)")
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                let kind = components?.queryItems?.first(where: { $0.name == "kind" })?.value.flatMap(WorkspaceRecordKind.init(rawValue:))
                let limit = components?.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50
                guard isActive(connection, generation: generation) else { return }
                let records = try await store.search(query, kind: kind, limit: limit)
                guard isActive(connection, generation: generation) else { return }
                send(status: 200, encodable: records.map(PublicWorkspaceRecord.init), on: connection, generation: generation)
            } else {
                send(status: 404, json: ["error": "Not found"], on: connection, generation: generation)
            }
        } catch {
            guard isActive(connection, generation: generation) else { return }
            send(status: 500, json: ["error": "Internal server error"], on: connection, generation: generation)
        }
    }

    private func send(status: Int, json: [String: String], on connection: NWConnection, generation: UInt64) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        send(status: status, body: data, on: connection, generation: generation)
    }

    private func send<T: Encodable>(status: Int, encodable: T, on connection: NWConnection, generation: UInt64) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        send(status: status, body: (try? encoder.encode(encodable)) ?? Data("{}".utf8), on: connection, generation: generation)
    }

    private func send(status: Int, body: Data, on connection: NWConnection, generation: UInt64) {
        guard isActive(connection, generation: generation) else { return }
        let reasons = [
            200: "OK", 400: "Bad Request", 401: "Unauthorised", 404: "Not Found",
            405: "Method Not Allowed", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
        ]
        let header = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self, weak connection] _ in
            guard let connection else { return }
            if let self, self.isActive(connection, generation: generation) {
                self.finish(connection, generation: generation)
            } else {
                connection.cancel()
            }
        })
    }

    private func loadOrCreateToken() async throws -> String {
        if let value = try credentialLock.withLock({
            try secretStore.string(for: KeychainSecretStore.localAPITokenAccount)
        }), !value.isEmpty {
            removeLegacyTokenFile()
            return value
        }

        // One-time migration from the private token file used by early builds.
        try await store.prepare()
        return try credentialLock.withLock {
            if let value = try secretStore.string(for: KeychainSecretStore.localAPITokenAccount), !value.isEmpty {
                removeLegacyTokenFile()
                return value
            }
            let url = store.rootURL.appendingPathComponent("api.token")
            if let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                try secretStore.set(value, for: KeychainSecretStore.localAPITokenAccount)
                removeLegacyTokenFile()
                return value
            }
            let value = try KeychainSecretStore.randomToken()
            try secretStore.set(value, for: KeychainSecretStore.localAPITokenAccount)
            return value
        }
    }

    private func removeLegacyTokenFile() {
        let url = store.rootURL.appendingPathComponent("api.token")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func isActive(_ connection: NWConnection, generation: UInt64) -> Bool {
        stateLock.withLock {
            accessGeneration == generation && connections[ObjectIdentifier(connection)] === connection
        }
    }

    private func activeToken(for connection: NWConnection, generation: UInt64) -> String? {
        stateLock.withLock {
            guard accessGeneration == generation,
                  connections[ObjectIdentifier(connection)] === connection,
                  !token.isEmpty else { return nil }
            return token
        }
    }

    private func completeHeader(on connection: NWConnection, generation: UInt64) -> Bool {
        stateLock.withLock {
            let identifier = ObjectIdentifier(connection)
            guard accessGeneration == generation, connections[identifier] === connection else { return false }
            pendingHeaders.remove(identifier)
            return true
        }
    }

    private func expireHeader(on connection: NWConnection, generation: UInt64) {
        let shouldCancel = stateLock.withLock {
            let identifier = ObjectIdentifier(connection)
            guard accessGeneration == generation,
                  connections[identifier] === connection,
                  pendingHeaders.contains(identifier) else { return false }
            connections.removeValue(forKey: identifier)
            pendingHeaders.remove(identifier)
            return true
        }
        if shouldCancel { connection.cancel() }
    }

    private func finish(_ connection: NWConnection, generation: UInt64) {
        let shouldCancel = stateLock.withLock {
            let identifier = ObjectIdentifier(connection)
            guard accessGeneration == generation, connections[identifier] === connection else { return false }
            connections.removeValue(forKey: identifier)
            pendingHeaders.remove(identifier)
            return true
        }
        if shouldCancel { connection.cancel() }
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
