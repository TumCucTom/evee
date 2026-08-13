import XCTest
@testable import EveeCore

final class MeetingRecordProjectionTests: XCTestCase {
    func testRelabelUpdatesDiarizedClusterAndCanonicalProjections() throws {
        let firstID = UUID()
        let secondID = UUID()
        let unrelatedID = UUID()
        let original = WorkspaceRecord(
            kind: .meeting,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            title: "Planning",
            text: "stale transcript",
            rawText: "stale raw transcript",
            segments: [
                TranscriptSegment(
                    id: secondID,
                    start: 20,
                    end: 25,
                    speaker: "Participant 1",
                    text: "I will send the release notes.",
                    channel: .system,
                    attribution: .diarized
                ),
                TranscriptSegment(
                    id: unrelatedID,
                    start: 10,
                    end: 15,
                    speaker: "Participant 2",
                    text: "We decided to ship on Friday.",
                    channel: .system,
                    attribution: .diarized
                ),
                TranscriptSegment(
                    id: firstID,
                    start: 0,
                    end: 5,
                    speaker: "Participant 1",
                    text: "First statement",
                    channel: .system,
                    attribution: .diarized
                ),
            ]
        )

        let changed = try MeetingRecordProjection().relabel(
            record: original,
            segmentID: firstID,
            label: "  Facilitator  "
        )

        XCTAssertEqual(changed.segments.map(\.id), [firstID, unrelatedID, secondID])
        XCTAssertEqual(changed.segments.map(\.speaker), ["Facilitator", "Participant 2", "Facilitator"])
        XCTAssertEqual(
            changed.text,
            "Facilitator: First statement\nParticipant 2: We decided to ship on Friday.\nFacilitator: I will send the release notes."
        )
        XCTAssertEqual(changed.rawText, changed.text)
        XCTAssertEqual(
            changed.meetingIntelligence,
            MeetingIntelligencePipeline().generate(from: changed.segments, generatedAt: changed.updatedAt)
        )
        XCTAssertGreaterThan(changed.updatedAt, original.updatedAt)
        XCTAssertEqual(original.text, "stale transcript")
        XCTAssertEqual(original.segments.first(where: { $0.id == firstID })?.speaker, "Participant 1")
    }

    func testRelabelNormalizesWhitespaceOnlyLabelToNil() throws {
        let segmentID = UUID()
        let record = WorkspaceRecord(
            kind: .meeting,
            title: "Planning",
            text: "Participant 1: First statement",
            segments: [TranscriptSegment(
                id: segmentID,
                start: 0,
                end: 5,
                speaker: "Participant 1",
                text: "First statement",
                attribution: .diarized
            )]
        )

        let changed = try MeetingRecordProjection().relabel(
            record: record,
            segmentID: segmentID,
            label: " \n\t "
        )

        XCTAssertNil(changed.segments.first?.speaker)
        XCTAssertEqual(changed.text, "First statement")
        XCTAssertEqual(changed.rawText, "First statement")
    }

    func testRelabelRejectsMissingSegmentWithoutMutatingOriginal() {
        let existingID = UUID()
        let missingID = UUID()
        let original = WorkspaceRecord(
            kind: .meeting,
            title: "Planning",
            text: "Participant 1: First statement",
            segments: [TranscriptSegment(
                id: existingID,
                start: 0,
                end: 5,
                speaker: "Participant 1",
                text: "First statement",
                attribution: .diarized
            )]
        )

        XCTAssertThrowsError(
            try MeetingRecordProjection().relabel(record: original, segmentID: missingID, label: "Facilitator")
        ) { error in
            XCTAssertEqual(error as? MeetingRecordProjectionError, .segmentNotFound(missingID))
        }
        XCTAssertEqual(original.text, "Participant 1: First statement")
        XCTAssertEqual(original.segments.first?.speaker, "Participant 1")
    }

    func testRelabelChangesOnlySelectedChannelAttributedSegment() throws {
        let selectedID = UUID()
        let otherID = UUID()
        let record = WorkspaceRecord(
            kind: .meeting,
            title: "Planning",
            text: "Other participant: First\nOther participant: Second",
            segments: [
                TranscriptSegment(
                    id: selectedID,
                    start: 0,
                    end: 2,
                    speaker: "Other participant",
                    text: "First",
                    channel: .system,
                    attribution: .channel
                ),
                TranscriptSegment(
                    id: otherID,
                    start: 3,
                    end: 5,
                    speaker: "Other participant",
                    text: "Second",
                    channel: .system,
                    attribution: .channel
                ),
            ]
        )

        let changed = try MeetingRecordProjection().relabel(
            record: record,
            segmentID: selectedID,
            label: "Guest"
        )

        XCTAssertEqual(changed.segments.first(where: { $0.id == selectedID })?.speaker, "Guest")
        XCTAssertEqual(changed.segments.first(where: { $0.id == otherID })?.speaker, "Other participant")
    }
}
