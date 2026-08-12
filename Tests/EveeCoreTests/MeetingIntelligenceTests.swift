import XCTest
@testable import EveeCore

final class MeetingIntelligenceTests: XCTestCase {
    func testTokenTimingsCreateRealUtteranceBoundaries() throws {
        let timings = [
            TranscriptTokenTiming(token: "▁Hello", start: 0.10, end: 0.40, confidence: 0.9),
            TranscriptTokenTiming(token: ".", start: 0.40, end: 0.48, confidence: 0.8),
            TranscriptTokenTiming(token: "▁Next", start: 1.30, end: 1.60, confidence: 0.7),
            TranscriptTokenTiming(token: "▁topic", start: 1.61, end: 2.00, confidence: 0.9),
        ]

        let segments = TokenTimingSegmenter().segments(
            transcriptText: "Hello. Next topic",
            duration: 2,
            timings: timings
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello.")
        XCTAssertEqual(segments[0].start, 0.10, accuracy: 0.001)
        XCTAssertEqual(segments[0].end, 0.48, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments[0].confidence), 0.85, accuracy: 0.001)
        XCTAssertEqual(segments[0].timingSource, .token)
        XCTAssertEqual(segments[1].text, "Next topic")
        XCTAssertEqual(segments[1].start, 1.30, accuracy: 0.001)
        XCTAssertEqual(segments[1].end, 2.00, accuracy: 0.001)
    }

    func testMissingTokenTimingsAreMarkedAsTrackEstimate() {
        let segments = TokenTimingSegmenter().segments(
            transcriptText: "Fallback transcript",
            duration: 4.5,
            timings: []
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 4.5)
        XCTAssertEqual(segments[0].timingSource, .trackEstimate)
    }

    func testNormalizedTokenLeadingSpacesRemainWordBoundaries() {
        let timings = [
            TranscriptTokenTiming(token: "Hello", start: 0, end: 0.3),
            TranscriptTokenTiming(token: " world", start: 0.31, end: 0.7),
            TranscriptTokenTiming(token: ".", start: 0.7, end: 0.75),
        ]

        let segments = TokenTimingSegmenter().segments(transcriptText: "Hello world.", duration: 0.75, timings: timings)

        XCTAssertEqual(segments.first?.text, "Hello world.")
    }

    func testAssemblerAlignsTracksAndUsesAnonymousSpeakerClusters() {
        let microphone = LocalTranscript(
            text: "Welcome",
            duration: 1,
            segments: [LocalTranscriptSegment(
                start: 0,
                end: 1,
                text: "Welcome",
                timingSource: .token
            )]
        )
        let system = LocalTranscript(
            text: "First point Second point",
            duration: 4,
            segments: [
                LocalTranscriptSegment(start: 0, end: 1.8, text: "First point", timingSource: .token),
                LocalTranscriptSegment(start: 2, end: 4, text: "Second point", timingSource: .token),
            ]
        )
        let intervals = [
            SpeakerInterval(speakerID: "cluster-b", start: 2, end: 4, confidence: 0.8),
            SpeakerInterval(speakerID: "cluster-a", start: 0, end: 1.8, confidence: 0.9),
        ]

        let result = MeetingTranscriptAssembler().assemble(
            microphone: microphone,
            system: system,
            systemSpeakerIntervals: intervals,
            microphoneOffset: 0.25,
            systemOffset: 5
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speaker, "You")
        XCTAssertEqual(result[0].start, 0.25, accuracy: 0.001)
        XCTAssertEqual(result[0].channel, .microphone)
        XCTAssertEqual(result[0].attribution, .channel)
        XCTAssertEqual(result[1].speaker, "Participant 1")
        XCTAssertEqual(result[1].start, 5, accuracy: 0.001)
        XCTAssertEqual(result[1].attribution, .diarized)
        XCTAssertEqual(result[2].speaker, "Participant 2")
        XCTAssertEqual(result[2].start, 7, accuracy: 0.001)
        XCTAssertEqual(result[2].channel, .system)
    }

    func testAssemblerDoesNotClaimRemoteIdentityWithoutDiarization() {
        let microphone = LocalTranscript(text: "", duration: 0, segments: [])
        let system = LocalTranscript(
            text: "Hello",
            duration: 1,
            segments: [LocalTranscriptSegment(start: 0, end: 1, text: "Hello", timingSource: .audioChunk)]
        )

        let result = MeetingTranscriptAssembler().assemble(microphone: microphone, system: system)

        XCTAssertEqual(result.first?.speaker, "Other participant")
        XCTAssertEqual(result.first?.attribution, .channel)
        XCTAssertEqual(result.first?.channel, .system)
    }

    func testAssemblerDoesNotForceSingleSpeakerForMixedUtterance() {
        let system = LocalTranscript(
            text: "A mixed exchange",
            duration: 4,
            segments: [LocalTranscriptSegment(start: 0, end: 4, text: "A mixed exchange", timingSource: .audioChunk)]
        )
        let intervals = [
            SpeakerInterval(speakerID: "first", start: 0, end: 2, confidence: 0.95),
            SpeakerInterval(speakerID: "second", start: 2, end: 4, confidence: 0.95),
        ]

        let result = MeetingTranscriptAssembler().assemble(
            microphone: LocalTranscript(text: "", duration: 0, segments: []),
            system: system,
            systemSpeakerIntervals: intervals
        )

        XCTAssertEqual(result.first?.speaker, "Other participant")
        XCTAssertEqual(result.first?.attribution, .channel)
        XCTAssertNil(result.first?.confidence)
    }

    func testAssemblerAggregatesFragmentedEvidenceForOneSpeaker() throws {
        let system = LocalTranscript(
            text: "One participant across pauses",
            duration: 4,
            segments: [LocalTranscriptSegment(start: 0, end: 4, text: "One participant across pauses", confidence: 0.9, timingSource: .token)]
        )
        let intervals = [
            SpeakerInterval(speakerID: "stable", start: 0, end: 1.4, confidence: 0.8),
            SpeakerInterval(speakerID: "stable", start: 1.6, end: 4, confidence: 0.6),
        ]

        let result = MeetingTranscriptAssembler().assemble(
            microphone: LocalTranscript(text: "", duration: 0, segments: []),
            system: system,
            systemSpeakerIntervals: intervals
        )

        XCTAssertEqual(result.first?.speaker, "Participant 1")
        XCTAssertEqual(result.first?.attribution, .diarized)
        XCTAssertEqual(try XCTUnwrap(result.first?.confidence), 0.674, accuracy: 0.001)
    }

    func testAssemblerNormalizesInvalidTrackOffsets() {
        let microphone = LocalTranscript(
            text: "Hello",
            duration: 1,
            segments: [LocalTranscriptSegment(start: 0, end: 1, text: "Hello", timingSource: .token)]
        )

        let result = MeetingTranscriptAssembler().assemble(
            microphone: microphone,
            system: nil,
            microphoneOffset: .infinity
        )

        XCTAssertEqual(result.first?.start, 0)
        XCTAssertEqual(result.first?.end, 1)
    }

    func testExtractiveIntelligenceKeepsSourceEvidence() throws {
        let decisionID = UUID()
        let actionID = UUID()
        let segments = [
            TranscriptSegment(
                id: decisionID,
                start: 12,
                end: 14,
                speaker: "Participant 1",
                text: "We decided to ship the smaller scope."
            ),
            TranscriptSegment(
                id: actionID,
                start: 20,
                end: 24,
                speaker: "Participant 2",
                text: "Alice will follow up by next Tuesday."
            ),
        ]

        let result = MeetingIntelligencePipeline().generate(from: segments)

        XCTAssertEqual(result.decisions.count, 1)
        XCTAssertEqual(result.decisions[0].sourceSegmentID, decisionID)
        XCTAssertEqual(result.decisions[0].sourceTime, 12)
        XCTAssertEqual(result.actionItems.count, 1)
        XCTAssertEqual(result.actionItems[0].sourceSegmentID, actionID)
        XCTAssertEqual(result.actionItems[0].assignee, "Alice")
        XCTAssertEqual(result.actionItems[0].dueText, "next Tuesday")
        XCTAssertTrue(result.summary.contains("We decided to ship the smaller scope."))
    }

    func testExtractiveIntelligenceDoesNotInventCommitments() {
        let segment = TranscriptSegment(
            start: 1,
            end: 4,
            speaker: "Participant 1",
            text: "We discussed the launch options and outstanding questions."
        )

        let result = MeetingIntelligencePipeline().generate(from: [segment])

        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.actionItems.isEmpty)
        XCTAssertEqual(result.summary, [segment.text])
    }

    func testExtractiveIntelligenceRejectsQuestionsAndNegatedActions() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, speaker: "You", text: "We agreed to launch on Friday?"),
            TranscriptSegment(start: 1, end: 2, speaker: "You", text: "I will not send the draft."),
            TranscriptSegment(start: 2, end: 3, speaker: "You", text: "Do we need to follow up?"),
        ]

        let result = MeetingIntelligencePipeline().generate(from: segments)

        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.actionItems.isEmpty)
    }

    func testLegacyTranscriptSegmentDecodesWithSafeDefaults() throws {
        let id = UUID()
        let json = Data(#"{"id":"\#(id.uuidString)","start":1.5,"end":3,"speaker":"You","text":"Legacy"}"#.utf8)

        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: json)

        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.channel)
        XCTAssertEqual(decoded.attribution, .unknown)
        XCTAssertNil(decoded.confidence)
        XCTAssertEqual(decoded.timingSource, .trackEstimate)
    }

    func testMeetingIntelligencePersistsWithWorkspaceRecord() throws {
        let intelligence = MeetingIntelligence(
            summary: ["Explicit summary"],
            decisions: [MeetingInsight(kind: .decision, text: "We decided to proceed.", sourceTime: 7)],
            actionItems: [MeetingInsight(kind: .actionItem, text: "Sam will prepare it.", assignee: "Sam")]
        )
        let record = WorkspaceRecord(
            kind: .meeting,
            title: "Planning",
            text: "Transcript",
            meetingIntelligence: intelligence
        )

        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: JSONEncoder().encode(record))

        XCTAssertEqual(decoded.meetingIntelligence, intelligence)
    }
}
