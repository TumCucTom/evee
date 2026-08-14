import Foundation

public enum LocalModelPreparationMode: Sendable {
    case validateExisting
    case downloadOrRepair
}

/// Makes model readiness mean that the provider can actually load the selected
/// model. Repair deliberately reuses the provider downloader without removing
/// any cache paths first.
public enum LocalModelReadiness {
    public static func prepare(
        _ provider: any LocalModelDownloading,
        mode: LocalModelPreparationMode,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws {
        switch mode {
        case .validateExisting:
            guard provider.isDownloaded else { throw TranscriptionError.modelNotDownloaded }
        case .downloadOrRepair:
            try await provider.download(progress: progress)
        }
        try Task.checkCancellation()
        try await provider.load()
        try Task.checkCancellation()
    }
}
