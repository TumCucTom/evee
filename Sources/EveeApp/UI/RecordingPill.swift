import EveeCore
import SwiftUI

struct RecordingPill: View {
    let status: SystemVoiceStatus
    let level: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: EveeSpacing.medium) {
            Image(systemName: statusSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusTone.color)
                .frame(width: 20)
                .accessibilityHidden(true)

            VoiceThread(
                presentation: VoiceThreadPresentation.make(phase: status.phase, level: level),
                lineWidth: 1.5
            )
            .frame(width: 78, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.hudTitle)
                    .font(EveeTypography.sectionTitle)
                    .foregroundStyle(EveeVisual.primaryText)
                    .lineLimit(1)
                Text(status.hudDetail)
                    .font(EveeTypography.metadata)
                    .foregroundStyle(EveeVisual.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, EveeSpacing.large)
        .frame(width: 376, height: 52)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: status.phase == .failed ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.2), radius: reduceMotion ? 5 : 14, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusSymbol: String {
        switch status.phase {
        case .ready: "checkmark.circle.fill"
        case .wakeStarting, .captureStarting: "waveform.circle"
        case .wakeListening, .wakeStopping: "mic.circle.fill"
        case .recording: "record.circle.fill"
        case .processing, .delivering: "ellipsis.circle"
        case .protected: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusTone: EveeStatusTone {
        if !status.warnings.isEmpty { return .warning }
        return switch status.phase {
        case .ready, .protected: .success
        case .wakeListening, .wakeStopping, .recording: .accent
        case .failed: .destructive
        case .wakeStarting, .captureStarting, .processing, .delivering: .neutral
        }
    }

    private var borderColor: Color {
        if status.phase == .failed || !status.warnings.isEmpty { return statusTone.color }
        return EveeVisual.hairline
    }

    private var accessibilityLabel: String {
        let microphone = status.isMicrophoneOpen ? "Microphone open." : "Microphone closed."
        return "\(status.hudTitle). \(microphone) \(status.hudDetail)"
    }
}
