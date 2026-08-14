import Foundation

public enum SelectionTransformError: LocalizedError, Equatable {
    case emptySelection
    case emptyInstruction
    case unsupportedInstruction

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "No editable text is selected. Select text in an accessible text field and try again."
        case .emptyInstruction:
            "Evee did not hear a transform instruction. The selected text was not changed."
        case .unsupportedInstruction:
            "That instruction is unsupported in this deterministic build. Supported commands: \(SelectionTransformPipeline.supportedCommandSummary). The selected text was not changed."
        }
    }
}

/// Local, deterministic selection transforms. This intentionally does not
/// pretend to support an open-ended AI rewrite: instructions outside this
/// documented set fail without changing the user's selection.
public struct SelectionTransformPipeline: Sendable {
    public static let supportedCommandSummary = "Concise, clean up, uppercase, lowercase, title case, bullets, numbered list, and replace … with … (case-insensitive, all matches)"

    private let cleanup = TextCleanupPipeline()

    public init() {}

    public func transform(
        selectedText: String,
        instruction: String,
        terms: [DictionaryTerm] = []
    ) throws -> String {
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionTransformError.emptySelection
        }
        let instructionText = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let command = instructionText.lowercased()
        guard !command.isEmpty else { throw SelectionTransformError.emptyInstruction }

        if command.contains("uppercase") || command.contains("upper case") || command == "all caps" {
            return selectedText.uppercased()
        }
        if command.contains("lowercase") || command.contains("lower case") {
            return selectedText.lowercased()
        }
        if command.contains("title case") || command.contains("capitalize every word") {
            return selectedText.localizedCapitalized
        }
        if command.contains("concise") || command.contains("shorter") {
            return cleanup.clean(selectedText, terms: terms, tone: .concise)
        }
        if command.contains("clean up") || command.contains("cleanup")
            || command.contains("fix punctuation") || command.contains("remove fillers") {
            return cleanup.clean(selectedText, terms: terms)
        }
        if command.contains("bullet") {
            return list(selectedText, marker: "•")
        }
        if command.contains("numbered list") || command.contains("number list") {
            return listItems(selectedText).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        if let replacement = replacementInstruction(instructionText) {
            return selectedText.replacingOccurrences(
                of: replacement.old,
                with: replacement.new,
                options: .caseInsensitive
            )
        }

        throw SelectionTransformError.unsupportedInstruction
    }

    private func list(_ text: String, marker: String) -> String {
        listItems(text).map { "\(marker) \($0)" }.joined(separator: "\n")
    }

    private func listItems(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: #"[.!?]+\s+"#, with: "\n", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
    }

    private func replacementInstruction(_ command: String) -> (old: String, new: String)? {
        guard let prefix = command.range(of: "replace ", options: [.caseInsensitive, .anchored]),
              let divider = command.range(of: " with ", options: .caseInsensitive) else { return nil }
        let old = String(command[prefix.upperBound..<divider.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let new = String(command[divider.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty else { return nil }
        return (old, new)
    }
}
