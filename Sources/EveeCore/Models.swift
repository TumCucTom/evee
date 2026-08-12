import Foundation

public enum WorkspaceRecordKind: String, Codable, CaseIterable, Sendable {
    case dictation
    case meeting
    case memo
}

public enum AudioTrackRole: String, Codable, CaseIterable, Sendable {
    case microphone
    case system
    case mixed
}

public struct WorkspaceAudioTrack: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: AudioTrackRole
    public var relativePath: String
    public var createdAt: Date
    public var duration: TimeInterval?
    public var byteCount: Int64?

    public init(
        id: UUID = UUID(),
        role: AudioTrackRole,
        relativePath: String,
        createdAt: Date = .now,
        duration: TimeInterval? = nil,
        byteCount: Int64? = nil
    ) {
        self.id = id
        self.role = role
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.duration = duration
        self.byteCount = byteCount
    }
}

public enum CaptureRecoveryStatus: String, Codable, Sendable {
    case recording
    case captured
    case processing
    case failed
}

public struct CaptureRecoveryManifest: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: WorkspaceRecordKind
    public var startedAt: Date
    public var updatedAt: Date
    public var status: CaptureRecoveryStatus
    public var tracks: [WorkspaceAudioTrack]
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        kind: WorkspaceRecordKind,
        startedAt: Date = .now,
        updatedAt: Date = .now,
        status: CaptureRecoveryStatus = .recording,
        tracks: [WorkspaceAudioTrack] = [],
        failureReason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.status = status
        self.tracks = tracks
        self.failureReason = failureReason
    }
}

/// Notes entered while a meeting is being captured are kept separately from the
/// eventual transcript so they survive an application crash or relaunch.
public struct MeetingDraft: Codable, Equatable, Sendable {
    public var captureID: UUID?
    public var title: String
    public var notes: String
    public var updatedAt: Date

    public init(captureID: UUID? = nil, title: String = "", notes: String = "", updatedAt: Date = .now) {
        self.captureID = captureID
        self.title = title
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

public enum WebhookDeliveryState: String, Codable, Sendable {
    case pending
    case delivered
    case failed
}

public struct WebhookDelivery: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var destination: String
    public var state: WebhookDeliveryState
    public var attemptCount: Int
    public var lastAttemptAt: Date?
    public var deliveredAt: Date?
    public var responseStatusCode: Int?
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        destination: String,
        state: WebhookDeliveryState = .pending,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        deliveredAt: Date? = nil,
        responseStatusCode: Int? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.destination = destination
        self.state = state
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.deliveredAt = deliveredAt
        self.responseStatusCode = responseStatusCode
        self.lastError = lastError
    }
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String?
    public var text: String

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, speaker: String? = nil, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct WorkspaceRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: WorkspaceRecordKind
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String
    public var text: String
    public var rawText: String?
    public var sourceApplication: String?
    public var audioRelativePath: String?
    public var audioTracks: [WorkspaceAudioTrack]
    public var duration: TimeInterval?
    public var segments: [TranscriptSegment]
    public var notes: String
    public var tags: [String]
    public var webhookDeliveries: [WebhookDelivery]

    public init(
        id: UUID = UUID(),
        kind: WorkspaceRecordKind,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        title: String,
        text: String,
        rawText: String? = nil,
        sourceApplication: String? = nil,
        audioRelativePath: String? = nil,
        audioTracks: [WorkspaceAudioTrack] = [],
        duration: TimeInterval? = nil,
        segments: [TranscriptSegment] = [],
        notes: String = "",
        tags: [String] = [],
        webhookDeliveries: [WebhookDelivery] = []
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.text = text
        self.rawText = rawText
        self.sourceApplication = sourceApplication
        self.audioRelativePath = audioRelativePath
        self.audioTracks = audioTracks
        self.duration = duration
        self.segments = segments
        self.notes = notes
        self.tags = tags
        self.webhookDeliveries = webhookDeliveries
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, updatedAt, title, text, rawText, sourceApplication
        case audioRelativePath, audioTracks, duration, segments, notes, tags, webhookDeliveries
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(WorkspaceRecordKind.self, forKey: .kind)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        title = try values.decode(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
        rawText = try values.decodeIfPresent(String.self, forKey: .rawText)
        sourceApplication = try values.decodeIfPresent(String.self, forKey: .sourceApplication)
        audioRelativePath = try values.decodeIfPresent(String.self, forKey: .audioRelativePath)
        audioTracks = try values.decodeIfPresent([WorkspaceAudioTrack].self, forKey: .audioTracks) ?? []
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
        segments = try values.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        webhookDeliveries = try values.decodeIfPresent([WebhookDelivery].self, forKey: .webhookDeliveries) ?? []
    }
}

public struct DictionaryTerm: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var spoken: String
    public var replacement: String
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), spoken: String, replacement: String, caseSensitive: Bool = false) {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }
}

public enum WritingTone: String, Codable, CaseIterable, Sendable {
    case natural
    case concise
    case professional
    case casual
    case verbatim
}

public struct AppWritingStyle: Identifiable, Codable, Hashable, Sendable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var displayName: String
    public var tone: WritingTone
    public var appendPeriod: Bool
    public var useParagraphs: Bool

    public init(bundleIdentifier: String, displayName: String, tone: WritingTone = .natural, appendPeriod: Bool = true, useParagraphs: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.tone = tone
        self.appendPeriod = appendPeriod
        self.useParagraphs = useParagraphs
    }
}

public enum SpeechModel: String, Codable, CaseIterable, Sendable {
    case parakeet
    case qwen3

    public var title: String { self == .parakeet ? "Parakeet v3" : "Qwen3 ASR" }
    public var detail: String { self == .parakeet ? "Fast · multilingual · ~735 MB" : "30 languages · macOS 15+ · ~1.75 GB" }
}

public struct EveeSettings: Codable, Equatable, Sendable {
    public var model: SpeechModel = .parakeet
    public var languageCode = "auto"
    public var retainDictationAudio = false
    public var retainMeetingAudio = false
    public var meetingCaptureEnabled = false
    public var localAPIEnabled = false
    public var localAPIPort: UInt16 = 4739
    public var webhookURL = ""
    /// Only populated while decoding settings written by older Evee builds. New
    /// settings files never encode this value; the app migrates it to Keychain.
    public var webhookSecret = ""
    public var defaultTone: WritingTone = .natural
    public var dictionary: [DictionaryTerm] = []
    public var appStyles: [AppWritingStyle] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case model, languageCode, retainDictationAudio, retainMeetingAudio, meetingCaptureEnabled
        case localAPIEnabled, localAPIPort, webhookURL, webhookSecret, defaultTone, dictionary, appStyles
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decodeIfPresent(SpeechModel.self, forKey: .model) ?? .parakeet
        languageCode = try values.decodeIfPresent(String.self, forKey: .languageCode) ?? "auto"
        retainDictationAudio = try values.decodeIfPresent(Bool.self, forKey: .retainDictationAudio) ?? false
        retainMeetingAudio = try values.decodeIfPresent(Bool.self, forKey: .retainMeetingAudio) ?? false
        meetingCaptureEnabled = try values.decodeIfPresent(Bool.self, forKey: .meetingCaptureEnabled) ?? false
        localAPIEnabled = try values.decodeIfPresent(Bool.self, forKey: .localAPIEnabled) ?? false
        localAPIPort = try values.decodeIfPresent(UInt16.self, forKey: .localAPIPort) ?? 4_739
        webhookURL = try values.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
        webhookSecret = try values.decodeIfPresent(String.self, forKey: .webhookSecret) ?? ""
        defaultTone = try values.decodeIfPresent(WritingTone.self, forKey: .defaultTone) ?? .natural
        dictionary = try values.decodeIfPresent([DictionaryTerm].self, forKey: .dictionary) ?? []
        appStyles = try values.decodeIfPresent([AppWritingStyle].self, forKey: .appStyles) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(languageCode, forKey: .languageCode)
        try values.encode(retainDictationAudio, forKey: .retainDictationAudio)
        try values.encode(retainMeetingAudio, forKey: .retainMeetingAudio)
        try values.encode(meetingCaptureEnabled, forKey: .meetingCaptureEnabled)
        try values.encode(localAPIEnabled, forKey: .localAPIEnabled)
        try values.encode(localAPIPort, forKey: .localAPIPort)
        try values.encode(webhookURL, forKey: .webhookURL)
        try values.encode(defaultTone, forKey: .defaultTone)
        try values.encode(dictionary, forKey: .dictionary)
        try values.encode(appStyles, forKey: .appStyles)
        // webhookSecret is deliberately omitted. It exists in CodingKeys only so
        // a one-time migration can read settings produced by older versions.
    }
}

public enum CaptureState: Equatable, Sendable {
    case idle
    case starting(kind: WorkspaceRecordKind)
    case recording(startedAt: Date, level: Float)
    case transcribing
    case delivering
    case failed(String)
}
