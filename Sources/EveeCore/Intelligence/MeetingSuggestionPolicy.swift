import Foundation

public struct MeetingSuggestionSettings: Equatable, Sendable {
    public var enabled: Bool
    public var nativeBundleIdentifiers: Set<String>
    public var browserBundleIdentifiers: Set<String>
    public var browserTitleTerms: [String]
    public var dismissedUntilByBundleIdentifier: [String: Date]

    public init(
        enabled: Bool,
        nativeBundleIdentifiers: Set<String>,
        browserBundleIdentifiers: Set<String>,
        browserTitleTerms: [String],
        dismissedUntilByBundleIdentifier: [String: Date]
    ) {
        self.enabled = enabled
        self.nativeBundleIdentifiers = nativeBundleIdentifiers
        self.browserBundleIdentifiers = browserBundleIdentifiers
        self.browserTitleTerms = browserTitleTerms
        self.dismissedUntilByBundleIdentifier = dismissedUntilByBundleIdentifier
    }

    public static let suggestionsDisabled = MeetingSuggestionSettings(
        enabled: false,
        nativeBundleIdentifiers: [],
        browserBundleIdentifiers: [],
        browserTitleTerms: [],
        dismissedUntilByBundleIdentifier: [:]
    )
}

public struct MeetingApplicationSnapshot: Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationName: String
    public let isBrowser: Bool
    public let permittedWindowTitle: String?
    public let observedAt: Date

    public init(bundleIdentifier: String, applicationName: String, isBrowser: Bool, permittedWindowTitle: String?, observedAt: Date) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.isBrowser = isBrowser
        self.permittedWindowTitle = permittedWindowTitle
        self.observedAt = observedAt
    }
}

public struct MeetingSuggestion: Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationName: String

    public init(bundleIdentifier: String, applicationName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }
}

public struct MeetingApplicationIdentity: Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?

    public init(processIdentifier: Int32, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    public func matches(processIdentifier candidateProcessIdentifier: Int32, bundleIdentifier candidateBundleIdentifier: String?) -> Bool {
        if processIdentifier > 0, candidateProcessIdentifier == processIdentifier {
            return true
        }
        guard let bundleIdentifier = normalized(bundleIdentifier),
              let candidateBundleIdentifier = normalized(candidateBundleIdentifier) else {
            return false
        }
        return bundleIdentifier == candidateBundleIdentifier
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

public enum MeetingSuggestionEvent: Equatable, Sendable {
    case observed(MeetingApplicationSnapshot)
    case ownApplicationActivated
    case externalApplicationUnavailable
    case dismissed
}

public struct MeetingSuggestionPolicy: Sendable {
    private let settings: MeetingSuggestionSettings

    public init(settings: MeetingSuggestionSettings) { self.settings = settings }

    public func nextSuggestion(
        current: MeetingSuggestion?,
        event: MeetingSuggestionEvent
    ) -> MeetingSuggestion? {
        switch event {
        case .ownApplicationActivated:
            return current
        case .observed(let snapshot):
            return evaluate(snapshot)
        case .externalApplicationUnavailable, .dismissed:
            return nil
        }
    }

    public func evaluate(_ snapshot: MeetingApplicationSnapshot) -> MeetingSuggestion? {
        guard settings.enabled,
              (settings.dismissedUntilByBundleIdentifier[snapshot.bundleIdentifier] ?? .distantPast) <= snapshot.observedAt else {
            return nil
        }
        if snapshot.isBrowser {
            guard settings.browserBundleIdentifiers.contains(snapshot.bundleIdentifier),
                  let title = snapshot.permittedWindowTitle,
                  settings.browserTitleTerms.contains(where: {
                      !$0.isEmpty && title.localizedCaseInsensitiveContains($0)
                  }) else { return nil }
        } else {
            guard settings.nativeBundleIdentifiers.contains(snapshot.bundleIdentifier) else { return nil }
        }
        return MeetingSuggestion(bundleIdentifier: snapshot.bundleIdentifier, applicationName: snapshot.applicationName)
    }
}
