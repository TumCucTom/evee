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
    static let primaryActionForeground = adaptive(.primaryActionForeground)
    static let accent = adaptive(.accent)
    static let success = adaptive(.success)
    static let warning = adaptive(.warning)
    static let destructive = adaptive(.destructive)

    static let spectralColors = zip(
        AccessibleActionPalette.gradientStops(for: .light),
        AccessibleActionPalette.gradientStops(for: .dark)
    ).map { light, dark in
        adaptive(light: nsColor(light), dark: nsColor(dark))
    }

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
    static let display = Font.largeTitle.bold()
    static let pageTitle = Font.title2.bold()
    static let sectionTitle = Font.headline
    static let body = Font.body
    static let metadata = Font.caption.weight(.medium)
    static let timestamp = Font.caption2.monospaced().weight(.semibold)
    static let button = Font.body.weight(.semibold)
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
    static let primaryActionForeground = EveeColors.primaryActionForeground
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
