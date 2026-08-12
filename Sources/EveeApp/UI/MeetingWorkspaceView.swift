import AppKit
import EveeCore
import SwiftUI

struct MeetingWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            header

            if isRecordingMeeting {
                recordingWorkspace
            } else if isProcessingMeeting {
                processingCard
            } else {
                LibraryView(title: "Past meetings", kind: .meeting, showsHeader: false)
            }
        }
        .background(AnimaTheme.paper)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Meetings").font(.system(size: 22, weight: .bold)).foregroundStyle(AnimaTheme.ink)
                Text("Capture your microphone and call audio locally — no meeting bot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRecordingMeeting {
                Button("Discard", role: .destructive) { Task { await store.cancelCapture() } }
                    .buttonStyle(.bordered)
                    .help("Stop and permanently discard this meeting capture")
                Button("Stop and transcribe") { Task { await store.finishCapture() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.return, modifiers: [])
            } else {
                Button { Task { await store.beginMeeting() } } label: {
                    Label(isProcessingMeeting ? "Processing meeting" : "Record meeting", systemImage: isProcessingMeeting ? "ellipsis" : "record.circle")
                }
                .buttonStyle(AlphaButtonStyle())
                .disabled(store.captureState != .idle)
                .help(store.captureState == .idle ? "Start a local meeting capture" : "Finish the current capture first")
            }
        }
        .padding(20)
    }

    private var recordingWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: store.isSystemAudioActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.isSystemAudioActive ? .green : .orange)
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.isSystemAudioActive ? "Microphone and system audio are recording" : "Microphone-only recording")
                            .font(.system(size: 13, weight: .semibold))
                        Text(store.isSystemAudioActive
                             ? "Evee is capturing both sides locally. No participant or bot joins your call."
                             : "Other speakers may be missing. Allow Screen & System Audio Recording for complete meeting capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !store.isSystemAudioActive {
                        Button("Open Privacy Settings", action: openScreenRecordingSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .accessibilityElement(children: .combine)

                Divider()

                TextField("Meeting title", text: $store.meetingTitle)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Meeting title")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Live notes").font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $store.meetingNotes)
                        .font(.system(size: 13))
                        .frame(minHeight: 250)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(AnimaTheme.raisedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .topLeading) {
                            if store.meetingNotes.isEmpty {
                                Text("Take notes while Evee listens…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(13)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("Live meeting notes")
                }
            }
            .animaCard()
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var processingCard: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Creating your meeting record").font(.headline)
            Text("Transcription runs locally. You can leave this screen and keep working.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Creating your meeting record locally")
    }

    private var isRecordingMeeting: Bool {
        guard store.captureKind == .meeting, case .recording = store.captureState else { return false }
        return true
    }

    private var isProcessingMeeting: Bool {
        guard store.captureKind == .meeting else { return false }
        switch store.captureState {
        case .transcribing, .delivering: true
        default: false
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
