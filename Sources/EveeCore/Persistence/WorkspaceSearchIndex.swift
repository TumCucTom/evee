import Foundation
import SQLite3
import CryptoKit

enum WorkspaceSearchIndexError: LocalizedError {
    case open(String)
    case statement(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "The workspace search index could not open: \(message)"
        case .statement(let message): return "The workspace search query could not be prepared: \(message)"
        case .execute(let message): return "The workspace search index could not update: \(message)"
        }
    }
}

/// A rebuildable FTS5 projection of the canonical JSON record store. The index
/// contains no secrets or audio and can be deleted at any time; `LibraryStore`
/// will recreate it from durable records on the next successful load.
final class WorkspaceSearchIndex {
    private var database: OpaquePointer?
    private let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            database = nil
            throw WorkspaceSearchIndexError.open(message)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=FULL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("CREATE TABLE IF NOT EXISTS workspace_index_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS workspace_fts USING fts5(id UNINDEXED, kind UNINDEXED, created_at UNINDEXED, title, body, notes, tags, source_application, tokenize='unicode61 remove_diacritics 2');")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close(database) }

    func rebuild(records: [WorkspaceRecord]) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("DELETE FROM workspace_fts;")
            for record in records { try insert(record) }
            try setMetadata(key: "record_count", value: String(records.count))
            try setMetadata(key: "fingerprint", value: fingerprint(records))
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func isCurrent(records: [WorkspaceRecord]) throws -> Bool {
        guard let statement = try prepare("SELECT value FROM workspace_index_meta WHERE key = 'fingerprint' LIMIT 1;") else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: value) == fingerprint(records)
    }

    func matchingIDs(query: String, kind: WorkspaceRecordKind?, limit: Int) throws -> [UUID] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " AND ")
        guard !terms.isEmpty else { return [] }

        let sql: String
        if kind == nil {
            sql = "SELECT id FROM workspace_fts WHERE workspace_fts MATCH ? ORDER BY bm25(workspace_fts, 0, 0, 0, 10, 1, 0.8, 0.6, 0.5), CAST(created_at AS REAL) DESC LIMIT ?;"
        } else {
            sql = "SELECT id FROM workspace_fts WHERE workspace_fts MATCH ? AND kind = ? ORDER BY bm25(workspace_fts, 0, 0, 0, 10, 1, 0.8, 0.6, 0.5), CAST(created_at AS REAL) DESC LIMIT ?;"
        }
        guard let statement = try prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, terms, -1, transient)
        if let kind {
            sqlite3_bind_text(statement, 2, kind.rawValue, -1, transient)
            sqlite3_bind_int(statement, 3, Int32(limit))
        } else {
            sqlite3_bind_int(statement, 2, Int32(limit))
        }

        var result: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: value)) {
                result.append(id)
            }
        }
        return result
    }

    private func insert(_ record: WorkspaceRecord) throws {
        let sql = "INSERT INTO workspace_fts(id, kind, created_at, title, body, notes, tags, source_application) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
        guard let statement = try prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }
        let values = [
            record.id.uuidString,
            record.kind.rawValue,
            String(record.createdAt.timeIntervalSince1970),
            record.title,
            record.text,
            record.notes,
            record.tags.joined(separator: " "),
            record.sourceApplication ?? "",
        ]
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func setMetadata(key: String, value: String) throws {
        guard let statement = try prepare("INSERT INTO workspace_index_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;") else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func fingerprint(_ records: [WorkspaceRecord]) -> String {
        let source = records
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSinceReferenceDate)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorkspaceSearchIndexError.statement(errorMessage())
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> WorkspaceSearchIndexError { .execute(errorMessage()) }

    private func errorMessage() -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }
}
