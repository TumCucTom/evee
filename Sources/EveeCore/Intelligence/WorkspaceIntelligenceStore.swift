import Foundation

private struct IntelligenceEnvelope<Value: Codable>: Codable {
    var schemaVersion: Int
    var updatedAt: Date
    var value: Value
}

public actor WorkspaceIntelligenceStore {
    public static let shared = WorkspaceIntelligenceStore()
    public static let schemaVersion = 1

    private let rootURL: URL
    private let preferencesURL: URL
    private let eventsURL: URL
    private let contextURL: URL
    private let journalURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var activeObservation: WorkspaceApplicationObservation?
    private var activeSince: Date?

    public init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = (rootURL ?? support.appendingPathComponent("Evee/Intelligence", isDirectory: true)).standardizedFileURL
        preferencesURL = self.rootURL.appendingPathComponent("preferences.json")
        eventsURL = self.rootURL.appendingPathComponent("dwell-events.json")
        contextURL = self.rootURL.appendingPathComponent("current-context.json")
        journalURL = self.rootURL.appendingPathComponent("journal.json")
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func preferences() throws -> WorkspaceIntelligencePreferences {
        try prepare()
        return try read(WorkspaceIntelligencePreferences.self, from: preferencesURL) ?? WorkspaceIntelligencePreferences()
    }

    public func savePreferences(_ proposed: WorkspaceIntelligencePreferences, at date: Date = .now) throws {
        let current = try preferences()
        let normalized = WorkspaceIntelligencePreferences(
            isEnabled: proposed.isEnabled,
            includeWindowTitles: proposed.includeWindowTitles,
            journalEnabled: proposed.journalEnabled,
            retentionDays: proposed.retentionDays,
            minimumDwellSeconds: proposed.minimumDwellSeconds
        )
        if current.isEnabled && (!normalized.isEnabled || (current.includeWindowTitles && !normalized.includeWindowTitles)) {
            try finishActive(at: date, preferences: current)
        }
        try write(normalized, to: preferencesURL)
        try applyRetention(preferences: normalized, now: date)
        if !normalized.includeWindowTitles { try removeStoredWindowTitles() }
        if !normalized.journalEnabled { try write([WorkspaceJournalEntry](), to: journalURL) }
        if !normalized.isEnabled { try removeIfPresent(contextURL) }
    }

    public func record(_ proposed: WorkspaceApplicationObservation, at date: Date = .now) throws {
        let preferences = try preferences()
        guard preferences.isEnabled else { return }
        let observation = WorkspaceApplicationObservation(
            bundleIdentifier: proposed.bundleIdentifier,
            applicationName: proposed.applicationName.trimmingCharacters(in: .whitespacesAndNewlines),
            windowTitle: preferences.includeWindowTitles ? sanitize(proposed.windowTitle) : nil
        )
        guard !observation.applicationName.isEmpty else { return }

        if activeObservation != observation {
            try finishActive(at: date, preferences: preferences)
            activeObservation = observation
            activeSince = date
        }
        let snapshot = WorkspaceContextSnapshot(
            capturedAt: date,
            bundleIdentifier: observation.bundleIdentifier,
            applicationName: observation.applicationName,
            windowTitle: observation.windowTitle
        )
        try write(snapshot, to: contextURL)
        try applyRetention(preferences: preferences, now: date)
    }

    public func stop(at date: Date = .now) throws {
        try finishActive(at: date, preferences: preferences())
        try removeIfPresent(contextURL)
    }

    public func timeline(since: Date? = nil, limit: Int = 100) throws -> WorkspaceIntelligenceStatus<[WorkspaceDwellEvent]> {
        let preferences = try preferences()
        let events = try storedEvents()
            .filter { since == nil || $0.endedAt >= since! }
            .sorted { $0.startedAt > $1.startedAt }
        return WorkspaceIntelligenceStatus(enabled: preferences.isEnabled, value: Array(events.prefix(max(1, min(limit, 500)))))
    }

    public func currentContext() throws -> WorkspaceIntelligenceStatus<WorkspaceContextSnapshot?> {
        let preferences = try preferences()
        let context = preferences.isEnabled ? try read(WorkspaceContextSnapshot.self, from: contextURL) : nil
        return WorkspaceIntelligenceStatus(enabled: preferences.isEnabled, value: context)
    }

    public func applicationUsage(since: Date? = nil, limit: Int = 100) throws -> WorkspaceIntelligenceStatus<[WorkspaceApplicationUsage]> {
        let preferences = try preferences()
        let events = try storedEvents().filter { since == nil || $0.endedAt >= since! }
        let groups = Dictionary(grouping: events) { event in
            [event.bundleIdentifier ?? "", event.applicationName].joined(separator: "\u{1F}")
        }
        let usage = groups.values.compactMap { values -> WorkspaceApplicationUsage? in
            guard let first = values.first else { return nil }
            return WorkspaceApplicationUsage(
                bundleIdentifier: first.bundleIdentifier,
                applicationName: first.applicationName,
                totalDuration: values.reduce(0) { $0 + $1.duration },
                visitCount: values.count,
                firstSeenAt: values.map(\.startedAt).min() ?? first.startedAt,
                lastSeenAt: values.map(\.endedAt).max() ?? first.endedAt
            )
        }.sorted { lhs, rhs in
            lhs.totalDuration == rhs.totalDuration ? lhs.applicationName < rhs.applicationName : lhs.totalDuration > rhs.totalDuration
        }
        return WorkspaceIntelligenceStatus(enabled: preferences.isEnabled, value: Array(usage.prefix(max(1, min(limit, 500)))))
    }

    public func journal(limit: Int = 30) throws -> WorkspaceIntelligenceStatus<[WorkspaceJournalEntry]> {
        let preferences = try preferences()
        let entries = try storedJournal().sorted { $0.day > $1.day }
        return WorkspaceIntelligenceStatus(
            enabled: preferences.isEnabled && preferences.journalEnabled,
            value: Array(entries.prefix(max(1, min(limit, 90))))
        )
    }

    public func purge() throws {
        activeObservation = nil
        activeSince = nil
        try prepare()
        try write([WorkspaceDwellEvent](), to: eventsURL)
        try write([WorkspaceJournalEntry](), to: journalURL)
        try removeIfPresent(contextURL)
    }

    private func finishActive(at date: Date, preferences: WorkspaceIntelligencePreferences) throws {
        defer {
            activeObservation = nil
            activeSince = nil
        }
        guard preferences.isEnabled,
              let observation = activeObservation,
              let startedAt = activeSince,
              date >= startedAt,
              date.timeIntervalSince(startedAt) >= preferences.minimumDwellSeconds else { return }
        var events = try storedEvents()
        events.append(WorkspaceDwellEvent(
            bundleIdentifier: observation.bundleIdentifier,
            applicationName: observation.applicationName,
            windowTitle: observation.windowTitle,
            startedAt: startedAt,
            endedAt: date
        ))
        try write(events, to: eventsURL)
        if preferences.journalEnabled { try rebuildJournal(events: events, generatedAt: date) }
    }

    private func applyRetention(preferences: WorkspaceIntelligencePreferences, now: Date) throws {
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -preferences.retentionDays, to: now) ?? now
        let currentEvents = try storedEvents()
        let retained = currentEvents.filter { $0.endedAt >= cutoff }
        if retained.count != currentEvents.count { try write(retained, to: eventsURL) }
        if preferences.journalEnabled { try rebuildJournal(events: retained, generatedAt: now) }
    }

    private func rebuildJournal(events: [WorkspaceDwellEvent], generatedAt: Date) throws {
        let calendar = Calendar(identifier: .gregorian)
        let existing = Dictionary(uniqueKeysWithValues: try storedJournal().map { (calendar.startOfDay(for: $0.day), $0.id) })
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.startedAt) }
        let entries = grouped.map { day, values in
            let appGroups = Dictionary(grouping: values, by: \.applicationName)
            let applications = appGroups.map { name, appEvents in
                WorkspaceJournalApplication(
                    applicationName: name,
                    duration: appEvents.reduce(0) { $0 + $1.duration },
                    visitCount: appEvents.count
                )
            }.sorted { $0.duration == $1.duration ? $0.applicationName < $1.applicationName : $0.duration > $1.duration }
            return WorkspaceJournalEntry(
                id: existing[day] ?? UUID(),
                day: day,
                generatedAt: generatedAt,
                trackedDuration: values.reduce(0) { $0 + $1.duration },
                applications: applications
            )
        }.sorted { $0.day > $1.day }
        try write(entries, to: journalURL)
    }

    private func removeStoredWindowTitles() throws {
        let events = try storedEvents()
        let redacted = events.map { event in
            WorkspaceDwellEvent(
                id: event.id,
                bundleIdentifier: event.bundleIdentifier,
                applicationName: event.applicationName,
                windowTitle: nil,
                startedAt: event.startedAt,
                endedAt: event.endedAt
            )
        }
        try write(redacted, to: eventsURL)
        if let snapshot = try read(WorkspaceContextSnapshot.self, from: contextURL) {
            try write(WorkspaceContextSnapshot(
                capturedAt: snapshot.capturedAt,
                bundleIdentifier: snapshot.bundleIdentifier,
                applicationName: snapshot.applicationName,
                windowTitle: nil
            ), to: contextURL)
        }
    }

    private func storedEvents() throws -> [WorkspaceDwellEvent] {
        try read([WorkspaceDwellEvent].self, from: eventsURL) ?? []
    }

    private func storedJournal() throws -> [WorkspaceJournalEntry] {
        try read([WorkspaceJournalEntry].self, from: journalURL) ?? []
    }

    private func sanitize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(500))
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    }

    private func read<Value: Codable>(_ type: Value.Type, from url: URL) throws -> Value? {
        try prepare()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try decoder.decode(IntelligenceEnvelope<Value>.self, from: Data(contentsOf: url))
        guard envelope.schemaVersion <= Self.schemaVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported workspace intelligence schema."))
        }
        return envelope.value
    }

    private func write<Value: Codable>(_ value: Value, to url: URL) throws {
        try prepare()
        let data = try encoder.encode(IntelligenceEnvelope(schemaVersion: Self.schemaVersion, updatedAt: .now, value: value))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
