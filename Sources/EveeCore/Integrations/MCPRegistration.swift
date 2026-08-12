import Foundation

public enum MCPRegistration {
    public static func configuration(executablePath: String) -> [String: Any] {
        ["mcpServers": ["evee": ["command": executablePath, "args": []]]]
    }

    public static func writeClaudeDesktopConfiguration(executablePath: String) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Claude/claude_desktop_config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["evee"] = ["command": executablePath, "args": []]
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
