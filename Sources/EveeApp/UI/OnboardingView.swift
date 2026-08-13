import AppKit
import EveeCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var focusedTarget: OnboardingFocusTarget?

    private var presentation: OnboardingPresentation { store.onboardingPresentation }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AnimaTheme.paper, AnimaTheme.cloud.opacity(0.74)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            Circle()
                .stroke(AnimaTheme.violet.opacity(0.10), lineWidth: 2)
                .frame(width: 620, height: 620)
                .offset(x: 330, y: -250)
                .accessibilityHidden(true)

            GeometryReader { proxy in
                ScrollView {
                    ViewThatFits(in: .vertical) {
                        onboardingContent(spacing: 22, padding: 40, showsFeatures: true)
                            .frame(minHeight: proxy.size.height)
                        onboardingContent(spacing: 14, padding: 20, showsFeatures: false)
                            .frame(minHeight: proxy.size.height)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear(perform: restoreFocus)
        .onChange(of: presentation.focusTarget) { _, _ in restoreFocus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPermissionState()
            restoreFocus()
        }
    }

    private func onboardingContent(
        spacing: CGFloat,
        padding: CGFloat,
        showsFeatures: Bool
    ) -> some View {
        VStack(spacing: spacing) {
            HStack(spacing: 12) {
                EveeMark(size: showsFeatures ? 48 : 40)
                Text("Evee")
                    .font(.system(size: showsFeatures ? 35 : 30, weight: .bold))
                    .foregroundStyle(AnimaTheme.aubergine)
            }
            VStack(spacing: 8) {
                Text("Speak naturally. Stay in flow.")
                    .font(.system(size: showsFeatures ? 30 : 24, weight: .bold))
                    .tracking(-0.7)
                Text("Private dictation, meetings and voice memory. Everything runs on your Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
            if showsFeatures {
                VStack(alignment: .leading, spacing: 13) {
                    feature("command", "Dictate anywhere", "Hold ⌥⌘Space, speak, release.")
                    feature("person.2.wave.2", "Capture meetings", "No bots join your call.")
                    feature("lock.shield", "Your voice stays yours", "No analytics or cloud processing.")
                }
                .animaCard()
                .frame(maxWidth: 480)
            }
            VStack(spacing: 10) {
                permissionRow(
                    title: "Microphone",
                    state: store.microphonePermissionState,
                    focus: store.microphonePermissionState == .denied ? .microphoneRecovery : .microphoneRequest,
                    actionTitle: presentation.microphoneActionTitle,
                    accessibilityLabel: presentation.microphoneAccessibilityLabel,
                    accessibilityHint: presentation.microphoneAccessibilityHint
                ) {
                    if store.microphonePermissionState == .denied {
                        store.openMicrophoneSettings()
                    } else {
                        Task { await store.requestMicrophonePermission() }
                    }
                }
                permissionRow(
                    title: "Accessibility",
                    state: store.accessibilityPermissionState,
                    focus: .accessibilityRequest,
                    actionTitle: presentation.accessibilityActionTitle,
                    accessibilityLabel: presentation.accessibilityAccessibilityLabel,
                    accessibilityHint: presentation.accessibilityAccessibilityHint
                ) {
                    store.requestAccessibilityPermission()
                }
            }
            .animaCard()
            .frame(maxWidth: 480)

            VStack(spacing: 10) {
                modelDownloadControl
                Text("Parakeet v3 · about 735 MB · Apple Silicon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(padding)
    }

    @ViewBuilder
    private var modelDownloadControl: some View {
        switch presentation.modelAction {
        case .download, .retry:
            Button(presentation.modelActionTitle ?? "Download") {
                store.startModelDownload()
            }
            .buttonStyle(AlphaButtonStyle())
            .disabled(!store.microphonePermissionGranted || !store.accessibilityPermissionGranted)
            .focused($focusedTarget, equals: .modelAction)
            .accessibilityLabel(presentation.modelAccessibilityLabel)
            .accessibilityValue(presentation.modelAccessibilityValue ?? "")
            .accessibilityHint(presentation.modelAccessibilityHint)
        case .cancel:
            Button(presentation.modelActionTitle ?? "Cancel") {
                store.cancelModelDownload()
            }
            .buttonStyle(AlphaButtonStyle())
            .focused($focusedTarget, equals: .modelAction)
            .accessibilityLabel(presentation.modelAccessibilityLabel)
            .accessibilityValue(presentation.modelAccessibilityValue ?? "")
            .accessibilityHint(presentation.modelAccessibilityHint)
            ProgressView(value: store.modelProgress?.fraction ?? 0)
                .frame(width: 260)
                .accessibilityLabel("Local model download progress")
                .accessibilityValue(presentation.modelAccessibilityValue ?? "Starting")
        case .none:
            if case .cancelling = onboardingModelState {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(presentation.modelAccessibilityLabel)
                    .accessibilityValue(presentation.modelAccessibilityValue ?? "Cancelling")
            } else {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(presentation.modelAccessibilityLabel)
                    .accessibilityValue(presentation.modelAccessibilityValue ?? "Ready")
                    .accessibilityHint(presentation.modelAccessibilityHint)
            }
        }
    }

    private var onboardingModelState: OnboardingModelState {
        switch store.modelDownloadState {
        case .idle:
            store.modelDownloadNeedsRetry
                ? .failed("The previous model download did not finish.")
                : .idle
        case .downloading(_, let progress):
            .downloading(fraction: progress?.fraction ?? 0, status: progress?.status ?? "Starting")
        case .failed(_, let message): .failed(message)
        case .ready: .ready
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(AnimaTheme.indigo)
                .frame(width: 28, height: 28)
                .background(AnimaTheme.indigo.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(
        title: String,
        state: PermissionState,
        focus: OnboardingFocusTarget,
        actionTitle: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state == .granted ? .green : AnimaTheme.indigo)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(permissionStatus(for: title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .focused($focusedTarget, equals: focus)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityHint(accessibilityHint)
            }
        }
    }

    private func permissionStatus(for title: String) -> String {
        title == "Microphone" ? presentation.microphoneStatus : presentation.accessibilityStatus
    }

    private func restoreFocus() {
        DispatchQueue.main.async {
            focusedTarget = presentation.focusTarget
        }
    }
}
