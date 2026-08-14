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
            ViewThatFits(in: .horizontal) {
                HStack { dictionaryFields }
                VStack(alignment: .leading, spacing: EveeSpacing.small) { dictionaryFields }
            }
            .animaCard()

            if store.settings.dictionary.isEmpty {
                ContentUnavailableView("No custom words yet", systemImage: "text.book.closed", description: Text("Add people, medicines, products or internal terminology."))
            } else {
                List {
                    ForEach(store.settings.dictionary) { term in
                        HStack(alignment: .top, spacing: EveeSpacing.small) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(term.spoken)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(term.spoken)
                                Text(term.replacement)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(term.replacement)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var dictionaryFields: some View {
        TextField("What it sounds like", text: $spoken)
            .accessibilityLabel("Spoken form")
        Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        TextField("How to write it", text: $replacement)
            .accessibilityLabel("Written replacement")
        Button("Add") { add() }
            .buttonStyle(AlphaButtonStyle())
            .disabled(spoken.isEmpty || replacement.isEmpty)
            .accessibilityLabel("Add dictionary replacement")
            .accessibilityHint("Adds the spoken and written forms to Evee's local dictionary.")
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
