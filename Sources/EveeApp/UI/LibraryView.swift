import EveeCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
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
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(AnimaTheme.ink)
                        Text("Your local voice archive").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if kind == .memo {
                        if isRecordingMemo {
                            Button("Discard", role: .destructive) { Task { await store.cancelCapture() } }
                                .buttonStyle(.bordered)
                                .help("Stop and permanently discard this memo")
                                .accessibilityLabel("Discard the current memo recording")
                                .accessibilityHint("Stops recording and permanently deletes this memo capture.")
                            Button("Stop and save") { Task { await store.finishCapture() } }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .keyboardShortcut(.return, modifiers: [])
                                .accessibilityLabel("Stop and save the current memo recording")
                        } else {
                            Button { Task { await store.beginMemo() } } label: { Label("New memo", systemImage: "waveform") }
                                .buttonStyle(AlphaButtonStyle())
                                .disabled(store.captureState != .idle || store.isTerminationCheckpointActive)
                                .help(store.captureState == .idle ? "Record a private voice memo" : "Finish the current capture first")
                                .accessibilityLabel("Record a new private memo")
                                .accessibilityHint("Starts a local microphone recording.")
                        }
                    }
                }
                .padding(20)
            }

            if !recoveryRows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Recover interrupted captures", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AnimaTheme.indigo)
                    Text("Evee found local audio that was not yet saved to your workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(recoveryRows) { capture in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 10) {
                                Image(systemName: capture.kind == .meeting ? "person.2.wave.2" : capture.kind == .memo ? "waveform" : "text.cursor")
                                    .frame(width: 24)
                                    .foregroundStyle(AnimaTheme.violet)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Interrupted \(capture.kind.rawValue)")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(capture.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            ForEach(store.recoveryAssessments(for: capture)) { assessment in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: assessment.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(assessment.isValid ? Color.green : Color.orange)
                                        .frame(width: 16)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recoveryTrackTitle(assessment.role))
                                            .font(.caption.weight(.semibold))
                                        Text(assessment.isValid ? "Playable and ready to recover" : assessment.failureReason ?? "This track is not playable")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }

                            HStack(spacing: 7) {
                                Button("Discard", role: .destructive) {
                                    Task { await store.discardRecovery(capture) }
                                }
                                .controlSize(.small)
                                .accessibilityLabel(AccessibilityCopy.discardRecovery(kind: capture.kind, startedAt: capture.startedAt))
                                .accessibilityHint("Permanently deletes the interrupted capture and its local audio.")

                                Spacer()

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
                            .disabled(
                                store.captureState != .idle
                                    || store.isTerminationCheckpointActive
                            )
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .animaCard()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything you have said…", text: $store.search)
                    .textFieldStyle(.plain)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AccessibilityCopy.clearSearch)
                    .accessibilityHint("Removes the current query and shows all workspace records.")
                }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(AnimaTheme.surface).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AnimaTheme.border))
            .padding(.horizontal, 20).padding(.bottom, 12)

            if rows.isEmpty {
                ContentUnavailableView(
                    store.search.isEmpty ? "Your voice workspace is ready" : "Nothing matched",
                    systemImage: store.search.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(store.search.isEmpty ? "Hold ⌥⌘Space in any app to create your first dictation." : "Try a person, project, phrase or app name.")
                )
            } else {
                List(selection: $store.selectedRecordID) {
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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AnimaTheme.paper)
    }

    @ViewBuilder
    private func recordRow(_ record: WorkspaceRecord) -> some View {
        RecordRow(record: record, snippet: store.indexedSnippet(for: record.id))
            .tag(record.id)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var isRecordingMemo: Bool {
        guard store.captureKind == .memo, case .recording = store.captureState else { return false }
        return true
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(colour)
                .frame(width: 30, height: 30).background(colour.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
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
        .padding(12).background(AnimaTheme.surface.opacity(0.88)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AnimaTheme.border.opacity(0.8)))
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilityCopy.recordRow(record: record, snippet: snippet))
    }

    private var icon: String { switch record.kind { case .dictation: "text.cursor"; case .meeting: "person.2.wave.2"; case .memo: "waveform" } }
    private var colour: Color { record.kind == .meeting ? AnimaTheme.violet : record.kind == .memo ? AnimaTheme.magenta : AnimaTheme.indigo }
}
