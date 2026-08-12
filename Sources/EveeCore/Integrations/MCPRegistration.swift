import Foundation

public struct MCPRegistrationResult: Equatable, Sendable {
    public var configurationURL: URL
    public var executableURL: URL
    public var replacedExistingRegistration: Bool

    public init(configurationURL: URL, executableURL: URL, replacedExistingRegistration: Bool) {
        self.configurationURL = configurationURL
        self.executableURL = executableURL
        self.replacedExistingRegistration = replacedExistingRegistration
    }
}

public struct MCPClientConfiguration: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var configurationURL: URL

    public init(name: String, configurationURL: URL) {
        self.name = name
        self.configurationURL = configurationURL
    }
}

public enum MCPRegistrationError: LocalizedError, Sendable {
    case executableMissing(URL)
    case executableNotRunnable(URL)
    case invalidConfiguration(URL)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let url): return "The Evee MCP helper is missing at \(url.path)."
        case .executableNotRunnable(let url): return "The Evee MCP helper is not executable at \(url.path)."
        case .invalidConfiguration(let url): return "The MCP configuration at \(url.path) is not a JSON object."
        }
    }
}

public enum MCPRegistration {
    public static func bundledExecutableURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/evee-mcp").standardizedFileURL
    }

    public static func configuration(executablePath: String) -> [String: Any] {
        ["mcpServers": ["evee": ["command": URL(fileURLWithPath: executablePath).standardizedFileURL.path, "args": []]]]
    }

    public static func detectedClients(fileManager: FileManager = .default) -> [MCPClientConfiguration] {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            MCPClientConfiguration(name: "Claude Desktop", configurationURL: support.appendingPathComponent("Claude/claude_desktop_config.json")),
            MCPClientConfiguration(name: "Cursor", configurationURL: home.appendingPathComponent(".cursor/mcp.json")),
            MCPClientConfiguration(name: "Windsurf", configurationURL: home.appendingPathComponent(".codeium/windsurf/mcp_config.json"))
        ]
        return candidates.filter { client in
            fileManager.fileExists(atPath: client.configurationURL.path)
                || fileManager.fileExists(atPath: client.configurationURL.deletingLastPathComponent().path)
        }
    }

    @discardableResult
    public static func writeDetectedClientConfigurations(bundle: Bundle = .main) throws -> [MCPRegistrationResult] {
        let executable = bundledExecutableURL(bundle: bundle)
        let clients = detectedClients()
        let targets = clients.isEmpty
            ? [MCPClientConfiguration(
                name: "Claude Desktop",
                configurationURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Claude/claude_desktop_config.json")
            )]
            : clients
        return try targets.map { try writeConfiguration(at: $0.configurationURL, executableURL: executable) }
    }

    @discardableResult
    public static func writeClaudeDesktopConfiguration(executablePath: String) throws -> MCPRegistrationResult {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Claude/claude_desktop_config.json")
        return try writeConfiguration(at: url, executableURL: URL(fileURLWithPath: executablePath))
    }

    @discardableResult
    public static func writeBundledClaudeDesktopConfiguration(bundle: Bundle = .main) throws -> MCPRegistrationResult {
        try writeClaudeDesktopConfiguration(executablePath: bundledExecutableURL(bundle: bundle).path)
    }

    @discardableResult
    public static func writeConfiguration(at url: URL, executableURL: URL) throws -> MCPRegistrationResult {
        let executable = executableURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw MCPRegistrationError.executableMissing(executable)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPRegistrationError.executableNotRunnable(executable)
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPRegistrationError.invalidConfiguration(url)
            }
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let replaced = servers["evee"] != nil
        servers["evee"] = ["command": executable.path, "args": []]
        root["mcpServers"] = servers

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return MCPRegistrationResult(configurationURL: url, executableURL: executable, replacedExistingRegistration: replaced)
    }
}
