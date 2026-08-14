import Foundation

public enum EveeColorRole: CaseIterable, Sendable {
    case canvas, sidebar, surface, elevatedSurface, hairline
    case primaryText, secondaryText, tertiaryText
    case accent, success, warning, destructive
}

public enum EveeVisualPalette {
    public static func rgb(_ role: EveeColorRole, appearance: InterfaceAppearance) -> RGBColor {
        switch (appearance, role) {
        case (.light, .canvas): RGBColor(red: 0.973, green: 0.973, blue: 0.969)
        case (.light, .sidebar): RGBColor(red: 0.956, green: 0.951, blue: 0.976)
        case (.light, .surface), (.light, .elevatedSurface): RGBColor(red: 1, green: 1, blue: 1)
        case (.light, .hairline): RGBColor(red: 0.82, green: 0.82, blue: 0.80)
        case (.light, .primaryText): RGBColor(red: 0.12, green: 0.12, blue: 0.12)
        case (.light, .secondaryText): RGBColor(red: 0.35, green: 0.35, blue: 0.35)
        case (.light, .tertiaryText): RGBColor(red: 0.48, green: 0.48, blue: 0.47)
        case (.light, .accent): RGBColor(red: 0.38, green: 0.16, blue: 0.82)
        case (.light, .success): RGBColor(red: 0.10, green: 0.45, blue: 0.27)
        case (.light, .warning): RGBColor(red: 0.65, green: 0.32, blue: 0.02)
        case (.light, .destructive): RGBColor(red: 0.68, green: 0.08, blue: 0.16)
        case (.dark, .canvas): RGBColor(red: 0.055, green: 0.055, blue: 0.065)
        case (.dark, .sidebar): RGBColor(red: 0.075, green: 0.07, blue: 0.095)
        case (.dark, .surface): RGBColor(red: 0.10, green: 0.095, blue: 0.12)
        case (.dark, .elevatedSurface): RGBColor(red: 0.135, green: 0.125, blue: 0.16)
        case (.dark, .hairline): RGBColor(red: 0.29, green: 0.28, blue: 0.34)
        case (.dark, .primaryText): RGBColor(red: 0.95, green: 0.94, blue: 0.97)
        case (.dark, .secondaryText): RGBColor(red: 0.73, green: 0.72, blue: 0.77)
        case (.dark, .tertiaryText): RGBColor(red: 0.60, green: 0.59, blue: 0.65)
        case (.dark, .accent): RGBColor(red: 0.68, green: 0.58, blue: 1)
        case (.dark, .success): RGBColor(red: 0.39, green: 0.82, blue: 0.59)
        case (.dark, .warning): RGBColor(red: 1, green: 0.67, blue: 0.28)
        case (.dark, .destructive): RGBColor(red: 1, green: 0.45, blue: 0.52)
        }
    }
}

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
        let fallback = mode == .listening ? 0.08 : 0
        return Self(mode: mode, level: min(1, max(0, level ?? fallback)))
    }
}

public enum EveeSettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case voice, writing, meetings, privacyAndStorage, integrations, application

    public var id: Self { self }
}
