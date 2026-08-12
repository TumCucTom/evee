import Foundation

public struct MemoIntelligence: Codable, Hashable, Sendable {
    public var title: String
    public var highlights: [String]
    public var actionItems: [String]

    public init(title: String, highlights: [String] = [], actionItems: [String] = []) {
        self.title = title
        self.highlights = highlights
        self.actionItems = actionItems
    }

    public var isEmpty: Bool { title.isEmpty && highlights.isEmpty && actionItems.isEmpty }
}

public struct MemoIntelligencePipeline: Sendable {
    public init() {}

    public func generate(from text: String) -> MemoIntelligence {
        let sentences = sentenceList(text)
        let title = title(from: sentences.first ?? text)
        let highlights = Array(sentences.prefix(3))
        let actionMarkers = ["need to", "remember to", "follow up", "todo", "to do", "action:", "next step"]
        let actions = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return !lower.hasSuffix("?") && actionMarkers.contains(where: lower.contains)
        }
        return MemoIntelligence(title: title, highlights: highlights, actionItems: Array(actions.prefix(8)))
    }

    private func sentenceList(_ value: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in value {
            current.append(character)
            if ".!?\n".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }

    private func title(from value: String) -> String {
        let words = value
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace)
        let bounded = words.prefix(9).joined(separator: " ")
        return bounded.isEmpty ? "Voice memo" : String(bounded.prefix(72))
    }
}
