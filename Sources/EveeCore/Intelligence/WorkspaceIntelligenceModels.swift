import Foundation

public struct WorkspaceIntelligencePreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var includeWindowTitles: Bool
    /// Optional so preferences written before web-address capture decode safely.
    public var includeWebAddresses: Bool?
    public var includeFocusedText: Bool?
    public var journalEnabled: Bool
    public var retentionDays: Int
    public var minimumDwellSeconds: TimeInterval

    public init(
        isEnabled: Bool = false,
        includeWindowTitles: Bool = false,
        includeWebAddresses: Bool = false,
        includeFocusedText: Bool = false,
        journalEnabled: Bool = false,
        retentionDays: Int = 7,
        minimumDwellSeconds: TimeInterval = 5
    ) {
        self.isEnabled = isEnabled
        self.includeWindowTitles = includeWindowTitles
        self.includeWebAddresses = includeWebAddresses
        self.includeFocusedText = includeFocusedText
        self.journalEnabled = journalEnabled
        self.retentionDays = max(1, min(retentionDays, 90))
        self.minimumDwellSeconds = max(1, min(minimumDwellSeconds, 300))
    }
}

public struct WorkspaceApplicationObservation: Codable, Equatable, Sendable {
    public var bundleIdentifier: String?
    public var applicationName: String
    public var windowTitle: String?
    public var webAddress: String?
    public var selectedText: String?
    public var visibleText: String?

    public init(
        bundleIdentifier: String?,
        applicationName: String,
        windowTitle: String? = nil,
        webAddress: String? = nil,
        selectedText: String? = nil,
        visibleText: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.webAddress = webAddress
        self.selectedText = selectedText
        self.visibleText = visibleText
    }
}

public struct WorkspaceDwellEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String?
    public var applicationName: String
    public var windowTitle: String?
    public var startedAt: Date
    public var endedAt: Date

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String?,
        applicationName: String,
        windowTitle: String?,
        startedAt: Date,
        endedAt: Date
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct WorkspaceContextSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var bundleIdentifier: String?
    public var applicationName: String
    public var windowTitle: String?
    public var webAddress: String?
    public var selectedText: String?
    public var visibleText: String?

    public init(
        capturedAt: Date,
        bundleIdentifier: String?,
        applicationName: String,
        windowTitle: String?,
        webAddress: String? = nil,
        selectedText: String? = nil,
        visibleText: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.webAddress = webAddress
        self.selectedText = selectedText
        self.visibleText = visibleText
    }
}

public struct WorkspaceApplicationUsage: Codable, Equatable, Sendable {
    public var bundleIdentifier: String?
    public var applicationName: String
    public var totalDuration: TimeInterval
    public var visitCount: Int
    public var firstSeenAt: Date
    public var lastSeenAt: Date
}

public struct WorkspaceJournalApplication: Codable, Equatable, Sendable {
    public var applicationName: String
    public var duration: TimeInterval
    public var visitCount: Int
}

public struct WorkspaceJournalEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var day: Date
    public var generatedAt: Date
    public var trackedDuration: TimeInterval
    public var applications: [WorkspaceJournalApplication]

    public init(
        id: UUID = UUID(),
        day: Date,
        generatedAt: Date,
        trackedDuration: TimeInterval,
        applications: [WorkspaceJournalApplication]
    ) {
        self.id = id
        self.day = day
        self.generatedAt = generatedAt
        self.trackedDuration = trackedDuration
        self.applications = applications
    }
}

public struct WorkspaceIntelligenceStatus<Value: Codable & Sendable>: Codable, Sendable {
    public var enabled: Bool
    public var collectedAt: Date
    public var value: Value

    public init(enabled: Bool, collectedAt: Date = .now, value: Value) {
        self.enabled = enabled
        self.collectedAt = collectedAt
        self.value = value
    }
}
