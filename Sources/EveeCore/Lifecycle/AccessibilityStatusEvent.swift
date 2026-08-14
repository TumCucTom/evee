import Foundation

public enum AccessibilityStatusEvent: Equatable, Sendable {
    case wakeListeningStarted
    case wakeListeningStopped
    case wakeListeningFailed(String)
    case captureStarted
    case captureStopped
    case captureCancelled
    case captureRecovered
    case captureFailed(String)
    case microphoneSilence
    case microphoneSignalRestored
    case channelFailed(AudioTrackRole, String)
    case modelDownloadStarted
    case modelDownloadProgress(Double)
    case modelDownloadCancelled
    case modelDownloadFailed(String)
    case modelReady
    case webhookRevoked
    case helperRevoked
    case audioExported(String)
    case audioExportFailed(String)
}

public struct AccessibilityAnnouncementReducer: Sendable {
    private var lastEvent: AccessibilityStatusEvent?
    private var lastProgressBucket = 0
    private var microphoneSilenceActive = false

    public init() {}

    public mutating func receive(_ event: AccessibilityStatusEvent) -> String? {
        if event == .microphoneSignalRestored {
            microphoneSilenceActive = false
            if lastEvent == .microphoneSilence { lastEvent = nil }
            return nil
        }

        if event == .microphoneSilence {
            guard !microphoneSilenceActive else { return nil }
            microphoneSilenceActive = true
        }

        if case .modelDownloadProgress(let fraction) = event {
            guard fraction.isFinite else { return nil }
            let boundedFraction = min(1, max(0, fraction))
            let bucket = min(10, Int((boundedFraction * 10 + 1e-9).rounded(.down)))
            guard bucket > lastProgressBucket else { return nil }
            lastProgressBucket = bucket
            return "Local model download \(bucket * 10) percent."
        }

        guard event != lastEvent else { return nil }
        lastEvent = event

        switch event {
        case .wakeListeningStarted:
            return "Wake phrase listening started."
        case .wakeListeningStopped:
            return "Wake phrase listening stopped."
        case .wakeListeningFailed(let message):
            return "Wake phrase listening failed. \(message)"
        case .captureStarted:
            return "Recording started."
        case .captureStopped:
            return "Recording stopped. Transcribing locally."
        case .captureCancelled:
            return "Recording discarded."
        case .captureRecovered:
            return "Interrupted capture recovered."
        case .captureFailed(let message):
            return "Capture failed. \(message)"
        case .microphoneSilence:
            return "No microphone signal has been detected. Check the selected input and mute switch."
        case .microphoneSignalRestored:
            return nil
        case .channelFailed(let role, let message):
            return "\(role.rawValue.capitalized) audio warning. \(message)"
        case .modelDownloadStarted:
            lastProgressBucket = 0
            return "Local model download started."
        case .modelDownloadCancelled:
            lastProgressBucket = 0
            return "Local model download cancelled."
        case .modelDownloadFailed(let message):
            lastProgressBucket = 0
            return "Local model download failed. \(message)"
        case .modelReady:
            lastProgressBucket = 0
            return "Local model is ready."
        case .webhookRevoked:
            return "Meeting webhook access revoked."
        case .helperRevoked:
            return "Local helper access revoked."
        case .audioExported(let track):
            return "Exported \(track) audio."
        case .audioExportFailed(let message):
            return "Audio export failed. \(message)"
        case .modelDownloadProgress:
            return nil
        }
    }
}
