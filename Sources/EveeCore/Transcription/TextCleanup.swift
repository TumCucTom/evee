import Foundation

public struct TextCleanupPipeline: Sendable {
    public init() {}

    public func clean(
        _ input: String,
        terms: [DictionaryTerm] = [],
        tone: WritingTone = .natural,
        appendPeriod: Bool = true,
        useParagraphs: Bool = true
    ) -> String {
        var text = input
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard tone != .verbatim else { return text }

        text = removeFillers(text)
        text = applyVocabulary(text, terms: terms)
        text = spokenFormatting(text)
        text = sentenceCase(text)

        if tone == .concise {
            text = text
                .replacingOccurrences(of: "I just wanted to ", with: "", options: [.caseInsensitive, .anchored])
                .replacingOccurrences(of: "basically ", with: "", options: .caseInsensitive)
        }

        if useParagraphs {
            text = text.replacingOccurrences(of: " new paragraph ", with: "\n\n", options: .caseInsensitive)
        }

        if appendPeriod, let last = text.last, !".!?…:;)\"'".contains(last) {
            text.append(".")
        }
        return text
    }

    private func removeFillers(_ input: String) -> String {
        input
            .replacingOccurrences(of: "(?i)(^|[ ,])(?:um+|uh+|erm+)(?=[ ,.]|$)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }

    private func applyVocabulary(_ input: String, terms: [DictionaryTerm]) -> String {
        terms.reduce(input) { text, term in
            let escaped = NSRegularExpression.escapedPattern(for: term.spoken)
            let options: String.CompareOptions = term.caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]
            return text.replacingOccurrences(of: "\\b\(escaped)\\b", with: term.replacement, options: options)
        }
    }

    private func spokenFormatting(_ input: String) -> String {
        let replacements = [
            " comma": ",", " full stop": ".", " period": ".", " question mark": "?",
            " exclamation mark": "!", " colon": ":", " semicolon": ";", " new line ": "\n",
            " open bracket ": " (", " close bracket": ")",
        ]
        return replacements.reduce(input) { $0.replacingOccurrences(of: $1.key, with: $1.value, options: .caseInsensitive) }
    }

    private func sentenceCase(_ input: String) -> String {
        var shouldCapitalise = true
        return String(input.map { character in
            defer {
                if ".!?\n".contains(character) { shouldCapitalise = true }
                else if !character.isWhitespace { shouldCapitalise = false }
            }
            return shouldCapitalise && character.isLetter ? Character(String(character).uppercased()) : character
        })
    }
}
