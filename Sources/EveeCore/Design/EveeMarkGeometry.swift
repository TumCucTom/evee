import CoreGraphics

public enum EveeMarkGeometry {
    public static func path(in rect: CGRect) -> CGPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        let path = CGMutablePath()
        path.move(to: point(0.76, 0.50))
        path.addLine(to: point(0.30, 0.50))
        path.addCurve(
            to: point(0.59, 0.22),
            control1: point(0.30, 0.32),
            control2: point(0.44, 0.22)
        )
        path.addCurve(
            to: point(0.81, 0.53),
            control1: point(0.77, 0.22),
            control2: point(0.84, 0.36)
        )
        path.addCurve(
            to: point(0.47, 0.79),
            control1: point(0.77, 0.72),
            control2: point(0.63, 0.81)
        )
        path.addCurve(
            to: point(0.23, 0.60),
            control1: point(0.34, 0.78),
            control2: point(0.25, 0.70)
        )
        return path
    }
}
