import EveeCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingMetadataResetConfirmation = false

    var body: some View {
        ZStack {
            AnimaTheme.paper.ignoresSafeArea()

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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                EveeMark(size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Evee").font(.system(size: 17, weight: .bold))
                    Text("by Anima").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            List(selection: $store.route) {
                Label("Workspace", systemImage: "rectangle.stack").tag(AppStore.Route.library)
                Label("Meetings", systemImage: "person.2.wave.2").tag(AppStore.Route.meetings)
                Label("Memos", systemImage: "waveform").tag(AppStore.Route.memos)
                Label("Dictionary", systemImage: "text.book.closed").tag(AppStore.Route.dictionary)
                Section {
                    Label("Settings", systemImage: "slider.horizontal.3").tag(AppStore.Route.settings)
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 8) {
                Text("GLOBAL SHORTCUTS").font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(.secondary)
                Label("Dictate or transform a selection", systemImage: "keyboard")
                    .font(.caption.weight(.medium))
                Text("Configure both in Settings").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(AnimaTheme.cloud.opacity(0.48))
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
            ContentUnavailableView("Choose a recording", systemImage: "waveform.badge.magnifyingglass", description: Text("Dictations, meetings and memos stay searchable on this Mac."))
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
