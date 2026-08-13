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

public struct MCPRemovalResult: Equatable, Sendable {
    public let configurationURL: URL
    public let removedRegistration: Bool

    public init(configurationURL: URL, removedRegistration: Bool) {
        self.configurationURL = configurationURL
        self.removedRegistration = removedRegistration
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
        case .invalidConfiguration(let url): return "The MCP configuration at \(url.path) is not a supported configuration."
        }
    }
}

public enum MCPRegistration {
    private static let codexOwnershipMarker = "# Managed by Evee local helper access."

    public static func bundledExecutableURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/evee-mcp").standardizedFileURL
    }

    public static func configuration(executablePath: String) -> [String: Any] {
        ["mcpServers": ["evee": ["command": URL(fileURLWithPath: executablePath).standardizedFileURL.path, "args": []]]]
    }

    public static func detectedClients(
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        applicationSupportURL: URL? = nil
    ) -> [MCPClientConfiguration] {
        let support = applicationSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = homeURL ?? fileManager.homeDirectoryForCurrentUser
        let candidates = [
            MCPClientConfiguration(name: "Claude Desktop", configurationURL: support.appendingPathComponent("Claude/claude_desktop_config.json")),
            MCPClientConfiguration(name: "Cursor", configurationURL: home.appendingPathComponent(".cursor/mcp.json")),
            MCPClientConfiguration(name: "Windsurf", configurationURL: home.appendingPathComponent(".codeium/windsurf/mcp_config.json")),
            MCPClientConfiguration(name: "Codex", configurationURL: home.appendingPathComponent(".codex/config.toml"))
        ]
        return candidates.filter { client in
            fileManager.fileExists(atPath: client.configurationURL.path)
                || fileManager.fileExists(atPath: client.configurationURL.deletingLastPathComponent().path)
        }
    }

    @discardableResult
    public static func writeDetectedClientConfigurations(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        applicationSupportURL: URL? = nil
    ) throws -> [MCPRegistrationResult] {
        let clients = detectedClients(
            fileManager: fileManager,
            homeURL: homeURL,
            applicationSupportURL: applicationSupportURL
        )
        guard !clients.isEmpty else { return [] }
        return try writeConfigurations(for: clients, executableURL: bundledExecutableURL(bundle: bundle))
    }

    @discardableResult
    public static func writeConfigurations(
        for clients: [MCPClientConfiguration],
        executableURL: URL
    ) throws -> [MCPRegistrationResult] {
        guard !clients.isEmpty else { return [] }
        let executable = try validatedExecutable(executableURL)
        let snapshots = try clients.map { client in
            try ConfigurationSnapshot(url: client.configurationURL)
        }
        do {
            return try clients.map { client in
                try writeConfiguration(at: client.configurationURL, executableURL: executable)
            }
        } catch {
            for snapshot in snapshots.reversed() { try? snapshot.restore() }
            throw error
        }
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
        let executable = try validatedExecutable(executableURL)

        try prepareParentDirectory(for: url)

        if url.pathExtension.lowercased() == "toml" {
            return try writeCodexConfiguration(at: url, executable: executable)
        }

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPRegistrationError.invalidConfiguration(url)
            }
            root = existing
        }
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            throw MCPRegistrationError.invalidConfiguration(url)
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

    @discardableResult
    public static func removeConfiguration(at url: URL) throws -> MCPRemovalResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MCPRemovalResult(configurationURL: url, removedRegistration: false)
        }
        if url.pathExtension.lowercased() == "toml" {
            let data = try Data(contentsOf: url)
            guard let source = String(data: data, encoding: .utf8) else {
                throw MCPRegistrationError.invalidConfiguration(url)
            }
            let removal = removingCodexRegistration(from: source)
            guard removal.removed else {
                return MCPRemovalResult(configurationURL: url, removedRegistration: false)
            }
            try writePrivate(Data(removal.source.utf8), to: url)
            return MCPRemovalResult(configurationURL: url, removedRegistration: true)
        }

        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPRegistrationError.invalidConfiguration(url)
        }
        guard let value = root["mcpServers"] else {
            return MCPRemovalResult(configurationURL: url, removedRegistration: false)
        }
        guard var servers = value as? [String: Any] else {
            throw MCPRegistrationError.invalidConfiguration(url)
        }
        guard servers.removeValue(forKey: "evee") != nil else {
            return MCPRemovalResult(configurationURL: url, removedRegistration: false)
        }
        root["mcpServers"] = servers
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writePrivate(updated, to: url)
        return MCPRemovalResult(configurationURL: url, removedRegistration: true)
    }

    private static func validatedExecutable(_ executableURL: URL) throws -> URL {
        let executable = executableURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw MCPRegistrationError.executableMissing(executable)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPRegistrationError.executableNotRunnable(executable)
        }
        return executable
    }

    private static func prepareParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw MCPRegistrationError.invalidConfiguration(url) }
            return
        }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writeCodexConfiguration(at url: URL, executable: URL) throws -> MCPRegistrationResult {
        let source: String
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = String(data: data, encoding: .utf8) else {
                throw MCPRegistrationError.invalidConfiguration(url)
            }
            source = existing
        } else {
            source = ""
        }
        let removal = removingCodexRegistration(from: source)
        let separator = removal.source.isEmpty ? "" : "\n"
        let table = "\(codexOwnershipMarker)\n[mcp_servers.evee]\ncommand = \"\(tomlEscaped(executable.path))\"\nargs = []\n"
        try writePrivate(Data((removal.source + separator + table).utf8), to: url)
        return MCPRegistrationResult(
            configurationURL: url,
            executableURL: executable,
            replacedExistingRegistration: removal.removed
        )
    }

    private static func removingCodexRegistration(from source: String) -> (source: String, removed: Bool) {
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let pattern = #"(?m)^[ \t]*\[([^\]\r\n]+)\][ \t]*(?:#[^\r\n]*)?(?:\r?\n|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return (source, false) }
        let headers = expression.matches(in: source, range: fullRange)
        var ranges: [NSRange] = []
        for (index, header) in headers.enumerated() {
            guard let nameRange = Range(header.range(at: 1), in: source) else { continue }
            let name = source[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isEveeCodexTable(name) else { continue }
            let end = index + 1 < headers.count ? headers[index + 1].range.location : fullRange.length
            var start = header.range.location
            let nsSource = source as NSString
            let marker = codexOwnershipMarker + "\n"
            if start >= (marker as NSString).length,
               nsSource.substring(with: NSRange(location: start - (marker as NSString).length, length: (marker as NSString).length)) == marker {
                start -= (marker as NSString).length
                if start > 0, nsSource.substring(with: NSRange(location: start - 1, length: 1)) == "\n" {
                    start -= 1
                }
            } else if start >= 2 {
                if nsSource.substring(with: NSRange(location: start - 2, length: 2)) == "\n\n" {
                    start -= 1
                }
            }
            ranges.append(NSRange(location: start, length: end - start))
        }
        guard !ranges.isEmpty else { return (source, false) }
        let merged = ranges.reduce(into: [NSRange]()) { result, range in
            guard let last = result.last, range.location <= NSMaxRange(last) else {
                result.append(range)
                return
            }
            result[result.count - 1] = NSUnionRange(last, range)
        }
        let mutable = NSMutableString(string: source)
        for range in merged.reversed() { mutable.deleteCharacters(in: range) }
        return (mutable as String, true)
    }

    private static func isEveeCodexTable(_ name: String) -> Bool {
        name == "mcp_servers.evee"
            || name.hasPrefix("mcp_servers.evee.")
            || name == "mcp_servers.\"evee\""
            || name.hasPrefix("mcp_servers.\"evee\".")
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

private struct ConfigurationSnapshot {
    let url: URL
    let data: Data?
    let permissions: NSNumber?

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            data = try Data(contentsOf: url)
            permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        } else {
            data = nil
            permissions = nil
        }
    }

    func restore() throws {
        if let data {
            try data.write(to: url, options: .atomic)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
