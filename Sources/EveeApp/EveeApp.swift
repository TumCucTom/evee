import AppKit
import Combine
import Darwin
import EveeCore
import SwiftUI

@main
struct EveeApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(EveeApplicationDelegate.self) private var applicationDelegate

    init() {
        guard CommandLine.arguments.contains("--installation-self-test") else { return }
        Task {
            do {
                try await InstallationSelfTest.run()
                print("Evee installation self-test passed")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                fputs("Evee installation self-test failed: \(error.localizedDescription)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 620)
                .background(WindowSharingProtectionInstaller())
                .background(CaptureOverlayInstaller().environmentObject(store))
                .onAppear { applicationDelegate.install(checkpoint: store) }
                .task {
                    WorkspaceIntelligenceRuntime.shared.start()
                    await store.bootstrap()
                    MeetingSuggestionRuntime.shared.start(store: store)
                }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Evee", systemImage: menuIcon) {
            MenuBarView()
                .environmentObject(store)
                .background(WindowSharingProtectionInstaller())
        }
        .menuBarExtraStyle(.window)

        Settings {
            Group {
                if store.privacyModeEnabled {
                    PrivacyModeView()
                } else {
                    SettingsView()
                }
            }
            .environmentObject(store)
            .frame(width: 680, height: 560)
            .background(WindowSharingProtectionInstaller())
        }
    }

    private var menuIcon: String {
        if !store.systemVoiceStatus.warnings.isEmpty {
            return "exclamationmark.waveform"
        }
        return switch store.systemVoiceStatus.phase {
        case .wakeListening, .wakeStopping: "mic.circle.fill"
        case .captureStarting, .wakeStarting: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .processing, .delivering: "ellipsis.circle"
        case .protected: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle"
        case .ready: "waveform.circle"
        }
    }
}

@MainActor
private final class EveeApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var checkpoint: (any CaptureCheckpointing)?
    private let termination = ApplicationTerminationCoordinator()

    func install(checkpoint: any CaptureCheckpointing) {
        guard self.checkpoint == nil else { return }
        self.checkpoint = checkpoint
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let checkpoint, let store = checkpoint as? AppStore else {
            presentFailure("Evee is still preparing its shutdown checkpoint. Wait a moment, then quit again.")
            return .terminateCancel
        }
        let decision = termination.requestTermination(
            plan: store.captureShutdownPlan,
            checkpoint: checkpoint,
            reply: { shouldTerminate in
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            },
            reportFailure: { [weak self] error in
                store.reportApplicationTerminationCheckpointFailure(error)
                self?.presentFailure("Evee could not finish its recovery checkpoint. The app stayed open and retained completed audio and notes. Check available disk space and permissions, then quit again.\n\n\(error.localizedDescription)")
            }
        )
        switch decision {
        case .terminateNow: return .terminateNow
        case .terminateLater: return .terminateLater
        case .terminateCancel: return .terminateCancel
        }
    }

    private func presentFailure(_ message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Evee stayed open to protect your data"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct CaptureOverlayInstaller: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { CaptureOverlayController.shared.install(store: store) }
    }
}

/// Owns a non-activating panel so capture feedback remains visible over every
/// application without stealing keyboard focus from the dictation target.
@MainActor
private final class CaptureOverlayController {
    static let shared = CaptureOverlayController()

    private weak var store: AppStore?
    private var observation: AnyCancellable?
    private var panel: CaptureHUDPanel?

    func install(store: AppStore) {
        guard self.store !== store else { return }
        self.store = store
        observation = store.$systemVoiceStatus
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.render(status) }
    }

    private func render(_ status: SystemVoiceStatus) {
        guard status.phase != .ready else {
            panel?.orderOut(nil)
            return
        }

        let content = RecordingPill(status: status)

        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: content)
        panel.setContentSize(NSSize(width: 410, height: 54))
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> CaptureHUDPanel {
        let panel = CaptureHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - 10
        )
        panel.setFrameOrigin(origin)
    }
}

private final class CaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
