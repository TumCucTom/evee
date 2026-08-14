import AppKit
import EveeCore
import SwiftUI

enum EveeColors {
    static let canvas = adaptive(.canvas)
    static let sidebar = adaptive(.sidebar)
    static let surface = adaptive(.surface)
    static let elevatedSurface = adaptive(.elevatedSurface)
    static let hairline = adaptive(.hairline)
    static let primaryText = adaptive(.primaryText)
    static let secondaryText = adaptive(.secondaryText)
    static let tertiaryText = adaptive(.tertiaryText)
    static let accent = adaptive(.accent)
    static let success = adaptive(.success)
    static let warning = adaptive(.warning)
    static let destructive = adaptive(.destructive)

    static let spectralColors = [
        adaptive(
            light: NSColor(red: 0.098, green: 0.220, blue: 0.953, alpha: 1),
            dark: NSColor(red: 0.40, green: 0.55, blue: 1, alpha: 1)
        ),
        adaptive(
            light: NSColor(red: 0.486, green: 0.141, blue: 0.882, alpha: 1),
            dark: NSColor(red: 0.68, green: 0.48, blue: 1, alpha: 1)
        ),
        adaptive(
            light: NSColor(red: 0.714, green: 0.102, blue: 0.835, alpha: 1),
            dark: NSColor(red: 0.86, green: 0.39, blue: 0.96, alpha: 1)
        ),
    ]

    private static func adaptive(_ role: EveeColorRole) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let interfaceAppearance: InterfaceAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .dark
                : .light
            return nsColor(EveeVisualPalette.rgb(role, appearance: interfaceAppearance))
        })
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func nsColor(_ color: EveeCore.RGBColor) -> NSColor {
        NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}

enum EveeTypography {
    static let display = Font.system(size: 32, weight: .bold, design: .rounded)
    static let pageTitle = Font.system(size: 22, weight: .bold)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let metadata = Font.system(size: 11, weight: .medium)
    static let timestamp = Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let button = Font.system(size: 13, weight: .semibold)
}

enum EveeSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
}

enum EveeShape {
    static let compactCornerRadius: CGFloat = 9
    static let panelCornerRadius: CGFloat = 16
}

enum EveeVisual {
    static let canvas = EveeColors.canvas
    static let sidebar = EveeColors.sidebar
    static let surface = EveeColors.surface
    static let elevatedSurface = EveeColors.elevatedSurface
    static let hairline = EveeColors.hairline
    static let primaryText = EveeColors.primaryText
    static let secondaryText = EveeColors.secondaryText
    static let tertiaryText = EveeColors.tertiaryText
    static let accent = EveeColors.accent
    static let success = EveeColors.success
    static let warning = EveeColors.warning
    static let destructive = EveeColors.destructive
    static let spectralColors = EveeColors.spectralColors

    static var spectralGradient: LinearGradient {
        LinearGradient(colors: spectralColors, startPoint: .leading, endPoint: .trailing)
    }

    static func animation(_ kind: EveeMotionKind, reduceMotion: Bool) -> Animation? {
        let duration = EveeMotionPolicy(reduceMotion: reduceMotion).duration(for: kind)
        guard duration > 0 else { return nil }
        if kind == .voiceSettlement {
            return .spring(duration: duration, bounce: 0.14)
        }
        return .easeOut(duration: duration)
    }
}
