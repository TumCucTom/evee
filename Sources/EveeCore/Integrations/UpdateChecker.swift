import Foundation

public struct EveeRelease: Codable, Hashable, Sendable {
    public var version: String
    public var pageURL: URL
    public var publishedAt: Date?

    public init(version: String, pageURL: URL, publishedAt: Date? = nil) {
        self.version = version
        self.pageURL = pageURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case invalidRelease

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The update service returned an invalid response."
        case .invalidRelease: "The latest release metadata is incomplete."
        }
    }
}

public struct UpdateChecker: Sendable {
    public init() {}

    public func latestRelease() async throws -> EveeRelease {
        let endpoint = URL(string: "https://api.github.com/repos/TumCucTom/evee/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateCheckError.invalidResponse }
        struct Payload: Decodable { var tag_name: String; var html_url: URL; var published_at: Date? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        let version = payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !version.isEmpty, payload.html_url.scheme == "https" else { throw UpdateCheckError.invalidRelease }
        return EveeRelease(version: version, pageURL: payload.html_url, publishedAt: payload.published_at)
    }

    public func isNewer(_ candidate: String, than installed: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(installed)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in Int(component.prefix(while: \.isNumber)) ?? 0 }
    }
}

public struct DiagnosticsReport: Sendable {
    public var appVersion: String
    public var operatingSystem: String
    public var model: String
    public var language: String
    public var recordCount: Int
    public var recoveryCount: Int
    public var microphonePermission: Bool
    public var accessibilityPermission: Bool
    public var systemAudioEnabled: Bool
    public var liveMeetingEnabled: Bool
    public var localAPIEnabled: Bool
    public var webhookConfigured: Bool
    public var inputDeviceSelected: Bool

    public func rendered() -> String {
        [
            "Evee diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: .now))",
            "App version: \(appVersion)",
            "Operating system: \(operatingSystem)",
            "Speech model: \(model)",
            "Language: \(language)",
            "Workspace records: \(recordCount)",
            "Recoverable captures: \(recoveryCount)",
            "Microphone permission: \(microphonePermission)",
            "Accessibility permission: \(accessibilityPermission)",
            "System audio enabled: \(systemAudioEnabled)",
            "Live meeting transcript enabled: \(liveMeetingEnabled)",
            "Local API enabled: \(localAPIEnabled)",
            "Webhook configured: \(webhookConfigured)",
            "Custom input selected: \(inputDeviceSelected)",
            "",
            "This report excludes transcript text, notes, window titles, file paths, tokens and secrets."
        ].joined(separator: "\n")
    }
}
