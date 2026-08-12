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
            let observation = WorkspaceApplicationObservation(
                bundleIdentifier: bundleIdentifier,
                applicationName: name,
                windowTitle: title
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

struct WorkspaceIntelligencePrivacyView: View {
    @State private var preferences = WorkspaceIntelligencePreferences()
    @State private var status: String?
    @State private var showingPurgeConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Track application dwell time", isOn: $preferences.isEnabled)
            Text("Off by default. When enabled, Evee stores app switches and dwell time locally. It never reads field contents, keystrokes, or screen pixels.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Include window titles", isOn: $preferences.includeWindowTitles)
                .disabled(!preferences.isEnabled)
            Text("Window titles can contain document names or private details. Turning this off removes previously stored titles.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Build a daily activity journal", isOn: $preferences.journalEnabled)
                .disabled(!preferences.isEnabled)
            Picker("Delete activity after", selection: $preferences.retentionDays) {
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .disabled(!preferences.isEnabled)

            HStack {
                Button("Save activity privacy settings") { Task { await save() } }
                Button("Delete activity data", role: .destructive) { showingPurgeConfirmation = true }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task { await load() }
        .confirmationDialog("Delete all stored activity and journal data?", isPresented: $showingPurgeConfirmation) {
            Button("Delete activity data", role: .destructive) { Task { await purge() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        do { preferences = try await WorkspaceIntelligenceStore.shared.preferences() }
        catch { status = error.localizedDescription }
    }

    private func save() async {
        do {
            try await WorkspaceIntelligenceStore.shared.savePreferences(preferences)
            WorkspaceIntelligenceRuntime.shared.preferencesChanged()
            status = "Saved"
        } catch { status = error.localizedDescription }
    }

    private func purge() async {
        do {
            try await WorkspaceIntelligenceStore.shared.purge()
            status = "Activity data deleted"
        } catch { status = error.localizedDescription }
    }
}
