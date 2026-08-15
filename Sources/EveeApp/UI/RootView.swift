import EveeCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarFocusRequest: Int?
    @State private var hasTransferredOnboardingFocus = false

    var body: some View {
        Group {
            if store.privacyModeEnabled {
                PrivacyModeView()
            } else {
                workspaceContent
            }
        }
        .tint(AnimaTheme.indigo)
        .onChange(of: store.modelReady) { wasReady, isReady in
            guard !wasReady, isReady, !hasTransferredOnboardingFocus, !store.privacyModeEnabled else { return }
            hasTransferredOnboardingFocus = true
            sidebarFocusRequest = 1
        }
    }

    private var workspaceContent: some View {
        ZStack {
            EveeCanvas().ignoresSafeArea()

            if !store.modelReady {
                OnboardingView()
            } else {
                switch layoutMode {
                case .threeColumn:
                    NavigationSplitView {
                        sidebar
                    } content: {
                        routeContent
                    } detail: {
                        detail
                    }
                    .navigationSplitViewStyle(.balanced)
                case .sidebarAndDetail:
                    NavigationSplitView {
                        sidebar
                    } detail: {
                        routeContent
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }

        }
        .tint(AnimaTheme.indigo)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let suggestion = store.meetingSuggestion {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: EveeSpacing.medium) {
                        meetingSuggestionHeading(suggestion)
                        Spacer(minLength: EveeSpacing.medium)
                        meetingSuggestionActions(suggestion)
                    }
                    VStack(alignment: .leading, spacing: EveeSpacing.small) {
                        meetingSuggestionHeading(suggestion)
                        meetingSuggestionActions(suggestion)
                    }
                }
                .padding(EveeSpacing.medium)
                .background(AnimaTheme.raisedSurface)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .contain)
            }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { store.statusMessage != nil },
            set: {
                if !$0 {
                    store.statusMessage = nil
                    store.dismissCaptureFailure()
                }
            }
        )) {
            if store.pendingDelivery != nil {
                Button("Retry Paste") { Task { await store.retryPendingTextDelivery() } }
                    .accessibilityLabel("Retry pasting the pending text")
                Button("Copy Text") { store.copyPendingTextDelivery() }
                    .accessibilityLabel("Copy the pending text to the clipboard")
            }
            Button("Open Settings") {
                store.route = .settings
                clearFailedCaptureIfNeeded()
            }
            .accessibilityLabel("Open Evee Settings")
            Button("Dismiss", role: .cancel) { clearFailedCaptureIfNeeded() }
                .accessibilityLabel("Dismiss Evee status message")
        } message: { Text(store.statusMessage ?? "") }
    }

    private var sidebar: some View {
        EveeSidebar(
            selection: $store.route,
            status: WorkspaceNavigationPresentation.status(for: store.systemVoiceStatus),
            focusRequest: $sidebarFocusRequest
        )
    }

    @ViewBuilder private var routeContent: some View {
        Group {
            switch store.route {
            case .library: LibraryView(title: "Workspace", kind: nil)
            case .meetings: MeetingWorkspaceView()
            case .memos: LibraryView(title: "Memos", kind: .memo)
            case .dictionary: DictionaryView()
            case .settings: SettingsView()
            }
        }
        .id(routeKind)
        .transition(routeTransition)
        .animation(EveeVisual.animation(.route, reduceMotion: reduceMotion), value: routeKind)
    }

    private var routeTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .offset(y: 3))
    }

    @ViewBuilder private var detail: some View {
        if let record = store.selectedRecord {
            RecordDetailView(record: record)
                .id(record.id)
        }
        else {
            EveeEmptyState(
                "Choose a recording",
                message: "Dictations, meetings and memos stay searchable on this Mac."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var layoutMode: RootLayoutMode {
        RootLayoutMode.route(routeKind, captureState: store.captureState)
    }

    private var routeKind: WorkspaceRouteKind {
        switch store.route {
        case .library: .library
        case .meetings: .meetings
        case .memos: .memos
        case .dictionary: .dictionary
        case .settings: .settings
        }
    }

    private var alertTitle: String {
        if case .failed = store.captureState { return "Capture stopped" }
        if case .checkpointed = store.captureState { return "Capture protected" }
        return "Evee needs attention"
    }

    private func meetingSuggestionHeading(_ suggestion: MeetingSuggestion) -> some View {
        Label(
            "Meeting app detected: \(suggestion.applicationName). Start a meeting recording?",
            systemImage: "person.2.wave.2"
        )
        .font(.callout)
        .foregroundStyle(EveeVisual.primaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func meetingSuggestionActions(_ suggestion: MeetingSuggestion) -> some View {
        HStack(spacing: EveeSpacing.small) {
            Button("Dismiss") { store.dismissMeetingSuggestion() }
                .accessibilityLabel("Dismiss meeting suggestion for \(suggestion.applicationName)")
                .accessibilityHint("Hides suggestions for this application for one hour.")
            Button("Start Meeting") { Task { await store.startSuggestedMeeting() } }
                .buttonStyle(EveeCaptureButtonStyle())
                .accessibilityLabel("Start meeting recording for \(suggestion.applicationName)")
                .accessibilityHint("Starts recording only after you activate this button.")
        }
    }

    private func clearFailedCaptureIfNeeded() {
        guard case .failed = store.captureState else { return }
        store.dismissCaptureFailure()
    }
}
