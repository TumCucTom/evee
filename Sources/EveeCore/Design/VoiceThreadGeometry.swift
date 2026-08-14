public enum VoiceThreadGeometry {
    public static let sampleCount = 9

    private static let idle = [0.0, 0, 0.04, 0.08, 0.10, 0.08, 0.04, 0, 0]
    private static let listeningEnvelope = [0.0, -0.34, 0.58, -0.78, 1.0, -0.78, 0.58, -0.34, 0]
    private static let processing = [0.0, 0.18, -0.26, 0.34, 0, -0.34, 0.26, -0.18, 0]
    private static let resolved = [0.0, 0, -0.08, -0.28, 0.48, 0.20, 0.05, 0, 0]
    private static let warning = [0.0, -0.08, 0.10, -0.36, 0.72, -0.36, 0.10, -0.08, 0]

    public static func points(mode: VoiceThreadMode, level: Double) -> [Double] {
        switch mode {
        case .idle:
            idle
        case .listening:
            listeningEnvelope.map { $0 * bounded(level) }
        case .processing:
            processing
        case .resolved:
            resolved
        case .warning:
            warning
        }
    }

    private static func bounded(_ level: Double) -> Double {
        guard level.isFinite else { return 0 }
        return min(1, max(0, level))
    }
}
