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
        case .recording: "waveform.circle.fill"
        case .transcribing, .delivering: "ellipsis.circle"
        default: "waveform.circle"
        }
    }
}
