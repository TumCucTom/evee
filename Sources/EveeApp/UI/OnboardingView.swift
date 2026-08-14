import AppKit
import EveeCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var focusedTarget: OnboardingFocusTarget?

    private var presentation: OnboardingPresentation { store.onboardingPresentation }

    var body: some View {
        ZStack {
            EveeVisual.canvas.ignoresSafeArea()

            GeometryReader { proxy in
                let sceneLayout = OnboardingSceneLayout.forViewport(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
                let density = OnboardingLayoutMode.forViewportHeight(proxy.size.height)

                if sceneLayout == .twoZone {
                    HStack(alignment: .center, spacing: EveeSpacing.xLarge) {
                        brandVoiceRegion
                            .frame(maxWidth: .infinity, alignment: .leading)
                        readinessPanel
                            .frame(width: 388)
                    }
                    .padding(.horizontal, EveeSpacing.xxLarge)
                    .padding(.vertical, EveeSpacing.xLarge)
                    .frame(minHeight: proxy.size.height)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: density == .spacious ? EveeSpacing.xLarge : EveeSpacing.large) {
                            brandVoiceRegion
                            readinessPanel
                        }
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(density == .spacious ? EveeSpacing.xLarge : EveeSpacing.large)
                        .frame(minHeight: proxy.size.height)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear(perform: restoreFocus)
        .onChange(of: presentation.focusTarget) { _, _ in restoreFocus() }
        .onChange(of: presentation.modelAction) { previousAction, _ in
            guard let target = presentation.focusRestorationTarget(
                previousModelAction: previousAction
            ) else { return }
            restoreFocus(to: target)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPermissionState()
            restoreFocus()
        }
    }

    private var brandVoiceRegion: some View {
        VStack(alignment: .leading, spacing: EveeSpacing.large) {
            HStack(spacing: EveeSpacing.small) {
                EveeMark(size: 40)
                Text("Evee")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(EveeVisual.primaryText)
            }

            VStack(alignment: .leading, spacing: EveeSpacing.small) {
                Text("Speak naturally. Stay in flow.")
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(EveeVisual.primaryText)
                Text("Private dictation, meetings and voice memory. Everything runs on your Mac.")
                    .font(EveeTypography.body)
                    .foregroundStyle(EveeVisual.secondaryText)
                    .frame(maxWidth: 350, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VoiceThread(
                presentation: VoiceThreadPresentation.make(phase: .ready, level: nil),
                lineWidth: 1.5
            )
            .frame(maxWidth: 320)
            .frame(height: 24)

            VStack(alignment: .leading, spacing: EveeSpacing.small) {
                feature("command", "Dictate anywhere", "Hold ⌥⌘Space, speak, release.")
                feature("person.2.wave.2", "Capture meetings", "No bots join your call.")
                feature("lock.shield", "Your voice stays yours", "No analytics or cloud processing.")
            }
        }
    }

    private var readinessPanel: some View {
        EveePanel {
            VStack(spacing: 10) {
                Text("Set up your workspace")
                    .font(EveeTypography.sectionTitle)
                    .foregroundStyle(EveeVisual.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

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

                Divider()

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

                Divider()

                modelReadinessRow
            }
        }
    }

    private var modelReadinessRow: some View {
        HStack(alignment: .top, spacing: EveeSpacing.small) {
            Image(systemName: isModelReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isModelReady ? EveeVisual.success : EveeVisual.accent)
                .frame(width: 16, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: EveeSpacing.xSmall) {
                Text("Local speech model")
                    .font(.system(size: 13, weight: .semibold))
                Text("Parakeet v3 · about 735 MB · Apple Silicon")
                    .font(EveeTypography.metadata)
                    .foregroundStyle(EveeVisual.secondaryText)
                modelDownloadControl
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var modelDownloadControl: some View {
        switch presentation.modelAction {
        case .download, .cancel, .retry:
            modelActionButton
            if presentation.modelAction == .cancel {
                ProgressView(value: store.modelProgress?.fraction ?? 0)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Local model download progress")
                    .accessibilityValue(presentation.modelAccessibilityValue ?? "Starting")
            }
            Text(presentation.modelAccessibilityValue ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Local model download status")
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

    private var modelActionButton: some View {
        NativeOnboardingActionButton(
            title: presentation.modelActionTitle ?? "Download",
            accessibilityLabel: presentation.modelAccessibilityLabel,
            accessibilityHelp: presentation.modelAccessibilityHint,
            isEnabled: store.microphonePermissionGranted && store.accessibilityPermissionGranted,
            action: activateModelAction
        )
        .frame(minHeight: 36)
        .fixedSize()
        .focused($focusedTarget, equals: .modelAction)
    }

    private func activateModelAction() {
        switch presentation.modelAction {
        case .download, .retry:
            store.startModelDownload()
        case .cancel:
            store.cancelModelDownload()
        case .none:
            break
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
        case .cancelling: .cancelling
        case .failed(_, let message): .failed(message)
        case .ready: .ready
        }
    }

    private var isModelReady: Bool {
        if case .ready = onboardingModelState { true } else { false }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: EveeSpacing.small) {
            Image(systemName: icon)
                .foregroundStyle(EveeVisual.accent)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(EveeVisual.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(EveeTypography.metadata).foregroundStyle(EveeVisual.secondaryText)
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
                .foregroundStyle(state == .granted ? EveeVisual.success : EveeVisual.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(permissionStatus(for: title))
                    .font(EveeTypography.metadata)
                    .foregroundStyle(EveeVisual.secondaryText)
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
        restoreFocus(to: presentation.focusTarget)
    }

    private func restoreFocus(to target: OnboardingFocusTarget) {
        DispatchQueue.main.async {
            focusedTarget = target
        }
    }
}

@MainActor
private struct NativeOnboardingActionButton: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let accessibilityHelp: String
    let isEnabled: Bool
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.activate(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.refusesFirstResponder = false
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: NSButton, coordinator: Coordinator) {
        button.title = title
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHelp)
        button.toolTip = accessibilityHelp
        button.isEnabled = isEnabled
        button.bezelColor = Self.actionBezelColor
        button.contentTintColor = Self.actionForegroundColor
        coordinator.action = action
    }

    private static let actionBezelColor = NSColor(name: nil) { effectiveAppearance in
        let appearance = interfaceAppearance(for: effectiveAppearance)
        return nsColor(AccessibleActionPalette.gradientStops(for: appearance)[1])
    }

    private static let actionForegroundColor = NSColor(name: nil) { effectiveAppearance in
        nsColor(EveeVisualPalette.rgb(
            .primaryActionForeground,
            appearance: interfaceAppearance(for: effectiveAppearance)
        ))
    }

    private static func interfaceAppearance(for effectiveAppearance: NSAppearance) -> InterfaceAppearance {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private static func nsColor(_ color: EveeCore.RGBColor) -> NSColor {
        return NSColor(
            srgbRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: 1
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func activate(_ sender: NSButton) {
            action()
        }
    }
}
