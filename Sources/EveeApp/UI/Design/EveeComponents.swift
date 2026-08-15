import EveeCore
import SwiftUI

struct EveePageHeader<Status: View, Actions: View>: View {
    let title: String
    let subtitle: String?
    private let status: Status
    private let actions: Actions

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder status: () -> Status,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.status = status()
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: EveeSpacing.large) {
                heading
                Spacer(minLength: EveeSpacing.large)
                actions
            }

            VStack(alignment: .leading, spacing: EveeSpacing.medium) {
                heading
                actions
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, EveeSpacing.medium)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: EveeSpacing.xSmall) {
            Text(title)
                .font(EveeTypography.pageTitle)
                .foregroundStyle(EveeVisual.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(EveeTypography.body)
                    .foregroundStyle(EveeVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status
                .padding(.top, EveeSpacing.xSmall)
        }
    }
}

extension EveePageHeader where Status == EmptyView, Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle, status: { EmptyView() }, actions: { EmptyView() })
    }
}

extension EveePageHeader where Status == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(title, subtitle: subtitle, status: { EmptyView() }, actions: actions)
    }
}

struct EveeAdaptiveActionRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: EveeSpacing.small) { content }
            VStack(alignment: .leading, spacing: EveeSpacing.small) { content }
        }
    }
}

struct EveeSettingsSection<Content: View>: View {
    let title: String
    private let content: Content
    @Environment(\.eveeAppearanceMode) private var appearanceMode

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EveeSpacing.medium) {
            Text(title)
                .font(EveeTypography.sectionTitle)
                .foregroundStyle(EveeVisual.primaryText)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: EveeSpacing.medium) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EveeSpacing.large)
        .eveeMaterial(.panel)
        .clipShape(RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous)
                .stroke(EveeVisual.hairline, lineWidth: 1)
        }
        .shadow(
            color: EveeVisual.primaryText.opacity(appearanceMode == .glass ? 0.12 : 0),
            radius: appearanceMode == .glass ? 18 : 0,
            y: appearanceMode == .glass ? 7 : 0
        )
        .accessibilityElement(children: .contain)
    }
}

struct EveePanel<Content: View>: View {
    private let isElevated: Bool
    private let content: Content
    @Environment(\.eveeAppearanceMode) private var appearanceMode

    init(isElevated: Bool = false, @ViewBuilder content: () -> Content) {
        self.isElevated = isElevated
        self.content = content()
    }

    var body: some View {
        content
            .padding(EveeSpacing.large)
            .eveeMaterial(.panel)
            .clipShape(RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EveeShape.panelCornerRadius, style: .continuous)
                    .stroke(EveeVisual.hairline, lineWidth: 1)
            }
            .shadow(
                color: EveeVisual.primaryText.opacity(appearanceMode == .glass ? 0.14 : (isElevated ? 0.08 : 0)),
                radius: appearanceMode == .glass ? 20 : (isElevated ? 14 : 0),
                y: appearanceMode == .glass ? 8 : (isElevated ? 5 : 0)
            )
    }
}

enum EveeStatusTone {
    case neutral
    case accent
    case success
    case warning
    case destructive

    init(_ tone: VoiceStatusTone) {
        self = switch tone {
        case .neutral: .neutral
        case .accent: .accent
        case .success: .success
        case .warning: .warning
        case .destructive: .destructive
        }
    }

    var color: Color {
        switch self {
        case .neutral: EveeVisual.secondaryText
        case .accent: EveeVisual.accent
        case .success: EveeVisual.success
        case .warning: EveeVisual.warning
        case .destructive: EveeVisual.destructive
        }
    }
}

struct EveeStatusChip: View {
    let label: String
    let systemImage: String
    var tone: EveeStatusTone = .neutral

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(EveeTypography.metadata)
            .foregroundStyle(tone.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, EveeSpacing.small)
            .frame(minHeight: 24)
            .background(tone.color.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(tone.color.opacity(0.22), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .help(label)
    }
}

struct EveeEmptyState<Action: View>: View {
    let title: String
    let message: String
    private let action: Action

    init(_ title: String, message: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: EveeSpacing.medium) {
            VoiceThread(presentation: .make(phase: .ready, level: 0), lineWidth: 1.5)
                .frame(width: 112, height: 24)
            Text(title)
                .font(EveeTypography.sectionTitle)
                .foregroundStyle(EveeVisual.primaryText)
            Text(message)
                .font(EveeTypography.body)
                .foregroundStyle(EveeVisual.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
                .padding(.top, EveeSpacing.xSmall)
        }
        .frame(maxWidth: 360)
        .padding(EveeSpacing.xLarge)
    }
}

extension EveeEmptyState where Action == EmptyView {
    init(_ title: String, message: String) {
        self.init(title, message: message) { EmptyView() }
    }
}

struct EveeSearchField: View {
    @Binding var text: String
    var prompt = "Search"

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: EveeSpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(EveeVisual.tertiaryText)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(EveeTypography.body)
                .focused($isFocused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(EveeVisual.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, EveeSpacing.medium)
        .frame(minHeight: 34)
        .background(EveeVisual.surface, in: RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                .stroke(isFocused ? EveeVisual.accent : EveeVisual.hairline, lineWidth: isFocused ? 2 : 1)
        }
    }
}

struct EveePrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EveeTypography.button)
            .foregroundStyle(EveeVisual.primaryActionForeground)
            .padding(.horizontal, EveeSpacing.large)
            .frame(minHeight: 36)
            .background(EveeVisual.accent)
            .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                        .stroke(EveeVisual.hairline, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
            .saturation(isEnabled ? 1 : 0.25)
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.62)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(EveeVisual.animation(.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct EveeCaptureButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EveeTypography.button)
            .foregroundStyle(EveeVisual.primaryActionForeground)
            .padding(.horizontal, EveeSpacing.large)
            .frame(minHeight: 36)
            .background(EveeVisual.spectralGradient)
            .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                        .stroke(EveeVisual.hairline, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
            .saturation(isEnabled ? 1 : 0.25)
            .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.62)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(EveeVisual.animation(.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct EveeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EveeTypography.button)
            .foregroundStyle(EveeVisual.primaryText)
            .padding(.horizontal, EveeSpacing.medium)
            .frame(minHeight: 34)
            .background(EveeVisual.surface)
            .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                    .stroke(EveeVisual.hairline, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(EveeVisual.animation(.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct EveeDestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let presentation = EveeButtonStatePresentation.destructive(isEnabled: isEnabled)
        return configuration.label
            .font(EveeTypography.button)
            .foregroundStyle(EveeVisual.destructive)
            .padding(.horizontal, EveeSpacing.medium)
            .frame(minHeight: 34)
            .background(EveeVisual.destructive.opacity(configuration.isPressed ? 0.14 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
            .overlay {
                if presentation.showsDisabledBoundary {
                    RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                        .stroke(EveeVisual.hairline, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
            .saturation(presentation.saturation)
            .opacity(presentation.opacity)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)
            .animation(EveeVisual.animation(.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Source-compatible migration route for existing journey views.
typealias AlphaButtonStyle = EveePrimaryButtonStyle
