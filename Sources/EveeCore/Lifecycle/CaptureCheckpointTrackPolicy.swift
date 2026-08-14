import Foundation

public enum CaptureCheckpointTrackPolicyError: LocalizedError, Equatable, Sendable {
    case noPlayableMeetingTrack
    case missingMicrophone(WorkspaceRecordKind)

    public var errorDescription: String? {
        switch self {
        case .noPlayableMeetingTrack:
            "The meeting checkpoint has no playable microphone or system-audio track."
        case .missingMicrophone(let kind):
            "The \(kind.rawValue) checkpoint requires a playable microphone track."
        }
    }
}

public enum CaptureCheckpointTrackPolicy {
    public static func validate(
        kind: WorkspaceRecordKind,
        validRoles: Set<AudioTrackRole>
    ) throws {
        switch kind {
        case .meeting:
            guard !validRoles.isDisjoint(with: [.microphone, .system]) else {
                throw CaptureCheckpointTrackPolicyError.noPlayableMeetingTrack
            }
        case .memo, .dictation:
            guard validRoles.contains(.microphone) else {
                throw CaptureCheckpointTrackPolicyError.missingMicrophone(kind)
            }
        }
    }
}
