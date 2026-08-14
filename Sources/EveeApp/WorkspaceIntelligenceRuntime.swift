import AppKit
import CoreGraphics
import EveeCore
import SwiftUI

@MainActor
final class WorkspaceIntelligenceRuntime {
    static let shared = WorkspaceIntelligenceRuntime()

    private let store = WorkspaceIntelligenceStore.shared
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard timer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in WorkspaceIntelligenceRuntime.shared.captureCurrentApplication() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { try? await WorkspaceIntelligenceStore.shared.stop() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in WorkspaceIntelligenceRuntime.shared.captureCurrentApplication() }
        }
        captureCurrentApplication()
    }

    func preferencesChanged() {
        captureCurrentApplication()
    }

    private func captureCurrentApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let name = application.localizedName else { return }
        let bundleIdentifier = application.bundleIdentifier
        let processIdentifier = application.processIdentifier
        Task {
            guard let preferences = try? await store.preferences(), preferences.isEnabled else { return }
            let title = preferences.includeWindowTitles
                ? frontmostWindowTitle(processIdentifier: processIdentifier)
                : nil
            let accessibilityContext = preferences.includeWebAddresses == true || preferences.includeFocusedText == true
                ? TextDelivery.frontmostApplication(
                    policy: ContextCollectionPolicy(
                        collectsDeliveryIdentity: true,
                        collectsSelectedText: preferences.includeFocusedText == true,
                        collectsWindowMetadata: false,
                        collectsWebAndFileMetadata: preferences.includeWebAddresses == true,
                        collectsRecipientMetadata: false,
                        collectsVisibleText: preferences.includeFocusedText == true
                    )
                )?.focusedTarget
                : nil
            let webAddress = preferences.includeWebAddresses == true ? accessibilityContext?.url : nil
            let observation = WorkspaceApplicationObservation(
                bundleIdentifier: bundleIdentifier,
                applicationName: name,
                windowTitle: title,
                webAddress: webAddress,
                selectedText: preferences.includeFocusedText == true ? accessibilityContext?.selectedText : nil,
                visibleText: preferences.includeFocusedText == true ? accessibilityContext?.visibleText : nil
            )
            try? await store.record(observation)
        }
    }

    private func frontmostWindowTitle(processIdentifier: pid_t) -> String? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] else { return nil }
        return entries.first { entry in
            (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier &&
                (entry[kCGWindowLayer] as? NSNumber)?.intValue == 0
        }?[kCGWindowName] as? String
    }
}

@MainActor
final class WorkspaceIntelligencePrivacyEditor: ObservableObject {
    @Published private(set) var draft = WorkspaceIntelligencePrivacyDraft()
    @Published private(set) var status: String?
    @Published var showingPurgeConfirmation = false

    var preferences: WorkspaceIntelligencePreferences { draft.preferences }

    func binding<Value>(for keyPath: WritableKeyPath<WorkspaceIntelligencePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.draft.preferences[keyPath: keyPath] },
            set: { value in
                var updated = self.draft.preferences
                updated[keyPath: keyPath] = value
                self.draft.update(updated)
            }
        )
    }

    func draftUpdate(_ updated: WorkspaceIntelligencePreferences) {
        draft.update(updated)
    }

    func loadIfNeeded() async {
        guard draft.beginInitialLoad() else { return }
        do {
            draft.receiveLoaded(try await WorkspaceIntelligenceStore.shared.preferences())
        } catch {
            status = "Activity privacy settings could not be loaded. Your current draft was kept."
        }
    }

    func save() async {
        let savedPreferences = draft.preferences
        do {
            try await WorkspaceIntelligenceStore.shared.savePreferences(savedPreferences)
            let savedCurrentDraft = draft.markSaved(ifMatching: savedPreferences)
            WorkspaceIntelligenceRuntime.shared.preferencesChanged()
            status = savedCurrentDraft ? "Saved" : "Saved earlier changes. Newer edits remain unsaved."
        } catch {
            status = "Activity privacy settings could not be saved. Your draft was kept."
        }
    }

    func purge() async {
        do {
            try await WorkspaceIntelligenceStore.shared.purge()
            status = "Activity data deleted"
        } catch {
            status = "Activity data could not be deleted."
        }
    }
}

struct WorkspaceIntelligencePrivacyView: View {
    @ObservedObject var editor: WorkspaceIntelligencePrivacyEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Track application dwell time", isOn: editor.binding(for: \.isEnabled))
            Text("Off by default. When enabled, Evee stores app switches and dwell time locally. It never reads field contents, keystrokes, or screen pixels.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Include window titles", isOn: editor.binding(for: \.includeWindowTitles))
                .disabled(!editor.preferences.isEnabled)
            Text("Window titles can contain document names or private details. Turning this off removes previously stored titles.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Include current web address", isOn: Binding(
                get: { editor.preferences.includeWebAddresses == true },
                set: { value in
                    var updated = editor.preferences
                    updated.includeWebAddresses = value
                    editor.draftUpdate(updated)
                }
            ))
            .disabled(!editor.preferences.isEnabled)
            Text("Web addresses require Accessibility permission. Query strings, fragments and credentials are removed before storage; turning this off removes the current stored address.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Include selected and visible accessibility text", isOn: Binding(
                get: { editor.preferences.includeFocusedText == true },
                set: { value in
                    var updated = editor.preferences
                    updated.includeFocusedText = value
                    editor.draftUpdate(updated)
                }
            ))
            .disabled(!editor.preferences.isEnabled)
            Text("Highly sensitive and off by default. When enabled, Evee stores bounded text exposed by the focused window for local context tools. Secure and protected fields are excluded. Turning this off removes the current stored text snapshot.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Build a daily activity journal", isOn: editor.binding(for: \.journalEnabled))
                .disabled(!editor.preferences.isEnabled)
            Picker("Delete activity after", selection: editor.binding(for: \.retentionDays)) {
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .disabled(!editor.preferences.isEnabled)

            ViewThatFits(in: .horizontal) {
                HStack { activityActions }
                VStack(alignment: .leading, spacing: 8) { activityActions }
            }
        }
        .task { await editor.loadIfNeeded() }
        .confirmationDialog("Delete all stored activity and journal data?", isPresented: $editor.showingPurgeConfirmation) {
            Button("Delete activity data", role: .destructive) { Task { await editor.purge() } }
                .accessibilityLabel(AccessibilityCopy.deleteActivityData)
                .accessibilityHint("Permanently deletes all locally stored activity observations and generated journal entries.")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel activity data deletion")
        }
    }

    @ViewBuilder
    private var activityActions: some View {
        Button("Save activity privacy settings") { Task { await editor.save() } }
            .accessibilityLabel("Save local activity privacy settings")
        Button("Delete activity data", role: .destructive) { editor.showingPurgeConfirmation = true }
            .accessibilityLabel(AccessibilityCopy.deleteActivityData)
            .accessibilityHint("Shows a confirmation before permanently deleting local activity data.")
        if let status = editor.status {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Activity privacy status: \(status)")
        }
    }

}
