@preconcurrency import AVFoundation
import Combine
import Foundation

public enum RetainedAudioValidationError: LocalizedError, Sendable {
    case invalidLocation
    case symbolicLink
    case notRegularFile
    case emptyFile
    case fileTooLarge
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .invalidLocation: "The retained audio location is invalid."
        case .symbolicLink: "The retained audio link was rejected for safety."
        case .notRegularFile: "The retained audio is not a regular file."
        case .emptyFile: "The retained audio file is empty."
        case .fileTooLarge: "The retained audio file is too large to open safely."
        case .unreadable: "The retained audio file cannot be read."
        }
    }
}

/// Performs cheap filesystem checks before an untrusted library entry reaches
/// an audio decoder. The library store separately enforces root containment.
public enum RetainedAudioPolicy {
    public static let maximumFileSize: Int64 = 16 * 1_024 * 1_024 * 1_024

    public static func validate(_ url: URL) throws {
        guard url.isFileURL else { throw RetainedAudioValidationError.invalidLocation }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw RetainedAudioValidationError.symbolicLink }
        guard values.isRegularFile == true else { throw RetainedAudioValidationError.notRegularFile }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw RetainedAudioValidationError.unreadable }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else { throw RetainedAudioValidationError.emptyFile }
        guard size <= maximumFileSize else { throw RetainedAudioValidationError.fileTooLarge }
    }
}

/// A small, main-actor playback surface for audio that Evee has explicitly retained.
/// The controller never copies audio into memory and keeps its periodic UI work suspended
/// whenever playback is paused or stopped.
@MainActor
public final class RetainedAudioPlayer: ObservableObject {
    @Published public private(set) var loadedURL: URL?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    public init() {}

    deinit { progressTimer?.invalidate() }

    public func load(_ url: URL) throws {
        stop()
        do {
            try RetainedAudioPolicy.validate(url)
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else {
                throw AudioCaptureError.invalidFormat
            }
            self.player = player
            loadedURL = url
            duration = player.duration
            currentTime = 0
            errorMessage = nil
        } catch {
            loadedURL = nil
            duration = 0
            currentTime = 0
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopProgressTimer()
            updateProgress()
            return
        }

        if player.currentTime >= max(0, player.duration - 0.05) {
            player.currentTime = 0
        }
        guard player.play() else {
            errorMessage = "The retained audio could not begin playback."
            return
        }
        isPlaying = true
        errorMessage = nil
        startProgressTimer()
        updateProgress()
    }

    public func seek(to time: TimeInterval) {
        guard let player else { return }
        let bounded = min(max(0, time), player.duration)
        player.currentTime = bounded
        currentTime = bounded
    }

    public func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
        stopProgressTimer()
    }

    public func clearError() {
        errorMessage = nil
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying, isPlaying {
            isPlaying = false
            stopProgressTimer()
            if player.currentTime >= max(0, player.duration - 0.05) {
                currentTime = player.duration
            }
        }
    }
}
