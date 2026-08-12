import AppKit
import Combine
import EveeCore
import SwiftUI

@main
struct EveeApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 620)
                .background(CaptureOverlayInstaller().environmentObject(store))
                .task { await store.bootstrap() }
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
        observation = store.$captureState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.render(state) }
    }

    private func render(_ state: CaptureState) {
        guard state != .idle, let store else {
            panel?.orderOut(nil)
            return
        }

        let content = RecordingPill(
            state: state,
            onStop: { [weak store] in Task { @MainActor in await store?.finishCapture() } },
            onCancel: { [weak store] in Task { @MainActor in await store?.cancelCapture() } }
        )

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
