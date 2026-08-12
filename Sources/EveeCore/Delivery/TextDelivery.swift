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

    public init(
        windowFingerprint: Int?,
        windowTitle: String?,
        document: String?,
        elementFingerprint: Int,
        elementIdentifier: String?,
        role: String?,
        subrole: String?
    ) {
        self.windowFingerprint = windowFingerprint
        self.windowTitle = windowTitle
        self.document = document
        self.elementFingerprint = elementFingerprint
        self.elementIdentifier = elementIdentifier
        self.role = role
        self.subrole = subrole
    }
}

@MainActor
public enum TextDelivery {
    public enum DeliveryError: LocalizedError {
        case accessibilityRequired
        case targetApplicationChanged(expected: String, actual: String?)
        case targetContextChanged(String)
        case clipboardWriteFailed

        public var errorDescription: String? {
            switch self {
            case .accessibilityRequired:
                "Enable Evee in System Settings → Privacy & Security → Accessibility, then try again. Your dictation has been saved."
            case let .targetApplicationChanged(expected, actual):
                "Evee did not paste because focus moved from \(expected) to \(actual ?? "another app"). Your dictation has been saved."
            case .targetContextChanged(let application):
                "Evee did not paste because the focused window, tab or text field changed inside \(application). Your dictation has been saved."
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

    public static func frontmostApplication() -> FrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplication(
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            name: app.localizedName ?? "App",
            processIdentifier: app.processIdentifier,
            focusedTarget: focusedTarget(processIdentifier: app.processIdentifier)
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
        restoreClipboardAfter delay: TimeInterval = 0.6
    ) async throws {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            throw DeliveryError.accessibilityRequired
        }

        try verifyTarget(target)

        let pasteboard = NSPasteboard.general
        let prior = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            prior.restore(to: pasteboard)
            throw DeliveryError.clipboardWriteFailed
        }
        let dictatedClipboardChange = pasteboard.changeCount

        do {
            try verifyTarget(target)
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
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw DeliveryError.clipboardWriteFailed
        }
    }

    private static func verifyTarget(_ target: FrontmostApplication) throws {
        let current = NSWorkspace.shared.frontmostApplication
        guard current?.processIdentifier == target.processIdentifier,
              current?.bundleIdentifier == target.bundleIdentifier else {
            throw DeliveryError.targetApplicationChanged(
                expected: target.name,
                actual: current?.localizedName
            )
        }


        guard let expected = target.focusedTarget else {
            // Dictations captured by a legacy build have no focused-recipient
            // snapshot. Keep the process-level check for backwards compatibility.
            return
        }
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
    }

    private static func focusedTarget(processIdentifier: pid_t) -> FocusedTargetContext? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let element = copyElement(kAXFocusedUIElementAttribute as CFString, from: application) else { return nil }
        let window = copyElement(kAXWindowAttribute as CFString, from: element)
            ?? copyElement(kAXFocusedWindowAttribute as CFString, from: application)
        return FocusedTargetContext(
            windowFingerprint: window.map { Int(CFHash($0)) },
            windowTitle: window.flatMap { copyString(kAXTitleAttribute as CFString, from: $0) },
            document: window.flatMap { copyString(kAXDocumentAttribute as CFString, from: $0) },
            elementFingerprint: Int(CFHash(element)),
            elementIdentifier: copyString(kAXIdentifierAttribute as CFString, from: element),
            role: copyString(kAXRoleAttribute as CFString, from: element),
            subrole: copyString(kAXSubroleAttribute as CFString, from: element)
        )
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
