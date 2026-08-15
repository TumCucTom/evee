import AppKit
import Combine
import EveeCore
import SwiftUI

struct EveeAppearanceModeKey: EnvironmentKey {
    static let defaultValue = EveeAppearanceMode.automatic
}

extension EnvironmentValues {
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
        case .automatic, .glass: nil
        case .dark: .dark
        case .light, .anima: .light
        }
    }

    private func applyNativeAppearance(_ mode: EveeAppearanceMode) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let name: NSAppearance.Name? = switch mode {
        case .automatic, .glass: nil
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

/// The shared workspace backdrop. Glass mode adds one restrained, static voice
/// trace so translucent surfaces have meaningful local content to refract.
struct EveeCanvas: View {
    @Environment(\.eveeAppearanceMode) private var appearanceMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            EveeVisual.canvas

            if appearanceMode == .glass, !reduceTransparency {
                VoiceThread(
                    presentation: VoiceThreadPresentation.make(
                        phase: .recording,
                        level: 0.34
                    ),
                    lineWidth: 24
                )
                .frame(maxWidth: 720)
                .frame(height: 210)
                .rotationEffect(.degrees(-4))
                .offset(x: 190, y: -180)
                .blur(radius: 26)
                .opacity(0.2)

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.22)
            }
        }
        .accessibilityHidden(true)
    }
}

enum EveeMaterialKind: Equatable {
    case rail
    case panel
    case hud

    var coreLayer: EveeMaterialLayer {
        self == .rail ? .rail : .panel
    }
}

private struct EveeMaterialSurface: ViewModifier {
    let kind: EveeMaterialKind
    @Environment(\.eveeAppearanceMode) private var appearanceMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let presentation = EveeMaterialPresentation.make(
            mode: appearanceMode,
            layer: kind.coreLayer,
            reduceTransparency: reduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )

        content.background {
            surface(presentation)
        }
    }

    @ViewBuilder
    private func surface(_ presentation: EveeMaterialPresentation) -> some View {
        if !presentation.usesTranslucency {
            baseColor
                .overlay(edge(presentation))
        } else if appearanceMode == .glass {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                nativeGlass(presentation)
            } else {
                materialFallback(presentation)
            }
#else
            materialFallback(presentation)
#endif
        } else {
            materialFallback(presentation)
        }
    }

    private func materialFallback(_ presentation: EveeMaterialPresentation) -> some View {
        Rectangle()
            .fill(materialStyle)
            .overlay(baseColor.opacity(presentation.tintOpacity))
            .overlay(edge(presentation))
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func nativeGlass(_ presentation: EveeMaterialPresentation) -> some View {
        Color.clear
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(baseColor.opacity(presentation.tintOpacity * 0.55))
            .overlay(edge(presentation))
    }
#endif

    private func edge(_ presentation: EveeMaterialPresentation) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(presentation.edgeOpacity),
                        EveeVisual.hairline.opacity(presentation.edgeOpacity * 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: presentation.edgeOpacity > 0 ? 1 : 0
            )
            .allowsHitTesting(false)
    }

    private var baseColor: Color {
        switch kind {
        case .rail: EveeVisual.sidebar
        case .panel: EveeVisual.surface
        case .hud: EveeVisual.elevatedSurface
        }
    }

    private var materialStyle: AnyShapeStyle {
        switch (appearanceMode == .glass, kind) {
        case (_, .rail): AnyShapeStyle(.ultraThinMaterial)
        case (true, .panel): AnyShapeStyle(.thinMaterial)
        case (true, .hud): AnyShapeStyle(.regularMaterial)
        case (false, .panel): AnyShapeStyle(.regularMaterial)
        case (false, .hud): AnyShapeStyle(.ultraThickMaterial)
        }
    }

    private var cornerRadius: CGFloat {
        kind == .rail ? 0 : EveeShape.panelCornerRadius
    }
}

extension View {
    func eveeMaterial(_ kind: EveeMaterialKind) -> some View {
        modifier(EveeMaterialSurface(kind: kind))
    }
}
