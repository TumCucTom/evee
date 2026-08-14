public enum VoiceStatusTone: Equatable, Sendable {
    case neutral
    case accent
    case success
    case warning
    case destructive

    public static func make(phase: SystemVoicePhase, hasWarning: Bool) -> Self {
        if hasWarning { return .warning }
        return switch phase {
        case .recording, .captureStarting, .wakeListening, .wakeStopping:
            .accent
        case .protected:
            .success
        case .failed:
            .destructive
        case .ready, .wakeStarting, .processing, .delivering:
            .neutral
        }
    }
}
