import EveeCore
import SwiftUI

struct VoiceThread: View {
    let presentation: VoiceThreadPresentation
    var lineWidth: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let samples = VoiceThreadGeometry.points(level: presentation.level, count: nineSampleCount)
            let path = VoiceThreadPath.path(samples: samples, size: size, lineWidth: lineWidth)
            context.stroke(path, with: .color(EveeVisual.hairline), lineWidth: lineWidth)

            switch presentation.mode {
            case .listening, .processing:
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: EveeVisual.spectralColors),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    lineWidth: lineWidth
                )
            case .resolved:
                context.stroke(path, with: .color(EveeVisual.success), lineWidth: lineWidth)
            case .warning:
                context.stroke(path, with: .color(EveeVisual.warning), lineWidth: lineWidth)
            case .idle:
                break
            }
        }
        .animation(
            EveeVisual.animation(.voiceSettlement, reduceMotion: reduceMotion),
            value: presentation
        )
        .accessibilityHidden(true)
    }

    private var nineSampleCount: Int { 9 }
}

enum VoiceThreadPath {
    static func path(samples: [Double], size: CGSize, lineWidth: CGFloat) -> Path {
        guard !samples.isEmpty else { return Path() }

        let drawableAmplitude = max(0, (size.height - lineWidth) / 2)
        let horizontalStep = samples.count > 1 ? size.width / CGFloat(samples.count - 1) : 0
        let points = samples.enumerated().map { index, sample in
            CGPoint(
                x: CGFloat(index) * horizontalStep,
                y: size.height / 2 - CGFloat(sample) * drawableAmplitude
            )
        }

        var path = Path()
        path.move(to: points[0])
        for index in points.indices.dropFirst() {
            let previous = points[index - 1]
            let current = points[index]
            let controlX = (previous.x + current.x) / 2
            path.addCurve(
                to: current,
                control1: CGPoint(x: controlX, y: previous.y),
                control2: CGPoint(x: controlX, y: current.y)
            )
        }
        return path
    }
}
