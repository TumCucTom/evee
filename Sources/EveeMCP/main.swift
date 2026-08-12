import EveeCore
import Foundation

@main
enum EveeMCP {
    static func main() async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"]
            else { continue }

            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]
            do {
                let result = try await handle(method: method, params: params)
                write(["jsonrpc": "2.0", "id": id, "result": result])
            } catch {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": error.localizedDescription]])
            }
        }
    }

    static func handle(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]], "serverInfo": ["name": "evee", "version": "0.1.0"]]
        case "tools/list":
            return ["tools": [
                ["name": "search_voice_workspace", "description": "Search local Evee dictations, meetings and memos.", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "kind": ["type": "string", "enum": ["dictation", "meeting", "memo"]], "limit": ["type": "integer"]], "required": ["query"]]],
                ["name": "get_voice_record", "description": "Get one local Evee record by UUID.", "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]],
            ]]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let value: Any
            if name == "search_voice_workspace" {
                let query = arguments["query"] as? String ?? ""
                let kind = (arguments["kind"] as? String).flatMap(WorkspaceRecordKind.init(rawValue:))
                let limit = arguments["limit"] as? Int ?? 20
                value = try await LibraryStore.shared.search(query, kind: kind, limit: limit)
            } else if name == "get_voice_record",
                      let raw = arguments["id"] as? String,
                      let id = UUID(uuidString: raw) {
                value = try await LibraryStore.shared.record(id: id) as Any
            } else {
                throw NSError(domain: "EveeMCP", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unknown tool"])
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded: Data
            if let records = value as? [WorkspaceRecord] { encoded = try encoder.encode(records) }
            else if let record = value as? WorkspaceRecord { encoded = try encoder.encode(record) }
            else { encoded = Data("null".utf8) }
            return ["content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]]]
        default:
            return [:]
        }
    }

    static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}
