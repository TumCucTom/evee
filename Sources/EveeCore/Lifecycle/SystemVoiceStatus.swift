import Foundation

public enum SystemVoicePhase: Equatable, Sendable {
    case ready
    case wakeStarting
    case wakeListening
    case wakeStopping
    case captureStarting
    case recording
    case processing
    case delivering
    case protected
    case failed
}

public enum SystemVoiceAction: Hashable, Sendable {
    case stopAndTranscribe
    case discard
}

public enum CaptureHealthReason: Equatable, Sendable {
    case silence
    case unavailable
    case failed(String)
}

public struct CaptureHealthWarning: Equatable, Sendable {
    public let channel: AudioTrackRole
    public let reason: CaptureHealthReason

    public init(channel: AudioTrackRole, reason: CaptureHealthReason) {
        self.channel = channel
        self.reason = reason
    }

    public var message: String {
        let channelName = channel == .system ? "System audio" : channel.rawValue.capitalized
        return switch reason {
        case .silence:
            "No microphone signal has been detected. Check the selected input and mute switch."
        case .unavailable:
            "\(channelName) is unavailable."
        case .failed(let detail):
            "\(channelName) failed. \(detail)"
        }
    }
}

public struct SystemVoiceStatus: Equatable, Sendable {
    public let phase: SystemVoicePhase
    public let isMicrophoneOpen: Bool
    public let menuTitle: String
    public let hudTitle: String
    public let hudDetail: String
    public let warnings: [CaptureHealthWarning]
    public let availableActions: Set<SystemVoiceAction>

    public var hudWarning: String? {
        warnings.first?.message
    }

    public static func make(
        capture: CaptureState,
        hotMic: HotMicState,
        warnings: [CaptureHealthWarning]
    ) -> SystemVoiceStatus {
        let warningSuffix = warnings.isEmpty ? "" : " · warning"
        let warningDetail = warnings.map(\.message).joined(separator: " ")

        switch capture {
        case .starting:
            let wakeMicrophoneIsClosing = hotMic == .active || hotMic == .stopping
            return Self(
                phase: .captureStarting,
                isMicrophoneOpen: wakeMicrophoneIsClosing,
                menuTitle: "Starting capture\(warningSuffix)",
                hudTitle: wakeMicrophoneIsClosing ? "Microphone open · Starting capture" : "Starting capture",
                hudDetail: detail("Preparing local audio. Use Discard in the Evee menu or your cancel shortcut.", warning: warningDetail),
                warnings: warnings,
                availableActions: [.discard]
            )
        case .recording:
            return Self(
                phase: .recording,
                isMicrophoneOpen: true,
                menuTitle: "Recording\(warningSuffix)",
                hudTitle: "Microphone open · Recording",
                hudDetail: detail("Use Stop and transcribe or Discard in the Evee menu and configured shortcuts.", warning: warningDetail),
                warnings: warnings,
                availableActions: [.stopAndTranscribe, .discard]
            )
        case .transcribing:
            return Self(
                phase: .processing,
                isMicrophoneOpen: false,
                menuTitle: "Transcribing locally\(warningSuffix)",
                hudTitle: "Transcribing locally",
                hudDetail: detail("The microphone is closed. You can keep working.", warning: warningDetail),
                warnings: warnings,
                availableActions: []
            )
        case .delivering:
            return Self(
                phase: .delivering,
                isMicrophoneOpen: false,
                menuTitle: "Delivering text\(warningSuffix)",
                hudTitle: "Delivering text",
                hudDetail: detail("The microphone is closed. Evee is finishing the requested delivery.", warning: warningDetail),
                warnings: warnings,
                availableActions: []
            )
        case .checkpointed(let message):
            return Self(
                phase: .protected,
                isMicrophoneOpen: false,
                menuTitle: "Capture protected",
                hudTitle: "Capture protected",
                hudDetail: message,
                warnings: warnings,
                availableActions: []
            )
        case .failed(let message):
            return Self(
                phase: .failed,
                isMicrophoneOpen: false,
                menuTitle: "Capture needs attention",
                hudTitle: "Capture needs attention",
                hudDetail: message,
                warnings: warnings,
                availableActions: []
            )
        case .idle:
            break
        }

        switch hotMic {
        case .disabled:
            return Self(
                phase: .ready,
                isMicrophoneOpen: false,
                menuTitle: warnings.isEmpty ? "Ready" : "Ready · warning",
                hudTitle: "Ready",
                hudDetail: warningDetail.isEmpty ? "Use a configured shortcut to begin." : warningDetail,
                warnings: warnings,
                availableActions: []
            )
        case .starting:
            return Self(
                phase: .wakeStarting,
                isMicrophoneOpen: false,
                menuTitle: "Starting wake phrase listening\(warningSuffix)",
                hudTitle: "Starting wake phrase listening",
                hudDetail: detail("Preparing the selected microphone.", warning: warningDetail),
                warnings: warnings,
                availableActions: []
            )
        case .active:
            return Self(
                phase: .wakeListening,
                isMicrophoneOpen: true,
                menuTitle: "Wake phrase listening\(warningSuffix)",
                hudTitle: "Microphone open · Wake phrase listening",
                hudDetail: detail("Evee is listening locally for your configured wake phrase.", warning: warningDetail),
                warnings: warnings,
                availableActions: []
            )
        case .stopping:
            return Self(
                phase: .wakeStopping,
                isMicrophoneOpen: true,
                menuTitle: "Stopping wake phrase listening\(warningSuffix)",
                hudTitle: "Microphone open · Stopping wake listener",
                hudDetail: detail("Closing the selected microphone.", warning: warningDetail),
                warnings: warnings,
                availableActions: []
            )
        case .failed(let message):
            return Self(
                phase: .failed,
                isMicrophoneOpen: false,
                menuTitle: "Wake listening failed",
                hudTitle: "Wake listening failed",
                hudDetail: message,
                warnings: warnings,
                availableActions: []
            )
        }
    }

    private static func detail(_ status: String, warning: String) -> String {
        warning.isEmpty ? status : "\(warning) \(status)"
    }
}
