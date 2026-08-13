import EveeCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack {
            AnimaTheme.paper.ignoresSafeArea()

            if !store.modelReady {
                OnboardingView()
            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    routeContent
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            }

        }
        .tint(AnimaTheme.indigo)
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
                Button("Copy Text") { store.copyPendingTextDelivery() }
            }
            Button("Open Settings") {
                store.route = .settings
                clearFailedCaptureIfNeeded()
            }
            Button("Dismiss", role: .cancel) { clearFailedCaptureIfNeeded() }
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
