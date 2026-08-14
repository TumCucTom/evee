import Foundation

public enum InterfaceAppearance: CaseIterable, Sendable {
    case light
    case dark
    case anima
}

public enum EveeAppearanceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case light
    case dark
    case anima

    public var id: Self { self }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        case .anima: "Anima"
        }
    }

    public var detail: String {
        switch self {
        case .automatic: "Match this Mac"
        case .light: "Crisp pearl"
        case .dark: "Quiet graphite"
        case .anima: "Warm and expressive"
        }
    }

    public func resolve(systemAppearance: InterfaceAppearance) -> InterfaceAppearance {
        switch self {
        case .automatic: systemAppearance == .dark ? .dark : .light
        case .light: .light
        case .dark: .dark
        case .anima: .anima
        }
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
