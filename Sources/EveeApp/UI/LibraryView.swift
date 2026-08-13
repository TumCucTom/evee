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
                            Button("Stop and save") { Task { await store.finishCapture() } }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .keyboardShortcut(.return, modifiers: [])
                        } else {
                            Button { Task { await store.beginMemo() } } label: { Label("New memo", systemImage: "waveform") }
                                .buttonStyle(AlphaButtonStyle())
                                .disabled(store.captureState != .idle || store.isTerminationCheckpointActive)
                                .help(store.captureState == .idle ? "Record a private voice memo" : "Finish the current capture first")
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
                        HStack(spacing: 10) {
                            Image(systemName: capture.kind == .meeting ? "person.2.wave.2" : capture.kind == .memo ? "waveform" : "text.cursor")
                                .frame(width: 24)
                                .foregroundStyle(AnimaTheme.violet)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Interrupted \(capture.kind.rawValue)")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(capture.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(capture.tracks.count) audio \(capture.tracks.count == 1 ? "track" : "tracks")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Discard", role: .destructive) {
                                Task { await store.discardRecovery(capture) }
                            }
                            .controlSize(.small)
                            .disabled(store.captureState != .idle || store.isTerminationCheckpointActive)
                            Button("Transcribe") {
                                Task { await store.recover(capture) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(
                                store.captureState != .idle
                                    || store.isTerminationCheckpointActive
                                    || !capture.tracks.contains(where: { $0.role == .microphone })
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
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
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
        RecordRow(record: record, snippet: searchSnippet(record))
            .tag(record.id)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func searchSnippet(_ record: WorkspaceRecord) -> String? {
        let query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let source = [record.text, record.notes, record.tags.joined(separator: " ")].joined(separator: "\n")
        guard let match = source.range(of: query, options: .caseInsensitive) else { return String(source.prefix(180)) }
        let start = source.index(match.lowerBound, offsetBy: -70, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(match.upperBound, offsetBy: 110, limitedBy: source.endIndex) ?? source.endIndex
        let prefix = start == source.startIndex ? "" : "…"
        let suffix = end == source.endIndex ? "" : "…"
        return prefix + source[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    private var isRecordingMemo: Bool {
        guard store.captureKind == .memo, case .recording = store.captureState else { return false }
        return true
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
        .accessibilityLabel("\(record.kind.rawValue.capitalized), \(record.title), \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private var icon: String { switch record.kind { case .dictation: "text.cursor"; case .meeting: "person.2.wave.2"; case .memo: "waveform" } }
    private var colour: Color { record.kind == .meeting ? AnimaTheme.violet : record.kind == .memo ? AnimaTheme.magenta : AnimaTheme.indigo }
}
