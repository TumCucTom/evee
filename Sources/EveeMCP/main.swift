import EveeCore
import Foundation

private struct MCPFailure: LocalizedError {
    var code: Int
    var message: String
    var errorDescription: String? { message }
}

private struct WorkspaceStats: Codable {
    var totalRecords: Int
    var dictations: Int
    var meetings: Int
    var memos: Int
    var totalDuration: TimeInterval
    var totalWords: Int
    var firstActivityAt: Date?
    var lastActivityAt: Date?
    var activeDays: Int
    var currentDailyStreak: Int
    var longestDailyStreak: Int
}

private struct SearchHit: Codable {
    var record: WorkspaceRecord
    var snippet: String
}

private struct JournalReportEntry: Codable {
    var activity: WorkspaceJournalEntry
    var voiceRecordCount: Int
    var dictationCount: Int
    var meetingCount: Int
    var memoCount: Int
    var meetingDecisions: [MeetingInsight]
    var meetingActionItems: [MeetingInsight]
    var memoActionItems: [String]
}

private struct PublicConfiguration: Codable {
    var model: SpeechModel
    var languageCode: String
    var retainDictationAudio: Bool
    var retainMeetingAudio: Bool
    var meetingCaptureEnabled: Bool
    var meetingDiarizationEnabled: Bool
    var localAPIEnabled: Bool
    var localAPIPort: UInt16
    var webhookConfigured: Bool
    var defaultTone: WritingTone
    var dictionaryTermCount: Int
    var appStyleCount: Int
    var activityTrackingEnabled: Bool
    var activityWindowTitlesEnabled: Bool
    var activityWebAddressesEnabled: Bool
    var activityFocusedTextEnabled: Bool
    var activityJournalEnabled: Bool
    var activityRetentionDays: Int
    var textDeliveryMode: TextDeliveryMode
    var emailFormattingMode: EmailFormattingMode
    var correctionLearningEnabled: Bool
    var smartLinkCount: Int
    var workspaceRetentionDays: Int
    var selectedInputDevice: Bool
    var lowLatencyMode: Bool
}

@main
enum EveeMCP {
    static let protocolVersion = "2025-03-26"

    static func main() async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }
            guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }

            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]
            guard let id = request["id"] else {
                // JSON-RPC notifications, including notifications/initialized, have no response.
                continue
            }

            do {
                let result = try await handle(method: method, params: params)
                write(["jsonrpc": "2.0", "id": id, "result": result])
            } catch let error as MCPFailure {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
            } catch {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": error.localizedDescription]])
            }
        }
    }

    static func handle(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "evee", "version": "0.2.0"],
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": toolDefinitions]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPFailure(code: -32602, message: "tools/call requires a tool name.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return ["content": [["type": "text", "text": try await callTool(name: name, arguments: arguments)]]]
        default:
            throw MCPFailure(code: -32601, message: "Method not found: \(method)")
        }
    }

    static func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let store = LibraryStore.shared
        let limit = max(1, min(arguments["limit"] as? Int ?? 20, 200))

        switch name {
        case "search":
            let query = arguments["query"] as? String ?? ""
            let kind = (arguments["kind"] as? String).flatMap(WorkspaceRecordKind.init(rawValue:))
            let records = try await store.search(query, kind: kind, limit: limit)
            return try encode(records.map { record in
                SearchHit(record: publicRecord(record), snippet: searchSnippet(for: record, query: query))
            })

        case "recent_activity":
            let kind = (arguments["kind"] as? String).flatMap(WorkspaceRecordKind.init(rawValue:))
            let since = parseDate(arguments["since"] as? String)
            let records = try await store.recent(kind: kind, limit: limit, since: since)
            return try encode(records.map(publicRecord))

        case "ambient_timeline":
            let since = parseDate(arguments["since"] as? String)
            let timeline = try await WorkspaceIntelligenceStore.shared.timeline(since: since, limit: limit)
            return try encode(timeline)

        case "ambient_app_usage":
            let since = parseDate(arguments["since"] as? String)
            let usage = try await WorkspaceIntelligenceStore.shared.applicationUsage(since: since, limit: limit)
            return try encode(usage)

        case "get_context":
            let context = try await WorkspaceIntelligenceStore.shared.currentContext()
            return try encode(context)

        case "get_journal":
            let journal = try await WorkspaceIntelligenceStore.shared.journal(limit: limit)
            let records = try await store.loadRecords()
            let calendar = Calendar.current
            let enriched = journal.value.map { entry in
                let matching = records.filter { calendar.isDate($0.createdAt, inSameDayAs: entry.day) }
                return JournalReportEntry(
                    activity: entry,
                    voiceRecordCount: matching.count,
                    dictationCount: matching.filter { $0.kind == .dictation }.count,
                    meetingCount: matching.filter { $0.kind == .meeting }.count,
                    memoCount: matching.filter { $0.kind == .memo }.count,
                    meetingDecisions: matching.compactMap(\.meetingIntelligence).flatMap(\.decisions),
                    meetingActionItems: matching.compactMap(\.meetingIntelligence).flatMap(\.actionItems),
                    memoActionItems: matching.compactMap(\.memoIntelligence).flatMap(\.actionItems)
                )
            }
            return try encode(WorkspaceIntelligenceStatus(enabled: journal.enabled, collectedAt: journal.collectedAt, value: enriched))

        case "get_dictation":
            return try await encodeRecord(kind: .dictation, arguments: arguments, store: store)
        case "get_meeting":
            return try await encodeRecord(kind: .meeting, arguments: arguments, store: store)
        case "get_memo":
            return try await encodeRecord(kind: .memo, arguments: arguments, store: store)

        case "get_stats":
            let records = try await store.loadRecords()
            let orderedDates = records.map(\.createdAt).sorted()
            let streaks = activityStreaks(records.map(\.createdAt))
            return try encode(WorkspaceStats(
                totalRecords: records.count,
                dictations: records.filter { $0.kind == .dictation }.count,
                meetings: records.filter { $0.kind == .meeting }.count,
                memos: records.filter { $0.kind == .memo }.count,
                totalDuration: records.compactMap(\.duration).reduce(0, +),
                totalWords: records.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count },
                firstActivityAt: orderedDates.first,
                lastActivityAt: orderedDates.last,
                activeDays: streaks.activeDays,
                currentDailyStreak: streaks.current,
                longestDailyStreak: streaks.longest
            ))

        case "get_config":
            let settings = try await store.loadSettings()
            let intelligence = try await WorkspaceIntelligenceStore.shared.preferences()
            return try encode(PublicConfiguration(
                model: settings.model,
                languageCode: settings.languageCode,
                retainDictationAudio: settings.retainDictationAudio,
                retainMeetingAudio: settings.retainMeetingAudio,
                meetingCaptureEnabled: settings.meetingCaptureEnabled,
                meetingDiarizationEnabled: settings.meetingDiarizationEnabled,
                localAPIEnabled: settings.localAPIEnabled,
                localAPIPort: settings.localAPIPort,
                webhookConfigured: !settings.webhookURL.isEmpty,
                defaultTone: settings.defaultTone,
                dictionaryTermCount: settings.dictionary.count,
                appStyleCount: settings.appStyles.count,
                activityTrackingEnabled: intelligence.isEnabled,
                activityWindowTitlesEnabled: intelligence.includeWindowTitles,
                activityWebAddressesEnabled: intelligence.includeWebAddresses == true,
                activityFocusedTextEnabled: intelligence.includeFocusedText == true,
                activityJournalEnabled: intelligence.journalEnabled,
                activityRetentionDays: intelligence.retentionDays,
                textDeliveryMode: settings.textDeliveryMode,
                emailFormattingMode: settings.emailFormattingMode,
                correctionLearningEnabled: settings.learnCorrections,
                smartLinkCount: settings.smartLinks.count,
                workspaceRetentionDays: settings.historyRetentionDays,
                selectedInputDevice: !settings.inputDeviceUID.isEmpty,
                lowLatencyMode: settings.lowLatencyMode
            ))

        default:
            throw MCPFailure(code: -32602, message: "Unknown tool: \(name)")
        }
    }

    static func encodeRecord(kind: WorkspaceRecordKind, arguments: [String: Any], store: LibraryStore) async throws -> String {
        if let rawID = arguments["id"] as? String {
            guard let id = UUID(uuidString: rawID), let record = try await store.record(id: id), record.kind == kind else {
                throw MCPFailure(code: -32602, message: "No \(kind.rawValue) exists with that id.")
            }
            return try encode(publicRecord(record))
        }
        let latest = try await store.recent(kind: kind, limit: 1).first
        return try encode(latest.map(publicRecord))
    }

    static func publicRecord(_ record: WorkspaceRecord) -> WorkspaceRecord {
        var copy = record
        for index in copy.webhookDeliveries.indices { copy.webhookDeliveries[index].payloadBody = nil }
        return copy
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    static func searchSnippet(for record: WorkspaceRecord, query: String) -> String {
        let source = [record.title, record.text, record.notes, record.tags.joined(separator: " ")].joined(separator: "\n")
        guard let range = source.range(of: query, options: .caseInsensitive) else { return String(source.prefix(240)) }
        let start = source.index(range.lowerBound, offsetBy: -90, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(range.upperBound, offsetBy: 150, limitedBy: source.endIndex) ?? source.endIndex
        return String(source[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func activityStreaks(_ dates: [Date], calendar: Calendar = .current) -> (activeDays: Int, current: Int, longest: Int) {
        let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
        guard !days.isEmpty else { return (0, 0, 0) }
        var longest = 1
        var run = 1
        for index in 1..<days.count {
            if calendar.dateComponents([.day], from: days[index - 1], to: days[index]).day == 1 {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }
        let today = calendar.startOfDay(for: .now)
        guard let last = days.last else { return (0, 0, 0) }
        let distance = calendar.dateComponents([.day], from: last, to: today).day ?? Int.max
        let current = (distance == 0 || distance == 1) ? run : 0
        return (days.count, current, longest)
    }

    static var toolDefinitions: [[String: Any]] {
        let limitProperty: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 200]
        let kindProperty: [String: Any] = ["type": "string", "enum": WorkspaceRecordKind.allCases.map(\.rawValue)]
        let idSchema: [String: Any] = ["type": "object", "properties": ["id": ["type": "string", "format": "uuid"]]]
        let sinceSchema: [String: Any] = [
            "type": "object",
            "properties": ["since": ["type": "string", "format": "date-time"], "limit": limitProperty],
        ]
        return [
            tool("search", "Search local Evee dictations, meetings, memos, notes and tags.", ["type": "object", "properties": ["query": ["type": "string"], "kind": kindProperty, "limit": limitProperty], "required": ["query"]]),
            tool("recent_activity", "Return recent local voice activity, optionally filtered by kind and time.", ["type": "object", "properties": ["kind": kindProperty, "since": ["type": "string", "format": "date-time"], "limit": limitProperty]]),
            tool("ambient_timeline", "Return locally collected application dwell events when activity tracking is enabled.", sinceSchema),
            tool("ambient_app_usage", "Summarise locally collected application dwell time when activity tracking is enabled.", sinceSchema),
            tool("get_context", "Return the current application context snapshot when activity tracking is enabled.", ["type": "object", "properties": [:]]),
            tool("get_journal", "Return durable daily activity summaries generated from collected dwell events.", ["type": "object", "properties": ["limit": limitProperty]]),
            tool("get_dictation", "Get a dictation by UUID, or the most recent dictation when omitted.", idSchema),
            tool("get_meeting", "Get a meeting by UUID, or the most recent meeting when omitted.", idSchema),
            tool("get_memo", "Get a memo by UUID, or the most recent memo when omitted.", idSchema),
            tool("get_stats", "Return aggregate counts, duration and word statistics for the local workspace.", ["type": "object", "properties": [:]]),
            tool("get_config", "Return non-secret Evee configuration and personalisation counts.", ["type": "object", "properties": [:]]),
        ]
    }

    static func tool(_ name: String, _ description: String, _ schema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": schema]
    }

    static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}
