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
            store?.handleMeetingSuggestion(.externalApplicationUnavailable)
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            store.handleMeetingSuggestion(.externalApplicationUnavailable)
            return
        }
        let ownApplication = MeetingApplicationIdentity(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        if ownApplication.matches(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        ) {
            store.handleMeetingSuggestion(.ownApplicationActivated)
            return
        }
        guard let bundleIdentifier = application.bundleIdentifier,
              let applicationName = application.localizedName else {
            store.handleMeetingSuggestion(.externalApplicationUnavailable)
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

        store.handleMeetingSuggestion(.observed(MeetingApplicationSnapshot(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            isBrowser: isBrowser,
            permittedWindowTitle: title,
            observedAt: .now
        )))
    }
}
