import EveeCore
import Foundation

enum InstallationSelfTest {
    enum ResultStatus: String {
        case passed
        case failed
    }

    static func run(rootURL: URL) async throws {
        guard Bundle.main.bundleIdentifier == "com.tumcuctom.evee" else {
            throw failure("The packaged bundle identifier is invalid.")
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/evee-mcp")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw failure("The packaged MCP helper is missing or not executable.")
        }
        let resourceBundles = ((try? FileManager.default.contentsOfDirectory(
            at: Bundle.main.resourceURL ?? Bundle.main.bundleURL,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "bundle" }
        guard !resourceBundles.isEmpty else {
            throw failure("Packaged dependency resource bundles are unavailable.")
        }
        guard let resources = Bundle.main.resourceURL else {
            throw failure("The packaged resource seal is unavailable.")
        }
        try ResourceSealVerifier.verify(resourcesURL: resources)

        let store = LibraryStore(rootURL: rootURL)
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

    static func prepareResultReporting() throws {
        guard let path = ProcessInfo.processInfo.environment["EVEE_SELF_TEST_RESULT_PATH"] else { return }
        let url = URL(fileURLWithPath: path)
        guard url.path == path, url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw failure("The self-test result location is invalid.")
        }
    }

    static func reportResult(status: ResultStatus) throws {
        guard let path = ProcessInfo.processInfo.environment["EVEE_SELF_TEST_RESULT_PATH"] else { return }
        let url = URL(fileURLWithPath: path)
        guard url.path == path, url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw failure("The self-test result location is invalid.")
        }
        let result: String
        switch status {
        case .passed: result = #"{"status":"passed"}"#
        case .failed: result = #"{"status":"failed","category":"installation-self-test"}"#
        }
        try Data(result.utf8).write(to: url, options: .atomic)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Evee.InstallationSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
