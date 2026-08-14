import EveeCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingMetadataResetConfirmation = false

    var body: some View {
        Group {
            if store.privacyModeEnabled {
                PrivacyModeView()
            } else {
                workspaceContent
            }
        }
        .tint(AnimaTheme.indigo)
    }

    private var workspaceContent: some View {
        ZStack {
            EveeVisual.canvas.ignoresSafeArea()

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
            if let warning = store.libraryRecoveryWarning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(warning)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    Button("Show in Finder") { store.revealPreservedLibraryFiles() }
                        .controlSize(.small)
                        .accessibilityLabel("Show preserved library data in Finder")
                        .accessibilityHint("Opens the private folder containing files Evee preserved for manual review.")
                    Button("Keep preserved data") { store.dismissLibraryRecoveryWarning() }
                        .controlSize(.small)
                        .accessibilityLabel("Dismiss preserved library data warning")
                        .accessibilityHint("Keeps the preserved data and hides this warning.")
                    if store.recordsQuarantineActive {
                        Button("Reset library metadata", role: .destructive) {
                            showingMetadataResetConfirmation = true
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Reset library metadata protection")
                        .accessibilityHint("Shows a confirmation before allowing future cleanup of unreferenced audio.")
                    }
                }
                .padding(10)
                .background(AnimaTheme.raisedSurface)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .contain)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let suggestion = store.meetingSuggestion {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.wave.2")
                        .foregroundStyle(AnimaTheme.indigo)
                        .accessibilityHidden(true)
                    Text("Meeting app detected: \(suggestion.applicationName). Start a meeting recording?")
                        .font(.callout)
                    Spacer(minLength: 12)
                    Button("Dismiss") { store.dismissMeetingSuggestion() }
                        .accessibilityLabel("Dismiss meeting suggestion for \(suggestion.applicationName)")
                        .accessibilityHint("Hides suggestions for this application for one hour.")
                    Button("Start Meeting") { Task { await store.startSuggestedMeeting() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Start meeting recording for \(suggestion.applicationName)")
                        .accessibilityHint("Starts recording only after you activate this button.")
                }
                .padding(10)
                .background(AnimaTheme.raisedSurface)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .contain)
            }
        }
        .confirmationDialog(
            "Reset library metadata protection?",
            isPresented: $showingMetadataResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset metadata protection", role: .destructive) {
                Task { await store.resetLibraryMetadataProtection() }
            }
            .accessibilityLabel("Confirm reset of library metadata protection")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel library metadata protection reset")
        } message: {
            Text("The preserved corrupt copy will remain, and no audio will be deleted by this action. Future maintenance may then remove audio that current library metadata does not reference.")
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
            status: WorkspaceNavigationPresentation.status(for: store.systemVoiceStatus)
        )
    }

    @ViewBuilder private var routeContent: some View {
        switch store.route {
        case .library: LibraryView(title: "Workspace", kind: nil)
        case .meetings: MeetingWorkspaceView()
        case .memos: LibraryView(title: "Memos", kind: .memo)
        case .dictionary: DictionaryView()
        case .settings: SettingsView()
        }
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
            .background(EveeVisual.canvas)
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

    private func clearFailedCaptureIfNeeded() {
        guard case .failed = store.captureState else { return }
        store.dismissCaptureFailure()
    }
}
