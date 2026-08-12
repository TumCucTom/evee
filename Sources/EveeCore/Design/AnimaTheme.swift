import AppKit
import SwiftUI

public enum AnimaTheme {
    public static let electric = Color(red: 0.098, green: 0.220, blue: 0.953)
    public static let indigo = adaptive(light: NSColor(red: 0.255, green: 0.188, blue: 0.882, alpha: 1), dark: NSColor(red: 0.56, green: 0.53, blue: 1, alpha: 1))
    public static let violet = adaptive(light: NSColor(red: 0.486, green: 0.141, blue: 0.882, alpha: 1), dark: NSColor(red: 0.68, green: 0.48, blue: 1, alpha: 1))
    public static let magenta = adaptive(light: NSColor(red: 0.714, green: 0.102, blue: 0.835, alpha: 1), dark: NSColor(red: 0.86, green: 0.39, blue: 0.96, alpha: 1))
    public static let periwinkle = adaptive(light: NSColor(red: 0.365, green: 0.373, blue: 0.937, alpha: 1), dark: NSColor(red: 0.58, green: 0.61, blue: 1, alpha: 1))
    public static let lilac = adaptive(light: NSColor(red: 0.612, green: 0.624, blue: 0.980, alpha: 1), dark: NSColor(red: 0.71, green: 0.72, blue: 1, alpha: 1))
    public static let aubergine = adaptive(light: NSColor(red: 0.184, green: 0.082, blue: 0.427, alpha: 1), dark: NSColor(red: 0.89, green: 0.86, blue: 1, alpha: 1))
    public static let cloud = adaptive(light: NSColor(red: 0.894, green: 0.918, blue: 0.957, alpha: 1), dark: NSColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1))
    public static let paper = adaptive(light: NSColor(red: 0.980, green: 0.980, blue: 1, alpha: 1), dark: NSColor(red: 0.055, green: 0.052, blue: 0.075, alpha: 1))
    public static let surface = adaptive(light: .white, dark: NSColor(red: 0.105, green: 0.098, blue: 0.14, alpha: 1))
    public static let raisedSurface = adaptive(light: NSColor(red: 0.985, green: 0.985, blue: 1, alpha: 1), dark: NSColor(red: 0.14, green: 0.13, blue: 0.19, alpha: 1))
    public static let ink = adaptive(light: NSColor(red: 0.129, green: 0.110, blue: 0.176, alpha: 1), dark: NSColor(red: 0.94, green: 0.93, blue: 0.98, alpha: 1))
    public static let border = adaptive(light: NSColor(red: 0.902, green: 0.902, blue: 0.941, alpha: 1), dark: NSColor(red: 0.25, green: 0.23, blue: 0.32, alpha: 1))

    public static let alphaGradient = LinearGradient(
        colors: [magenta, violet, electric],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
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

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .background(AnimaTheme.alphaGradient)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

public struct AnimaCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        content
            .padding(16)
            .background(AnimaTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AnimaTheme.border))
            .shadow(color: AnimaTheme.aubergine.opacity(reduceMotion ? 0 : 0.05), radius: 12, y: 5)
    }
}

public extension View {
    func animaCard() -> some View { modifier(AnimaCardModifier()) }
}
