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
        .background(EveeVisual.canvas)
    }

    private var header: some View {
        EveePageHeader(
            "Meetings",
            subtitle: "Capture your microphone and call audio locally — no meeting bot"
        ) {
            if isRecordingMeeting {
                compactRecordingStatus(label: "Meeting recording")
            }
        } actions: {
            if isRecordingMeeting {
                HStack(spacing: EveeSpacing.small) {
                    Button("Discard", role: .destructive) { Task { await store.cancelCapture() } }
                        .buttonStyle(EveeDestructiveButtonStyle())
                        .help("Stop and permanently discard this meeting capture")
                        .accessibilityLabel("Discard the current meeting capture")
                        .accessibilityHint("Stops recording and permanently deletes the current local meeting audio.")
                    Button("Stop and transcribe") { Task { await store.finishCapture() } }
                        .buttonStyle(EveePrimaryButtonStyle())
                        .accessibilityLabel("Stop and transcribe the current meeting")
                }
            } else {
                Button { Task { await store.beginMeeting() } } label: {
                    Label(isProcessingMeeting ? "Processing meeting" : "Record meeting", systemImage: isProcessingMeeting ? "ellipsis" : "record.circle")
                }
                .buttonStyle(EveePrimaryButtonStyle())
                .disabled(store.captureState != .idle)
                .help(store.captureState == .idle ? "Start a local meeting capture" : "Finish the current capture first")
                .accessibilityLabel(isProcessingMeeting ? "Meeting transcription is in progress" : "Record a new meeting")
                .accessibilityHint("Starts local microphone and optional system-audio capture without joining the meeting.")
            }
        }
        .padding(.horizontal, EveeSpacing.xLarge)
        .padding(.top, EveeSpacing.xLarge)
    }

    private var recordingWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EveeSpacing.medium) {
                activeSessionAnchor

                EveePanel {
                    HStack(alignment: .top, spacing: EveeSpacing.medium) {
                        Image(systemName: store.isSystemAudioActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(store.isSystemAudioActive ? EveeVisual.success : EveeVisual.warning)
                            .font(.system(size: 17, weight: .semibold))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.isSystemAudioActive ? "Microphone and system audio are recording" : "Microphone-only recording")
                                .font(.system(size: 13, weight: .semibold))
                            Text(store.isSystemAudioActive
                                 ? "Evee is capturing microphone audio and all Mac system audio locally. Pause unrelated media and notifications; no participant or bot joins your call."
                                 : "Other speakers may be missing. Enable system-audio capture in Settings and allow Screen & System Audio Recording to include them.")
                                .font(EveeTypography.metadata)
                                .foregroundStyle(EveeVisual.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        if !store.isSystemAudioActive {
                            Button("Open Privacy Settings", action: openScreenRecordingSettings)
                                .buttonStyle(EveeSecondaryButtonStyle())
                                .controlSize(.small)
                                .accessibilityLabel("Open Screen and System Audio Recording settings")
                                .accessibilityHint("Opens System Settings so Evee can include other meeting participants in local capture.")
                        }
                    }

                    if let liveMeetingStatus = store.liveMeetingStatus {
                        Text(liveMeetingStatus)
                            .font(EveeTypography.metadata)
                            .foregroundStyle(EveeVisual.secondaryText)
                            .accessibilityLabel(liveMeetingStatus)
                    }

                    if let warning = store.microphoneHealthWarning {
                        Label(warning, systemImage: "mic.slash.fill")
                            .font(EveeTypography.metadata)
                            .foregroundStyle(EveeVisual.warning)
                            .accessibilityLabel("Microphone warning: \(warning)")
                    }
                }

                EveePanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live transcript")
                            .font(EveeTypography.sectionTitle)
                        if store.liveMeetingTranscript.isEmpty {
                            Text("Listening for speech…")
                                .font(EveeTypography.body)
                                .foregroundStyle(EveeVisual.tertiaryText)
                        } else {
                            ForEach(store.liveMeetingTranscript.suffix(12)) { update in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(liveTimestamp(update.timestamp))
                                        .font(EveeTypography.timestamp)
                                        .foregroundStyle(EveeVisual.secondaryText)
                                        .frame(width: 36, alignment: .leading)
                                    Text(update.channel == .microphone ? "You" : "Others")
                                        .font(EveeTypography.metadata)
                                        .foregroundStyle(update.channel == .microphone ? AnimaTheme.indigo : AnimaTheme.violet)
                                        .frame(width: 48, alignment: .leading)
                                    Text(update.text)
                                        .font(EveeTypography.body)
                                        .foregroundStyle(update.isConfirmed ? EveeVisual.primaryText : EveeVisual.secondaryText)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                }

                EveePanel {
                    VStack(alignment: .leading, spacing: EveeSpacing.medium) {
                        TextField("Meeting title", text: $store.meetingTitle)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Meeting title")

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live notes").font(EveeTypography.sectionTitle)
                            TextEditor(text: $store.meetingNotes)
                                .font(EveeTypography.body)
                                .frame(minHeight: 250)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(EveeVisual.elevatedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius))
                                .overlay(alignment: .topLeading) {
                                    if store.meetingNotes.isEmpty {
                                        Text("Take notes while Evee listens…")
                                            .font(EveeTypography.body)
                                            .foregroundStyle(EveeVisual.tertiaryText)
                                            .padding(13)
                                            .allowsHitTesting(false)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .accessibilityLabel("Live meeting notes")
                            }
                    }
                }
            }
            .padding(.horizontal, EveeSpacing.xLarge)
            .padding(.bottom, EveeSpacing.xLarge)
        }
    }

    private var activeSessionAnchor: some View {
        EveePanel(isElevated: true) {
            VStack(alignment: .leading, spacing: EveeSpacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recording meeting")
                        .font(EveeTypography.sectionTitle)
                        .foregroundStyle(EveeVisual.primaryText)
                    Spacer()
                    if let startedAt = recordingStartedAt {
                        Text(startedAt, style: .timer)
                            .font(EveeTypography.timestamp)
                            .monospacedDigit()
                            .foregroundStyle(EveeVisual.secondaryText)
                            .accessibilityLabel("Elapsed meeting recording time")
                            .accessibilityValue(AccessibilityCopy.elapsedRecordingTime(startedAt: startedAt, now: .now))
                    }
                }
                VoiceThread(
                    presentation: VoiceThreadPresentation.make(
                        phase: store.systemVoiceStatus.phase,
                        level: captureLevel
                    )
                )
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func compactRecordingStatus(label: String) -> some View {
        HStack(spacing: EveeSpacing.small) {
            VoiceThread(
                presentation: VoiceThreadPresentation.make(
                    phase: store.systemVoiceStatus.phase,
                    level: captureLevel
                ),
                lineWidth: 1.5
            )
            .frame(width: 72, height: 20)
            EveeStatusChip(label: label, systemImage: "record.circle.fill", tone: .accent)
            if let startedAt = recordingStartedAt {
                Text(startedAt, style: .timer)
                    .font(EveeTypography.timestamp)
                    .monospacedDigit()
                    .foregroundStyle(EveeVisual.secondaryText)
                    .accessibilityLabel("Elapsed recording time")
                    .accessibilityValue(AccessibilityCopy.elapsedRecordingTime(startedAt: startedAt, now: .now))
            }
        }
        .accessibilityElement(children: .contain)
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

    private var recordingStartedAt: Date? {
        guard case .recording(let startedAt, _) = store.captureState else { return nil }
        return startedAt
    }

    private var captureLevel: Double? {
        guard case .recording(_, let level) = store.captureState else { return nil }
        return Double(level)
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
