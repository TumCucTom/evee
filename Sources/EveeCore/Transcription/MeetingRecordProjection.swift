import Foundation

public enum MeetingRecordProjectionError: Error, Equatable {
    case segmentNotFound(UUID)
}

public struct MeetingRecordProjection: Sendable {
    public init() {}

    public func relabel(
        record: WorkspaceRecord,
        segmentID: UUID,
        label: String?
    ) throws -> WorkspaceRecord {
        guard let target = record.segments.first(where: { $0.id == segmentID }) else {
            throw MeetingRecordProjectionError.segmentNotFound(segmentID)
        }

        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = normalized?.isEmpty == false ? normalized : nil
        var changed = record
        for index in changed.segments.indices {
            let belongsToCluster = target.attribution == .diarized
                && changed.segments[index].attribution == .diarized
                && changed.segments[index].speaker == target.speaker
            if changed.segments[index].id == segmentID || belongsToCluster {
                changed.segments[index].speaker = finalLabel
            }
        }

        changed.segments.sort { $0.start < $1.start }
        let transcript = changed.segments.map { segment in
            if let speaker = segment.speaker { return "\(speaker): \(segment.text)" }
            return segment.text
        }.joined(separator: "\n")
        let now = max(Date.now, record.updatedAt.addingTimeInterval(0.001))
        changed.rawText = transcript
        changed.text = transcript
        changed.updatedAt = now
        changed.meetingIntelligence = MeetingIntelligencePipeline()
            .generate(from: changed.segments, generatedAt: now)
        return changed
    }
}
