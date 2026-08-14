import EveeCore
import SwiftUI

struct VoiceThread: View {
    let presentation: VoiceThreadPresentation
    var lineWidth: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var processingProgress: CGFloat = 0

    var body: some View {
        let samples = VoiceThreadSampleVector(
            VoiceThreadGeometry.points(mode: presentation.mode, level: presentation.level)
        )
        let shape = VoiceThreadShape(samples: samples, lineWidth: lineWidth)

        ZStack {
            shape.stroke(EveeVisual.hairline, lineWidth: lineWidth)

            switch presentation.mode {
            case .listening:
                shape.stroke(EveeVisual.spectralGradient, lineWidth: lineWidth)
            case .processing:
                shape.stroke(EveeVisual.accent.opacity(0.28), lineWidth: lineWidth)
                processingHighlight(shape)
            case .resolved:
                shape.stroke(EveeVisual.success, lineWidth: lineWidth)
            case .warning:
                shape.stroke(EveeVisual.warning, lineWidth: lineWidth)
            case .idle:
                EmptyView()
            }
        }
        .animation(
            EveeVisual.animation(.voiceSettlement, reduceMotion: reduceMotion),
            value: presentation
        )
        .onAppear(perform: updateProcessingMotion)
        .onChange(of: presentation.mode) { _, _ in updateProcessingMotion() }
        .onChange(of: reduceMotion) { _, _ in updateProcessingMotion() }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func processingHighlight(_ shape: VoiceThreadShape) -> some View {
        let start = max(0, processingProgress - 0.16)
        let end = min(1, processingProgress + 0.16)
        shape
            .trim(from: start, to: end)
            .stroke(EveeVisual.spectralGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func updateProcessingMotion() {
        let motion = VoiceThreadProcessingMotion.make(
            mode: presentation.mode,
            reduceMotion: reduceMotion
        )
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            processingProgress = CGFloat(motion.startProgress)
        }
        guard motion.animatesHighlight else { return }
        withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
            processingProgress = CGFloat(motion.endProgress)
        }
    }
}

struct VoiceThreadSampleVector: VectorArithmetic {
    var values: [Double]

    init(_ values: [Double]) {
        self.values = Array(values.prefix(VoiceThreadGeometry.sampleCount))
        if self.values.count < VoiceThreadGeometry.sampleCount {
            self.values.append(
                contentsOf: repeatElement(
                    0,
                    count: VoiceThreadGeometry.sampleCount - self.values.count
                )
            )
        }
    }

    static var zero: Self {
        Self(Array(repeating: 0, count: VoiceThreadGeometry.sampleCount))
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(zip(lhs.values, rhs.values).map(+))
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(zip(lhs.values, rhs.values).map(-))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

struct VoiceThreadShape: Shape {
    var samples: VoiceThreadSampleVector
    let lineWidth: CGFloat

    var animatableData: VoiceThreadSampleVector {
        get { samples }
        set { samples = newValue }
    }

    func path(in rect: CGRect) -> Path {
        VoiceThreadPath.path(
            samples: samples.values,
            size: rect.size,
            lineWidth: lineWidth
        )
    }
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
