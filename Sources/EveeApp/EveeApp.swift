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
                .background(CaptureOverlayInstaller().environmentObject(store))
                .onAppear { applicationDelegate.install(checkpoint: store) }
                .task {
                    WorkspaceIntelligenceRuntime.shared.start()
                    await store.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Evee", systemImage: menuIcon) {
            MenuBarView().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store).frame(width: 680, height: 560)
        }
    }

    private var menuIcon: String {
        switch store.captureState {
        case .starting: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing, .delivering: "ellipsis.circle"
        default: "waveform.circle"
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
    private var statusObservation: AnyCancellable?
    private var panel: CaptureHUDPanel?
    private var announcedState: CaptureAnnouncementState?

    func install(store: AppStore) {
        guard self.store !== store else { return }
        self.store = store
        observation = store.$captureState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.render(state) }
        statusObservation = store.$statusMessage
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { message in
                NSAccessibility.post(
                    element: NSApplication.shared,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: message,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue
                    ]
                )
            }
    }

    private func render(_ state: CaptureState) {
        announceStateChange(state)
        guard state != .idle, let store else {
            panel?.orderOut(nil)
            return
        }

        let content = RecordingPill(
            state: state,
            operation: store.captureOperation,
            onStop: { [weak store] in Task { @MainActor in await store?.finishCapture() } },
            onCancel: { [weak store] in Task { @MainActor in await store?.cancelCapture() } }
        )

        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: content)
        panel.setContentSize(NSSize(width: 410, height: 54))
        position(panel)
        panel.orderFrontRegardless()
    }

    private func announceStateChange(_ state: CaptureState) {
        let announcement = CaptureAnnouncementState(
            state,
            isSelectionTransform: store?.captureOperation == .selectionTransform
        )
        guard announcement != announcedState else { return }
        let previous = announcedState
        announcedState = announcement

        let message: String?
        switch state {
        case .idle:
            message = previous == nil ? nil : "Evee is ready."
        case .starting:
            message = "Evee is preparing audio capture."
        case .recording:
            message = "Evee is recording."
        case .transcribing:
            message = "Evee is transcribing locally."
        case .delivering:
            message = store?.captureOperation == .selectionTransform
                ? "Evee is verifying and replacing the selected text."
                : "Evee is verifying and inserting the finished text."
        case .failed(let detail):
            message = "Evee capture failed. \(detail)"
        }
        guard let message else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
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

private enum CaptureAnnouncementState: Equatable {
    case idle, starting, recording, transcribing, delivering, deliveringSelection, failed(String)

    init(_ state: CaptureState, isSelectionTransform: Bool) {
        switch state {
        case .idle: self = .idle
        case .starting: self = .starting
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .delivering: self = isSelectionTransform ? .deliveringSelection : .delivering
        case .failed(let detail): self = .failed(detail)
        }
    }
}

private final class CaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
