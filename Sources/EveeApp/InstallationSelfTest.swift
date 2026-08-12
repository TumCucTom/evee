import EveeCore
import Foundation

enum InstallationSelfTest {
    static func run() async throws {
        guard Bundle.main.bundleIdentifier == "com.tumcuctom.evee" else {
            throw failure("The packaged bundle identifier is invalid.")
        }
        guard let helper = Bundle.main.sharedSupportURL?
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/evee-mcp"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw failure("The packaged MCP helper is missing or not executable.")
        }
        let resourceBundles = ((try? FileManager.default.contentsOfDirectory(
            at: Bundle.main.resourceURL ?? Bundle.main.bundleURL,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "bundle" }
        guard !resourceBundles.isEmpty else {
            throw failure("Packaged dependency resource bundles are unavailable.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-installation-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let record = WorkspaceRecord(kind: .memo, title: "Installation check", text: "searchable self test")
        try await store.upsert(record)
        let matches = try await store.search("searchable")
        guard matches.map(\.id) == [record.id] else {
            throw failure("The packaged persistence and search pipeline did not round-trip a record.")
        }

        var settings = EveeSettings()
        settings.webhookSecret = "must-not-persist"
        let encoded = try JSONEncoder().encode(settings)
        guard !encoded.contains(Data("must-not-persist".utf8)) else {
            throw failure("The packaged settings encoder exposed a protected secret.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Evee.InstallationSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
