import AppKit
import ApplicationServices
import Foundation

public struct FrontmostApplication: Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var processIdentifier: pid_t

    public init(bundleIdentifier: String, name: String, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }
}

@MainActor
public enum TextDelivery {
    public enum DeliveryError: LocalizedError {
        case accessibilityRequired
        case targetApplicationChanged(expected: String, actual: String?)
        case clipboardWriteFailed

        public var errorDescription: String? {
            switch self {
            case .accessibilityRequired:
                "Enable Evee in System Settings → Privacy & Security → Accessibility, then try again. Your dictation has been saved."
            case let .targetApplicationChanged(expected, actual):
                "Evee did not paste because focus moved from \(expected) to \(actual ?? "another app"). Your dictation has been saved."
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
            processIdentifier: app.processIdentifier
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

    private static func verifyTarget(_ target: FrontmostApplication) throws {
        let current = NSWorkspace.shared.frontmostApplication
        guard current?.processIdentifier == target.processIdentifier,
              current?.bundleIdentifier == target.bundleIdentifier else {
            throw DeliveryError.targetApplicationChanged(
                expected: target.name,
                actual: current?.localizedName
            )
        }
    }
}
