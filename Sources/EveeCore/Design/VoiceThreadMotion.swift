public struct VoiceThreadProcessingMotion: Equatable, Sendable {
    public let showsHighlight: Bool
    public let animatesHighlight: Bool
    public let startProgress: Double
    public let endProgress: Double

    public static func make(mode: VoiceThreadMode, reduceMotion: Bool) -> Self {
        guard mode == .processing else {
            return Self(
                showsHighlight: false,
                animatesHighlight: false,
                startProgress: 0,
                endProgress: 0
            )
        }

        if reduceMotion {
            return Self(
                showsHighlight: true,
                animatesHighlight: false,
                startProgress: 0.5,
                endProgress: 0.5
            )
        }

        return Self(
            showsHighlight: true,
            animatesHighlight: true,
            startProgress: 0,
            endProgress: 1
        )
    }
}
