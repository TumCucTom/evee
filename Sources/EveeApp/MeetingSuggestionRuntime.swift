import AppKit
import EveeCore

@MainActor
final class MeetingSuggestionRuntime {
    static let shared = MeetingSuggestionRuntime()

    private weak var store: AppStore?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    func start(store: AppStore) {
        self.store = store
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in MeetingSuggestionRuntime.shared.captureCurrentApplication() }
            }
        }
        captureCurrentApplication()
    }

    func settingsChanged() {
        captureCurrentApplication()
    }

    private func captureCurrentApplication() {
        guard let store, store.settings.meetingSuggestionsEnabled else {
            store?.observeMeetingApplication(nil)
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              let applicationName = application.localizedName else {
            store.observeMeetingApplication(nil)
            return
        }

        let isBrowser = store.settings.meetingSuggestionBrowserBundleIdentifiers.contains(bundleIdentifier)
        let title: String?
        if isBrowser, TextDelivery.isAccessibilityTrusted {
            let target = TextDelivery.frontmostApplication(policy: ContextCollectionPolicy(
                collectsDeliveryIdentity: true,
                collectsSelectedText: false,
                collectsWindowMetadata: true,
                collectsWebAndFileMetadata: false,
                collectsRecipientMetadata: false,
                collectsVisibleText: false
            ))
            title = target?.bundleIdentifier == bundleIdentifier ? target?.focusedTarget?.windowTitle : nil
        } else {
            title = nil
        }

        store.observeMeetingApplication(MeetingApplicationSnapshot(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            isBrowser: isBrowser,
            permittedWindowTitle: title,
            observedAt: .now
        ))
    }
}
