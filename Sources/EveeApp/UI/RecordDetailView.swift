import AppKit
import EveeCore
import SwiftUI

struct RecordDetailView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var audioPlayer = RetainedAudioPlayer()
    @State private var draft: WorkspaceRecord
    @State private var confirmDelete = false
    @State private var selectedAudioPath = ""
    @State private var audioStatusMessage: String?

    init(record: WorkspaceRecord) { _draft = State(initialValue: record) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Title", text: $draft.title).font(.system(size: 22, weight: .bold)).textFieldStyle(.plain)
                        Text(draft.createdAt.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                    .help("Copy the finished text")
                    Button("Save") { Task { await store.update(draft) } }
                        .buttonStyle(AlphaButtonStyle())
                        .keyboardShortcut("s", modifiers: .command)
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this record")
                        .accessibilityLabel("Delete \(draft.kind.rawValue)")
                }

                metadata

                if let context = draft.context {
                    contextSection(context)
                }

                if !retainedAudioTracks.isEmpty {
                    retainedAudioSection
                }

                if draft.kind == .meeting,
                   let intelligence = draft.meetingIntelligence,
                   !intelligence.isEmpty {
                    meetingIntelligenceSection(intelligence)
                }

                if draft.kind == .meeting {
                    section("Notes", subtitle: "Your notes stay distinct from the transcript") {
                        TextEditor(text: $draft.notes)
                            .font(.system(size: 13))
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(AnimaTheme.raisedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Meeting notes")
                    }
                }

                section(draft.kind == .meeting ? "Transcript" : "Text", subtitle: draft.rawText == draft.text ? nil : "Polished locally") {
                    TextEditor(text: $draft.text)
                        .font(.system(size: 14))
                        .frame(minHeight: 260)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(AnimaTheme.raisedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(draft.kind == .meeting ? "Meeting transcript" : "Record text")
                }

                if !draft.segments.isEmpty {
                    section("Speaker timeline", subtitle: "Participant numbers are anonymous local speaker clusters, not identified people") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(draft.segments) { segment in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(timestamp(segment.start))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let speaker = segment.speaker {
                                            Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(AnimaTheme.violet)
                                        }
                                        if let provenance = segmentProvenance(segment) {
                                            Text(provenance)
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(segment.text).font(.system(size: 12)).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }

                if let raw = draft.rawText, raw != draft.text {
                    DisclosureGroup("Original transcript") { Text(raw).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8) }
                }
            }
            .padding(24)
        }
        .background(AnimaTheme.paper)
        .id(draft.id)
        .onAppear(perform: selectInitialAudioTrack)
        .onDisappear { audioPlayer.stop() }
        .confirmationDialog("Delete this \(draft.kind.rawValue)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { Task { await store.delete(draft) } }
        } message: { Text("The local record and retained audio will be removed. This cannot be undone in Evee.") }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Label(draft.kind.rawValue.capitalized, systemImage: kindIcon)
            if draft.operation == .selectionTransform {
                Label("Selection transform", systemImage: "wand.and.stars")
            }
            if let duration = draft.duration {
                Label(timestamp(duration), systemImage: "clock")
            }
            if let app = draft.sourceApplication, !app.isEmpty {
                Label(app, systemImage: "app")
            }
            if !retainedAudioTracks.isEmpty {
                Label("Audio retained", systemImage: "internaldrive")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func contextSection(_ context: WorkspaceContext) -> some View {
        section("Capture context", subtitle: "Stored locally because context history was enabled when this record was created") {
            VStack(alignment: .leading, spacing: 7) {
                if let applicationName = context.applicationName {
                    LabeledContent("Application", value: applicationName)
                }
                if let bundleIdentifier = context.bundleIdentifier {
                    LabeledContent("Bundle", value: bundleIdentifier)
                }
                if let windowTitle = context.windowTitle {
                    LabeledContent("Window", value: windowTitle)
                }
                if let document = context.document {
                    LabeledContent("Document", value: document)
                }
                if let focusedRole = context.focusedRole {
                    LabeledContent("Focused control", value: focusedRole)
                }
                if let selectedText = context.selectedText {
                    DisclosureGroup("Original selected text") {
                        Text(selectedText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func meetingIntelligenceSection(_ intelligence: MeetingIntelligence) -> some View {
        section("Meeting overview", subtitle: "Extracted locally from the timed source transcript; verify before acting") {
            VStack(alignment: .leading, spacing: 16) {
                if !intelligence.summary.isEmpty {
                    insightGroup("Transcript highlights", icon: "text.alignleft") {
                        ForEach(intelligence.summary, id: \.self) { item in
                            insightRow(item)
                        }
                    }
                }
                if !intelligence.decisions.isEmpty {
                    insightGroup("Decisions", icon: "checkmark.seal") {
                        ForEach(intelligence.decisions) { item in
                            evidenceRow(item)
                        }
                    }
                }
                if !intelligence.actionItems.isEmpty {
                    insightGroup("Action items", icon: "checklist") {
                        ForEach(intelligence.actionItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                evidenceRow(item)
                                HStack(spacing: 8) {
                                    if let assignee = item.assignee, !assignee.isEmpty {
                                        Label(assignee, systemImage: "person")
                                    }
                                    if let dueText = item.dueText, !dueText.isEmpty {
                                        Label(dueText, systemImage: "calendar")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func insightGroup<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AnimaTheme.violet)
            content()
        }
    }

    private func insightRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(AnimaTheme.violet.opacity(0.7))
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private func evidenceRow(_ item: MeetingInsight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let sourceTime = item.sourceTime {
                Text(timestamp(sourceTime))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(item.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private var retainedAudioTracks: [WorkspaceAudioTrack] {
        if !draft.audioTracks.isEmpty { return draft.audioTracks }
        guard let legacyPath = draft.audioRelativePath else { return [] }
        return [WorkspaceAudioTrack(role: .microphone, relativePath: legacyPath, duration: draft.duration)]
    }

    private var selectedAudioTrack: WorkspaceAudioTrack? {
        retainedAudioTracks.first { $0.relativePath == selectedAudioPath }
    }

    private var retainedAudioSection: some View {
        section("Retained audio", subtitle: "Play or export the local recording without uploading it") {
            VStack(alignment: .leading, spacing: 12) {
                if retainedAudioTracks.count > 1 {
                    Picker("Audio track", selection: $selectedAudioPath) {
                        ForEach(retainedAudioTracks) { track in
                            Text(audioTrackTitle(track.role)).tag(track.relativePath)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Retained audio track")
                    .onChange(of: selectedAudioPath) { _, _ in loadSelectedAudioTrack() }
                } else if let track = retainedAudioTracks.first {
                    Label(audioTrackTitle(track.role), systemImage: track.role == .system ? "speaker.wave.2" : "mic")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button(action: audioPlayer.togglePlayback) {
                        Label(audioPlayer.isPlaying ? "Pause" : "Play", systemImage: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(audioPlayer.loadedURL == nil)
                    .accessibilityHint(audioPlayer.isPlaying ? "Pauses retained audio" : "Plays retained audio")

                    Text(timestamp(audioPlayer.currentTime))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 42, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { audioPlayer.currentTime },
                            set: { audioPlayer.seek(to: $0) }
                        ),
                        in: 0...max(audioPlayer.duration, 0.01)
                    )
                    .disabled(audioPlayer.loadedURL == nil)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(timestamp(audioPlayer.currentTime)) of \(timestamp(audioPlayer.duration))")

                    Text(timestamp(audioPlayer.duration))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 42, alignment: .leading)

                    Button(action: exportSelectedAudioTrack) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedAudioTrack == nil)
                    .help("Export the selected retained audio track")
                }

                if let message = audioPlayer.errorMessage ?? audioStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(audioPlayer.errorMessage == nil ? AnimaTheme.ink.opacity(0.62) : Color.red)
                        .accessibilityLabel("Audio status: \(message)")
                }
            }
        }
    }

    private var kindIcon: String {
        switch draft.kind {
        case .dictation: "text.cursor"
        case .meeting: "person.2.wave.2"
        case .memo: "waveform"
        }
    }

    private func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func selectInitialAudioTrack() {
        guard let first = retainedAudioTracks.first else { return }
        if !retainedAudioTracks.contains(where: { $0.relativePath == selectedAudioPath }) {
            selectedAudioPath = first.relativePath
        }
        loadSelectedAudioTrack()
    }

    private func loadSelectedAudioTrack() {
        let path = selectedAudioPath
        guard !path.isEmpty else { return }
        audioPlayer.stop()
        audioStatusMessage = "Loading audio…"
        Task { @MainActor in
            do {
                let url = try await LibraryStore.shared.safeURL(forRelativePath: path)
                guard selectedAudioPath == path else { return }
                try audioPlayer.load(url)
                audioStatusMessage = nil
            } catch {
                guard selectedAudioPath == path else { return }
                audioStatusMessage = error.localizedDescription
            }
        }
    }

    private func exportSelectedAudioTrack() {
        guard let track = selectedAudioTrack else { return }
        let recordTitle = draft.title
        Task { @MainActor in
            do {
                let source = try await LibraryStore.shared.safeURL(forRelativePath: track.relativePath)
                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = exportFileName(title: recordTitle, role: track.role, fileExtension: source.pathExtension)
                panel.title = "Export retained audio"
                panel.prompt = "Export"
                guard panel.runModal() == .OK, let destination = panel.url else { return }

                try await Task.detached(priority: .utility) {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: destination.path) {
                        try manager.removeItem(at: destination)
                    }
                    try manager.copyItem(at: source, to: destination)
                }.value
                audioStatusMessage = "Exported \(audioTrackTitle(track.role).lowercased()) audio."
            } catch {
                audioStatusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func audioTrackTitle(_ role: AudioTrackRole) -> String {
        switch role {
        case .microphone: "Microphone"
        case .system: "Other participants"
        case .mixed: "Mixed"
        }
    }

    private func segmentProvenance(_ segment: TranscriptSegment) -> String? {
        switch segment.attribution {
        case .diarized:
            return "Anonymous speaker model"
        case .channel:
            return segment.channel.map(audioTrackTitle)
        case .unknown:
            return nil
        }
    }

    private func exportFileName(title: String, role: AudioTrackRole, fileExtension pathExtension: String) -> String {
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeTitle.isEmpty ? "Evee audio" : String(safeTitle.prefix(64))
        let suffix = pathExtension.isEmpty ? "audio" : pathExtension
        return "\(base) - \(audioTrackTitle(role)).\(suffix)"
    }

    private func section<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            content()
        }.animaCard()
    }
}
