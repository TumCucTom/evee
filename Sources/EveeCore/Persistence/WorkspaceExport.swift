import Foundation

public enum WorkspaceExportFormat: String, CaseIterable, Sendable {
    case json
    case markdown

    public var fileExtension: String { rawValue == "json" ? "json" : "md" }
    public var title: String { rawValue == "json" ? "JSON" : "Markdown" }
}

public enum WorkspaceExporter {
    public static func data(for records: [WorkspaceRecord], format: WorkspaceExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var copies = records
            for recordIndex in copies.indices {
                for deliveryIndex in copies[recordIndex].webhookDeliveries.indices {
                    copies[recordIndex].webhookDeliveries[deliveryIndex].payloadBody = nil
                }
            }
            return try encoder.encode(copies)
        case .markdown:
            let body = records.sorted { $0.createdAt > $1.createdAt }.map(markdown).joined(separator: "\n\n---\n\n")
            return Data(body.utf8)
        }
    }

    private static func markdown(_ record: WorkspaceRecord) -> String {
        var sections = [
            "# \(record.title)",
            "- Type: \(record.kind.rawValue)",
            "- Created: \(ISO8601DateFormatter().string(from: record.createdAt))"
        ]
        if let source = record.sourceApplication { sections.append("- Application: \(source)") }
        if !record.tags.isEmpty { sections.append("- Tags: \(record.tags.joined(separator: ", "))") }
        sections.append("\n\(record.text)")
        if !record.notes.isEmpty { sections.append("\n## Notes\n\n\(record.notes)") }
        return sections.joined(separator: "\n")
    }
}
