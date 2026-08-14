import EveeCore
import SwiftUI

struct RecordingPill: View {
    @ObservedObject var model: CaptureOverlayPresentationModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            compactLayout
            largeTextLayout
        }
        .padding(.horizontal, EveeSpacing.large)
        .padding(.vertical, EveeSpacing.small)
        .frame(width: 376)
        .frame(minHeight: 52)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: presentation.phase == .failed ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.2), radius: reduceMotion ? 5 : 14, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var compactLayout: some View {
        HStack(spacing: EveeSpacing.medium) {
            Image(systemName: statusSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusTone.color)
                .frame(width: 20)
                .accessibilityHidden(true)

            VoiceThread(
                presentation: VoiceThreadPresentation.make(phase: presentation.phase, level: presentation.level),
                lineWidth: 1.5
            )
            .frame(width: 78, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(EveeTypography.sectionTitle)
                    .foregroundStyle(EveeVisual.primaryText)
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(EveeTypography.metadata)
                    .foregroundStyle(EveeVisual.secondaryText)
                    .lineLimit(allowsExpandedDetail ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var largeTextLayout: some View {
        VStack(alignment: .leading, spacing: EveeSpacing.small) {
            HStack(spacing: EveeSpacing.small) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTone.color)
                    .accessibilityHidden(true)
                VoiceThread(
                    presentation: VoiceThreadPresentation.make(phase: presentation.phase, level: presentation.level),
                    lineWidth: 1.5
                )
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            }
            Text(presentation.title)
                .font(EveeTypography.sectionTitle)
                .foregroundStyle(EveeVisual.primaryText)
            Text(presentation.detail)
                .font(EveeTypography.metadata)
                .foregroundStyle(EveeVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presentation: CaptureOverlayPresentation { model.presentation }

    private var allowsExpandedDetail: Bool {
        presentation.phase == .failed || presentation.hasWarning
    }

    private var statusSymbol: String {
        switch presentation.phase {
        case .ready: "circle"
        case .wakeStarting, .captureStarting: "waveform.circle"
        case .wakeListening, .wakeStopping: "mic.circle.fill"
        case .recording: "record.circle.fill"
        case .processing, .delivering: "ellipsis.circle"
        case .protected: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusTone: EveeStatusTone {
        EveeStatusTone(
            VoiceStatusTone.make(
                phase: presentation.phase,
                hasWarning: presentation.hasWarning
            )
        )
    }

    private var borderColor: Color {
        if presentation.phase == .failed || presentation.hasWarning { return statusTone.color }
        return EveeVisual.hairline
    }
}
