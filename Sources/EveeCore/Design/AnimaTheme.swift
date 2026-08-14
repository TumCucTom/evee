import AppKit
import SwiftUI

public enum AnimaTheme {
    public static let electric = adaptive(
        light: NSColor(red: 0.098, green: 0.220, blue: 0.953, alpha: 1),
        dark: NSColor(red: 0.40, green: 0.55, blue: 1, alpha: 1)
    )
    public static let indigo = semantic(.accent)
    public static let violet = adaptive(light: NSColor(red: 0.486, green: 0.141, blue: 0.882, alpha: 1), dark: NSColor(red: 0.68, green: 0.48, blue: 1, alpha: 1))
    public static let magenta = adaptive(light: NSColor(red: 0.714, green: 0.102, blue: 0.835, alpha: 1), dark: NSColor(red: 0.86, green: 0.39, blue: 0.96, alpha: 1))
    public static let periwinkle = adaptive(light: NSColor(red: 0.365, green: 0.373, blue: 0.937, alpha: 1), dark: NSColor(red: 0.58, green: 0.61, blue: 1, alpha: 1))
    public static let lilac = adaptive(light: NSColor(red: 0.612, green: 0.624, blue: 0.980, alpha: 1), dark: NSColor(red: 0.71, green: 0.72, blue: 1, alpha: 1))
    public static let aubergine = semantic(.primaryText)
    public static let cloud = semantic(.sidebar)
    public static let paper = semantic(.canvas)
    public static let surface = semantic(.surface)
    public static let raisedSurface = semantic(.elevatedSurface)
    public static let ink = semantic(.primaryText)
    public static let border = semantic(.hairline)

    public static let alphaGradient = LinearGradient(
        colors: [electric, violet, magenta],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let actionForeground = swiftUIColor(AccessibleActionPalette.foreground)
    public static let disabledActionBorder = swiftUIColor(AccessibleActionPalette.disabledBorder)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }

    private static func semantic(_ role: EveeColorRole) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let interfaceAppearance: InterfaceAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .dark
                : .light
            return nsColor(EveeVisualPalette.rgb(role, appearance: interfaceAppearance))
        })
    }

    private static func nsColor(_ color: RGBColor) -> NSColor {
        NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private static func swiftUIColor(_ color: RGBColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }
}

/// Evee's product glyph. This deliberately uses an SF Symbol rather than
/// approximating an Anima brand mark that is not bundled with the app.
public struct EveeMark: View {
    public var size: CGFloat

    public init(size: CGFloat = 32) { self.size = size }

    public var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AnimaTheme.alphaGradient)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Kept as a source-compatible alias for the onboarding screen.
@available(*, deprecated, renamed: "EveeMark")
public typealias AlphaMark = EveeMark

public struct AlphaButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AnimaTheme.actionForeground)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .background(AnimaTheme.alphaGradient)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            AnimaTheme.disabledActionBorder,
                            style: StrokeStyle(lineWidth: 2, dash: [5, 3])
                        )
                }
            }
            .saturation(isEnabled ? 1 : 0.28)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: EveeMotionPolicy(reduceMotion: false).duration(for: .press)),
                value: configuration.isPressed
            )
    }
}

public struct AnimaCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        content
            .padding(16)
            .background(AnimaTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AnimaTheme.border))
            .shadow(color: AnimaTheme.aubergine.opacity(reduceMotion ? 0 : 0.04), radius: 12, y: 5)
    }
}

public extension View {
    func animaCard() -> some View { modifier(AnimaCardModifier()) }
}
