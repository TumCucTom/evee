import AppKit
import EveeCore
import SwiftUI

struct RecordDetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft: WorkspaceRecord
    @State private var confirmDelete = false

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
                    section("Speaker timeline", subtitle: "Speaker labels are generated from the available local audio channels") {
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
        .confirmationDialog("Delete this \(draft.kind.rawValue)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { Task { await store.delete(draft) } }
        } message: { Text("The local record and retained audio will be removed. This cannot be undone in Evee.") }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Label(draft.kind.rawValue.capitalized, systemImage: kindIcon)
            if let duration = draft.duration {
                Label(timestamp(duration), systemImage: "clock")
            }
            if let app = draft.sourceApplication, !app.isEmpty {
                Label(app, systemImage: "app")
            }
            if draft.audioRelativePath != nil {
                Label("Audio retained", systemImage: "internaldrive")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
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

    private func section<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            content()
        }.animaCard()
    }
}
