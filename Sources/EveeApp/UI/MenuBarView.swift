import AppKit
import EveeCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                EveeMark(size: 24)
                Text("Evee").font(.headline)
                Spacer()
                EveeStatusChip(
                    label: store.systemVoiceStatus.menuTitle,
                    systemImage: statusIcon,
                    tone: statusTone
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(menuBarPresentation.openAccessibilityLabel)
            VoiceThread(
                presentation: VoiceThreadPresentation.make(
                    phase: store.systemVoiceStatus.phase,
                    level: captureLevel
                ),
                lineWidth: 1.5
            )
            .frame(height: 22)
            Divider()
            Toggle("Privacy mode", isOn: $store.privacyModeEnabled)
                .accessibilityLabel(
                    PrivacyPresentation(enabled: store.privacyModeEnabled).accessibilityLabel
                )
                .accessibilityHint("Hides sensitive content in Evee windows for this session.")
            Text(PrivacyPresentation(enabled: store.privacyModeEnabled).windowProtectionCopy)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(store.systemVoiceStatus.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(EveeVisual.warning)
                    .lineLimit(3)
                    .accessibilityLabel("Capture warning: \(warning.message)")
            }

            switch store.captureState {
            case .starting:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Preparing \(captureName)…").font(.caption)
                }
                if store.systemVoiceStatus.availableActions.contains(.discard) {
                    Button("Discard", role: .destructive) { Task { await store.cancelCapture() } }
                        .accessibilityLabel("Discard preparation for \(captureName)")
                }
            case .recording:
                Text("Recording \(captureName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if store.systemVoiceStatus.availableActions.contains(.discard) {
                        Button("Discard", role: .destructive) { Task { await store.cancelCapture() } }
                            .accessibilityLabel("Discard \(captureName)")
                            .accessibilityHint("Stops recording and permanently deletes this capture.")
                    }
                    if store.systemVoiceStatus.availableActions.contains(.stopAndTranscribe) {
                        Button("Stop and transcribe") { Task { await store.finishCapture() } }
                            .buttonStyle(EveeCaptureButtonStyle())
                            .accessibilityLabel("Stop and transcribe \(captureName)")
                    }
                }
            case .transcribing, .delivering:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(store.captureState == .transcribing ? "Transcribing locally…" : "Inserting text…")
                        .font(.caption)
                }
            case .failed:
                Label("Capture needs attention. Open Evee for details.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(EveeVisual.warning)
                    .lineLimit(3)
                Button("Open Evee", action: showMainWindow)
                    .accessibilityLabel("Open Evee to review the capture error")
            case .checkpointed:
                Label("Capture protected. Open Recovery in Evee to review it.", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(EveeVisual.success)
                    .lineLimit(3)
                HStack {
                    Button("Open Recovery") {
                        store.openCheckpointedRecovery()
                    }
                    .accessibilityLabel("Open Evee capture recovery")
                    Button("Retry Quit") { NSApp.terminate(nil) }
                        .accessibilityLabel("Retry quitting Evee")
                }
            case .idle:
                Button("Start dictation") { Task { await store.beginDictation() } }
                    .buttonStyle(EveeCaptureButtonStyle())
                    .accessibilityLabel("Start a new dictation")
                Button("Transform selected text") { Task { await store.beginSelectionTransform() } }
                    .accessibilityLabel("Start a selected-text transform instruction")
                Button("Record meeting") { Task { await store.beginMeeting() } }
                    .accessibilityLabel("Start a new meeting recording")
                Button("Record memo") { Task { await store.beginMemo() } }
                    .accessibilityLabel("Start a new memo recording")
            }

            Divider()
            Text("Use your configured dictation or transform shortcut in any app")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Evee", action: showMainWindow)
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Open the Evee window")
        }
        .padding(14)
        .frame(width: 290)
    }

    private var captureName: String {
        if store.captureOperation == .selectionTransform { return "a transform instruction" }
        return switch store.captureKind {
        case .dictation: "a dictation"
        case .meeting: "a meeting"
        case .memo: "a memo"
        case nil: "audio"
        }
    }

    private var menuBarPresentation: MenuBarVoicePresentation {
        MenuBarVoicePresentation.make(status: store.systemVoiceStatus)
    }

    private var statusIcon: String {
        if !store.systemVoiceStatus.warnings.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        return switch store.systemVoiceStatus.phase {
        case .ready: "circle"
        case .wakeStarting, .captureStarting: "waveform.circle"
        case .wakeListening, .wakeStopping: "mic.circle.fill"
        case .recording: "record.circle"
        case .processing, .delivering: "ellipsis.circle"
        case .protected: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusTone: EveeStatusTone {
        EveeStatusTone(
            VoiceStatusTone.make(
                phase: store.systemVoiceStatus.phase,
                hasWarning: !store.systemVoiceStatus.warnings.isEmpty
            )
        )
    }

    private var captureLevel: Double? {
        guard case .recording(_, let level) = store.captureState else { return nil }
        return Double(level)
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.title == "Evee" && $0.styleMask.contains(.titled)
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openNewMainWindow()
        }
    }

    private func openNewMainWindow() {
        let menus = NSApp.mainMenu?.items.compactMap(\.submenu) ?? []
        for menu in menus {
            guard let index = menu.items.firstIndex(where: { item in
                item.keyEquivalent.lowercased() == "n" &&
                    item.keyEquivalentModifierMask.contains(.command)
            }) else { continue }
            menu.performActionForItem(at: index)
            return
        }
    }
}
