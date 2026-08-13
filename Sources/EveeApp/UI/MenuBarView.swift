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
                Label(status, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColour)
            }
            Divider()

            switch store.captureState {
            case .starting:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Preparing \(captureName)…").font(.caption)
                }
                Button("Cancel", role: .destructive) { Task { await store.cancelCapture() } }
            case .recording:
                Text("Recording \(captureName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Discard", role: .destructive) { Task { await store.cancelCapture() } }
                    Button("Stop and transcribe") { Task { await store.finishCapture() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            case .transcribing, .delivering:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(store.captureState == .transcribing ? "Transcribing locally…" : "Inserting text…")
                        .font(.caption)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                Button("Open Evee", action: showMainWindow)
            case .checkpointed(let message):
                Label(message, systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(3)
                HStack {
                    Button("Open Recovery") {
                        store.openCheckpointedRecovery()
                    }
                    Button("Retry Quit") { NSApp.terminate(nil) }
                }
            case .idle:
                Button("Start dictation") { Task { await store.beginDictation() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AnimaTheme.indigo)
                Button("Transform selected text") { Task { await store.beginSelectionTransform() } }
                Button("Record meeting") { Task { await store.beginMeeting() } }
                Button("Record memo") { Task { await store.beginMemo() } }
            }

            Divider()
            Text("Use your configured dictation or transform shortcut in any app")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Evee", action: showMainWindow)
                .keyboardShortcut(",", modifiers: .command)
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

    private var status: String {
        switch store.captureState {
        case .idle: "Ready"
        case .starting: "Starting"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .delivering: "Inserting"
        case .checkpointed: "Protected"
        case .failed: "Error"
        }
    }

    private var statusIcon: String {
        switch store.captureState {
        case .idle: "checkmark.circle.fill"
        case .starting: "waveform.circle"
        case .recording: "record.circle"
        case .transcribing, .delivering: "ellipsis.circle"
        case .checkpointed: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColour: Color {
        switch store.captureState {
        case .idle: .green
        case .starting: .secondary
        case .recording: .red
        case .checkpointed: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }
}
