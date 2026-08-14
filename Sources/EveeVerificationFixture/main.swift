import EveeCore
import Foundation

@main
enum EveeVerificationFixture {
    static func main() async {
        do {
            let homeURL = try homeURL(arguments: Array(CommandLine.arguments.dropFirst()))
            try await seed(homeURL: homeURL)
        } catch {
            fputs("Verification fixture failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func homeURL(arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--home", arguments[1].hasPrefix("/") else {
            throw FixtureError.invalidArguments
        }
        let home = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FixtureError.invalidHome
        }
        return home
    }

    private static func seed(homeURL: URL) async throws {
        let support = homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        let workspaceRoot = support.appendingPathComponent("Evee", isDirectory: true)
        let realSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Evee", isDirectory: true)
            .standardizedFileURL
        guard workspaceRoot.standardizedFileURL != realSupport else { throw FixtureError.realDataRoot }
        guard !FileManager.default.fileExists(atPath: workspaceRoot.path) else { throw FixtureError.workspaceAlreadyExists }

        let now = Date()
        let dictationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let meetingID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let memoID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let decisionSegmentID = UUID(uuidString: "20000000-0000-0000-0000-000000000011")!
        let actionSegmentID = UUID(uuidString: "20000000-0000-0000-0000-000000000012")!

        let dictation = WorkspaceRecord(
            id: dictationID,
            kind: .dictation,
            createdAt: now.addingTimeInterval(-180),
            updatedAt: now.addingTimeInterval(-180),
            title: "Synthetic dictation",
            text: "Alpha verification phrase for search",
            sourceApplication: "Fixture Editor",
            duration: 4
        )
        let segments = [
            TranscriptSegment(
                id: decisionSegmentID,
                start: 0,
                end: 4,
                speaker: nil,
                text: "Decision: ship the isolated verifier.",
                channel: .microphone,
                attribution: .channel,
                timingSource: .token
            ),
            TranscriptSegment(
                id: actionSegmentID,
                start: 4,
                end: 8,
                speaker: nil,
                text: "Action: inspect the packaged helper.",
                channel: .system,
                attribution: .channel,
                timingSource: .token
            ),
        ]
        let meeting = WorkspaceRecord(
            id: meetingID,
            kind: .meeting,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120),
            title: "Synthetic meeting",
            text: segments.map(\.text).joined(separator: " "),
            sourceApplication: "Fixture Meeting",
            duration: 8,
            segments: segments,
            meetingIntelligence: MeetingIntelligence(
                summary: ["Decision evidence: ship the isolated verifier"],
                decisions: [MeetingInsight(kind: .decision, text: "ship the isolated verifier", sourceSegmentID: decisionSegmentID, sourceTime: 0)],
                actionItems: [MeetingInsight(kind: .actionItem, text: "inspect the packaged helper", sourceSegmentID: actionSegmentID, sourceTime: 4)],
                method: .localExtractive,
                generatedAt: now
            ),
            notes: "Decision evidence: ship the isolated verifier"
        )
        let memo = WorkspaceRecord(
            id: memoID,
            kind: .memo,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60),
            title: "Synthetic memo",
            text: "Remember to inspect the packaged helper.",
            sourceApplication: "Fixture Notes",
            duration: 3,
            memoIntelligence: MemoIntelligence(
                title: "Inspect the packaged helper",
                highlights: ["Remember to inspect the packaged helper."],
                actionItems: ["Inspect the packaged helper"]
            )
        )

        let store = LibraryStore(rootURL: workspaceRoot)
        try await store.save([dictation, meeting, memo])
        var settings = EveeSettings()
        settings.mcpEnabled = true
        settings.model = .parakeet
        settings.languageCode = "en"
        settings.localAPIEnabled = false
        settings.webhookURL = ""
        settings.dictionary = [
            DictionaryTerm(spoken: "alpha", replacement: "Alpha"),
            DictionaryTerm(spoken: "beta", replacement: "Beta"),
            DictionaryTerm(spoken: "gamma", replacement: "Gamma"),
        ]
        settings.appStyles = [
            AppWritingStyle(bundleIdentifier: "fixture.editor", displayName: "Fixture Editor", tone: .concise),
            AppWritingStyle(bundleIdentifier: "fixture.browser", displayName: "Fixture Browser", tone: .professional),
        ]
        try await store.save(settings)

        let intelligence = WorkspaceIntelligenceStore(
            rootURL: workspaceRoot.appendingPathComponent("Intelligence", isDirectory: true)
        )
        try await intelligence.savePreferences(WorkspaceIntelligencePreferences(
            isEnabled: true,
            includeWindowTitles: true,
            includeWebAddresses: false,
            includeFocusedText: false,
            journalEnabled: true,
            retentionDays: 7,
            minimumDwellSeconds: 1
        ), at: now.addingTimeInterval(-6))
        try await intelligence.record(WorkspaceApplicationObservation(
            bundleIdentifier: "fixture.editor",
            applicationName: "Editor",
            windowTitle: "Fixture document"
        ), at: now.addingTimeInterval(-6))
        try await intelligence.record(WorkspaceApplicationObservation(
            bundleIdentifier: "fixture.browser",
            applicationName: "Browser",
            windowTitle: "Fixture page"
        ), at: now.addingTimeInterval(-3))
        try await intelligence.record(WorkspaceApplicationObservation(
            bundleIdentifier: "fixture.browser",
            applicationName: "Browser",
            windowTitle: "Fixture page"
        ), at: now)
    }

    private enum FixtureError: LocalizedError {
        case invalidArguments
        case invalidHome
        case realDataRoot
        case workspaceAlreadyExists

        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "Usage: evee-verification-fixture --home <absolute-directory>."
            case .invalidHome: return "Fixture home must be an existing directory."
            case .realDataRoot: return "Refusing to write the real Evee application-support directory."
            case .workspaceAlreadyExists: return "Fixture workspace already exists."
            }
        }
    }
}
