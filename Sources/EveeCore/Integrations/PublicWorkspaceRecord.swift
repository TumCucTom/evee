import Foundation

public struct PublicWorkspaceRecord: Codable, Sendable {
    public let id: UUID
    public let kind: WorkspaceRecordKind
    public let createdAt: Date
    public let updatedAt: Date
    public let title: String
    public let text: String
    public let sourceApplication: String?
    public let duration: TimeInterval?
    public let segments: [TranscriptSegment]
    public let meetingIntelligence: MeetingIntelligence?
    public let memoIntelligence: MemoIntelligence?
    public let notes: String
    public let tags: [String]

    public init(_ record: WorkspaceRecord) {
        id = record.id
        kind = record.kind
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        title = record.title
        text = record.text
        sourceApplication = record.sourceApplication
        duration = record.duration
        segments = record.segments
        meetingIntelligence = record.meetingIntelligence
        memoIntelligence = record.memoIntelligence
        notes = record.notes
        tags = record.tags
    }
}
