import Foundation

public enum PermissionState: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

public enum OnboardingModelState: Equatable, Sendable {
    case idle
    case downloading(fraction: Double, status: String)
    case cancelling
    case failed(String)
    case ready
}

public enum OnboardingFocusTarget: Hashable, Sendable {
    case microphoneRequest
    case microphoneRecovery
    case accessibilityRequest
    case modelAction
}

public enum ModelOnboardingAction: Equatable, Sendable {
    case download
    case cancel
    case retry
    case none
}

public enum OnboardingLayoutMode: Equatable, Sendable {
    case compact
    case spacious

    public static func forViewportHeight(_ height: CGFloat) -> Self {
        height < 720 ? .compact : .spacious
    }
}

public enum OnboardingSceneLayout: Equatable, Sendable {
    case stacked
    case twoZone

    public static func forViewport(width: CGFloat, height: CGFloat) -> Self {
        width >= 860 && height >= 620 ? .twoZone : .stacked
    }
}

public struct OnboardingPresentation: Equatable, Sendable {
    public let focusTarget: OnboardingFocusTarget
    public let microphoneActionTitle: String
    public let microphoneStatus: String
    public let microphoneAccessibilityLabel: String
    public let microphoneAccessibilityHint: String
    public let accessibilityActionTitle: String
    public let accessibilityStatus: String
    public let accessibilityAccessibilityLabel: String
    public let accessibilityAccessibilityHint: String
    public let modelAction: ModelOnboardingAction
    public let modelActionTitle: String?
    public let modelAccessibilityLabel: String
    public let modelAccessibilityValue: String?
    public let modelAccessibilityHint: String

    public init(
        microphone: PermissionState,
        accessibility: PermissionState,
        model: OnboardingModelState
    ) {
        switch microphone {
        case .notDetermined:
            microphoneActionTitle = "Allow Microphone"
            microphoneStatus = "Permission needed"
            microphoneAccessibilityLabel = "Allow microphone access"
            microphoneAccessibilityHint = "Shows the macOS microphone permission request. Audio stays on this Mac."
        case .denied:
            microphoneActionTitle = "Open Microphone Settings"
            microphoneStatus = "Access denied"
            microphoneAccessibilityLabel = "Open Microphone Settings"
            microphoneAccessibilityHint = "Opens System Settings so you can allow Evee to use the microphone."
        case .granted:
            microphoneActionTitle = "Allow Microphone"
            microphoneStatus = "Ready"
            microphoneAccessibilityLabel = "Microphone access granted"
            microphoneAccessibilityHint = "Evee can use the microphone for local capture."
        }

        accessibilityActionTitle = "Open Accessibility Settings"
        switch accessibility {
        case .notDetermined:
            accessibilityStatus = "Permission needed"
            accessibilityAccessibilityLabel = "Open Accessibility Settings"
            accessibilityAccessibilityHint = "Opens System Settings so Evee can type finished dictation into other apps."
        case .denied:
            accessibilityStatus = "Access not yet granted"
            accessibilityAccessibilityLabel = "Reopen Accessibility Settings"
            accessibilityAccessibilityHint = "Opens System Settings so you can enable Accessibility access for Evee."
        case .granted:
            accessibilityStatus = "Ready"
            accessibilityAccessibilityLabel = "Accessibility access granted"
            accessibilityAccessibilityHint = "Evee can deliver finished dictation into other apps."
        }

        if microphone != .granted {
            focusTarget = microphone == .denied ? .microphoneRecovery : .microphoneRequest
        } else if accessibility != .granted {
            focusTarget = .accessibilityRequest
        } else {
            focusTarget = .modelAction
        }

        switch model {
        case .idle:
            modelAction = .download
            modelActionTitle = "Download"
            modelAccessibilityLabel = "Download local model"
            modelAccessibilityValue = "Not downloaded"
            modelAccessibilityHint = "Downloads and prepares the selected speech model on this Mac."
        case .downloading(let fraction, let status):
            let percentage = Int((min(max(fraction, 0), 1) * 100).rounded())
            modelAction = .cancel
            modelActionTitle = "Cancel"
            modelAccessibilityLabel = "Cancel local model download"
            modelAccessibilityValue = "\(percentage) percent, \(status)"
            modelAccessibilityHint = "Stops this download without deleting completed model cache."
        case .cancelling:
            modelAction = .none
            modelActionTitle = nil
            modelAccessibilityLabel = "Cancelling local model download"
            modelAccessibilityValue = "Cancelling"
            modelAccessibilityHint = "The current local model download is stopping."
        case .failed(let message):
            modelAction = .retry
            modelActionTitle = "Retry"
            modelAccessibilityLabel = "Retry local model download"
            modelAccessibilityValue = message
            modelAccessibilityHint = "Attempts the local model download again."
        case .ready:
            modelAction = .none
            modelActionTitle = nil
            modelAccessibilityLabel = "Local model ready"
            modelAccessibilityValue = "Ready"
            modelAccessibilityHint = "The selected local speech model is downloaded and prepared."
        }
    }

    public func focusRestorationTarget(
        previousModelAction: ModelOnboardingAction
    ) -> OnboardingFocusTarget? {
        guard focusTarget == .modelAction,
              modelAction != .none,
              modelAction != previousModelAction else { return nil }
        return .modelAction
    }
}
