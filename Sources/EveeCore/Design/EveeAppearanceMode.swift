import Foundation

public enum InterfaceAppearance: CaseIterable, Sendable {
    case light
    case dark
    case anima
}

public enum EveeAppearanceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case glass
    case light
    case dark
    case anima

    public var id: Self { self }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .glass: "Glass"
        case .light: "Light"
        case .dark: "Dark"
        case .anima: "Anima"
        }
    }

    public var detail: String {
        switch self {
        case .automatic: "Match this Mac"
        case .glass: "Fluid, translucent surfaces"
        case .light: "Crisp pearl"
        case .dark: "Quiet graphite"
        case .anima: "Warm and expressive"
        }
    }

    public func resolve(systemAppearance: InterfaceAppearance) -> InterfaceAppearance {
        switch self {
        case .automatic, .glass: systemAppearance == .dark ? .dark : .light
        case .light: .light
        case .dark: .dark
        case .anima: .anima
        }
    }
}

public enum EveeMaterialLayer: Sendable {
    case rail
    case panel
}

public struct EveeMaterialPresentation: Equatable, Sendable {
    public let usesTranslucency: Bool
    public let tintOpacity: Double
    public let edgeOpacity: Double

    public static func make(
        mode: EveeAppearanceMode,
        layer: EveeMaterialLayer,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Self {
        if reduceTransparency {
            return Self(
                usesTranslucency: false,
                tintOpacity: 1,
                edgeOpacity: mode == .glass ? (increaseContrast ? 0.92 : 0.64) : 0
            )
        }

        guard mode == .glass else {
            return Self(
                usesTranslucency: true,
                tintOpacity: 0.42,
                edgeOpacity: 0
            )
        }

        return Self(
            usesTranslucency: true,
            tintOpacity: layer == .rail ? 0.18 : 0.12,
            edgeOpacity: increaseContrast ? 0.94 : 0.66
        )
    }
}

public enum EveeAppearancePreference {
    public static let key = "interfaceAppearance"

    public static func load(from defaults: UserDefaults = .standard) -> EveeAppearanceMode {
        guard let rawValue = defaults.string(forKey: key),
              let mode = EveeAppearanceMode(rawValue: rawValue) else {
            return .automatic
        }
        return mode
    }

    public static func save(_ mode: EveeAppearanceMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
