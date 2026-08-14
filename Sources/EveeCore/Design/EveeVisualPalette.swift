import Foundation

public enum EveeColorRole: CaseIterable, Sendable {
    case canvas, sidebar, surface, elevatedSurface, hairline
    case primaryText, secondaryText, tertiaryText, primaryActionForeground
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
        case (.light, .tertiaryText): RGBColor(red: 0.40, green: 0.40, blue: 0.39)
        case (.light, .primaryActionForeground): RGBColor(red: 1, green: 1, blue: 1)
        case (.light, .accent): RGBColor(red: 0.38, green: 0.16, blue: 0.82)
        case (.light, .success): RGBColor(red: 0.10, green: 0.45, blue: 0.27)
        case (.light, .warning): RGBColor(red: 0.65, green: 0.32, blue: 0.02)
        case (.light, .destructive): RGBColor(red: 0.68, green: 0.08, blue: 0.16)
        case (.dark, .canvas): RGBColor(red: 0.082, green: 0.082, blue: 0.082)
        case (.dark, .sidebar): RGBColor(red: 0.094, green: 0.090, blue: 0.106)
        case (.dark, .surface): RGBColor(red: 0.118, green: 0.118, blue: 0.118)
        case (.dark, .elevatedSurface): RGBColor(red: 0.149, green: 0.137, blue: 0.157)
        case (.dark, .hairline): RGBColor(red: 0.231, green: 0.227, blue: 0.239)
        case (.dark, .primaryText): RGBColor(red: 0.95, green: 0.94, blue: 0.93)
        case (.dark, .secondaryText): RGBColor(red: 0.72, green: 0.70, blue: 0.68)
        case (.dark, .tertiaryText): RGBColor(red: 0.60, green: 0.58, blue: 0.56)
        case (.dark, .primaryActionForeground): RGBColor(red: 0.055, green: 0.055, blue: 0.065)
        case (.dark, .accent): RGBColor(red: 0.62, green: 0.46, blue: 0.95)
        case (.dark, .success): RGBColor(red: 0.39, green: 0.82, blue: 0.59)
        case (.dark, .warning): RGBColor(red: 1, green: 0.67, blue: 0.28)
        case (.dark, .destructive): RGBColor(red: 1, green: 0.45, blue: 0.52)
        case (.anima, .canvas): RGBColor(red: 0.965, green: 0.949, blue: 0.925)
        case (.anima, .sidebar): RGBColor(red: 0.925, green: 0.906, blue: 0.957)
        case (.anima, .surface): RGBColor(red: 0.995, green: 0.984, blue: 0.965)
        case (.anima, .elevatedSurface): RGBColor(red: 0.976, green: 0.957, blue: 0.993)
        case (.anima, .hairline): RGBColor(red: 0.735, green: 0.700, blue: 0.788)
        case (.anima, .primaryText): RGBColor(red: 0.125, green: 0.105, blue: 0.155)
        case (.anima, .secondaryText): RGBColor(red: 0.330, green: 0.290, blue: 0.380)
        case (.anima, .tertiaryText): RGBColor(red: 0.430, green: 0.385, blue: 0.475)
        case (.anima, .primaryActionForeground): RGBColor(red: 1, green: 0.995, blue: 0.985)
        case (.anima, .accent): RGBColor(red: 0.320, green: 0.250, blue: 0.820)
        case (.anima, .success): RGBColor(red: 0.120, green: 0.420, blue: 0.260)
        case (.anima, .warning): RGBColor(red: 0.625, green: 0.295, blue: 0.025)
        case (.anima, .destructive): RGBColor(red: 0.650, green: 0.075, blue: 0.145)
        }
    }
}
