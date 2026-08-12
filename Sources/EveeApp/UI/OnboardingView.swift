import EveeCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [AnimaTheme.paper, AnimaTheme.cloud.opacity(0.74)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            Circle().stroke(AnimaTheme.violet.opacity(0.10), lineWidth: 2).frame(width: 620, height: 620).offset(x: 330, y: -250).accessibilityHidden(true)
            VStack(spacing: 22) {
                HStack(spacing: 12) { AlphaMark(size: 48); Text("Evee").font(.system(size: 35, weight: .bold)).foregroundStyle(AnimaTheme.aubergine) }
                VStack(spacing: 8) {
                    Text("Speak naturally. Stay in flow.").font(.system(size: 30, weight: .bold)).tracking(-0.7)
                    Text("Private dictation, meetings and voice memory. Everything runs on your Mac.")
                        .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
                }
                VStack(alignment: .leading, spacing: 13) {
                    feature("command", "Dictate anywhere", "Hold ⌥⌘Space, speak, release.")
                    feature("person.2.wave.2", "Capture meetings", "No bots join your call.")
                    feature("lock.shield", "Your voice stays yours", "No analytics or cloud processing.")
                }.animaCard().frame(maxWidth: 480)
                VStack(spacing: 10) {
                    Button { Task { await store.downloadSelectedModel() } } label: { Text(store.modelProgress?.status ?? "Download local model") }.buttonStyle(AlphaButtonStyle())
                    if let progress = store.modelProgress { ProgressView(value: progress.fraction).frame(width: 260) }
                    Text("Parakeet v3 · about 735 MB · Apple Silicon").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(40)
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(AnimaTheme.indigo).frame(width: 28, height: 28).background(AnimaTheme.indigo.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13, weight: .semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
