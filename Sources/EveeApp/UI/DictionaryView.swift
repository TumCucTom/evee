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
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("How to write it", text: $replacement)
                    .accessibilityLabel("Written replacement")
                Button("Add") { add() }.buttonStyle(AlphaButtonStyle()).disabled(spoken.isEmpty || replacement.isEmpty)
            }.animaCard()

            if store.settings.dictionary.isEmpty {
                ContentUnavailableView("No custom words yet", systemImage: "text.book.closed", description: Text("Add people, medicines, products or internal terminology."))
            } else {
                List {
                    ForEach(store.settings.dictionary) { term in
                        HStack { Text(term.spoken); Spacer(); Image(systemName: "arrow.right").foregroundStyle(.tertiary); Text(term.replacement).fontWeight(.semibold) }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Replace \(term.spoken) with \(term.replacement)")
                    }.onDelete(perform: delete)
                }.scrollContentBackground(.hidden)
            }
        }.padding(20).background(AnimaTheme.paper)
    }

    private func add() {
        store.settings.dictionary.append(DictionaryTerm(spoken: spoken, replacement: replacement))
        spoken = ""; replacement = ""
        Task { await store.saveSettings() }
    }

    private func delete(_ offsets: IndexSet) {
        store.settings.dictionary.remove(atOffsets: offsets)
        Task { await store.saveSettings() }
    }
}
