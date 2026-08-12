import FluidAudio
import Foundation

public enum TranscriptTimingSource: String, Codable, Sendable {
    /// Start and end were emitted by the speech recognizer for the underlying tokens.
    case token
    /// The recognizer processed a bounded audio chunk with known sample boundaries.
    case audioChunk
    /// Only the containing track duration was available.
    case trackEstimate
}

public enum SpeakerAttribution: String, Codable, Sendable {
    /// The microphone/system channel establishes the source, but not a person's identity.
    case channel
    /// An offline speaker model associated this interval with a stable anonymous speaker.
    case diarized
    /// No reliable channel or diarization association was available.
    case unknown
}

public struct LocalTranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var confidence: Float?
    public var timingSource: TranscriptTimingSource

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Float? = nil,
        timingSource: TranscriptTimingSource
    ) {
        self.id = id
        self.start = max(0, start)
        self.end = max(self.start, end)
        self.text = text
        self.confidence = confidence
        self.timingSource = timingSource
    }
}

public struct LocalTranscript: Codable, Hashable, Sendable {
    public var text: String
    public var duration: TimeInterval
    public var segments: [LocalTranscriptSegment]

    public init(text: String, duration: TimeInterval, segments: [LocalTranscriptSegment]) {
        self.text = text
        self.duration = max(0, duration)
        self.segments = segments
    }
}

/// A speech token whose timestamps are expressed on the source audio track's clock.
/// This app-owned value keeps transcript assembly independent of a model vendor's
/// serialization details while preserving the timing emitted by the recognizer.
public struct TranscriptTokenTiming: Codable, Hashable, Sendable {
    public var token: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?

    public init(token: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.token = token
        self.start = max(0, start)
        self.end = max(self.start, end)
        self.confidence = confidence
    }
}

/// Converts token-level recognizer output into bounded utterances without inventing
/// timestamps. Silence gaps are the primary boundary; punctuation only splits after
/// a short pause, which avoids turning every clause into a tiny timeline row.
public struct TokenTimingSegmenter: Sendable {
    public var silenceBoundary: TimeInterval
    public var punctuationPause: TimeInterval
    public var maximumSegmentDuration: TimeInterval

    public init(
        silenceBoundary: TimeInterval = 0.65,
        punctuationPause: TimeInterval = 0.18,
        maximumSegmentDuration: TimeInterval = 15
    ) {
        self.silenceBoundary = max(0, silenceBoundary)
        self.punctuationPause = max(0, punctuationPause)
        self.maximumSegmentDuration = max(1, maximumSegmentDuration)
    }

    public func segments(
        transcriptText: String,
        duration: TimeInterval,
        timings: [TranscriptTokenTiming]
    ) -> [LocalTranscriptSegment] {
        let usable = timings
            .filter { $0.end > $0.start && !cleanedToken($0.token).isEmpty }
            .sorted { lhs, rhs in lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start }

        guard !usable.isEmpty else {
            let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [LocalTranscriptSegment(
                start: 0,
                end: max(0, duration),
                text: text,
                timingSource: .trackEstimate
            )]
        }

        var groups: [[TranscriptTokenTiming]] = []
        var current: [TranscriptTokenTiming] = []
        for timing in usable {
            if let previous = current.last {
                let gap = max(0, timing.start - previous.end)
                let currentDuration = previous.end - (current.first?.start ?? previous.start)
                let punctuationBoundary = endsSentence(cleanedToken(previous.token)) && gap >= punctuationPause
                if gap >= silenceBoundary || punctuationBoundary || currentDuration >= maximumSegmentDuration {
                    groups.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            }
            current.append(timing)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let text = renderedText(group.map(\.token))
            guard !text.isEmpty else { return nil }
            let confidences = group.compactMap(\.confidence)
            let confidence = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Float(confidences.count)
            return LocalTranscriptSegment(
                start: first.start,
                end: last.end,
                text: text,
                confidence: confidence,
                timingSource: .token
            )
        }
    }

    private func cleanedToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) else { return "" }
        return trimmed
    }

    private func renderedText(_ tokens: [String]) -> String {
        var result = ""
        let punctuation = CharacterSet(charactersIn: ".,!?;:%)]}")
        for raw in tokens {
            var value = cleanedToken(raw)
            guard !value.isEmpty else { continue }
            let startsWord = value.hasPrefix("▁") || value.hasPrefix("Ġ")
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "▁Ġ"))
            guard !value.isEmpty else { continue }
            let firstScalar = value.unicodeScalars.first
            let isPunctuation = firstScalar.map(punctuation.contains) ?? false
            if !result.isEmpty && startsWord && !isPunctuation { result.append(" ") }
            result.append(value)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endsSentence(_ token: String) -> Bool {
        guard let final = token.last else { return false }
        return ".!?".contains(final)
    }
}

public struct SpeakerInterval: Codable, Hashable, Sendable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?

    public init(speakerID: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.speakerID = speakerID
        self.start = max(0, start)
        self.end = max(self.start, end)
        self.confidence = confidence
    }
}

public enum MeetingInsightKind: String, Codable, Sendable {
    case decision
    case actionItem
}

public struct MeetingInsight: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: MeetingInsightKind
    public var text: String
    public var assignee: String?
    public var dueText: String?
    public var sourceSegmentID: UUID?
    public var sourceTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        kind: MeetingInsightKind,
        text: String,
        assignee: String? = nil,
        dueText: String? = nil,
        sourceSegmentID: UUID? = nil,
        sourceTime: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.assignee = assignee
        self.dueText = dueText
        self.sourceSegmentID = sourceSegmentID
        self.sourceTime = sourceTime
    }
}

public enum MeetingIntelligenceMethod: String, Codable, Sendable {
    /// Deterministic, local extraction from transcript evidence. This is not a generative summary.
    case localExtractive
}

public struct MeetingIntelligence: Codable, Hashable, Sendable {
    public var summary: [String]
    public var decisions: [MeetingInsight]
    public var actionItems: [MeetingInsight]
    public var method: MeetingIntelligenceMethod
    public var generatedAt: Date

    public init(
        summary: [String] = [],
        decisions: [MeetingInsight] = [],
        actionItems: [MeetingInsight] = [],
        method: MeetingIntelligenceMethod = .localExtractive,
        generatedAt: Date = .now
    ) {
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.method = method
        self.generatedAt = generatedAt
    }

    public var isEmpty: Bool { summary.isEmpty && decisions.isEmpty && actionItems.isEmpty }
}

/// Runs FluidAudio's offline segmentation + embedding + clustering pipeline.
/// Speaker IDs are anonymous model clusters and must not be presented as known people.
public actor FluidOfflineMeetingDiarizer {
    private let manager: OfflineDiarizerManager
    private var isPrepared = false

    public init() {
        manager = OfflineDiarizerManager()
    }

    /// Downloads/compiles diarization models when absent. Call from an explicit
    /// user-facing preparation flow rather than surprising the user at meeting stop.
    public func prepareModels() async throws {
        guard !isPrepared else { return }
        try await manager.prepareModels()
        isPrepared = true
    }

    /// Uses FluidAudio's disk-backed file path so long meetings are not loaded
    /// into a second full-size in-memory sample array.
    public func diarize(fileURL: URL) async throws -> [SpeakerInterval] {
        try await prepareModels()
        let result = try await manager.process(fileURL)
        return result.segments
            .map {
                SpeakerInterval(
                    speakerID: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds),
                    confidence: $0.qualityScore
                )
            }
            .filter { $0.end > $0.start }
            .sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
            }
    }
}

public struct MeetingTranscriptAssembler: Sendable {
    public init() {}

    /// Combines independently timed microphone and system transcripts. Offsets
    /// are relative to the meeting's common clock and must come from capture-time
    /// monotonic timestamps; callers must not assume both recorders began at zero.
    public func assemble(
        microphone: LocalTranscript,
        system: LocalTranscript?,
        systemSpeakerIntervals: [SpeakerInterval] = [],
        microphoneOffset: TimeInterval = 0,
        systemOffset: TimeInterval = 0
    ) -> [TranscriptSegment] {
        var result = microphone.segments.map { segment in
            TranscriptSegment(
                id: segment.id,
                start: segment.start + microphoneOffset,
                end: segment.end + microphoneOffset,
                speaker: "You",
                text: segment.text,
                channel: .microphone,
                attribution: .channel,
                confidence: segment.confidence,
                timingSource: segment.timingSource
            )
        }

        if let system {
            let labels = anonymousSpeakerLabels(systemSpeakerIntervals)
            result.append(contentsOf: system.segments.map { segment in
                let shiftedStart = segment.start + systemOffset
                let shiftedEnd = segment.end + systemOffset
                let match = bestSpeaker(
                    forStart: shiftedStart,
                    end: shiftedEnd,
                    intervals: systemSpeakerIntervals,
                    offset: systemOffset
                )
                return TranscriptSegment(
                    id: segment.id,
                    start: shiftedStart,
                    end: shiftedEnd,
                    speaker: match.flatMap { labels[$0.speakerID] } ?? "Other participant",
                    text: segment.text,
                    channel: .system,
                    attribution: match == nil ? .channel : .diarized,
                    confidence: combinedConfidence(segment.confidence, match?.confidence),
                    timingSource: segment.timingSource
                )
            })
        }

        return result
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
            }
    }

    private func anonymousSpeakerLabels(_ intervals: [SpeakerInterval]) -> [String: String] {
        let ordered = Dictionary(grouping: intervals, by: \.speakerID)
            .map { (id: $0.key, first: $0.value.map(\.start).min() ?? .infinity) }
            .sorted { lhs, rhs in lhs.first == rhs.first ? lhs.id < rhs.id : lhs.first < rhs.first }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, value in
            (value.id, "Participant \(index + 1)")
        })
    }

    private func bestSpeaker(
        forStart start: TimeInterval,
        end: TimeInterval,
        intervals: [SpeakerInterval],
        offset: TimeInterval
    ) -> SpeakerInterval? {
        intervals
            .map { interval -> (SpeakerInterval, TimeInterval) in
                let shifted = SpeakerInterval(
                    speakerID: interval.speakerID,
                    start: interval.start + offset,
                    end: interval.end + offset,
                    confidence: interval.confidence
                )
                return (shifted, max(0, min(end, shifted.end) - max(start, shifted.start)))
            }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    private func combinedConfidence(_ transcript: Float?, _ speaker: Float?) -> Float? {
        switch (transcript, speaker) {
        case let (left?, right?): min(left, right)
        case let (value?, nil), let (nil, value?): value
        case (nil, nil): nil
        }
    }
}

/// Deterministic local extraction with source evidence. It intentionally avoids
/// claiming semantic conclusions that are not explicitly stated in the transcript.
public struct MeetingIntelligencePipeline: Sendable {
    public init() {}

    public func generate(from segments: [TranscriptSegment], generatedAt: Date = .now) -> MeetingIntelligence {
        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }

        let decisions = uniqueInsights(ordered.compactMap(decision))
        let actions = uniqueInsights(ordered.compactMap(actionItem))
        let summary = extractSummary(from: ordered, decisions: decisions, actions: actions)
        return MeetingIntelligence(
            summary: summary,
            decisions: decisions,
            actionItems: actions,
            generatedAt: generatedAt
        )
    }

    private func decision(_ segment: TranscriptSegment) -> MeetingInsight? {
        let text = normalized(segment.text)
        let lower = text.lowercased()
        let markers = ["we decided", "we agreed", "the decision is", "decision:", "agreed to", "we committed to"]
        guard markers.contains(where: lower.contains) else { return nil }
        return MeetingInsight(
            kind: .decision,
            text: text,
            sourceSegmentID: segment.id,
            sourceTime: segment.start
        )
    }

    private func actionItem(_ segment: TranscriptSegment) -> MeetingInsight? {
        let text = normalized(segment.text)
        let lower = text.lowercased()
        let markers = ["action item", "todo", "to-do", "follow up", "i will", "i'll", "you will", "you'll", "needs to", "need to"]
        guard markers.contains(where: lower.contains) else { return nil }
        return MeetingInsight(
            kind: .actionItem,
            text: text,
            assignee: assignee(in: text, fallbackSpeaker: segment.speaker),
            dueText: dueText(in: text),
            sourceSegmentID: segment.id,
            sourceTime: segment.start
        )
    }

    private func extractSummary(
        from segments: [TranscriptSegment],
        decisions: [MeetingInsight],
        actions: [MeetingInsight]
    ) -> [String] {
        var candidates = decisions.map(\.text) + actions.map(\.text)
        candidates.append(contentsOf: segments
            .map { normalized($0.text) }
            .filter { $0.split(whereSeparator: \.isWhitespace).count >= 5 })
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }.prefix(4).map { $0 }
    }

    private func uniqueInsights(_ values: [MeetingInsight]) -> [MeetingInsight] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.text.lowercased()).inserted }
    }

    private func assignee(in text: String, fallbackSpeaker: String?) -> String? {
        let lower = text.lowercased()
        if lower.contains("i will") || lower.contains("i'll") { return fallbackSpeaker }
        guard let expression = try? NSRegularExpression(
            pattern: #"\b([\p{Lu}][\p{L}'-]{1,40})\s+(?i:will|needs to|should|owns)\b"#
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[nameRange])
    }

    private func dueText(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\b(?:by|before|due)\s+((?:today|tomorrow|next\s+\w+|(?:mon|tues|wednes|thurs|fri|satur|sun)day|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?)(?:\s+(?:morning|afternoon|evening|at\s+\d{1,2}(?::\d{2})?))?)"#
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let dueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[dueRange])
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
