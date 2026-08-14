public enum VoiceThreadGeometry {
    private static let fixedHalfEnvelope = [0.0, -0.34, 0.58, -0.78, 1.0]

    public static func points(level: Double, count: Int) -> [Double] {
        let sampleCount = normalizedSampleCount(count)
        guard sampleCount > 1 else { return [0] }

        let clampedLevel = level.isFinite ? min(1, max(0, level)) : 0
        let halfCount = sampleCount / 2
        let leadingHalf = (0...halfCount).map { index in
            interpolatedEnvelope(at: Double(index) / Double(halfCount)) * clampedLevel
        }

        return leadingHalf + leadingHalf.dropLast().reversed()
    }

    private static func normalizedSampleCount(_ count: Int) -> Int {
        let positiveCount = max(1, count)
        return positiveCount.isMultiple(of: 2) ? positiveCount + 1 : positiveCount
    }

    private static func interpolatedEnvelope(at position: Double) -> Double {
        let scaledPosition = position * Double(fixedHalfEnvelope.count - 1)
        let lowerIndex = Int(scaledPosition.rounded(.down))
        let upperIndex = min(lowerIndex + 1, fixedHalfEnvelope.count - 1)
        let fraction = scaledPosition - Double(lowerIndex)
        return fixedHalfEnvelope[lowerIndex]
            + (fixedHalfEnvelope[upperIndex] - fixedHalfEnvelope[lowerIndex]) * fraction
    }
}
