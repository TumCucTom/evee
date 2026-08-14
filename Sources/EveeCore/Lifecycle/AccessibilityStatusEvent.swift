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

private enum AccessibilityStatusEventKey: Equatable, Sendable {
    case wakeListeningStarted
    case wakeListeningStopped
    case wakeListeningFailed
    case captureStarted
    case captureStopped
    case captureCancelled
    case captureRecovered
    case captureFailed
    case microphoneSilence
    case microphoneSignalRestored
    case channelFailed(AudioTrackRole)
    case modelDownloadStarted
    case modelDownloadProgress
    case modelDownloadCancelled
    case modelDownloadFailed
    case modelReady
    case webhookRevoked
    case helperRevoked
    case audioExported
    case audioExportFailed
}

private extension AccessibilityStatusEvent {
    var deduplicationKey: AccessibilityStatusEventKey {
        switch self {
        case .wakeListeningStarted: .wakeListeningStarted
        case .wakeListeningStopped: .wakeListeningStopped
        case .wakeListeningFailed: .wakeListeningFailed
        case .captureStarted: .captureStarted
        case .captureStopped: .captureStopped
        case .captureCancelled: .captureCancelled
        case .captureRecovered: .captureRecovered
        case .captureFailed: .captureFailed
        case .microphoneSilence: .microphoneSilence
        case .microphoneSignalRestored: .microphoneSignalRestored
        case .channelFailed(let role, _): .channelFailed(role)
        case .modelDownloadStarted: .modelDownloadStarted
        case .modelDownloadProgress: .modelDownloadProgress
        case .modelDownloadCancelled: .modelDownloadCancelled
        case .modelDownloadFailed: .modelDownloadFailed
        case .modelReady: .modelReady
        case .webhookRevoked: .webhookRevoked
        case .helperRevoked: .helperRevoked
        case .audioExported: .audioExported
        case .audioExportFailed: .audioExportFailed
        }
    }
}

public struct AccessibilityAnnouncementReducer: Sendable {
    private var lastEventKey: AccessibilityStatusEventKey?
    private var lastProgressBucket = 0
    private var microphoneSilenceActive = false

    public init() {}

    public mutating func receive(_ event: AccessibilityStatusEvent) -> String? {
        if event == .microphoneSignalRestored {
            microphoneSilenceActive = false
            if lastEventKey == .microphoneSilence { lastEventKey = nil }
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

        let eventKey = event.deduplicationKey
        guard eventKey != lastEventKey else { return nil }
        lastEventKey = eventKey

        switch event {
        case .wakeListeningStarted:
            return "Wake phrase listening started."
        case .wakeListeningStopped:
            return "Wake phrase listening stopped."
        case .wakeListeningFailed:
            return "Wake phrase listening needs attention. Open Evee for details."
        case .captureStarted:
            return "Recording started."
        case .captureStopped:
            return "Recording stopped. Transcribing locally."
        case .captureCancelled:
            return "Recording discarded."
        case .captureRecovered:
            return "Interrupted capture recovered."
        case .captureFailed:
            return "Capture needs attention. Open Evee for recovery options."
        case .microphoneSilence:
            return "No microphone signal has been detected. Check the selected input and mute switch."
        case .microphoneSignalRestored:
            return nil
        case .channelFailed(let role, _):
            return "\(role.rawValue.capitalized) audio needs attention. Open Evee for details."
        case .modelDownloadStarted:
            lastProgressBucket = 0
            return "Local model download started."
        case .modelDownloadCancelled:
            lastProgressBucket = 0
            return "Local model download cancelled."
        case .modelDownloadFailed:
            lastProgressBucket = 0
            return "Local model download needs attention. Open Evee for details."
        case .modelReady:
            lastProgressBucket = 0
            return "Local model is ready."
        case .webhookRevoked:
            return "Meeting webhook access revoked."
        case .helperRevoked:
            return "Local helper access revoked."
        case .audioExported:
            return "Audio exported."
        case .audioExportFailed:
            return "Audio export needs attention. Open Evee for details."
        case .modelDownloadProgress:
            return nil
        }
    }
}
