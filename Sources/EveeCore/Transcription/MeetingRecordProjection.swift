import Foundation

public enum MeetingRecordProjectionError: Error, Equatable {
    case segmentNotFound(UUID)
}

public struct MeetingSpeakerLabelDraft: Sendable, Equatable {
    public let segmentID: UUID
    public var text: String

    public init(segmentID: UUID, text: String) {
        self.segmentID = segmentID
        self.text = text
    }

    public func applying(to record: WorkspaceRecord) throws -> WorkspaceRecord {
        try MeetingRecordProjection().relabel(record: record, segmentID: segmentID, label: text)
    }
}

public struct MeetingRecordProjection: Sendable {
    public init() {}

    public func relabel(
        record: WorkspaceRecord,
        segmentID: UUID,
        label: String?
    ) throws -> WorkspaceRecord {
        var changed = record
        assignLegacyClusterIDs(recordID: record.id, segments: &changed.segments)
        guard let target = changed.segments.first(where: { $0.id == segmentID }) else {
            throw MeetingRecordProjectionError.segmentNotFound(segmentID)
        }

        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = normalized?.isEmpty == false ? normalized : nil
        for index in changed.segments.indices {
            let belongsToCluster = target.attribution == .diarized
                && changed.segments[index].attribution == .diarized
                && target.diarizationClusterID != nil
                && changed.segments[index].diarizationClusterID == target.diarizationClusterID
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

    private func assignLegacyClusterIDs(recordID: UUID, segments: inout [TranscriptSegment]) {
        for index in segments.indices {
            guard segments[index].attribution == .diarized else {
                segments[index].diarizationClusterID = nil
                continue
            }
            if let clusterID = segments[index].diarizationClusterID,
               !clusterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let recordKey = recordID.uuidString.lowercased()
            if let speaker = segments[index].speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
               !speaker.isEmpty {
                let labelKey = Data(speaker.utf8).base64EncodedString()
                segments[index].diarizationClusterID = "legacy-label:\(recordKey):\(labelKey)"
            } else {
                segments[index].diarizationClusterID = "legacy-segment:\(recordKey):\(segments[index].id.uuidString.lowercased())"
            }
        }
    }
}
