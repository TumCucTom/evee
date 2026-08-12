import AppKit
import ApplicationServices
import Foundation

public struct FrontmostApplication: Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var processIdentifier: pid_t
    public var focusedTarget: FocusedTargetContext?

    public init(
        bundleIdentifier: String,
        name: String,
        processIdentifier: pid_t,
        focusedTarget: FocusedTargetContext? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
        self.focusedTarget = focusedTarget
    }
}

/// A value-only snapshot of the exact accessibility recipient active when a
/// dictation starts. The AX element and window hashes distinguish tabs,
/// documents and recipients which live inside the same application process.
public struct FocusedTargetContext: Equatable, Sendable {
    public var windowFingerprint: Int?
    public var windowTitle: String?
    public var document: String?
    public var elementFingerprint: Int
    public var elementIdentifier: String?
    public var role: String?
    public var subrole: String?
    public var selectedText: String?
    public var url: String?
    public var codeFile: String?
    public var recipient: String?
    public var visibleText: String?

    public init(
        windowFingerprint: Int?,
        windowTitle: String?,
        document: String?,
        elementFingerprint: Int,
        elementIdentifier: String?,
        role: String?,
        subrole: String?,
        selectedText: String? = nil,
        url: String? = nil,
        codeFile: String? = nil,
        recipient: String? = nil,
        visibleText: String? = nil
    ) {
        self.windowFingerprint = windowFingerprint
        self.windowTitle = windowTitle
        self.document = document
        self.elementFingerprint = elementFingerprint
        self.elementIdentifier = elementIdentifier
        self.role = role
        self.subrole = subrole
        self.selectedText = selectedText
        self.url = url
        self.codeFile = codeFile
        self.recipient = recipient
        self.visibleText = visibleText
    }
}

/// A fail-closed policy for deciding whether a synthetic paste changed the
/// focused field exactly as expected before Return may be generated.
public enum TextInsertionVerification {
    public static func confirmsInsertion(
        before: String,
        after: String,
        insertedText: String,
        replacing selectedText: String? = nil
    ) -> Bool {
        guard !insertedText.isEmpty, before != after else { return false }
        let removedLength = selectedText?.utf16.count ?? 0
        guard after.utf16.count - before.utf16.count == insertedText.utf16.count - removedLength else {
            return false
        }
        return occurrenceCount(of: insertedText, in: after) > occurrenceCount(of: insertedText, in: before)
    }

    private static func occurrenceCount(of needle: String, in value: String) -> Int {
        var count = 0
        var searchRange = value.startIndex..<value.endIndex
        while let match = value.range(of: needle, range: searchRange) {
            count += 1
            searchRange = match.upperBound..<value.endIndex
        }
        return count
    }
}

@MainActor
public enum TextDelivery {
    public enum DeliveryError: LocalizedError {
        case accessibilityRequired
        case targetApplicationChanged(expected: String, actual: String?)
        case targetContextChanged(String)
        case selectedTextChanged(String)
        case autoSendDeclined(String)
        case clipboardWriteFailed

        public var shouldOfferPasteRetry: Bool {
            if case .autoSendDeclined = self { return false }
            return true
        }

        public var errorDescription: String? {
            switch self {
            case .accessibilityRequired:
                "Enable Evee in System Settings → Privacy & Security → Accessibility, then try again. Your dictation has been saved."
            case let .targetApplicationChanged(expected, actual):
                "Evee did not paste because focus moved from \(expected) to \(actual ?? "another app"). Your dictation has been saved."
            case .targetContextChanged(let application):
                "Evee did not paste because the focused window, tab or text field changed inside \(application). Your dictation has been saved."
            case .selectedTextChanged(let application):
                "Evee did not replace the selection because the selected text changed inside \(application). The transformed result has been saved."
            case .autoSendDeclined(let application):
                "Evee pasted the text but did not press Return because focus changed inside \(application). Review the inserted text and send it yourself."
            case .clipboardWriteFailed:
                "Evee could not prepare the clipboard for pasting. Your dictation has been saved."
            }
        }
    }

    private struct PasteboardSnapshot {
        struct Item {
            var values: [(NSPasteboard.PasteboardType, Data)]
        }

        var items: [Item]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                Item(values: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restoredItems = items.map { snapshot in
                let item = NSPasteboardItem()
                for (type, data) in snapshot.values {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    public static func frontmostApplication(includeVisibleText: Bool = false) -> FrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let focusedTarget = focusedTarget(processIdentifier: app.processIdentifier, includeVisibleText: includeVisibleText) else { return nil }
        return FrontmostApplication(
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            name: app.localizedName ?? "App",
            processIdentifier: app.processIdentifier,
            focusedTarget: focusedTarget
        )
    }

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func paste(
        _ text: String,
        to target: FrontmostApplication,
        expectedSelectedText: String? = nil,
        sendAfterPaste: Bool = false,
        restoreClipboardAfter delay: TimeInterval = 0.6
    ) async throws {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            throw DeliveryError.accessibilityRequired
        }

        try verifyTarget(target, expectedSelectedText: expectedSelectedText)
        let valueBeforePaste = sendAfterPaste ? focusedEditableValue(processIdentifier: target.processIdentifier) : nil

        let pasteboard = NSPasteboard.general
        let prior = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            prior.restore(to: pasteboard)
            throw DeliveryError.clipboardWriteFailed
        }
        let dictatedClipboardChange = pasteboard.changeCount

        do {
            try verifyTarget(target, expectedSelectedText: expectedSelectedText)
        } catch {
            if pasteboard.changeCount == dictatedClipboardChange {
                prior.restore(to: pasteboard)
            }
            throw error
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if sendAfterPaste {
            var insertionVerified = false
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(100))
                do {
                    try verifyTarget(target, expectedSelectedText: nil)
                } catch {
                    if pasteboard.changeCount == dictatedClipboardChange {
                        prior.restore(to: pasteboard)
                    }
                    throw DeliveryError.autoSendDeclined(target.name)
                }
                if let before = valueBeforePaste,
                   let after = focusedEditableValue(processIdentifier: target.processIdentifier),
                   TextInsertionVerification.confirmsInsertion(
                       before: before,
                       after: after,
                       insertedText: text,
                       replacing: expectedSelectedText
                   ) {
                    insertionVerified = true
                    break
                }
            }
            guard insertionVerified else {
                if pasteboard.changeCount == dictatedClipboardChange {
                    prior.restore(to: pasteboard)
                }
                throw DeliveryError.autoSendDeclined(target.name)
            }
            postKey(virtualKey: 36)
        }

        try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
        if pasteboard.changeCount == dictatedClipboardChange {
            prior.restore(to: pasteboard)
        }
    }

    /// Explicit fallback used after a guarded paste is declined. Unlike the
    /// temporary paste operation, this intentionally leaves the text on the
    /// clipboard because the user has asked to paste it themselves.
    public static func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let prior = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            prior.restore(to: pasteboard)
            throw DeliveryError.clipboardWriteFailed
        }
    }

    public static func deliver(
        _ text: String,
        to target: FrontmostApplication?,
        mode: TextDeliveryMode,
        expectedSelectedText: String? = nil
    ) async throws {
        switch mode {
        case .copyOnly:
            try copyToClipboard(text)
        case .paste, .pasteAndSend:
            guard let target else {
                throw DeliveryError.targetApplicationChanged(expected: "the capture app", actual: nil)
            }
            try await paste(
                text,
                to: target,
                expectedSelectedText: expectedSelectedText,
                sendAfterPaste: mode == .pasteAndSend
            )
        }
    }

    private static func verifyTarget(_ target: FrontmostApplication, expectedSelectedText: String? = nil) throws {
        let current = NSWorkspace.shared.frontmostApplication
        guard current?.processIdentifier == target.processIdentifier,
              current?.bundleIdentifier == target.bundleIdentifier else {
            throw DeliveryError.targetApplicationChanged(
                expected: target.name,
                actual: current?.localizedName
            )
        }


        guard let expected = target.focusedTarget else { throw DeliveryError.targetContextChanged(target.name) }
        guard let actual = focusedTarget(processIdentifier: target.processIdentifier),
              actual.elementFingerprint == expected.elementFingerprint,
              actual.windowFingerprint == expected.windowFingerprint,
              equivalent(actual.document, expected.document),
              equivalent(actual.windowTitle, expected.windowTitle),
              equivalent(actual.elementIdentifier, expected.elementIdentifier),
              equivalent(actual.role, expected.role),
              equivalent(actual.subrole, expected.subrole) else {
            throw DeliveryError.targetContextChanged(target.name)
        }
        if let expectedSelectedText,
           actual.selectedText != expectedSelectedText {
            throw DeliveryError.selectedTextChanged(target.name)
        }
    }

    private static func focusedTarget(processIdentifier: pid_t, includeVisibleText: Bool = false) -> FocusedTargetContext? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let element = copyElement(kAXFocusedUIElementAttribute as CFString, from: application) else { return nil }
        let window = copyElement(kAXWindowAttribute as CFString, from: element)
            ?? copyElement(kAXFocusedWindowAttribute as CFString, from: application)
        let document = window.flatMap { copyString(kAXDocumentAttribute as CFString, from: $0) }
        let url = copyURLString("AXURL" as CFString, from: element)
            ?? window.flatMap { copyURLString("AXURL" as CFString, from: $0) }
            ?? document.flatMap { URL(string: $0)?.scheme == nil ? nil : $0 }
        return FocusedTargetContext(
            windowFingerprint: window.map { Int(CFHash($0)) },
            windowTitle: window.flatMap { copyString(kAXTitleAttribute as CFString, from: $0) },
            document: document,
            elementFingerprint: Int(CFHash(element)),
            elementIdentifier: copyString(kAXIdentifierAttribute as CFString, from: element),
            role: copyString(kAXRoleAttribute as CFString, from: element),
            subrole: copyString(kAXSubroleAttribute as CFString, from: element),
            selectedText: selectedText(from: element),
            url: url,
            codeFile: codeFile(from: document, windowTitle: window.flatMap { copyString(kAXTitleAttribute as CFString, from: $0) }),
            recipient: recipient(from: element),
            visibleText: includeVisibleText ? window.flatMap { visibleText(from: $0) } : nil
        )
    }

    private static func focusedEditableValue(processIdentifier: pid_t) -> String? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let element = copyElement(kAXFocusedUIElementAttribute as CFString, from: application) else { return nil }
        if copyBoolean("AXProtectedContent" as CFString, from: element) == true
            || copyString(kAXRoleAttribute as CFString, from: element) == "AXSecureTextField"
            || copyString(kAXSubroleAttribute as CFString, from: element) == "AXSecureTextField" {
            return nil
        }
        guard let value = copyString(kAXValueAttribute as CFString, from: element), value.count <= 1_000_000 else { return nil }
        return value
    }

    private static func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private static func copyString(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyURLString(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func recipient(from element: AXUIElement) -> String? {
        guard !isProtected(element) else { return nil }
        for attribute in [kAXDescriptionAttribute as CFString, kAXTitleAttribute as CFString, kAXHelpAttribute as CFString] {
            if let value = copyString(attribute, from: element)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty, value.count <= 120,
               value.localizedCaseInsensitiveContains("recipient") || value.localizedCaseInsensitiveContains("to:") {
                return value
                    .replacingOccurrences(of: "recipient", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "to:", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func codeFile(from document: String?, windowTitle: String?) -> String? {
        let extensions = Set(["c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "jsx", "kt", "m", "mm", "php", "py", "rb", "rs", "sh", "sql", "swift", "ts", "tsx", "vue"])
        for candidate in [document, windowTitle].compactMap({ $0 }) {
            let path = candidate.components(separatedBy: " — ").first ?? candidate
            if extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) { return path }
        }
        return nil
    }

    private static func visibleText(from root: AXUIElement) -> String? {
        var queue = [root]
        var pieces: [String] = []
        var characterCount = 0
        var visited = 0
        while !queue.isEmpty, visited < 120, characterCount < 20_000 {
            let element = queue.removeFirst()
            visited += 1
            if !isProtected(element) {
                for attribute in [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString, kAXValueAttribute as CFString] {
                    guard let value = copyString(attribute, from: element)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty, value.count <= 2_000 else { continue }
                    pieces.append(value)
                    characterCount += value.count
                    break
                }
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(40))
            }
        }
        let result = pieces.joined(separator: "\n")
        return result.isEmpty ? nil : String(result.prefix(20_000))
    }

    private static func selectedText(from element: AXUIElement) -> String? {
        // Secure fields and protected web inputs must never enter the context
        // snapshot, even transiently.
        if copyBoolean("AXProtectedContent" as CFString, from: element) == true
            || copyString(kAXRoleAttribute as CFString, from: element) == "AXSecureTextField"
            || copyString(kAXSubroleAttribute as CFString, from: element) == "AXSecureTextField" {
            return nil
        }
        guard let value = copyString(kAXSelectedTextAttribute as CFString, from: element),
              !value.isEmpty,
              value.count <= 100_000 else { return nil }
        return value
    }

    private static func isProtected(_ element: AXUIElement) -> Bool {
        copyBoolean("AXProtectedContent" as CFString, from: element) == true
            || copyString(kAXRoleAttribute as CFString, from: element) == "AXSecureTextField"
            || copyString(kAXSubroleAttribute as CFString, from: element) == "AXSecureTextField"
    }

    private static func copyBoolean(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func postKey(virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func equivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs?.trimmingCharacters(in: .whitespacesAndNewlines), rhs?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case (nil, nil), ("", nil), (nil, ""), ("", ""):
            return true
        case let (left?, right?):
            return left == right
        default:
            return false
        }
    }
}
