import Foundation

public struct WritingEnhancementPipeline: Sendable {
    public init() {}

    public func enhance(
        _ input: String,
        smartLinks: [SmartLink],
        emailMode: EmailFormattingMode,
        emailSignOff: String,
        context: WorkspaceContext?
    ) -> String {
        var result = applySmartLinks(input, links: smartLinks)
        guard shouldFormatAsEmail(mode: emailMode, context: context) else { return result }
        result = formatEmail(result, recipient: context?.recipient, signOff: emailSignOff)
        return result
    }

    public func applySmartLinks(_ input: String, links: [SmartLink]) -> String {
        links.reduce(input) { text, link in
            let phrase = link.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty,
                  let url = URL(string: link.destination),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return text }
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            return text.replacingOccurrences(
                of: "\\b\(escaped)\\b",
                with: link.destination,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    public func shouldFormatAsEmail(mode: EmailFormattingMode, context: WorkspaceContext?) -> Bool {
        switch mode {
        case .off: return false
        case .always: return true
        case .automatic:
            let bundle = context?.bundleIdentifier?.lowercased() ?? ""
            let url = context?.url?.lowercased() ?? ""
            return bundle.contains("mail") || bundle.contains("outlook")
                || url.contains("mail.google.") || url.contains("outlook.")
                || url.contains("proton.me/mail")
        }
    }

    public func formatEmail(_ input: String, recipient: String?, signOff: String) -> String {
        var body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return body }

        let firstLine = body.split(separator: "\n", maxSplits: 1).first?.lowercased() ?? ""
        if !firstLine.hasPrefix("hi ") && !firstLine.hasPrefix("hello ") && !firstLine.hasPrefix("dear ") {
            let name = recipient?.trimmingCharacters(in: .whitespacesAndNewlines)
            body = "Hi\(name.map { " \($0)" } ?? ""),\n\n\(body)"
        }

        let closing = signOff.trimmingCharacters(in: .whitespacesAndNewlines)
        if !closing.isEmpty {
            let lower = body.lowercased()
            let alreadyClosed = ["best,", "regards,", "thanks,", "thank you,"].contains { lower.contains("\n\n\($0)") }
            if !alreadyClosed { body += "\n\nBest,\n\(closing)" }
        }
        return body
    }
}

public struct CorrectionLearner: Sendable {
    public init() {}

    /// Learns only unambiguous, one-token substitutions. It deliberately
    /// declines insertions, deletions, phrases and large edits.
    public func candidate(from original: String, edited: String) -> DictionaryTerm? {
        let before = words(original)
        let after = words(edited)
        guard before.count == after.count, before.count >= 2 else { return nil }
        let differences = zip(before, after).filter { $0.0.caseInsensitiveCompare($0.1) != .orderedSame }
        guard differences.count == 1, let change = differences.first,
              change.0.count >= 2, change.1.count >= 2,
              change.0.rangeOfCharacter(from: .letters) != nil,
              change.1.rangeOfCharacter(from: .letters) != nil else { return nil }
        return DictionaryTerm(spoken: change.0, replacement: change.1)
    }

    private func words(_ value: String) -> [String] {
        value.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
    }
}
