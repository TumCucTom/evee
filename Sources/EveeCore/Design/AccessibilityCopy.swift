import Foundation

public enum AccessibilityCopy {
    public static func recordRow(record: WorkspaceRecord, snippet: String?) -> String {
        [
            record.kind.rawValue.capitalized,
            record.title,
            snippet,
            record.sourceApplication,
            record.createdAt.formatted(date: .abbreviated, time: .shortened),
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: ", ")
    }

    public static let clearSearch = "Clear workspace search"

    public static func removeAppStyle(named applicationName: String) -> String {
        "Remove writing style for \(applicationName)"
    }

    public static func removeSmartLink(phrase: String) -> String {
        "Remove smart link for \(phrase)"
    }

    public static func removeDictionaryTerm(spoken: String, replacement: String) -> String {
        "Remove dictionary replacement \(spoken) with \(replacement)"
    }

    public static func exportRetainedTrack(named trackName: String) -> String {
        "Export retained \(trackName) audio"
    }

    public static func recoveredNotes(startedAt: Date) -> String {
        "Recovered meeting notes from \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    public static func speakerLabel(start: TimeInterval, currentLabel: String?) -> String {
        let seconds = max(0, Int(start))
        let label = currentLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Speaker at \(seconds / 60) minutes \(seconds % 60) seconds, \((label?.isEmpty == false ? label : nil) ?? "unlabelled")"
    }

    public static func elapsedRecordingTime(startedAt: Date, now: Date) -> String {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        var components: [String] = []

        if minutes > 0 {
            components.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")")
        }
        if seconds > 0 || minutes == 0 {
            components.append("\(seconds) \(seconds == 1 ? "second" : "seconds")")
        }
        return "\(components.joined(separator: " ")) elapsed"
    }

    public static func helperRegistration(clientCount: Int) -> String {
        "Enable local helper access for \(clientCount) selected \(clientCount == 1 ? "client" : "clients")"
    }

    public static let helperRevocation = "Revoke local helper access from registered clients"

    public static func deleteRecord(kind: WorkspaceRecordKind, title: String) -> String {
        "Delete \(kind.rawValue) \(title) permanently"
    }

    public static func discardRecovery(kind: WorkspaceRecordKind, startedAt: Date) -> String {
        "Discard interrupted \(kind.rawValue) from \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    public static let deleteActivityData = "Delete all stored activity and journal data"
    public static let revokeLocalAPIAccess = "Revoke local API access and delete its token"
    public static let cancelWebhookOutbox = "Cancel all undelivered webhook items"
}

public enum WorkspaceRouteKind: Equatable, Sendable {
    case library
    case meetings
    case memos
    case dictionary
    case settings
}

public enum RootLayoutMode: Equatable, Sendable {
    case threeColumn
    case sidebarAndDetail

    public static func route(_ route: WorkspaceRouteKind, captureState: CaptureState) -> Self {
        switch route {
        case .settings, .dictionary:
            .sidebarAndDetail
        case .meetings where captureState != .idle:
            .sidebarAndDetail
        default:
            .threeColumn
        }
    }
}
