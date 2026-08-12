import EveeCore
import SwiftUI

struct RecordingPill: View {
    let state: CaptureState
    let operation: WorkspaceRecordOperation?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        state: CaptureState,
        operation: WorkspaceRecordOperation? = nil,
        onStop: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.state = state
        self.operation = operation
        self.onStop = onStop
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AnimaTheme.ink)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            if canCancel {
                if let onCancel {
                    Button("Discard", role: .destructive, action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Stop recording and permanently discard this capture")
                }
                if let onStop, case .recording = state {
                    Button("Stop", action: onStop)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                        .keyboardShortcut(.return, modifiers: [])
                        .help("Stop recording and transcribe")
                }
            }
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
        switch state {
        case .recording(_, let level):
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(index.isMultiple(of: 2) ? AnimaTheme.magenta : AnimaTheme.periwinkle)
                        .frame(width: 3, height: reduceMotion ? 12 : barHeight(level: level, index: index))
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28)
                .accessibilityHidden(true)
        default:
            ProgressView()
                .controlSize(.small)
                .frame(width: 28)
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        switch state {
        case .idle: "Ready"
        case .starting: operation == .selectionTransform ? "Starting selection transform" : "Starting capture"
        case .recording: operation == .selectionTransform ? "Recording transform instruction" : "Recording"
        case .transcribing: "Transcribing locally"
        case .delivering: operation == .selectionTransform ? "Replacing selected text" : "Inserting text"
        case .failed: "Capture needs attention"
        }
    }

    private var detail: String {
        switch state {
        case .idle: "Hold your shortcut to dictate"
        case .starting(let kind): operation == .selectionTransform
            ? "Keep the original text selected · you can discard at any time"
            : "Preparing \(kind.rawValue) audio · you can discard at any time"
        case .recording(let startedAt, _): operation == .selectionTransform
            ? "Speak a supported transform, then release or press Stop"
            : "Started \(startedAt.formatted(date: .omitted, time: .standard)) · audio stays on this Mac"
        case .transcribing: "You can keep working while Evee processes the audio"
        case .delivering: operation == .selectionTransform ? "Verifying the original selection before replacement" : "Sending the finished text to your active app"
        case .failed(let message): message
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .starting: operation == .selectionTransform
            ? "Evee is preparing a selection transform. Keep the original text selected. Use Discard to cancel."
            : "Evee is preparing audio capture. Use Discard to cancel."
        case .recording: operation == .selectionTransform
            ? "Evee is recording a transform instruction. Use Stop to transform or Discard to leave the selection unchanged."
            : "Evee is recording. Use Stop to transcribe or Discard to delete the recording."
        case .transcribing: "Evee is transcribing locally."
        case .delivering: operation == .selectionTransform ? "Evee is verifying and replacing the selected text." : "Evee is inserting the finished text."
        case .failed(let message): "Evee capture failed. \(message)"
        case .idle: "Evee is ready."
        }
    }

    private var canCancel: Bool {
        switch state {
        case .starting, .recording: true
        default: false
        }
    }

    private func barHeight(level: Float, index: Int) -> CGFloat {
        let normalised = min(max(CGFloat(level) * 24, 5), 24)
        let variance: CGFloat = index.isMultiple(of: 3) ? 0.65 : (index.isMultiple(of: 2) ? 0.85 : 1)
        return max(5, normalised * variance)
    }
}
