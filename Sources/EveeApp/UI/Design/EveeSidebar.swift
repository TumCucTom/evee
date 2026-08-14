import EveeCore
import SwiftUI

struct EveeSidebar: View {
    @Binding var selection: AppStore.Route
    let status: WorkspaceNavigationPresentation.Status

    @FocusState private var focusedRoute: AppStore.Route?

    var body: some View {
        VStack(spacing: 0) {
            brand
            navigation
            Spacer(minLength: EveeSpacing.large)
            statusModule
        }
        .padding(.horizontal, EveeSpacing.medium)
        .padding(.bottom, EveeSpacing.medium)
        .background(EveeVisual.sidebar)
    }

    private var brand: some View {
        HStack(spacing: EveeSpacing.small) {
            EveeMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Evee")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(EveeVisual.primaryText)
                Text("by Anima")
                    .font(EveeTypography.metadata)
                    .foregroundStyle(EveeVisual.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, EveeSpacing.xSmall)
        .padding(.vertical, EveeSpacing.large)
        .accessibilityElement(children: .combine)
    }

    private var navigation: some View {
        VStack(spacing: EveeSpacing.xSmall) {
            ForEach(WorkspaceNavigationPresentation.items) { item in
                EveeNavigationButton(
                    item: item,
                    route: route(for: item.route),
                    selection: $selection,
                    focusedRoute: $focusedRoute
                )
                if item.route == .memos {
                    Divider()
                        .padding(.vertical, EveeSpacing.xSmall)
                        .padding(.horizontal, EveeSpacing.small)
                }
            }
        }
        .onMoveCommand(perform: moveSelection)
    }

    private var statusModule: some View {
        VStack(alignment: .leading, spacing: EveeSpacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: EveeSpacing.small) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(statusTone.color)
                    .accessibilityHidden(true)
                Text(status.title)
                    .font(EveeTypography.sectionTitle)
                    .foregroundStyle(EveeVisual.primaryText)
                Spacer(minLength: 0)
                if status.isMicrophoneOpen {
                    Text("MIC OPEN")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(EveeVisual.destructive)
                }
            }

            Text(status.detail)
                .font(EveeTypography.metadata)
                .foregroundStyle(EveeVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let warningTitle = status.warningTitle {
                Label(warningTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(EveeTypography.metadata.weight(.semibold))
                    .foregroundStyle(EveeVisual.warning)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(warningTitle)
            }

            if status.phase == .ready {
                DisclosureGroup("Keyboard shortcuts") {
                    Button("Configure in Settings") { selection = .settings }
                        .buttonStyle(.link)
                        .accessibilityHint("Opens Evee Settings to configure dictation and selection transform shortcuts.")
                        .padding(.top, EveeSpacing.xSmall)
                }
                .font(EveeTypography.metadata)
                .foregroundStyle(EveeVisual.secondaryText)
            }
        }
        .padding(EveeSpacing.medium)
        .background(EveeVisual.surface)
        .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                .stroke(status.hasWarning ? EveeVisual.warning : EveeVisual.hairline, lineWidth: status.hasWarning ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusTone: EveeStatusTone {
        if status.hasWarning { return .warning }
        return switch status.phase {
        case .recording, .captureStarting, .wakeListening: .accent
        case .protected: .success
        case .failed: .destructive
        default: .neutral
        }
    }

    private func route(for route: WorkspaceRouteKind) -> AppStore.Route {
        switch route {
        case .library: .library
        case .meetings: .meetings
        case .memos: .memos
        case .dictionary: .dictionary
        case .settings: .settings
        }
    }

    private func navigationRoute(for route: AppStore.Route) -> WorkspaceRouteKind {
        switch route {
        case .library: .library
        case .meetings: .meetings
        case .memos: .memos
        case .dictionary: .dictionary
        case .settings: .settings
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let moveDirection: WorkspaceNavigationPresentation.MoveDirection?
        switch direction {
        case .up:
            moveDirection = .previous
        case .down:
            moveDirection = .next
        default:
            moveDirection = nil
        }

        guard let moveDirection else { return }
        let destination = WorkspaceNavigationPresentation.move(
            from: navigationRoute(for: focusedRoute ?? selection),
            direction: moveDirection
        )
        let route = route(for: destination)
        selection = route
        focusedRoute = route
    }
}

private struct EveeNavigationButton: View {
    let item: WorkspaceNavigationPresentation.Item
    let route: AppStore.Route
    @Binding var selection: AppStore.Route
    let focusedRoute: FocusState<AppStore.Route?>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isSelected: Bool { selection == route }
    private var isFocused: Bool { focusedRoute.wrappedValue == route }

    var body: some View {
        Button {
            selection = route
        } label: {
            HStack(spacing: EveeSpacing.medium) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? EveeVisual.accent : EveeVisual.secondaryText)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(EveeTypography.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(EveeVisual.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, EveeSpacing.medium)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .background(rowSurface)
            .clipShape(RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EveeShape.compactCornerRadius, style: .continuous)
                    .stroke(isFocused ? EveeVisual.accent : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .focused(focusedRoute, equals: route)
        .onHover { isHovering = $0 }
        .animation(EveeVisual.animation(.selection, reduceMotion: reduceMotion), value: isHovering)
        .animation(EveeVisual.animation(.selection, reduceMotion: reduceMotion), value: isSelected)
        .accessibilityLabel(item.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Open \(item.title)")
    }

    private var rowSurface: Color {
        if isSelected { return EveeVisual.surface }
        if isHovering { return EveeVisual.surface.opacity(0.62) }
        return .clear
    }
}
