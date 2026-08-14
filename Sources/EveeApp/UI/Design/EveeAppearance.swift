import AppKit
import Combine
import EveeCore
import SwiftUI

private struct EveeAppearanceModeKey: EnvironmentKey {
    static let defaultValue = EveeAppearanceMode.automatic
}

private extension EnvironmentValues {
    var eveeAppearanceMode: EveeAppearanceMode {
        get { self[EveeAppearanceModeKey.self] }
        set { self[EveeAppearanceModeKey.self] = newValue }
    }
}

@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()

    @Published private(set) var mode: EveeAppearanceMode

    private let defaults: UserDefaults
    private var displayOptionsObservation: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = EveeAppearancePreference.load(from: defaults)
        self.mode = mode
        EveeAppearanceRuntime.update(mode)
        displayOptionsObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.activate() }
    }

    func select(_ mode: EveeAppearanceMode) {
        guard self.mode != mode else { return }
        EveeAppearancePreference.save(mode, to: defaults)
        EveeAppearanceRuntime.update(mode)
        applyNativeAppearance(mode)
        self.mode = mode
        NSApp.windows.forEach { window in
            window.contentView?.needsDisplay = true
        }
    }

    func activate() {
        EveeAppearanceRuntime.update(mode)
        applyNativeAppearance(mode)
    }

    var preferredColorScheme: ColorScheme? {
        switch mode {
        case .automatic: nil
        case .dark: .dark
        case .light, .anima: .light
        }
    }

    private func applyNativeAppearance(_ mode: EveeAppearanceMode) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let name: NSAppearance.Name? = switch mode {
        case .automatic: nil
        case .light, .anima:
            highContrast ? .accessibilityHighContrastAqua : .aqua
        case .dark:
            highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
        }
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
    }
}

struct EveeAppearanceBoundary<Content: View>: View {
    @ObservedObject var appearance: AppearanceController
    private let content: Content

    init(
        appearance: AppearanceController,
        @ViewBuilder content: () -> Content
    ) {
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        content
            .preferredColorScheme(appearance.preferredColorScheme)
            .environment(\.eveeAppearanceMode, appearance.mode)
            .environmentObject(appearance)
            .onAppear { appearance.activate() }
    }
}

enum EveeMaterialKind {
    case rail
    case panel
}

private struct EveeMaterialSurface: ViewModifier {
    let kind: EveeMaterialKind
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                kind == .rail ? EveeVisual.sidebar : EveeVisual.surface
            } else {
                Rectangle()
                    .fill(kind == .rail ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
                    .overlay((kind == .rail ? EveeVisual.sidebar : EveeVisual.surface).opacity(0.42))
            }
        }
    }
}

extension View {
    func eveeMaterial(_ kind: EveeMaterialKind) -> some View {
        modifier(EveeMaterialSurface(kind: kind))
    }
}
