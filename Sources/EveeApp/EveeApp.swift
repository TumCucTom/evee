import AppKit
import Combine
import Darwin
import EveeCore
import SwiftUI

struct EveeApplication: App {
    @StateObject private var store = AppStore()
    @StateObject private var appearance = AppearanceController.shared
    @NSApplicationDelegateAdaptor(EveeApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            EveeAppearanceBoundary(appearance: appearance) {
                RootView()
                    .environmentObject(store)
                    .frame(minWidth: 920, minHeight: 620)
                    .background(WindowSharingProtectionInstaller())
                    .background(
                        CaptureOverlayInstaller()
                            .environmentObject(store)
                            .environmentObject(appearance)
                    )
                    .onAppear { applicationDelegate.install(checkpoint: store) }
                    .task {
                        WorkspaceIntelligenceRuntime.shared.start()
                        await store.bootstrap()
                        MeetingSuggestionRuntime.shared.start(store: store)
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            EveeAppearanceBoundary(appearance: appearance) {
                MenuBarView()
                    .environmentObject(store)
                    .background(WindowSharingProtectionInstaller())
            }
        } label: {
            Image(systemName: menuIcon)
                .accessibilityLabel(menuBarPresentation.closedAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EveeAppearanceBoundary(appearance: appearance) {
                Group {
                    if store.privacyModeEnabled {
                        PrivacyModeView()
                    } else {
                        SettingsView()
                    }
                }
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 580)
                .background(WindowSharingProtectionInstaller())
            }
        }
        .defaultSize(width: 780, height: 640)
        .windowResizability(.contentMinSize)
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

    private var menuBarPresentation: MenuBarVoicePresentation {
        MenuBarVoicePresentation.make(status: store.systemVoiceStatus)
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
                self?.presentFailure("Evee could not finish its recovery checkpoint. The app stayed open and retained completed audio and notes. Check available disk space and permissions, then open Evee for details before quitting again.")
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
    @EnvironmentObject private var appearance: AppearanceController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { CaptureOverlayController.shared.install(store: store, appearance: appearance) }
    }
}

/// Owns a non-activating panel so capture feedback remains visible over every
/// application without stealing keyboard focus from the dictation target.
@MainActor
private final class CaptureOverlayController: CaptureOverlayRendering {
    static let shared = CaptureOverlayController()

    private weak var store: AppStore?
    private var observation: AnyCancellable?
    private var panel: CaptureHUDPanel?
    private var hostingView: NSView?
    private var presentationModel: CaptureOverlayPresentationModel?
    private lazy var updateDriver = CaptureOverlayUpdateDriver(renderer: self)

    func install(store: AppStore, appearance: AppearanceController) {
        guard self.store !== store else { return }
        self.store = store
        createOverlay(appearance: appearance)
        observation = store.$captureOverlaySnapshot
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateDriver.receive(snapshot, at: ProcessInfo.processInfo.systemUptime)
            }
    }

    func createOverlay() {
        createOverlay(appearance: .shared)
    }

    private func createOverlay(appearance: AppearanceController) {
        guard panel == nil else { return }
        let initialStatus = SystemVoiceStatus.make(capture: .idle, hotMic: .disabled, warnings: [])
        let initialSnapshot = CaptureOverlaySnapshot.make(status: initialStatus, capture: .idle)
        let model = CaptureOverlayPresentationModel(
            presentation: CaptureOverlayPresentation.make(snapshot: initialSnapshot)
        )
        let hostingView = NSHostingView(
            rootView: EveeAppearanceBoundary(appearance: appearance) {
                RecordingPill(model: model)
            }
        )
        let panel = makePanel()
        panel.contentView = hostingView
        panel.setContentSize(NSSize(width: 376, height: 52))
        self.presentationModel = model
        self.hostingView = hostingView
        self.panel = panel
    }

    func apply(_ presentation: CaptureOverlayPresentation) {
        guard let model = presentationModel, let hostingView, let panel else { return }
        let needsIntrinsicResize = !model.presentation.hasSameSemantics(as: presentation)
        model.update(presentation)
        guard needsIntrinsicResize else { return }
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        let intrinsicHeight = hostingView.fittingSize.height
        let semanticMinimumHeight: CGFloat = presentation.phase == .failed || presentation.hasWarning ? 76 : 52
        panel.setContentSize(NSSize(width: 376, height: max(semanticMinimumHeight, intrinsicHeight)))
    }

    func presentOverlay(reposition: Bool) {
        guard let panel else { return }
        if reposition { position(panel) }
        panel.orderFrontRegardless()
    }

    func hideOverlay() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> CaptureHUDPanel {
        let panel = CaptureHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 52),
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

@MainActor
final class CaptureOverlayPresentationModel: ObservableObject {
    @Published private(set) var presentation: CaptureOverlayPresentation

    init(presentation: CaptureOverlayPresentation) {
        self.presentation = presentation
    }

    func update(_ presentation: CaptureOverlayPresentation) {
        guard self.presentation != presentation else { return }
        self.presentation = presentation
    }
}

private final class CaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
