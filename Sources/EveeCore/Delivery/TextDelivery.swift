import AppKit
import ApplicationServices
import Foundation

public struct FrontmostApplication: Sendable {
    public var bundleIdentifier: String
    public var name: String
}

@MainActor
public enum TextDelivery {
    public static func frontmostApplication() -> FrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplication(bundleIdentifier: app.bundleIdentifier ?? "unknown", name: app.localizedName ?? "App")
    }

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func paste(_ text: String, restoreClipboardAfter delay: TimeInterval = 0.6) async throws {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            throw NSError(domain: "Evee.Accessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enable Evee in System Settings → Privacy & Security → Accessibility."])
        }

        let pasteboard = NSPasteboard.general
        let prior = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
        if pasteboard.string(forType: .string) == text {
            pasteboard.clearContents()
            if let prior { pasteboard.setString(prior, forType: .string) }
        }
    }
}
