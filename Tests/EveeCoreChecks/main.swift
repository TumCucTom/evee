import EveeCore
import Darwin
import Foundation
import Network

private enum CoreCheckError: Error {
    case connectionFailed(String)
    case listenerFailed(String)
    case timedOut
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

    print("api-limits: passed")
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
} else {
    fputs("usage: evee-core-checks --filter <context-policy|public-record|api-revoke|api-rotate|api-limits>\n", stderr)
    exit(EXIT_FAILURE)
}
