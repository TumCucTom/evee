import EveeCore
import SwiftUI

struct RecordingPill: View {
    let state: CaptureState

    var body: some View {
        HStack(spacing: 10) {
            if case .recording(_, let level) = state {
                Circle().fill(.red).frame(width: 8, height: 8)
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { index in
                        Capsule().fill(AnimaTheme.periwinkle).frame(width: 3, height: max(5, CGFloat(level) * CGFloat(8 + index * 3)))
                    }
                }.frame(height: 24)
                Text("Listening").font(.system(size: 12, weight: .semibold))
            } else {
                ProgressView().controlSize(.small)
                Text(label).font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 14).frame(height: 42).background(.ultraThickMaterial)
        .clipShape(Capsule()).overlay(Capsule().stroke(AnimaTheme.border)).shadow(color: AnimaTheme.aubergine.opacity(0.15), radius: 16, y: 6)
        .padding(.bottom, 18)
    }

    private var label: String { switch state { case .transcribing: "Transcribing locally"; case .delivering: "Pasting"; case .failed: "Needs attention"; default: "Ready" } }
}
