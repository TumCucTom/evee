import EveeCore
import SwiftUI

struct RecordingPill: View {
    let status: SystemVoiceStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(status.hudTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AnimaTheme.ink)
                Text(status.hudDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 14)
        .frame(width: 410, height: 54)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(AnimaTheme.border))
        .shadow(color: .black.opacity(0.22), radius: reduceMotion ? 5 : 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var statusIcon: some View {
        switch status.phase {
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 28)
                .accessibilityHidden(true)
        case .wakeListening, .wakeStopping:
            Image(systemName: "mic.fill")
                .foregroundStyle(AnimaTheme.magenta)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28)
                .accessibilityHidden(true)
        case .ready, .protected:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28)
                .accessibilityHidden(true)
        case .wakeStarting, .captureStarting, .processing, .delivering:
            ProgressView()
                .controlSize(.small)
                .frame(width: 28)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let microphone = status.isMicrophoneOpen ? "Microphone open." : "Microphone closed."
        return "\(status.hudTitle). \(microphone) \(status.hudDetail)"
    }
}
