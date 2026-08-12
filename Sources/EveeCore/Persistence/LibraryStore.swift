import Foundation

public actor LibraryStore {
    public static let shared = LibraryStore()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public let rootURL: URL
    public let audioURL: URL
    private let recordsURL: URL
    private let settingsURL: URL

    public init(rootURL: URL? = nil) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? applicationSupport.appendingPathComponent("Evee", isDirectory: true)
        self.audioURL = self.rootURL.appendingPathComponent("Audio", isDirectory: true)
        self.recordsURL = self.rootURL.appendingPathComponent("records.json")
        self.settingsURL = self.rootURL.appendingPathComponent("settings.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
    }

    public func loadRecords() throws -> [WorkspaceRecord] {
        try prepare()
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return [] }
        return try decoder.decode([WorkspaceRecord].self, from: Data(contentsOf: recordsURL))
    }

    public func save(_ records: [WorkspaceRecord]) throws {
        try prepare()
        try encoder.encode(records).write(to: recordsURL, options: .atomic)
    }

    public func loadSettings() throws -> EveeSettings {
        try prepare()
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return EveeSettings() }
        return try decoder.decode(EveeSettings.self, from: Data(contentsOf: settingsURL))
    }

    public func save(_ settings: EveeSettings) throws {
        try prepare()
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    public func search(_ query: String, kind: WorkspaceRecordKind? = nil, limit: Int = 50) throws -> [WorkspaceRecord] {
        let records = try loadRecords()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records
            .filter { record in
                (kind == nil || record.kind == kind) &&
                (needle.isEmpty || [record.title, record.text, record.notes, record.tags.joined(separator: " ")]
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains(needle))
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(1, limit))
            .map { $0 }
    }

    public func record(id: UUID) throws -> WorkspaceRecord? {
        try loadRecords().first { $0.id == id }
    }

    public func upsert(_ record: WorkspaceRecord) throws {
        var records = try loadRecords()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records)
    }

    public func delete(id: UUID) throws {
        var records = try loadRecords()
        guard let record = records.first(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        if let relative = record.audioRelativePath {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(relative))
        }
        try save(records)
    }
}
