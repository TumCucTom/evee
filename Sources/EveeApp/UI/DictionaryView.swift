import EveeCore
import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var spoken = ""
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dictionary").font(.system(size: 22, weight: .bold)).foregroundStyle(AnimaTheme.ink)
                Text("Teach Evee names, acronyms and specialist terms").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("What it sounds like", text: $spoken)
                    .accessibilityLabel("Spoken form")
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("How to write it", text: $replacement)
                    .accessibilityLabel("Written replacement")
                Button("Add") { add() }
                    .buttonStyle(AlphaButtonStyle())
                    .disabled(spoken.isEmpty || replacement.isEmpty)
                    .accessibilityLabel("Add dictionary replacement")
                    .accessibilityHint("Adds the spoken and written forms to Evee's local dictionary.")
            }.animaCard()

            if store.settings.dictionary.isEmpty {
                ContentUnavailableView("No custom words yet", systemImage: "text.book.closed", description: Text("Add people, medicines, products or internal terminology."))
            } else {
                List {
                    ForEach(store.settings.dictionary) { term in
                        HStack {
                            Text(term.spoken)
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                            Text(term.replacement).fontWeight(.semibold)
                            Button(role: .destructive) { delete(term.id) } label: {
                                Image(systemName: "trash").accessibilityHidden(true)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(AccessibilityCopy.removeDictionaryTerm(spoken: term.spoken, replacement: term.replacement))
                            .accessibilityHint("Permanently removes this local dictionary entry.")
                        }
                            .accessibilityElement(children: .contain)
                    }
                }.scrollContentBackground(.hidden)
            }
        }.padding(20).background(AnimaTheme.paper)
    }

    private func add() {
        store.settings.dictionary.append(DictionaryTerm(spoken: spoken, replacement: replacement))
        spoken = ""; replacement = ""
        Task { await store.saveSettings() }
    }

    private func delete(_ id: UUID) {
        store.settings.dictionary.removeAll { $0.id == id }
        Task { await store.saveSettings() }
    }
}
