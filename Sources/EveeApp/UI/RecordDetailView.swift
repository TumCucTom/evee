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
                    Button("Save") { Task { await store.update(draft) } }.buttonStyle(AlphaButtonStyle())
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }

                if draft.kind == .meeting {
                    section("Notes", subtitle: "Your notes stay distinct from the transcript") {
                        TextEditor(text: $draft.notes).font(.system(size: 13)).frame(minHeight: 130).scrollContentBackground(.hidden)
                    }
                }

                section(draft.kind == .meeting ? "Transcript" : "Text", subtitle: draft.rawText == draft.text ? nil : "Polished locally") {
                    TextEditor(text: $draft.text).font(.system(size: 14)).frame(minHeight: 260).scrollContentBackground(.hidden)
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

    private func section<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            content()
        }.animaCard()
    }
}
