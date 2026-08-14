import Foundation

public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(with other: RGBColor) -> Double {
        let high = max(relativeLuminance, other.relativeLuminance)
        let low = min(relativeLuminance, other.relativeLuminance)
        return (high + 0.05) / (low + 0.05)
    }
}

public enum InterfaceAppearance: CaseIterable, Sendable {
    case light
    case dark
}

public enum AccessibleActionPalette {
    private static let lightStops = [
        RGBColor(red: 0.098, green: 0.220, blue: 0.953),
        RGBColor(red: 0.486, green: 0.141, blue: 0.882),
        RGBColor(red: 0.714, green: 0.102, blue: 0.835),
    ]
    private static let darkStops = [
        RGBColor(red: 0.40, green: 0.55, blue: 1),
        RGBColor(red: 0.68, green: 0.48, blue: 1),
        RGBColor(red: 0.86, green: 0.39, blue: 0.96),
    ]

    public static func gradientStops(for appearance: InterfaceAppearance) -> [RGBColor] {
        switch appearance {
        case .light: lightStops
        case .dark: darkStops
        }
    }

    public static func paper(for appearance: InterfaceAppearance) -> RGBColor {
        EveeVisualPalette.rgb(.canvas, appearance: appearance)
    }

    public static let foreground = EveeVisualPalette.rgb(.surface, appearance: .light)
    public static let disabledBorder = RGBColor(red: 0.365, green: 0.373, blue: 0.937)
}
