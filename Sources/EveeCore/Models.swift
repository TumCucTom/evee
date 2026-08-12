import Foundation

public enum WorkspaceRecordKind: String, Codable, CaseIterable, Sendable {
    case dictation
    case meeting
    case memo
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
    public var duration: TimeInterval?
    public var segments: [TranscriptSegment]
    public var notes: String
    public var tags: [String]

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
        duration: TimeInterval? = nil,
        segments: [TranscriptSegment] = [],
        notes: String = "",
        tags: [String] = []
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
        self.duration = duration
        self.segments = segments
        self.notes = notes
        self.tags = tags
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

public struct EveeSettings: Codable, Sendable {
    public var model: SpeechModel = .parakeet
    public var languageCode = "auto"
    public var retainDictationAudio = false
    public var retainMeetingAudio = false
    public var meetingCaptureEnabled = false
    public var localAPIEnabled = false
    public var localAPIPort: UInt16 = 4739
    public var webhookURL = ""
    public var webhookSecret = ""
    public var defaultTone: WritingTone = .natural
    public var dictionary: [DictionaryTerm] = []
    public var appStyles: [AppWritingStyle] = []

    public init() {}
}

public enum CaptureState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date, level: Float)
    case transcribing
    case delivering
    case failed(String)
}
