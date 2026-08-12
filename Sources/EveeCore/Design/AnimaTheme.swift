import SwiftUI

public enum AnimaTheme {
    public static let electric = Color(red: 0.098, green: 0.220, blue: 0.953)
    public static let indigo = Color(red: 0.255, green: 0.188, blue: 0.882)
    public static let violet = Color(red: 0.486, green: 0.141, blue: 0.882)
    public static let magenta = Color(red: 0.714, green: 0.102, blue: 0.835)
    public static let periwinkle = Color(red: 0.365, green: 0.373, blue: 0.937)
    public static let lilac = Color(red: 0.612, green: 0.624, blue: 0.980)
    public static let aubergine = Color(red: 0.184, green: 0.082, blue: 0.427)
    public static let cloud = Color(red: 0.894, green: 0.918, blue: 0.957)
    public static let paper = Color(red: 0.980, green: 0.980, blue: 1.000)
    public static let ink = Color(red: 0.129, green: 0.110, blue: 0.176)
    public static let border = Color(red: 0.902, green: 0.902, blue: 0.941)

    public static let alphaGradient = LinearGradient(
        colors: [Color(red: 0.608, green: 0.110, blue: 0.859), violet, electric],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

public struct AlphaMark: View {
    public var size: CGFloat

    public init(size: CGFloat = 32) { self.size = size }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height)
            var path = Path()
            path.move(to: CGPoint(x: scale * 0.18, y: scale * 0.72))
            path.addCurve(
                to: CGPoint(x: scale * 0.60, y: scale * 0.28),
                control1: CGPoint(x: scale * 0.26, y: scale * 0.20),
                control2: CGPoint(x: scale * 0.70, y: scale * 0.12)
            )
            path.addCurve(
                to: CGPoint(x: scale * 0.82, y: scale * 0.70),
                control1: CGPoint(x: scale * 0.52, y: scale * 0.48),
                control2: CGPoint(x: scale * 0.62, y: scale * 0.78)
            )
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [AnimaTheme.magenta, AnimaTheme.violet, AnimaTheme.electric]),
                startPoint: .zero,
                endPoint: CGPoint(x: scale, y: scale)
            ), style: StrokeStyle(lineWidth: scale * 0.12, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct AlphaButtonStyle: ButtonStyle {
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
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

public struct AnimaCardModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AnimaTheme.border))
            .shadow(color: AnimaTheme.aubergine.opacity(0.05), radius: 12, y: 5)
    }
}

public extension View {
    func animaCard() -> some View { modifier(AnimaCardModifier()) }
}
