import Foundation
import Network

public final class LocalAPIServer: @unchecked Sendable {
    private let store: LibraryStore
    private let queue = DispatchQueue(label: "com.tumcuctom.evee.api")
    private var listener: NWListener?
    private var token = ""

    public init(store: LibraryStore = .shared) { self.store = store }

    public func start(port: UInt16) async throws -> String {
        stop()
        token = try await loadOrCreateToken()
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
        return token
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        if case .hostPort(let host, _) = connection.endpoint {
            let peer = String(describing: host)
            guard peer == "127.0.0.1" || peer == "::1" || peer == "localhost" else {
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1_024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            Task { await self.respond(to: request, on: connection) }
        }
    }

    private func respond(to request: String, on connection: NWConnection) async {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { send(status: 400, json: ["error": "Malformed request"], on: connection); return }

        let authorised = request.components(separatedBy: "\r\n").contains { line in
            line.caseInsensitiveCompare("Authorization: Bearer \(token)") == .orderedSame
        }
        guard authorised else { send(status: 401, json: ["error": "Unauthorised"], on: connection); return }

        let method = String(parts[0])
        let target = String(parts[1])
        guard method == "GET" else { send(status: 405, json: ["error": "Read-only API"], on: connection); return }

        do {
            if target == "/health" {
                send(status: 200, json: ["status": "ok"], on: connection)
            } else if target.hasPrefix("/v1/records/") {
                let rawID = target.replacingOccurrences(of: "/v1/records/", with: "").split(separator: "?")[0]
                guard let id = UUID(uuidString: String(rawID)), let record = try await store.record(id: id) else {
                    send(status: 404, json: ["error": "Record not found"], on: connection); return
                }
                send(status: 200, encodable: record, on: connection)
            } else if target.hasPrefix("/v1/records") {
                let components = URLComponents(string: "http://localhost\(target)")
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                let kind = components?.queryItems?.first(where: { $0.name == "kind" })?.value.flatMap(WorkspaceRecordKind.init(rawValue:))
                send(status: 200, encodable: try await store.search(query, kind: kind), on: connection)
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
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        send(status: status, body: (try? encoder.encode(encodable)) ?? Data("{}".utf8), on: connection)
    }

    private func send(status: Int, body: Data, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorised", 404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"][status] ?? "OK"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func loadOrCreateToken() async throws -> String {
        let root = store.rootURL
        try await store.prepare()
        let url = root.appendingPathComponent("api.token")
        if let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }
}
