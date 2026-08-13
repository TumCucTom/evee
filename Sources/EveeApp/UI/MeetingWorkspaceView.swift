import AppKit
import EveeCore
import SwiftUI

struct MeetingWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            header

            if isStartingMeeting {
                startingCard
            } else if isRecordingMeeting {
                recordingWorkspace
            } else if isProcessingMeeting {
                processingCard
            } else {
                VStack(spacing: 0) {
                    if let warning = store.meetingRecoveryWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AnimaTheme.raisedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            .accessibilityLabel("Meeting recovery warning: \(warning)")
                    }
                    if store.hasMeetingDraft { restoredDraftCard }
                    LibraryView(title: "Past meetings", kind: .meeting, showsHeader: false)
                }
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
                    .accessibilityLabel("Discard the current meeting capture")
                    .accessibilityHint("Stops recording and permanently deletes the current local meeting audio.")
                Button("Stop and transcribe") { Task { await store.finishCapture() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.return, modifiers: [])
                    .accessibilityLabel("Stop and transcribe the current meeting")
            } else {
                Button { Task { await store.beginMeeting() } } label: {
                    Label(isProcessingMeeting ? "Processing meeting" : "Record meeting", systemImage: isProcessingMeeting ? "ellipsis" : "record.circle")
                }
                .buttonStyle(AlphaButtonStyle())
                .disabled(store.captureState != .idle)
                .help(store.captureState == .idle ? "Start a local meeting capture" : "Finish the current capture first")
                .accessibilityLabel(isProcessingMeeting ? "Meeting transcription is in progress" : "Record a new meeting")
                .accessibilityHint("Starts local microphone and optional system-audio capture without joining the meeting.")
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
                             ? "Evee is capturing microphone audio and all Mac system audio locally. Pause unrelated media and notifications; no participant or bot joins your call."
                             : "Other speakers may be missing. Enable system-audio capture in Settings and allow Screen & System Audio Recording to include them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !store.isSystemAudioActive {
                        Button("Open Privacy Settings", action: openScreenRecordingSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Open Screen and System Audio Recording settings")
                            .accessibilityHint("Opens System Settings so Evee can include other meeting participants in local capture.")
                    }
                }
                .accessibilityElement(children: .combine)

                Divider()

                if let liveMeetingStatus = store.liveMeetingStatus {
                    Text(liveMeetingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(liveMeetingStatus)
                }

                if let warning = store.microphoneHealthWarning {
                    Label(warning, systemImage: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Microphone warning: \(warning)")
                }

                if !store.liveMeetingTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live transcript").font(.system(size: 12, weight: .semibold))
                        ForEach(store.liveMeetingTranscript.suffix(12)) { update in
                            HStack(alignment: .top, spacing: 8) {
                                Text(liveTimestamp(update.timestamp))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .leading)
                                Text(update.channel == .microphone ? "You" : "Others")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(update.channel == .microphone ? AnimaTheme.indigo : AnimaTheme.violet)
                                    .frame(width: 48, alignment: .leading)
                                Text(update.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(update.isConfirmed ? .primary : .secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(10)
                    .background(AnimaTheme.raisedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .contain)
                }

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

    private var startingCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Preparing meeting audio").font(.system(size: 13, weight: .semibold))
                Text("Microphone or system-audio permission may be waiting. You can cancel safely.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .destructive) { Task { await store.cancelCapture() } }
                .accessibilityLabel("Cancel meeting audio preparation")
                .accessibilityHint("Stops preparation and removes this incomplete capture.")
        }
        .animaCard()
        .padding(20)
    }

    private var restoredDraftCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(recoveredNotesLabel, systemImage: "doc.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AnimaTheme.indigo)
                Spacer()
                Button("Discard notes", role: .destructive) {
                    Task { await store.discardMeetingDraft() }
                }
                .controlSize(.small)
                .accessibilityLabel("Discard recovered meeting notes")
                .accessibilityHint("Permanently removes the restored title and notes.")
            }
            Text("These notes were restored from your last interrupted meeting and continue to save automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Meeting title", text: $store.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Recovered meeting title")
            TextEditor(text: $store.meetingNotes)
                .font(.system(size: 13))
                .frame(minHeight: 80, maxHeight: 130)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(AnimaTheme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(recoveredNotesLabel)
        }
        .animaCard()
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
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

    private var isStartingMeeting: Bool {
        guard store.captureKind == .meeting, case .starting = store.captureState else { return false }
        return true
    }

    private var isProcessingMeeting: Bool {
        guard store.captureKind == .meeting else { return false }
        return switch store.captureState {
        case .transcribing, .delivering: true
        default: false
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private var recoveredNotesLabel: String {
        guard let startedAt = store.meetingDraftStartedAt else { return "Recovered meeting notes" }
        return AccessibilityCopy.recoveredNotes(startedAt: startedAt)
    }

    private func liveTimestamp(_ date: Date) -> String {
        guard case .recording(let startedAt, _) = store.captureState else { return "00:00" }
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
