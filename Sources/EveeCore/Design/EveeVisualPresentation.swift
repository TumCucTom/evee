import Foundation

public enum EveeMotionKind: Sendable {
    case press, selection, route, voiceSettlement
}

public struct EveeMotionPolicy: Equatable, Sendable {
    public let reduceMotion: Bool

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    public func duration(for kind: EveeMotionKind) -> TimeInterval {
        guard !reduceMotion else { return 0 }
        return switch kind {
        case .press: 0.12
        case .selection: 0.2
        case .route: 0.26
        case .voiceSettlement: 0.36
        }
    }
}

public struct EveeButtonStatePresentation: Equatable, Sendable {
    public let opacity: Double
    public let saturation: Double
    public let showsDisabledBoundary: Bool

    public static func destructive(isEnabled: Bool) -> Self {
        Self(
            opacity: isEnabled ? 1 : 0.55,
            saturation: isEnabled ? 1 : 0.3,
            showsDisabledBoundary: !isEnabled
        )
    }
}

public enum VoiceThreadMode: Equatable, Sendable {
    case idle, listening, processing, resolved, warning
}

public struct VoiceThreadPresentation: Equatable, Sendable {
    public let mode: VoiceThreadMode
    public let level: Double

    public static func make(phase: SystemVoicePhase, level: Double?) -> Self {
        let mode: VoiceThreadMode = switch phase {
        case .wakeListening, .recording: .listening
        case .wakeStarting, .wakeStopping, .captureStarting, .processing, .delivering: .processing
        case .protected: .resolved
        case .failed: .warning
        case .ready: .idle
        }
        let measuredLevel = level.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return Self(mode: mode, level: min(1, max(0, measuredLevel)))
    }
}

public struct CaptureOverlaySnapshot: Equatable, Sendable {
    public let status: SystemVoiceStatus
    public let level: Double?

    public static func make(status: SystemVoiceStatus, capture: CaptureState) -> Self {
        let level: Double? = switch capture {
        case .recording(_, let measuredLevel) where measuredLevel.isFinite:
            Double(measuredLevel)
        case .idle, .starting, .recording, .transcribing, .delivering, .checkpointed, .failed:
            nil
        }
        return Self(status: status, level: level)
    }
}

public enum EveeSettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case voice, writing, meetings, privacyAndStorage, integrations, application

    public var id: Self { self }

    public var title: String {
        switch self {
        case .voice: "Voice"
        case .writing: "Writing"
        case .meetings: "Meetings"
        case .privacyAndStorage: "Privacy & Storage"
        case .integrations: "Integrations"
        case .application: "Application"
        }
    }

    public var symbolName: String {
        switch self {
        case .voice: "waveform"
        case .writing: "textformat"
        case .meetings: "person.2"
        case .privacyAndStorage: "lock.doc"
        case .integrations: "point.3.connected.trianglepath.dotted"
        case .application: "gearshape"
        }
    }
}
