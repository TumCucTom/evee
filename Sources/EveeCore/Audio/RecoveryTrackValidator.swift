import AVFoundation
import Foundation

public struct RecoveryTrackValidator: Sendable {
    public init() {}

    public func assess(
        _ track: WorkspaceAudioTrack,
        sourceURL: URL,
        resolvedURL: URL
    ) -> RecoveryTrackAssessment {
        do {
            let sourceValues = try sourceURL.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .fileSizeKey,
            ])
            guard sourceValues.isSymbolicLink != true else {
                throw ValidationError.symbolicLink
            }
            guard sourceValues.isDirectory != true, sourceValues.isRegularFile == true else {
                throw ValidationError.notAFile
            }
            guard let byteCount = sourceValues.fileSize, byteCount > 0 else {
                throw ValidationError.empty
            }

            let file = try AVAudioFile(forReading: resolvedURL)
            let sampleRate = file.processingFormat.sampleRate
            let duration = Double(file.length) / sampleRate
            guard file.length > 0,
                  sampleRate.isFinite,
                  sampleRate > 0,
                  duration.isFinite,
                  duration > 0 else {
                throw ValidationError.noDecodableAudio
            }
            return RecoveryTrackAssessment(track: track, isValid: true)
        } catch {
            return RecoveryTrackAssessment(
                track: track,
                isValid: false,
                failureReason: (error as? LocalizedError)?.errorDescription ?? "The audio container could not be decoded."
            )
        }
    }
}

private enum ValidationError: LocalizedError {
    case symbolicLink
    case notAFile
    case empty
    case noDecodableAudio

    var errorDescription: String? {
        switch self {
        case .symbolicLink:
            "Linked audio files cannot be recovered."
        case .notAFile:
            "The recovery track is not a regular audio file."
        case .empty:
            "The recovery track is empty."
        case .noDecodableAudio:
            "The recovery track has no playable audio."
        }
    }
}
