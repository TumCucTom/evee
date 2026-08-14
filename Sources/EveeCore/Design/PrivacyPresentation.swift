public struct PrivacyPresentation: Equatable, Sendable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public var constructsWorkspaceContent: Bool { !enabled }
    public var constructsSettingsContent: Bool { !enabled }
    public var constructsMenuContent: Bool { true }

    public var accessibilityLabel: String {
        enabled
            ? "Privacy mode is on. Sensitive Evee content is hidden."
            : "Privacy mode is off."
    }

    public var windowProtectionCopy: String {
        "Window sharing exclusion is best-effort. Turn on privacy mode to hide sensitive in-app content."
    }
}
