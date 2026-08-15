import EveeCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingMetadataResetConfirmation = false
    let title: String
    let kind: WorkspaceRecordKind?
    let showsHeader: Bool

    init(title: String, kind: WorkspaceRecordKind?, showsHeader: Bool = true) {
        self.title = title
        self.kind = kind
        self.showsHeader = showsHeader
    }

    private var rows: [WorkspaceRecord] {
        let records = store.filteredRecords
        return kind.map { value in records.filter { $0.kind == value } } ?? records
    }

    private var recoveryRows: [CaptureRecoveryManifest] {
        kind.map { selectedKind in
            store.recoverableCaptures.filter { $0.kind == selectedKind }
        } ?? store.recoverableCaptures
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                EveePageHeader(title, subtitle: "Your local voice archive") {
                    if kind == .memo, isRecordingMemo {
                        memoRecordingStatus
                    }
                } actions: {
                    if kind == .memo {
                        if isRecordingMemo {
                            EveeAdaptiveActionRow {
                                Button("Discard", role: .destructive) { Task { await store.cancelCapture() } }
                                    .buttonStyle(EveeDestructiveButtonStyle())
                                    .help("Stop and permanently discard this memo")
                                    .accessibilityLabel("Discard the current memo recording")
                                    .accessibilityHint("Stops recording and permanently deletes this memo capture.")
                                Button("Stop and save") { Task { await store.finishCapture() } }
                                    .buttonStyle(EveeCaptureButtonStyle())
                                    .keyboardShortcut(.return, modifiers: .command)
                                    .accessibilityLabel("Stop and save the current memo recording")
                            }
                        } else {
                            Button { Task { await store.beginMemo() } } label: { Label("New memo", systemImage: "waveform") }
                                .buttonStyle(EveeCaptureButtonStyle())
                                .disabled(store.captureState != .idle || store.isTerminationCheckpointActive)
                                .help(store.captureState == .idle ? "Record a private voice memo" : "Finish the current capture first")
                                .accessibilityLabel("Record a new private memo")
                                .accessibilityHint("Starts a local microphone recording.")
                        }
                    }
                }
                .padding(.horizontal, EveeSpacing.xLarge)
                .padding(.top, EveeSpacing.xLarge)
            }

            EveeSearchField(text: $store.search, prompt: "Search everything you have said…")
                .padding(.horizontal, EveeSpacing.xLarge)
                .padding(.bottom, EveeSpacing.medium)

            List(selection: $store.selectedRecordID) {
                if kind == nil, let warning = store.libraryRecoveryWarning {
                    libraryMetadataRecoveryPanel(warning)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(
                            top: EveeSpacing.small,
                            leading: EveeSpacing.xLarge,
                            bottom: EveeSpacing.medium,
                            trailing: EveeSpacing.xLarge
                        ))
                }

                if !recoveryRows.isEmpty {
                    recoveryPanel
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(
                            top: EveeSpacing.small,
                            leading: EveeSpacing.xLarge,
                            bottom: EveeSpacing.medium,
                            trailing: EveeSpacing.xLarge
                        ))
                }

                if rows.isEmpty {
                    EveeEmptyState(
                        store.search.isEmpty ? "Your voice workspace is ready" : "Nothing matched",
                        message: store.search.isEmpty ? "Hold ⌥⌘Space in any app to create your first dictation." : "Try a person, project, phrase or app name."
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    if store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(rows) { record in recordRow(record) }
                    } else {
                        ForEach(WorkspaceRecordKind.allCases, id: \.self) { resultKind in
                            let matches = rows.filter { $0.kind == resultKind }
                            if !matches.isEmpty {
                                Section("\(resultKind.rawValue.capitalized)s · \(matches.count)") {
                                    ForEach(matches) { record in recordRow(record) }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(EveeCanvas())
        .confirmationDialog(
            "Reset library metadata protection?",
            isPresented: $showingMetadataResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset metadata protection", role: .destructive) {
                Task { await store.resetLibraryMetadataProtection() }
            }
            .accessibilityLabel("Confirm reset of library metadata protection")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel library metadata protection reset")
        } message: {
            Text("The preserved corrupt copy will remain, and no audio will be deleted by this action. Future maintenance may then remove audio that current library metadata does not reference.")
        }
    }

    private func libraryMetadataRecoveryPanel(_ warning: String) -> some View {
        VStack(alignment: .leading, spacing: EveeSpacing.medium) {
            Label("Review preserved library data", systemImage: "externaldrive.badge.exclamationmark")
                .font(EveeTypography.sectionTitle)
                .foregroundStyle(EveeVisual.warning)
            Text(warning)
                .font(EveeTypography.metadata)
                .foregroundStyle(EveeVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            EveeAdaptiveActionRow {
                Button("Show in Finder") { store.revealPreservedLibraryFiles() }
                    .controlSize(.small)
                    .accessibilityLabel("Show preserved library data in Finder")
                    .accessibilityHint("Opens the private folder containing files Evee preserved for manual review.")
                Button("Keep preserved data") { store.dismissLibraryRecoveryWarning() }
                    .controlSize(.small)
                    .accessibilityLabel("Dismiss preserved library data warning")
                    .accessibilityHint("Keeps the preserved data and hides this warning.")
                if store.recordsQuarantineActive {
                    Button("Reset library metadata", role: .destructive) {
                        showingMetadataResetConfirmation = true
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Reset library metadata protection")
                    .accessibilityHint("Shows a confirmation before allowing future cleanup of unreferenced audio.")
                }
            }
        }
        .padding(EveeSpacing.large)
        .background(EveeVisual.surface)
        .clipShape(RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous)
                .stroke(EveeVisual.warning.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var recoveryPanel: some View {
        VStack(alignment: .leading, spacing: EveeSpacing.medium) {
            Label("Recover interrupted captures", systemImage: "arrow.counterclockwise.circle.fill")
                .font(EveeTypography.sectionTitle)
                .foregroundStyle(EveeVisual.warning)
            Text("Evee found local audio that was not yet saved to your workspace.")
                .font(EveeTypography.metadata)
                .foregroundStyle(EveeVisual.secondaryText)

            ForEach(recoveryRows) { capture in
                VStack(alignment: .leading, spacing: EveeSpacing.small) {
                    HStack(spacing: EveeSpacing.small) {
                        Image(systemName: capture.kind == .meeting ? "person.2.wave.2" : capture.kind == .memo ? "waveform" : "text.cursor")
                            .frame(width: 24)
                            .foregroundStyle(EveeVisual.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: EveeSpacing.xSmall) {
                            Text("Interrupted \(capture.kind.rawValue)")
                                .font(EveeTypography.metadata)
                            Text(capture.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(EveeTypography.timestamp)
                                .foregroundStyle(EveeVisual.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }

                    ForEach(store.recoveryAssessments(for: capture)) { assessment in
                        HStack(alignment: .top, spacing: EveeSpacing.small) {
                            Image(systemName: assessment.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(assessment.isValid ? EveeVisual.success : EveeVisual.warning)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: EveeSpacing.xSmall) {
                                Text(recoveryTrackTitle(assessment.role))
                                    .font(EveeTypography.metadata)
                                Text(assessment.isValid ? "Playable and ready to recover" : assessment.failureReason ?? "This track is not playable")
                                    .font(EveeTypography.timestamp)
                                    .foregroundStyle(EveeVisual.secondaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    EveeAdaptiveActionRow {
                        Button("Discard", role: .destructive) {
                            Task { await store.discardRecovery(capture) }
                        }
                        .controlSize(.small)
                        .accessibilityLabel(AccessibilityCopy.discardRecovery(kind: capture.kind, startedAt: capture.startedAt))
                        .accessibilityHint("Permanently deletes the interrupted capture and its local audio.")

                        Button("Recover all valid") {
                            Task { await store.recover(capture, trackSelection: .allValid) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canRecoverAll(capture))
                        .accessibilityLabel("Recover all valid tracks from interrupted \(capture.kind.rawValue)")
                        .accessibilityHint("Transcribes every playable local audio track and saves one workspace record.")

                        if capture.tracks.contains(where: { $0.role == .microphone }) {
                            Button("Microphone") {
                                Task { await store.recover(capture, trackSelection: .roles([.microphone])) }
                            }
                            .controlSize(.small)
                            .disabled(!isValid(.microphone, in: capture))
                            .accessibilityLabel("Recover interrupted \(capture.kind.rawValue) from microphone audio")
                        }

                        if capture.tracks.contains(where: { $0.role == .system }) {
                            Button("System") {
                                Task { await store.recover(capture, trackSelection: .roles([.system])) }
                            }
                            .controlSize(.small)
                            .disabled(capture.kind != .meeting || !isValid(.system, in: capture))
                            .accessibilityLabel("Recover interrupted meeting from system audio")
                        }
                    }
                    .disabled(store.captureState != .idle || store.isTerminationCheckpointActive)
                }
                .padding(.top, EveeSpacing.small)
                .accessibilityElement(children: .contain)
            }
        }
        .padding(EveeSpacing.large)
        .background(EveeVisual.surface)
        .clipShape(RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous)
                .stroke(EveeVisual.warning.opacity(0.55), lineWidth: 1)
        }
    }

    private var memoRecordingStatus: some View {
        HStack(spacing: EveeSpacing.small) {
            VoiceThread(
                presentation: VoiceThreadPresentation.make(
                    phase: store.systemVoiceStatus.phase,
                    level: captureLevel
                ),
                lineWidth: 1.5
            )
            .frame(width: 72, height: 20)
            EveeStatusChip(label: "Memo recording", systemImage: "record.circle.fill", tone: .accent)
            if let startedAt = recordingStartedAt {
                Text(startedAt, style: .timer)
                    .font(EveeTypography.timestamp)
                    .monospacedDigit()
                    .foregroundStyle(EveeVisual.secondaryText)
                    .accessibilityLabel("Elapsed memo recording time")
                    .accessibilityValue(Text(startedAt, style: .timer))
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func recordRow(_ record: WorkspaceRecord) -> some View {
        RecordRow(
            record: record,
            snippet: store.indexedSnippet(for: record.id),
            isSelected: store.selectedRecordID == record.id
        )
            .tag(record.id)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
    }

    private var isRecordingMemo: Bool {
        guard store.captureKind == .memo, case .recording = store.captureState else { return false }
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

    private func isValid(_ role: AudioTrackRole, in capture: CaptureRecoveryManifest) -> Bool {
        store.recoveryAssessments(for: capture).contains { $0.role == role && $0.isValid }
    }

    private func canRecoverAll(_ capture: CaptureRecoveryManifest) -> Bool {
        let validRoles = Set(store.recoveryAssessments(for: capture).filter(\.isValid).map(\.role))
        guard !validRoles.isEmpty else { return false }
        return capture.kind == .meeting || validRoles.contains(.microphone)
    }

    private func recoveryTrackTitle(_ role: AudioTrackRole) -> String {
        switch role {
        case .microphone: "Microphone track"
        case .system: "System-audio track"
        case .mixed: "Mixed track"
        }
    }
}

private struct RecordRow: View {
    let record: WorkspaceRecord
    var snippet: String?
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: 24, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(snippet ?? record.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 5) {
                    Text(record.operation == .selectionTransform ? "Transform" : record.kind.rawValue.capitalized)
                    if let app = record.sourceApplication { Text("·"); Text(app) }
                    Text("·"); Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, EveeSpacing.medium)
        .padding(.vertical, EveeSpacing.small)
        .contentShape(Rectangle())
        .background(rowSurface)
        .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
        .shadow(color: EveeVisual.primaryText.opacity(isSelected ? 0.08 : 0), radius: isSelected ? 8 : 0, y: isSelected ? 2 : 0)
        .onHover { isHovering = $0 }
        .animation(EveeVisual.animation(.selection, reduceMotion: reduceMotion), value: isSelected)
        .animation(EveeVisual.animation(.selection, reduceMotion: reduceMotion), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilityCopy.recordRow(record: record, snippet: snippet))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var icon: String { switch record.kind { case .dictation: "text.cursor"; case .meeting: "person.2.wave.2"; case .memo: "waveform" } }
    private var colour: Color { record.kind == .meeting ? AnimaTheme.violet : record.kind == .memo ? AnimaTheme.magenta : AnimaTheme.indigo }
    private var rowSurface: Color {
        if isSelected { return EveeVisual.elevatedSurface }
        if isHovering { return EveeVisual.surface.opacity(0.72) }
        return .clear
    }
}
