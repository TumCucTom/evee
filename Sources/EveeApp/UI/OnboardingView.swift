import EveeCore
import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [AnimaTheme.paper, AnimaTheme.cloud.opacity(0.74)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            Circle().stroke(AnimaTheme.violet.opacity(0.10), lineWidth: 2).frame(width: 620, height: 620).offset(x: 330, y: -250).accessibilityHidden(true)
            VStack(spacing: 22) {
                HStack(spacing: 12) { EveeMark(size: 48); Text("Evee").font(.system(size: 35, weight: .bold)).foregroundStyle(AnimaTheme.aubergine) }
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
                    permissionRow(
                        title: "Microphone",
                        granted: store.microphonePermissionGranted,
                        actionTitle: "Allow"
                    ) { Task { await store.requestMicrophonePermission() } }
                    permissionRow(
                        title: "Accessibility",
                        granted: store.accessibilityPermissionGranted,
                        actionTitle: "Open Settings"
                    ) { store.requestAccessibilityPermission() }
                }
                .animaCard()
                .frame(maxWidth: 480)
                VStack(spacing: 10) {
                    modelDownloadControl
                    Text("Parakeet v3 · about 735 MB · Apple Silicon").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(40)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPermissionState()
        }
    }

    @ViewBuilder
    private var modelDownloadControl: some View {
        switch store.modelDownloadState {
        case .idle:
            Button(store.modelDownloadNeedsRetry ? "Retry" : "Download") {
                store.startModelDownload()
            }
            .buttonStyle(AlphaButtonStyle())
            .disabled(!store.microphonePermissionGranted || !store.accessibilityPermissionGranted)
            .accessibilityLabel(store.modelDownloadNeedsRetry ? "Retry local model download" : "Download local model")
            .accessibilityValue(store.modelDownloadNeedsRetry ? "Previous download did not finish" : "Not downloaded")
            .accessibilityHint("Downloads and prepares the selected speech model on this Mac.")
        case .downloading(_, let progress):
            Button("Cancel") {
                store.cancelModelDownload()
            }
            .buttonStyle(AlphaButtonStyle())
            .accessibilityLabel("Cancel local model download")
            .accessibilityValue(modelDownloadAccessibilityValue(progress))
            .accessibilityHint("Stops this download without deleting any completed model cache.")
            if let progress {
                ProgressView(value: progress.fraction)
                    .frame(width: 260)
                    .accessibilityLabel("Local model download progress")
                    .accessibilityValue(modelDownloadAccessibilityValue(progress))
            }
        case .failed(_, let message):
            Button("Retry") {
                store.startModelDownload()
            }
            .buttonStyle(AlphaButtonStyle())
            .disabled(!store.microphonePermissionGranted || !store.accessibilityPermissionGranted)
            .accessibilityLabel("Retry local model download")
            .accessibilityValue(message)
            .accessibilityHint("Attempts the local model download again.")
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Local model ready")
                .accessibilityValue("Ready")
                .accessibilityHint("The selected local speech model is downloaded and prepared.")
        }
    }

    private func modelDownloadAccessibilityValue(_ progress: ModelProgress?) -> String {
        guard let progress else { return "Starting" }
        return "\(Int((progress.fraction * 100).rounded())) percent, \(progress.status)"
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(AnimaTheme.indigo).frame(width: 28, height: 28).background(AnimaTheme.indigo.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13, weight: .semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : AnimaTheme.indigo)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if granted {
                Text("Ready").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
    }
}
