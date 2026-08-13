import AppKit
import AVFoundation
import Combine
import EveeCore
import Foundation
import KeyboardShortcuts
import UniformTypeIdentifiers

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.command, .option]))
    static let transformSelection = Self("transformSelection", default: .init(.space, modifiers: [.command, .option, .shift]))
    static let toggleHandsFree = Self("toggleHandsFree")
}

private enum CaptureTerminationCheckpointError: LocalizedError {
    case invalidAudio(URL)
    case missingTrack(AudioTrackRole)
    case requiredTracksUnavailable(WorkspaceRecordKind, String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio(let url):
            "The captured audio at \(url.lastPathComponent) is not playable. Evee kept the source file and stayed open."
        case .missingTrack(let role):
            "The \(role.rawValue) capture was written but could not be added to its recovery manifest."
        case .requiredTracksUnavailable(let kind, let detail):
            "The \(kind.rawValue) recovery checkpoint does not contain its required playable audio. \(detail)"
        }
    }
}

@MainActor
final class AppStore: ObservableObject, ApplicationTerminationCheckpoint {
    typealias ModelDownloaderFactory = @Sendable (SpeechModel) throws -> any LocalModelDownloading
    typealias WakeListenerFactory = @Sendable () -> any WakePhraseListening
    typealias MicrophonePermissionProvider = @MainActor @Sendable () -> Bool
    typealias MicrophoneStarter = @MainActor @Sendable (URL, String?, Bool) async throws -> Void
    typealias MicrophoneStopper = @MainActor @Sendable () async throws -> URL
    typealias MicrophoneRecordingProbe = @MainActor @Sendable () -> Bool
    typealias SystemAudioStarter = @MainActor @Sendable (URL) async throws -> Void
    typealias SystemAudioStopper = @MainActor @Sendable () async throws -> Void
    typealias TextDeliverer = @MainActor @Sendable (String, FrontmostApplication?, TextDeliveryMode, String?) async throws -> Void
    typealias RecoveryTranscriberFactory = @MainActor @Sendable (SpeechModel) throws -> any LocalTranscriber

    enum Route: Hashable { case library, meetings, memos, dictionary, settings }
    struct PendingTextDelivery {
        var text: String
        var target: FrontmostApplication?
        var mode: TextDeliveryMode
        var expectedSelectedText: String?
    }

    @Published var route: Route = .library
    @Published var records: [WorkspaceRecord] = []
    @Published var settings = EveeSettings()
    @Published var captureState: CaptureState = .idle {
        didSet {
            guard settings.audioCuesEnabled else { return }
            CaptureAudioCuePlayer.playTransition(from: oldValue, to: captureState)
        }
    }
    @Published var search = ""
    @Published var selectedRecordID: UUID?
    @Published private(set) var modelDownloadState: ModelDownloadState = .idle
    @Published private(set) var modelDownloadNeedsRetry = false
    @Published private(set) var modelAvailabilityWarning: String?
    @Published var statusMessage: String?
    @Published var meetingTitle = ""
    @Published var meetingNotes = ""
    @Published var webhookSecret = ""
    @Published private var indexedSearchResults: [WorkspaceRecord]?
    @Published private(set) var localAPICredentials: LocalAPICredentials?
    @Published private(set) var pendingDelivery: PendingTextDelivery?
    @Published private(set) var recoverableCaptures: [CaptureRecoveryManifest] = []
    @Published private(set) var recoveryTrackAssessments: [UUID: [RecoveryTrackAssessment]] = [:]
    @Published private(set) var libraryRecoveryWarning: String?
    @Published private(set) var recordsQuarantineActive = false
    private var preservedCorruptURLs: [URL] = []
    @Published private(set) var captureKind: WorkspaceRecordKind?
    @Published private(set) var captureOperation: WorkspaceRecordOperation?
    @Published private(set) var isSystemAudioActive = false
    @Published private(set) var isPreparingMeetingDiarization = false
    @Published private(set) var meetingDiarizationReady = false
    @Published private(set) var accessibilityPermissionGranted = TextDelivery.isAccessibilityTrusted
    @Published private(set) var microphonePermissionGranted = false
    @Published private(set) var liveMeetingTranscript: [LiveMeetingTranscriptUpdate] = []
    @Published private(set) var liveMeetingStatus: String?
    @Published private(set) var availableUpdate: EveeRelease?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var microphoneHealthWarning: String?
    @Published private(set) var hotMicState: HotMicState = .disabled

    var modelProgress: ModelProgress? {
        guard case .downloading(_, let progress) = modelDownloadState else { return nil }
        return progress
    }

    var modelReady: Bool {
        if case .ready = modelDownloadState { return true }
        return false
    }

    func isSpeechModelSupported(_ model: SpeechModel) -> Bool {
        speechModelAvailability.isSupported(model)
    }

    func speechModelUnavailableReason(_ model: SpeechModel) -> String? {
        speechModelAvailability.unavailableReason(for: model)
    }

    var hotMicActive: Bool {
        hotMicState == .active
    }

    var webhookOutboxCount: Int {
        records.reduce(into: 0) { count, record in
            count += record.webhookDeliveries.filter {
                ($0.state != .delivered && $0.state != .cancelled) || $0.requiresExplicitReplacement
            }.count
        }
    }

    let recorder = MicrophoneRecorder()
    private let systemAudioRecorder = SystemAudioRecorder()
    private let library: LibraryStore
    private let cleanup = TextCleanupPipeline()
    private let selectionTransform = SelectionTransformPipeline()
    private let writingEnhancements = WritingEnhancementPipeline()
    private let meetingDiarizer = FluidOfflineMeetingDiarizer()
    private let api = LocalAPIServer()
    private let secretStore = KeychainSecretStore()
    private let modelDownloaderFactory: ModelDownloaderFactory
    private let wakeListenerFactory: WakeListenerFactory
    private let microphonePermissionProvider: MicrophonePermissionProvider
    private let modelDownloadDefaults: UserDefaults?
    private let speechModelAvailability: SpeechModelAvailability
    private let microphoneStarter: MicrophoneStarter?
    private let microphoneStopper: MicrophoneStopper?
    private let microphoneRecordingProbe: MicrophoneRecordingProbe?
    private let systemAudioStarter: SystemAudioStarter?
    private let systemAudioStopper: SystemAudioStopper?
    private let textDeliverer: TextDeliverer
    private let recoveryTranscriberFactory: RecoveryTranscriberFactory
    private var transcriber: (any LocalTranscriber)?
    private var modelDownloadStateMachine = ModelDownloadStateMachine()
    private var modelDownloadOperation: LifecycleOperation?
    private var modelDownloadTask: Task<Void, Never>?
    private var modelsRequiringRepair: Set<SpeechModel> = []
    private var activeAudioURL: URL?
    private var activeSystemAudioURL: URL?
    private var activeRecoveryID: UUID?
    private var activeRecoveryDirectory: URL?
    private var activeRecoveryTrackSelection: RecoveryTrackSelection?
    private var activeApplication: FrontmostApplication?
    private var activeKind: WorkspaceRecordKind = .dictation
    private var activeOperation: WorkspaceRecordOperation = .capture
    private var activeSelectedText: String?
    private var captureStartedAt: Date?
    private var microphoneTrackStartedAt: Date?
    private var systemTrackStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var pushToTalkHeld = false
    private var transformShortcutHeld = false
    private var activeShortcut: CaptureShortcut?
    private var stopRequestedDuringStart: UUID?
    private var shortcutTask: Task<Void, Never>?
    private var meetingDraftCaptureID: UUID?
    private var didBootstrap = false
    private var webhookRetryTask: Task<Void, Never>?
    private let webhookOutboxTransactions: WebhookOutboxTransactions
    private let webhookOutboxCoordinator: WebhookOutboxCoordinator
    private var configuredWebhookDestination: String?
    private var pendingWebhookTerminationRecords: [WorkspaceRecord] = []
    private var liveMeetingTranscriber: LiveMeetingTranscriber?
    private var liveMeetingUpdateTask: Task<Void, Never>?
    private var microphoneHealthTask: Task<Void, Never>?
    private var lastNonSilentAudioAt = Date.distantPast
    private var wakePhraseListener: (any WakePhraseListening)?
    private var hotMicStateMachine = HotMicStateMachine()
    private var hotMicTranscriptTask: Task<Void, Never>?
    private var suppressDraftAutosave = false
    private var terminationCheckpointRecoveryID: UUID?
    private var terminationWorkGate = TerminationWorkGate()
    private var microphoneStartTask: Task<Void, Error>?
    private var systemAudioStartTask: Task<Void, Error>?
    private var deliveryTask: Task<Void, Error>?
    private struct RecordCommitOperation {
        var id: UInt64
        var recoveryID: UUID?
        var task: Task<WorkspaceRecord, Error>
    }
    private var recordCommitOperation: RecordCommitOperation?
    private var recordCommitSequence: UInt64 = 0

    private enum CaptureShortcut: Equatable, Sendable { case dictation, selectionTransform }
    private enum PushToTalkEvent: Sendable {
        case dictationDown
        case dictationUp
        case transformDown
        case transformUp
    }
    private let shortcutEvents: AsyncStream<PushToTalkEvent>
    private let shortcutContinuation: AsyncStream<PushToTalkEvent>.Continuation

    private enum CaptureLifecycle: Equatable {
        case idle
        case starting(UUID)
        case recording(UUID)
        case finishing(UUID)
        case cancelling(UUID)
    }

    private var captureLifecycle: CaptureLifecycle = .idle

    var terminationWorkGeneration: UInt64 { terminationWorkGate.generation }
    var isTerminationCheckpointActive: Bool { terminationWorkGate.isCheckpointActive }
    private var isApplicationTerminationCheckpointing: Bool { terminationWorkGate.isCheckpointActive }

    @discardableResult
    func prepareForTerminationCheckpoint() -> UInt64 {
        let generation = terminationWorkGate.prepareCheckpoint()
        deliveryTask?.cancel()
        hotMicStateMachine.disable()
        publishHotMicState()
        return generation
    }

    var captureShutdownPlan: CaptureShutdownPlan {
        let snapshot: CaptureLifecycleSnapshot
        if case .delivering = captureState {
            snapshot = .delivering
        } else {
            snapshot = switch captureLifecycle {
            case .idle:
                if case .failed = captureState { .failed } else { .idle }
            case .starting:
                .starting(kind: activeKind, recoveryID: activeRecoveryID)
            case .recording(let id):
                .recording(kind: activeKind, recoveryID: activeRecoveryID ?? id)
            case .finishing(let id):
                .finishing(recoveryID: activeRecoveryID ?? id)
            case .cancelling:
                if let terminationCheckpointRecoveryID {
                    .finishing(recoveryID: terminationCheckpointRecoveryID)
                } else {
                    .cancelling
                }
            }
        }

        let plan = CaptureShutdownPlan.make(for: snapshot)
        guard plan == .terminateImmediately else { return plan }
        let hasRunningApplicationService = localAPICredentials != nil ||
            hotMicState != .disabled ||
            webhookRetryTask != nil ||
            !pendingWebhookTerminationRecords.isEmpty ||
            records.contains { record in
                record.webhookDeliveries.contains {
                    $0.state != .delivered && $0.state != .cancelled
                }
            }
        return hasRunningApplicationService ? .invalidateDeliveryAndAwaitCommit : .terminateImmediately
    }

    init(
        modelDownloaderFactory: @escaping ModelDownloaderFactory = { try TranscriberFactory.make($0) },
        wakeListenerFactory: @escaping WakeListenerFactory = { WakePhraseListener() },
        microphonePermissionProvider: @escaping MicrophonePermissionProvider = { MicrophoneRecorder.isPermissionGranted },
        modelDownloadDefaults: UserDefaults? = .standard,
        library: LibraryStore = .shared,
        microphoneStarter: MicrophoneStarter? = nil,
        microphoneStopper: MicrophoneStopper? = nil,
        microphoneRecordingProbe: MicrophoneRecordingProbe? = nil,
        systemAudioStarter: SystemAudioStarter? = nil,
        systemAudioStopper: SystemAudioStopper? = nil,
        textDeliverer: @escaping TextDeliverer = { text, target, mode, expectedSelectedText in
            try await TextDelivery.deliver(
                text,
                to: target,
                mode: mode,
                expectedSelectedText: expectedSelectedText
            )
        },
        recoveryTranscriberFactory: @escaping RecoveryTranscriberFactory = { try TranscriberFactory.make($0) },
        speechModelAvailability: SpeechModelAvailability = .current
    ) {
        self.modelDownloaderFactory = modelDownloaderFactory
        self.wakeListenerFactory = wakeListenerFactory
        self.microphonePermissionProvider = microphonePermissionProvider
        self.modelDownloadDefaults = modelDownloadDefaults
        self.speechModelAvailability = speechModelAvailability
        self.library = library
        self.microphoneStarter = microphoneStarter
        self.microphoneStopper = microphoneStopper
        self.microphoneRecordingProbe = microphoneRecordingProbe
        self.systemAudioStarter = systemAudioStarter
        self.systemAudioStopper = systemAudioStopper
        self.textDeliverer = textDeliverer
        self.recoveryTranscriberFactory = recoveryTranscriberFactory
        self.microphonePermissionGranted = microphonePermissionProvider()
        let webhookOutboxTransactions = WebhookOutboxTransactions()
        self.webhookOutboxTransactions = webhookOutboxTransactions
        self.webhookOutboxCoordinator = WebhookOutboxCoordinator(transactions: webhookOutboxTransactions)
        let eventPair = AsyncStream<PushToTalkEvent>.makeStream()
        shortcutEvents = eventPair.stream
        shortcutContinuation = eventPair.continuation

        recorder.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self, case .recording(let startedAt, _) = self.captureState else { return }
                if level > 0.01 {
                    self.lastNonSilentAudioAt = .now
                    self.microphoneHealthWarning = nil
                }
                self.captureState = .recording(startedAt: startedAt, level: level)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($meetingTitle, $meetingNotes)
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] title, notes in
                Task { @MainActor in
                    await self?.autosaveMeetingDraft(title: title, notes: notes)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($search.removeDuplicates(), $route.removeDuplicates())
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] query, route in
                Task { @MainActor in await self?.refreshIndexedSearch(query: query, route: route) }
            }
            .store(in: &cancellables)

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            self?.shortcutContinuation.yield(.dictationDown)
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.shortcutContinuation.yield(.dictationUp)
        }
        KeyboardShortcuts.onKeyDown(for: .transformSelection) { [weak self] in
            self?.shortcutContinuation.yield(.transformDown)
        }
        KeyboardShortcuts.onKeyUp(for: .transformSelection) { [weak self] in
            self?.shortcutContinuation.yield(.transformUp)
        }
        KeyboardShortcuts.onKeyUp(for: .toggleHandsFree) { [weak self] in
            Task { @MainActor in await self?.toggleHandsFreeDictation() }
        }
        shortcutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.shortcutEvents {
                guard !self.isApplicationTerminationCheckpointing else { continue }
                switch event {
                case .dictationDown:
                    guard !self.pushToTalkHeld else { continue }
                    self.pushToTalkHeld = true
                    guard self.activeShortcut == nil else { continue }
                    self.activeShortcut = .dictation
                    await self.beginDictation()
                    if self.captureLifecycle == .idle { self.activeShortcut = nil }
                case .dictationUp:
                    self.pushToTalkHeld = false
                    guard self.activeShortcut == .dictation else { continue }
                    self.activeShortcut = nil
                    await self.finishCapture()
                case .transformDown:
                    guard !self.transformShortcutHeld else { continue }
                    self.transformShortcutHeld = true
                    guard self.activeShortcut == nil else { continue }
                    self.activeShortcut = .selectionTransform
                    await self.beginSelectionTransform()
                    if self.captureLifecycle == .idle { self.activeShortcut = nil }
                case .transformUp:
                    self.transformShortcutHeld = false
                    guard self.activeShortcut == .selectionTransform else { continue }
                    self.activeShortcut = nil
                    await self.finishCapture()
                }
            }
        }
    }

    var filteredRecords: [WorkspaceRecord] {
        let kindMatches: (WorkspaceRecord) -> Bool = { record in
            switch self.route {
            case .meetings: record.kind == .meeting
            case .memos: record.kind == .memo
            default: true
            }
        }
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return records.filter(kindMatches)
        }
        return (indexedSearchResults ?? []).filter(kindMatches)
    }

    private func refreshIndexedSearch(query: String, route: Route) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            indexedSearchResults = nil
            return
        }
        let kind: WorkspaceRecordKind? = switch route {
        case .meetings: .meeting
        case .memos: .memo
        default: nil
        }
        do {
            let result = try await library.search(trimmed, kind: kind, limit: 200)
            guard search.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed, self.route == route else { return }
            indexedSearchResults = result
        } catch {
            guard search.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed, self.route == route else { return }
            indexedSearchResults = []
            statusMessage = error.localizedDescription
        }
    }

    var selectedRecord: WorkspaceRecord? {
        get { selectedRecordID.flatMap { id in records.first(where: { $0.id == id }) } }
        set { selectedRecordID = newValue?.id }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            try await library.prepare()
            var preservedCorruptURLs: [URL] = []
            let settingsLoad = try await library.loadSettingsRecoveringCorruption()
            settings = settingsLoad.value
            if let preserved = settingsLoad.preservedCorruptURL { preservedCorruptURLs.append(preserved) }
            let settingsWereRecovered = settingsLoad.preservedCorruptURL != nil
            if !settingsWereRecovered {
                let helperStorageRoot = await library.rootURL
                do {
                    let recovery = try await MCPOwnedRegistration.recover(
                        allowedRootURLs: [FileManager.default.homeDirectoryForCurrentUser],
                        storageRootURL: helperStorageRoot,
                        settings: settings,
                        saveSettings: { [library] settings in try await library.save(settings) }
                    )
                    settings = try await library.loadSettings()
                    if !recovery.cleanupFailures.isEmpty {
                        statusMessage = recovery.authorizationDisabled
                            ? "Local helper access is disabled. An unfinished client registration needs manual cleanup."
                            : "Local helper access remains enabled because the setting could not be saved. Registration recovery needs manual cleanup."
                    }
                } catch {
                    let recoveryError = error
                    var disabled = settings
                    disabled.mcpEnabled = false
                    do {
                        try await library.save(disabled)
                        settings = disabled
                        statusMessage = "Local helper access is disabled. Registration recovery needs manual cleanup: \(recoveryError.localizedDescription)"
                    } catch {
                        settings = (try? await library.loadSettings()) ?? settings
                        statusMessage = settings.mcpEnabled
                            ? "Local helper access remains enabled because the setting could not be saved: \(error.localizedDescription)"
                            : "Local helper access is disabled. Registration recovery needs manual cleanup: \(recoveryError.localizedDescription)"
                    }
                }
            }
            let persistedModel = settings.model
            let safeModel = speechModelAvailability.safeSelection(for: persistedModel)
            if safeModel != persistedModel {
                settings.model = safeModel
                try await library.save(settings)
                let warning = speechModelAvailability.unavailableReason(for: persistedModel)
                    ?? "The saved speech model is unavailable on this Mac. Evee selected \(safeModel.title)."
                modelAvailabilityWarning = warning
                statusMessage = [warning, statusMessage].compactMap { $0 }.joined(separator: " ")
            }
            configuredWebhookDestination = normalizedWebhookDestination(settings.webhookURL)
            try await loadAndMigrateSecrets()
            let recordsLoad = try await library.loadRecordsRecoveringCorruption()
            records = recordsLoad.value.sorted { $0.createdAt > $1.createdAt }
            if let preserved = recordsLoad.preservedCorruptURL { preservedCorruptURLs.append(preserved) }
            recordsQuarantineActive = try await library.recordsQuarantine() != nil
            let recordsWereRecovered = recordsQuarantineActive
            if recordsLoad.manualRecoveryWarning != nil {
                let libraryRoot = await library.rootURL
                preservedCorruptURLs.append(libraryRoot.appendingPathComponent("Corrupt", isDirectory: true))
            }
            if !recordsWereRecovered {
                if settings.historyRetentionDays > 0 {
                    let cutoff = Calendar.current.date(byAdding: .day, value: -settings.historyRetentionDays, to: .now) ?? .distantPast
                    _ = try await library.purgeRecords(olderThan: cutoff)
                    records = try await library.loadRecords().sorted { $0.createdAt > $1.createdAt }
                }
                await retireUnsupportedWebhookPayloads()
                try await library.reconcileAudioStorage()
            }
            let draftLoad = try await library.loadMeetingDraftRecoveringCorruption()
            if let preserved = draftLoad.preservedCorruptURL { preservedCorruptURLs.append(preserved) }
            if let draft = draftLoad.value {
                suppressDraftAutosave = true
                meetingDraftCaptureID = draft.captureID
                meetingTitle = draft.title
                meetingNotes = draft.notes
                suppressDraftAutosave = false
            }
            await refreshRecoverableCaptures()
            if !preservedCorruptURLs.isEmpty {
                let paths = Array(Set(preservedCorruptURLs.map(\.path))).sorted()
                self.preservedCorruptURLs = paths.map { URL(fileURLWithPath: $0) }
                let protection = recordsQuarantineActive
                    ? " Record-audio cleanup remains disabled until you explicitly reset library metadata protection."
                    : ""
                let recoverySummary = recordsLoad.manualRecoveryWarning
                    ?? "Evee preserved unreadable local data and continued with safe defaults."
                libraryRecoveryWarning = "\(recoverySummary)\(protection) Review this private location before deleting anything:\n\(paths.joined(separator: "\n"))"
            }
            let selectedProvider = try modelDownloaderFactory(settings.model)
            transcriber = selectedProvider as? any LocalTranscriber
            reconcileModelDownloadCache(selectedProvider, model: settings.model)
            refreshPermissionState()
            if settings.localAPIEnabled { localAPICredentials = try await api.startWithCredentials(port: settings.localAPIPort) }
            if settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await cancelWebhookOutbox()
            } else {
                await retryPendingWebhookDeliveries()
            }
            await updateHotMicState()
        } catch {
            didBootstrap = false
            statusMessage = error.localizedDescription
        }
    }

    func saveSettings() async {
        if let reason = speechModelAvailability.unavailableReason(for: settings.model) {
            modelAvailabilityWarning = reason
            statusMessage = reason
            return
        }
        do {
            let destinationValue = normalizedWebhookDestination(settings.webhookURL)
            if let destinationValue {
                guard let destination = URL(string: destinationValue) else { throw WebhookEndpointError.invalidURL }
                try WebhookEndpointPolicy.validate(destination)
            }
            if destinationValue != configuredWebhookDestination {
                await cancelWebhookOutbox()
                configuredWebhookDestination = destinationValue
            }
            if webhookSecret.isEmpty {
                try secretStore.delete(KeychainSecretStore.webhookSigningSecretAccount)
            } else {
                try secretStore.set(webhookSecret, for: KeychainSecretStore.webhookSigningSecretAccount)
            }
            settings.webhookSecret = ""
            try await library.save(settings)
            if settings.historyRetentionDays > 0 {
                let cutoff = Calendar.current.date(byAdding: .day, value: -settings.historyRetentionDays, to: .now) ?? .distantPast
                let removed = try await library.purgeRecords(olderThan: cutoff)
                if removed > 0 {
                    records = try await library.loadRecords().sorted { $0.createdAt > $1.createdAt }
                    if let selectedRecordID, !records.contains(where: { $0.id == selectedRecordID }) { self.selectedRecordID = nil }
                    statusMessage = "Removed \(removed) \(removed == 1 ? "record" : "records") outside the retention window."
                }
            }
            cancelModelDownload()
            transcriber?.unload()
            let selectedProvider = try modelDownloaderFactory(settings.model)
            transcriber = selectedProvider as? any LocalTranscriber
            reconcileModelDownloadCache(selectedProvider, model: settings.model)
            if settings.localAPIEnabled {
                localAPICredentials = try await api.startWithCredentials(port: settings.localAPIPort)
            } else {
                api.stop()
                localAPICredentials = nil
            }
            await updateHotMicState()
        } catch { statusMessage = error.localizedDescription }
    }

    func rotateLocalAPIToken() {
        do {
            localAPICredentials = try api.rotateToken()
            statusMessage = "The local API token was rotated. Existing clients have been revoked."
        } catch { statusMessage = error.localizedDescription }
    }

    func revokeLocalAPIAccess() async {
        do {
            try api.revokeToken()
            localAPICredentials = nil
            settings.localAPIEnabled = false
            try await library.save(settings)
            statusMessage = "Local API access was revoked and the listener was stopped."
        } catch { statusMessage = error.localizedDescription }
    }

    func enableLocalHelperAccess(for clients: [MCPClientConfiguration]) async throws -> [MCPRegistrationResult] {
        let rootURL = await library.rootURL
        let results = try await MCPOwnedRegistration.enable(
            clients: clients,
            executableURL: MCPRegistration.bundledExecutableURL(),
            allowedRootURLs: [FileManager.default.homeDirectoryForCurrentUser],
            storageRootURL: rootURL,
            settings: settings,
            saveSettings: { [library] settings in try await library.save(settings) }
        )
        guard !results.isEmpty else { return [] }
        settings.mcpEnabled = true
        return results
    }

    func inspectLocalHelperClients() async throws -> [MCPClientRegistrationInspection] {
        let rootURL = await library.rootURL
        return try MCPOwnedRegistration.inspectSupportedClients(
            storageRootURL: rootURL,
            expectedExecutableURL: MCPRegistration.bundledExecutableURL(),
            allowedRootURLs: [FileManager.default.homeDirectoryForCurrentUser]
        )
    }

    func adoptLegacyLocalHelperAccess(for clients: [MCPClientConfiguration]) async throws -> [MCPRegistrationResult] {
        let rootURL = await library.rootURL
        let results = try await MCPOwnedRegistration.adoptRecognizedLegacy(
            clients: clients,
            expectedExecutableURL: MCPRegistration.bundledExecutableURL(),
            allowedRootURLs: [FileManager.default.homeDirectoryForCurrentUser],
            storageRootURL: rootURL,
            settings: settings,
            saveSettings: { [library] settings in try await library.save(settings) }
        )
        guard !results.isEmpty else { return [] }
        settings.mcpEnabled = true
        return results
    }

    func removeLegacyLocalHelperRegistrations(for clients: [MCPClientConfiguration]) async throws -> MCPRevocationOutcome {
        let rootURL = await library.rootURL
        let outcome = try await MCPOwnedRegistration.removeRecognizedLegacy(
            clients: clients,
            expectedExecutableURL: MCPRegistration.bundledExecutableURL(),
            allowedRootURLs: [FileManager.default.homeDirectoryForCurrentUser],
            storageRootURL: rootURL,
            settings: settings,
            saveSettings: { [library] settings in try await library.save(settings) }
        )
        if outcome.authorizationDisabled { settings.mcpEnabled = false }
        return outcome
    }

    func revokeLocalHelperAccess() async throws -> MCPRevocationOutcome {
        let rootURL = await library.rootURL
        let outcome = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [FileManager.default.homeDirectoryForCurrentUser],
            storageRootURL: rootURL,
            settings: settings,
            saveSettings: { [library] settings in try await library.save(settings) }
        )
        if outcome.authorizationDisabled {
            settings.mcpEnabled = false
        }
        return outcome
    }

    func startModelDownload() {
        let model = settings.model
        if let reason = speechModelAvailability.unavailableReason(for: model) {
            modelAvailabilityWarning = reason
            statusMessage = reason
            return
        }
        guard let operation = modelDownloadStateMachine.begin(model: model) else { return }

        modelDownloadOperation = operation
        modelDownloadNeedsRetry = true
        modelDownloadDefaults?.set(true, forKey: modelDownloadAttemptKey(for: model))
        publishModelDownloadState()

        let factory = modelDownloaderFactory
        let forceRepair = modelsRequiringRepair.contains(model)
        modelDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let downloader = try factory(model)
                guard self.modelDownloadOperation == operation else { return }
                let mode: LocalModelPreparationMode = forceRepair || !downloader.isDownloaded
                    ? .downloadOrRepair
                    : .validateExisting
                try await LocalModelReadiness.prepare(downloader, mode: mode) { [weak self] progress in
                        Task { @MainActor in
                            self?.receiveModelDownloadProgress(progress, operation: operation)
                        }
                }
                self.completeModelDownload(downloader, model: model, operation: operation)
            } catch {
                self.failModelDownload(error, model: model, operation: operation)
            }
        }
    }

    func cancelModelDownload() {
        guard let operation = modelDownloadOperation else { return }
        modelDownloadStateMachine.cancel(operation)
        modelDownloadOperation = nil
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelDownloadNeedsRetry = true
        publishModelDownloadState()
    }

    func downloadSelectedModel() async {
        startModelDownload()
    }

    private func receiveModelDownloadProgress(_ progress: ModelProgress, operation: LifecycleOperation) {
        guard modelDownloadStateMachine.update(operation, progress: progress) else { return }
        publishModelDownloadState()
    }

    private func completeModelDownload(
        _ downloader: any LocalModelDownloading,
        model: SpeechModel,
        operation: LifecycleOperation
    ) {
        guard modelDownloadStateMachine.complete(operation) else { return }
        if let selectedTranscriber = downloader as? any LocalTranscriber {
            transcriber = selectedTranscriber
        }
        modelDownloadOperation = nil
        modelDownloadTask = nil
        modelDownloadNeedsRetry = false
        modelsRequiringRepair.remove(model)
        modelDownloadDefaults?.set(false, forKey: modelDownloadAttemptKey(for: model))
        publishModelDownloadState()
    }

    private func failModelDownload(_ error: Error, model: SpeechModel, operation: LifecycleOperation) {
        guard modelDownloadStateMachine.fail(operation, message: error.localizedDescription) else { return }
        modelDownloadOperation = nil
        modelDownloadTask = nil
        modelDownloadNeedsRetry = true
        modelsRequiringRepair.insert(model)
        modelDownloadDefaults?.set(true, forKey: modelDownloadAttemptKey(for: model))
        publishModelDownloadState()
        statusMessage = error.localizedDescription
    }

    private func reconcileModelDownloadCache(_ downloader: any LocalModelDownloading, model: SpeechModel) {
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelDownloadOperation = nil
        modelDownloadStateMachine = ModelDownloadStateMachine()

        if let operation = modelDownloadStateMachine.begin(model: model) {
            if downloader.isDownloaded {
                modelDownloadOperation = operation
                modelDownloadNeedsRetry = false
                publishModelDownloadState()
                modelDownloadTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await LocalModelReadiness.prepare(
                            downloader,
                            mode: .validateExisting,
                            progress: { _ in }
                        )
                        self.completeModelDownload(downloader, model: model, operation: operation)
                    } catch {
                        self.failModelDownload(error, model: model, operation: operation)
                    }
                }
                return
            } else if modelDownloadDefaults?.bool(forKey: modelDownloadAttemptKey(for: model)) == true {
                _ = modelDownloadStateMachine.fail(
                    operation,
                    message: "The previous model download did not finish."
                )
                modelDownloadNeedsRetry = true
                modelsRequiringRepair.insert(model)
            } else {
                modelDownloadStateMachine.cancel(operation)
                modelDownloadNeedsRetry = false
            }
        }
        publishModelDownloadState()
    }

    private func publishModelDownloadState() {
        modelDownloadState = modelDownloadStateMachine.state
    }

    private func modelDownloadAttemptKey(for model: SpeechModel) -> String {
        "Evee.ModelDownloadAttempted.\(model.rawValue)"
    }

    func prepareMeetingDiarization() async {
        guard captureLifecycle == .idle else {
            statusMessage = "Finish the current capture before preparing speaker separation."
            return
        }
        guard !isPreparingMeetingDiarization else { return }
        isPreparingMeetingDiarization = true
        defer { isPreparingMeetingDiarization = false }
        do {
            try await meetingDiarizer.prepareModels()
            meetingDiarizationReady = true
            statusMessage = "Anonymous speaker separation is ready for meetings."
        } catch {
            meetingDiarizationReady = false
            statusMessage = "Speaker separation could not be prepared: \(error.localizedDescription)"
        }
    }

    func refreshPermissionState() {
        accessibilityPermissionGranted = TextDelivery.isAccessibilityTrusted
        microphonePermissionGranted = microphonePermissionProvider()
    }

    func requestAccessibilityPermission() {
        _ = TextDelivery.requestAccessibility()
        refreshPermissionState()
    }

    func requestMicrophonePermission() async {
        microphonePermissionGranted = await recorder.requestPermission()
    }

    func beginDictation() async {
        guard captureLifecycle == .idle, !isApplicationTerminationCheckpointing else { return }
        refreshPermissionState()
        if !microphonePermissionGranted {
            await requestMicrophonePermission()
            guard microphonePermissionGranted else {
                statusMessage = AudioCaptureError.microphoneDenied.localizedDescription
                return
            }
        }
        guard accessibilityPermissionGranted else {
            requestAccessibilityPermission()
            statusMessage = "Enable Evee in System Settings → Privacy & Security → Accessibility, then hold the shortcut again."
            return
        }
        activeApplication = TextDelivery.frontmostApplication(
            policy: .ordinaryDictation(
                retainMetadata: settings.retainContextMetadata,
                captureVisibleText: settings.captureVisibleContext
            )
        )
        guard activeApplication != nil else {
            statusMessage = "Evee could not identify the app that should receive this dictation."
            return
        }
        activeKind = .dictation
        activeOperation = .capture
        activeSelectedText = nil
        await beginCapture(prefix: "dictation")
    }

    func beginSelectionTransform() async {
        guard captureLifecycle == .idle, !isApplicationTerminationCheckpointing else { return }
        refreshPermissionState()
        if !microphonePermissionGranted {
            await requestMicrophonePermission()
            guard microphonePermissionGranted else {
                statusMessage = AudioCaptureError.microphoneDenied.localizedDescription
                return
            }
        }
        guard accessibilityPermissionGranted else {
            requestAccessibilityPermission()
            statusMessage = "Enable Evee in System Settings → Privacy & Security → Accessibility, then try the transform shortcut again."
            return
        }
        guard let target = TextDelivery.frontmostApplication(
            policy: .selectionTransformation(
                retainMetadata: settings.retainContextMetadata,
                captureVisibleText: settings.captureVisibleContext
            )
        ),
              let selectedText = target.focusedTarget?.selectedText,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = SelectionTransformError.emptySelection.localizedDescription
            return
        }
        activeApplication = target
        activeKind = .dictation
        activeOperation = .selectionTransform
        activeSelectedText = selectedText
        await beginCapture(prefix: "transform")
    }

    func beginMeeting() async {
        guard captureLifecycle == .idle, !isApplicationTerminationCheckpointing else { return }
        if meetingDraftCaptureID != nil {
            statusMessage = "An interrupted meeting draft is still open. Recover or discard it before starting another meeting."
            route = .meetings
            return
        }
        activeApplication = nil
        activeKind = .meeting
        activeOperation = .capture
        activeSelectedText = nil
        await beginCapture(prefix: "meeting")
    }

    func beginMemo() async {
        guard captureLifecycle == .idle, !isApplicationTerminationCheckpointing else { return }
        activeApplication = nil
        activeKind = .memo
        activeOperation = .capture
        activeSelectedText = nil
        await beginCapture(prefix: "memo")
    }

    func toggleHandsFreeDictation() async {
        guard !isApplicationTerminationCheckpointing else { return }
        switch captureLifecycle {
        case .idle:
            await beginDictation()
        case .starting, .recording:
            if activeKind == .dictation && activeOperation == .capture {
                await finishCapture()
            } else {
                statusMessage = "Hands-free dictation cannot replace the capture already in progress."
            }
        case .finishing, .cancelling:
            statusMessage = "Wait for the current capture to finish before toggling hands-free dictation."
        default:
            statusMessage = "Hands-free dictation cannot replace the capture already in progress."
        }
    }

    private func beginCapture(prefix: String) async {
        guard captureLifecycle == .idle, terminationWorkGate.beginWork() else { return }
        let sessionID = UUID()
        captureLifecycle = .starting(sessionID)
        captureKind = activeKind
        captureOperation = activeOperation
        captureState = .starting(kind: activeKind)
        stopRequestedDuringStart = nil

        if activeKind == .meeting {
            meetingDraftCaptureID = sessionID
            await persistMeetingDraft()
        }

        do {
            await stopHotMic()
            if activeKind == .meeting { await startLiveMeetingTranscription() }
            guard captureLifecycle == .starting(sessionID) else {
                await cleanUpCancelledStart(sessionID: sessionID)
                return
            }
            _ = try await library.beginRecoveryCapture(kind: activeKind, id: sessionID)
            let directory = await library.recoveryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            activeRecoveryID = sessionID
            activeRecoveryDirectory = directory
            await refreshRecoverableCaptures()
            let url = directory.appendingPathComponent("microphone.caf")
            activeAudioURL = url
            microphoneTrackStartedAt = .now
            let microphoneStarter = self.microphoneStarter
            let microphoneStartTask = Task { @MainActor [recorder, settings] in
                if let microphoneStarter {
                    try await microphoneStarter(
                        url,
                        settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID,
                        settings.lowLatencyMode
                    )
                } else {
                    try await recorder.start(
                        at: url,
                        deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID,
                        lowLatency: settings.lowLatencyMode
                    )
                }
            }
            self.microphoneStartTask = microphoneStartTask
            try await microphoneStartTask.value
            if self.microphoneStartTask != nil { self.microphoneStartTask = nil }

            guard captureLifecycle == .starting(sessionID) else {
                await cleanUpCancelledStart(sessionID: sessionID)
                return
            }

            if activeKind == .meeting && settings.meetingCaptureEnabled {
                let systemURL = directory.appendingPathComponent("system.m4a")
                activeSystemAudioURL = systemURL
                do {
                    systemTrackStartedAt = .now
                    let systemAudioStarter = self.systemAudioStarter
                    let systemStartTask = Task { @MainActor [weak self, systemAudioRecorder] in
                        if let systemAudioStarter {
                            try await systemAudioStarter(systemURL)
                        } else {
                            try await systemAudioRecorder.start(at: systemURL)
                        }
                        self?.isSystemAudioActive = true
                    }
                    self.systemAudioStartTask = systemStartTask
                    try await systemStartTask.value
                    if self.systemAudioStartTask != nil { self.systemAudioStartTask = nil }
                    guard captureLifecycle == .starting(sessionID) else {
                        await cleanUpCancelledStart(sessionID: sessionID)
                        return
                    }
                    isSystemAudioActive = true
                } catch {
                    guard captureLifecycle == .starting(sessionID) else {
                        await cleanUpCancelledStart(sessionID: sessionID)
                        return
                    }
                    activeSystemAudioURL = nil
                    systemTrackStartedAt = nil
                    isSystemAudioActive = false
                    statusMessage = "Meeting capture is using your microphone only. Enable Screen Recording permission to include everyone else."
                }
            } else if activeKind == .meeting {
                activeSystemAudioURL = nil
                systemTrackStartedAt = nil
                isSystemAudioActive = false
            }

            let startedAt = Date.now
            captureStartedAt = startedAt
            captureLifecycle = .recording(sessionID)
            captureState = .recording(startedAt: startedAt, level: 0)
            startMicrophoneHealthMonitor(sessionID: sessionID)

            if stopRequestedDuringStart == sessionID {
                stopRequestedDuringStart = nil
                await finishCapture()
            }
        } catch {
            guard captureLifecycle == .starting(sessionID) else {
                await cleanUpCancelledStart(sessionID: sessionID)
                return
            }
            await failSession(sessionID: sessionID, error: error, preserveRecoveryAudio: false)
        }
    }

    func finishCapture() async {
        let sessionID: UUID
        switch captureLifecycle {
        case .starting(let id):
            stopRequestedDuringStart = id
            return
        case .recording(let id):
            sessionID = id
            captureLifecycle = .finishing(id)
        case .idle, .finishing, .cancelling:
            return
        }

        do {
            let stoppedMicrophoneURL = try await stopMicrophone()
            activeAudioURL = stoppedMicrophoneURL
            if isSystemAudioActive {
                do {
                    try await stopSystemAudio()
                } catch {
                    statusMessage = "System audio ended unexpectedly; Evee will keep processing the microphone track. \(error.localizedDescription)"
                }
                isSystemAudioActive = false
            }
            if activeKind == .meeting { await stopLiveMeetingTranscription() }

            guard let recoveryID = activeRecoveryID else {
                throw NSError(domain: "Evee.Recovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "The capture recovery session is unavailable."])
            }
            var recovery = try await library.addRecoveryTrack(
                captureID: recoveryID,
                kind: activeKind,
                role: .microphone,
                sourceURL: stoppedMicrophoneURL,
                startedAt: microphoneTrackStartedAt
            )
            guard let microphoneTrack = recovery.tracks.first(where: { $0.role == .microphone }) else {
                throw NSError(domain: "Evee.Recovery", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone recording could not be recovered."])
            }
            let audioURL = try await library.safeURL(forRelativePath: microphoneTrack.relativePath)
            activeAudioURL = audioURL
            if let systemURL = activeSystemAudioURL,
               FileManager.default.fileExists(atPath: systemURL.path) {
                recovery = try await library.addRecoveryTrack(
                    captureID: recoveryID,
                    kind: activeKind,
                    role: .system,
                    sourceURL: systemURL,
                    startedAt: systemTrackStartedAt
                )
                if let systemTrack = recovery.tracks.first(where: { $0.role == .system }) {
                    activeSystemAudioURL = try await library.safeURL(forRelativePath: systemTrack.relativePath)
                }
            }

            guard captureLifecycle == .finishing(sessionID) else { return }
            captureState = .transcribing
            let engine = try transcriber ?? recoveryTranscriberFactory(settings.model)
            transcriber = engine
            let microphoneTranscript = try await engine.transcribeDetailed(fileURL: audioURL, languageCode: settings.languageCode)
            guard captureLifecycle == .finishing(sessionID) else { return }

            var raw = microphoneTranscript.text
            var segments: [TranscriptSegment] = activeKind == .meeting
                ? MeetingTranscriptAssembler().assemble(microphone: microphoneTranscript, system: nil, microphoneOffset: microphoneOffset)
                : [TranscriptSegment(start: 0, end: microphoneTranscript.duration, text: microphoneTranscript.text)]
            if activeKind == .meeting,
               let systemURL = activeSystemAudioURL,
               FileManager.default.fileExists(atPath: systemURL.path) {
                do {
                    let systemTranscript = try await engine.transcribeDetailed(fileURL: systemURL, languageCode: settings.languageCode)
                    guard captureLifecycle == .finishing(sessionID) else { return }
                    let speakerIntervals = await speakerIntervalsIfAvailable(for: systemURL)
                    segments = MeetingTranscriptAssembler().assemble(
                        microphone: microphoneTranscript,
                        system: systemTranscript,
                        systemSpeakerIntervals: speakerIntervals,
                        microphoneOffset: microphoneOffset,
                        systemOffset: systemOffset
                    )
                    raw = chronologicalTranscript(segments)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard canCommitMicrophoneFallback(after: error) else { throw error }
                    statusMessage = systemTrackFallbackMessage(error)
                }
            }
            let polished: String
            if activeOperation == .selectionTransform {
                polished = try selectionTransform.transform(
                    selectedText: activeSelectedText ?? "",
                    instruction: microphoneTranscript.text,
                    terms: settings.dictionary
                )
            } else {
                let style = styleForActiveApplication()
                let cleaned = cleanup.clean(
                    raw,
                    terms: settings.dictionary,
                    tone: style?.tone ?? settings.defaultTone,
                    appendPeriod: style?.appendPeriod ?? true,
                    useParagraphs: style?.useParagraphs ?? true
                )
                polished = writingEnhancements.enhance(
                    cleaned,
                    smartLinks: settings.smartLinks,
                    emailMode: settings.emailFormattingMode,
                    emailSignOff: settings.emailSignOff,
                    context: activeWorkspaceContext()
                )
            }
            let intelligence = activeKind == .meeting ? MeetingIntelligencePipeline().generate(from: segments) : nil
            try await completeRecord(sessionID: sessionID, raw: raw, polished: polished, segments: segments, meetingIntelligence: intelligence)
        } catch {
            guard captureLifecycle == .finishing(sessionID) else { return }
            await failSession(sessionID: sessionID, error: error, preserveRecoveryAudio: true)
        }
    }

    func cancelCapture() async {
        guard !isApplicationTerminationCheckpointing else {
            openCheckpointedRecovery()
            return
        }
        let sessionID: UUID
        switch captureLifecycle {
        case .idle:
            if case .failed = captureState { captureState = .idle }
            return
        case .starting(let id), .recording(let id), .finishing(let id), .cancelling(let id):
            sessionID = id
        }

        let wasStarting: Bool
        if case .starting = captureLifecycle { wasStarting = true } else { wasStarting = false }
        captureLifecycle = .cancelling(sessionID)
        stopRequestedDuringStart = nil

        if isMicrophoneRecording, let stoppedURL = try? await stopMicrophone() {
            activeAudioURL = stoppedURL
        }
        if isSystemAudioActive {
            try? await stopSystemAudio()
            isSystemAudioActive = false
        }
        if activeKind == .meeting { await stopLiveMeetingTranscription(discardPendingAudio: true) }
        removeActiveRecoveryFiles()
        if activeKind == .meeting { await clearMeetingDraft() }
        await refreshRecoverableCaptures()

        // A permission request may still be suspended inside recorder.start(). Keep the
        // lifecycle closed until that continuation observes cancellation and cleans up.
        if !wasStarting {
            resetSession(state: .idle)
        }
    }

    /// Clears a terminal capture error after its alert has been acknowledged. This is
    /// deliberately synchronous so every SwiftUI alert dismissal path can hide the HUD.
    func dismissCaptureFailure() {
        guard captureLifecycle == .idle, case .failed = captureState else { return }
        captureState = .idle
        if settings.hotMicEnabled {
            Task { @MainActor [weak self] in await self?.updateHotMicState() }
        }
    }

    private func completeRecord(
        sessionID: UUID,
        raw: String,
        polished: String,
        segments: [TranscriptSegment],
        meetingIntelligence: MeetingIntelligence? = nil
    ) async throws {
        guard captureLifecycle == .finishing(sessionID) else { return }
        let duration = captureStartedAt.map { Date.now.timeIntervalSince($0) }
        let configuredRetention = switch activeKind {
            case .dictation: settings.retainDictationAudio
            case .meeting: settings.retainMeetingAudio
            case .memo: settings.retainMemoAudio
            }
        let keepAudio = activeRecoveryTrackSelection != nil || configuredRetention
        let recordKind = activeKind
        let memoIntelligence = activeKind == .memo ? MemoIntelligencePipeline().generate(from: polished) : nil
        let title: String = switch activeKind {
        case .dictation where activeOperation == .selectionTransform: "Transform · \(String(polished.prefix(60)))"
        case .dictation: String(polished.prefix(72))
        case .meeting: meetingTitle.isEmpty ? "Meeting · \(Date.now.formatted(date: .abbreviated, time: .shortened))" : meetingTitle
        case .memo: memoIntelligence?.title ?? String(polished.prefix(72))
        }
        var record = WorkspaceRecord(
            kind: activeKind,
            title: title,
            text: polished,
            rawText: raw,
            sourceApplication: settings.retainContextMetadata ? activeApplication?.name : nil,
            duration: duration,
            meetingIntelligence: activeKind == .meeting ? meetingIntelligence : nil,
            memoIntelligence: memoIntelligence,
            notes: activeKind == .meeting ? meetingNotes : "",
            operation: activeOperation,
            context: persistedActiveContext()
        )
        if activeKind == .meeting { record.segments = segments }
        if case .roles(let roles) = activeRecoveryTrackSelection,
           roles == [.system] {
            record.tags.append("Recovered from system audio")
        }

        guard terminationWorkGate.beginWork() else { return }
        recordCommitSequence &+= 1
        let commitID = recordCommitSequence
        let recoveryID = activeRecoveryID
        let recoveryTrackSelection = activeRecoveryTrackSelection
        let commitTask = Task { [library] in
            try await library.commitRecoveredRecord(
                record,
                recoveryID: recoveryID,
                trackSelection: recoveryTrackSelection,
                keepAudio: keepAudio
            )
        }
        recordCommitOperation = RecordCommitOperation(id: commitID, recoveryID: recoveryID, task: commitTask)
        do {
            record = try await commitTask.value
        } catch {
            if recordCommitOperation?.id == commitID { recordCommitOperation = nil }
            throw error
        }
        acceptDurableRecord(record, commitID: commitID)
        await refreshRecoverableCaptures()

        guard !isApplicationTerminationCheckpointing else {
            captureState = .checkpointed("Capture saved. Quit again to close Evee, or open Recovery to review it.")
            return
        }

        if recordKind == .dictation {
            captureState = .delivering
            let expectedSelection = activeOperation == .selectionTransform ? activeSelectedText : nil
            let mode = settings.textDeliveryMode
            pendingDelivery = mode == .copyOnly ? nil : PendingTextDelivery(
                text: polished,
                target: activeApplication,
                mode: mode,
                expectedSelectedText: expectedSelection
            )
            do {
                try await runTextDelivery(
                    polished,
                    to: activeApplication,
                    mode: mode,
                    expectedSelectedText: expectedSelection
                )
                pendingDelivery = nil
                if mode == .copyOnly {
                    statusMessage = activeOperation == .selectionTransform
                        ? "Transformed text copied. The original selection was not changed."
                        : "Dictation copied. Paste it wherever you choose."
                } else {
                    statusMessage = nil
                }
            } catch let error as TextDelivery.DeliveryError {
                if !error.shouldOfferPasteRetry { pendingDelivery = nil }
                statusMessage = error.localizedDescription
            } catch {
                statusMessage = error.localizedDescription
            }
        }

        if recordKind == .meeting { await clearMeetingDraft() }
        resetSession(state: .idle)
        if recordCommitOperation?.id == commitID { recordCommitOperation = nil }

        if recordKind == .meeting,
           let destination = URL(string: settings.webhookURL),
           !settings.webhookURL.isEmpty {
            await enqueueAndDeliverWebhook(record: record, destination: destination)
        }
    }

    func retryPendingTextDelivery() async {
        guard !isApplicationTerminationCheckpointing else { return }
        guard let pendingDelivery, let target = pendingDelivery.target else {
            statusMessage = "The original destination is unavailable. Copy the text and paste it manually."
            return
        }
        do {
            try await runTextDelivery(
                pendingDelivery.text,
                to: target,
                mode: pendingDelivery.mode,
                expectedSelectedText: pendingDelivery.expectedSelectedText
            )
            self.pendingDelivery = nil
            statusMessage = nil
        } catch { statusMessage = error.localizedDescription }
    }

    func copyPendingTextDelivery() {
        guard !isApplicationTerminationCheckpointing else { return }
        guard let pendingDelivery else { return }
        do {
            try TextDelivery.copyToClipboard(pendingDelivery.text)
            self.pendingDelivery = nil
            statusMessage = "Dictation copied. Paste it wherever you choose."
        } catch { statusMessage = error.localizedDescription }
    }

    private func runTextDelivery(
        _ text: String,
        to target: FrontmostApplication?,
        mode: TextDeliveryMode,
        expectedSelectedText: String?
    ) async throws {
        guard terminationWorkGate.beginWork() else { throw CancellationError() }
        let textDeliverer = self.textDeliverer
        let task = Task { @MainActor in
            try await textDeliverer(text, target, mode, expectedSelectedText)
        }
        deliveryTask = task
        defer { deliveryTask = nil }
        try await task.value
    }

    private var isMicrophoneRecording: Bool {
        microphoneRecordingProbe?() ?? recorder.isRecording
    }

    private func stopMicrophone() async throws -> URL {
        if let microphoneStopper { return try await microphoneStopper() }
        return try await recorder.stop()
    }

    private func stopSystemAudio() async throws {
        if let systemAudioStopper {
            try await systemAudioStopper()
        } else {
            try await systemAudioRecorder.stop()
        }
    }

    private func acceptDurableRecord(_ record: WorkspaceRecord, commitID: UInt64) {
        if !records.contains(where: { $0.id == record.id }) {
            records.insert(record, at: 0)
        }
        selectedRecordID = record.id
        if recordCommitOperation?.id == commitID {
            activeRecoveryID = nil
            activeRecoveryDirectory = nil
            terminationCheckpointRecoveryID = nil
        }
    }

    func openCheckpointedRecovery() {
        route = activeKind == .meeting ? .meetings : .library
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }

    private func cleanUpCancelledStart(sessionID: UUID) async {
        let preservesRecovery = terminationCheckpointRecoveryID == sessionID
        if isMicrophoneRecording, let stoppedURL = try? await stopMicrophone() {
            activeAudioURL = stoppedURL
        }
        try? await stopSystemAudio()
        isSystemAudioActive = false
        if activeKind == .meeting { await stopLiveMeetingTranscription(discardPendingAudio: true) }
        if preservesRecovery { return }
        removeActiveRecoveryFiles()
        if activeKind == .meeting { await clearMeetingDraft() }
        await refreshRecoverableCaptures()
        if captureLifecycle == .cancelling(sessionID) || captureLifecycle == .starting(sessionID) {
            resetSession(state: .idle)
        }
    }

    private func failSession(sessionID: UUID, error: Error, preserveRecoveryAudio: Bool) async {
        if isMicrophoneRecording, let stoppedURL = try? await stopMicrophone() {
            activeAudioURL = stoppedURL
        }
        try? await stopSystemAudio()
        if activeKind == .meeting { await stopLiveMeetingTranscription(discardPendingAudio: true) }
        isSystemAudioActive = false

        let recoveryPath = activeAudioURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
        if !preserveRecoveryAudio {
            removeActiveRecoveryFiles()
            if activeKind == .meeting {
                // Keep the user's notes, but detach them from a capture that
                // never started so the meeting can be retried immediately.
                meetingDraftCaptureID = nil
                await persistMeetingDraft()
            }
        }
        await refreshRecoverableCaptures()
        let detail: String
        if preserveRecoveryAudio, let recoveryPath {
            detail = "\(error.localizedDescription) The original audio was kept for recovery at \(recoveryPath)."
        } else {
            detail = error.localizedDescription
        }
        guard captureLifecycle == .starting(sessionID) || captureLifecycle == .finishing(sessionID) else { return }
        resetSession(state: .failed(detail))
        statusMessage = detail
    }

    private func removeActiveRecoveryFiles() {
        if let activeRecoveryDirectory {
            try? FileManager.default.removeItem(at: activeRecoveryDirectory)
        } else {
            if let activeAudioURL { try? FileManager.default.removeItem(at: activeAudioURL) }
            if let activeSystemAudioURL { try? FileManager.default.removeItem(at: activeSystemAudioURL) }
        }
    }

    private func resetSession(state: CaptureState) {
        captureState = state
        captureLifecycle = .idle
        captureKind = nil
        captureOperation = nil
        activeAudioURL = nil
        activeSystemAudioURL = nil
        activeRecoveryID = nil
        activeRecoveryDirectory = nil
        activeRecoveryTrackSelection = nil
        activeApplication = nil
        activeOperation = .capture
        activeSelectedText = nil
        captureStartedAt = nil
        microphoneTrackStartedAt = nil
        systemTrackStartedAt = nil
        isSystemAudioActive = false
        stopRequestedDuringStart = nil
        recorder.setBufferHandler(nil)
        systemAudioRecorder.setBufferHandler(nil)
        microphoneHealthTask?.cancel()
        microphoneHealthTask = nil
        microphoneHealthWarning = nil
        if state == .idle, settings.hotMicEnabled, !isApplicationTerminationCheckpointing {
            Task { @MainActor [weak self] in await self?.updateHotMicState() }
        }
    }

    var hasMeetingDraft: Bool {
        !meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func recover(
        _ capture: CaptureRecoveryManifest,
        trackSelection: RecoveryTrackSelection = .allValid
    ) async {
        guard captureLifecycle == .idle, !isApplicationTerminationCheckpointing else {
            statusMessage = "Recovery is protected while Evee finishes the quit checkpoint. Wait for it to finish, then retry."
            return
        }
        if capture.kind == .meeting, let draftID = meetingDraftCaptureID, draftID != capture.id {
            statusMessage = "These notes belong to a different interrupted meeting. Recover or discard that meeting first."
            return
        }
        let assessments: [RecoveryTrackAssessment]
        do {
            assessments = try await library.assessRecoveryTracks(captureID: capture.id)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        let selectedRoles: Set<AudioTrackRole> = switch trackSelection {
        case .allValid:
            Set(assessments.filter(\.isValid).map(\.role))
        case .roles(let roles):
            roles
        }
        guard !selectedRoles.isEmpty else {
            statusMessage = "This recovery has no playable audio tracks. You can discard it after reviewing the track details."
            return
        }
        for role in selectedRoles {
            guard let assessment = assessments.first(where: { $0.role == role }), assessment.isValid else {
                statusMessage = assessments.first(where: { $0.role == role })?.failureReason
                    ?? "The selected \(role.rawValue) recovery track is unavailable."
                return
            }
        }
        if capture.kind != .meeting, selectedRoles != [.microphone] {
            statusMessage = "System-audio-only recovery is available for meetings. Dictations and memos require a valid microphone track."
            return
        }
        let microphoneTrack = capture.tracks.first(where: { $0.role == .microphone && selectedRoles.contains(.microphone) })
        let systemTrack = capture.tracks.first(where: { $0.role == .system && selectedRoles.contains(.system) })
        guard microphoneTrack != nil || systemTrack != nil else {
            statusMessage = "The selected recovery audio is unavailable."
            return
        }
        guard terminationWorkGate.beginWork() else {
            statusMessage = "Recovery is protected while Evee finishes the quit checkpoint. Wait for it to finish, then retry."
            return
        }

        let sessionID = capture.id
        activeKind = capture.kind
        activeOperation = .capture
        activeSelectedText = nil
        captureKind = capture.kind
        activeRecoveryID = sessionID
        activeRecoveryTrackSelection = .roles(selectedRoles)
        captureStartedAt = capture.startedAt
        captureLifecycle = .finishing(sessionID)
        captureState = .transcribing
        do {
            activeRecoveryDirectory = await library.recoveryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            try? await library.updateRecoveryCapture(id: sessionID, status: .processing)

            let microphoneURL: URL?
            if let microphoneTrack {
                microphoneURL = try await library.safeURL(forRelativePath: microphoneTrack.relativePath)
            } else {
                microphoneURL = nil
            }
            let systemURL: URL?
            if let systemTrack {
                systemURL = try await library.safeURL(forRelativePath: systemTrack.relativePath)
            } else {
                systemURL = nil
            }
            activeAudioURL = microphoneURL
            activeSystemAudioURL = systemURL

            let engine = try transcriber ?? recoveryTranscriberFactory(settings.model)
            transcriber = engine
            let microphoneTranscript: LocalTranscript?
            if let microphoneURL {
                microphoneTranscript = try await engine.transcribeDetailed(fileURL: microphoneURL, languageCode: settings.languageCode)
            } else {
                microphoneTranscript = nil
            }
            guard captureLifecycle == .finishing(sessionID) else { return }

            var raw = microphoneTranscript?.text ?? ""
            var segments: [TranscriptSegment]
            if let microphoneTranscript {
                segments = capture.kind == .meeting
                    ? MeetingTranscriptAssembler().assemble(microphone: microphoneTranscript, system: nil)
                    : [TranscriptSegment(start: 0, end: microphoneTranscript.duration, text: microphoneTranscript.text)]
            } else {
                segments = []
            }
            if capture.kind == .meeting,
               let systemURL,
               FileManager.default.fileExists(atPath: systemURL.path) {
                do {
                    let systemTranscript = try await engine.transcribeDetailed(fileURL: systemURL, languageCode: settings.languageCode)
                    guard captureLifecycle == .finishing(sessionID) else { return }
                    let speakerIntervals = await speakerIntervalsIfAvailable(for: systemURL)
                    let microphoneOffset = microphoneTrack.map { recoveryOffset(for: $0, in: capture) } ?? 0
                    let systemOffset = systemTrack.map { recoveryOffset(for: $0, in: capture) } ?? 0
                    let microphoneForAssembly = microphoneTranscript
                        ?? LocalTranscript(text: "", duration: 0, segments: [])
                    segments = MeetingTranscriptAssembler().assemble(
                        microphone: microphoneForAssembly,
                        system: systemTranscript,
                        systemSpeakerIntervals: speakerIntervals,
                        microphoneOffset: microphoneOffset,
                        systemOffset: systemOffset
                    )
                    raw = chronologicalTranscript(segments)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard microphoneTranscript != nil else { throw error }
                    guard canCommitMicrophoneFallback(after: error) else { throw error }
                    statusMessage = systemTrackFallbackMessage(error)
                }
            }

            let polished = cleanup.clean(
                raw,
                terms: settings.dictionary,
                tone: settings.defaultTone,
                appendPeriod: true,
                useParagraphs: true
            )
            let intelligence = capture.kind == .meeting ? MeetingIntelligencePipeline().generate(from: segments) : nil
            try await completeRecord(sessionID: sessionID, raw: raw, polished: polished, segments: segments, meetingIntelligence: intelligence)
            if selectedRoles == [.system] {
                statusMessage = "Meeting recovered from system audio. The transcript is labelled as other-participant audio."
            }
        } catch {
            guard captureLifecycle == .finishing(sessionID) else { return }
            try? await library.updateRecoveryCapture(id: sessionID, status: .failed, failureReason: error.localizedDescription)
            await failSession(sessionID: sessionID, error: error, preserveRecoveryAudio: true)
        }
    }

    func discardRecovery(_ capture: CaptureRecoveryManifest) async {
        guard captureLifecycle == .idle, !isApplicationTerminationCheckpointing else { return }
        do {
            try await library.discardRecoveryCapture(id: capture.id)
            if meetingDraftCaptureID == capture.id { await clearMeetingDraft() }
            await refreshRecoverableCaptures()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func discardMeetingDraft() async {
        guard !isApplicationTerminationCheckpointing else { return }
        await clearMeetingDraft()
    }

    private func autosaveMeetingDraft(title: String, notes: String) async {
        guard !suppressDraftAutosave else { return }
        do {
            let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let draft = hasContent || meetingDraftCaptureID != nil
                ? MeetingDraft(captureID: meetingDraftCaptureID, title: title, notes: notes)
                : nil
            try await library.saveMeetingDraft(draft)
        } catch {
            statusMessage = "Meeting notes could not be saved: \(error.localizedDescription)"
        }
    }

    private func persistMeetingDraft() async {
        await autosaveMeetingDraft(title: meetingTitle, notes: meetingNotes)
    }

    private func clearMeetingDraft() async {
        suppressDraftAutosave = true
        meetingDraftCaptureID = nil
        meetingTitle = ""
        meetingNotes = ""
        suppressDraftAutosave = false
        do {
            try await library.saveMeetingDraft(nil)
        } catch {
            statusMessage = "The meeting draft was cleared in Evee but could not be removed from disk: \(error.localizedDescription)"
        }
    }

    private func refreshRecoverableCaptures() async {
        do {
            let captures = try await library.recoverableCaptures()
            var assessments: [UUID: [RecoveryTrackAssessment]] = [:]
            for capture in captures {
                assessments[capture.id] = try await library.assessRecoveryTracks(captureID: capture.id)
            }
            recoverableCaptures = captures
            recoveryTrackAssessments = assessments
        } catch {
            statusMessage = "Recovery recordings could not be loaded: \(error.localizedDescription)"
        }
    }

    func recoveryAssessments(for capture: CaptureRecoveryManifest) -> [RecoveryTrackAssessment] {
        recoveryTrackAssessments[capture.id] ?? capture.tracks.map {
            RecoveryTrackAssessment(track: $0, isValid: false, failureReason: "Checking audio…")
        }
    }

    var meetingRecoveryWarning: String? {
        for capture in recoverableCaptures where capture.kind == .meeting {
            guard meetingDraftCaptureID == nil || meetingDraftCaptureID == capture.id else { continue }
            let assessments = recoveryAssessments(for: capture)
            let microphoneValid = assessments.contains { $0.role == .microphone && $0.isValid }
            let systemValid = assessments.contains { $0.role == .system && $0.isValid }
            if systemValid, !microphoneValid {
                return "Only the system-audio track is playable. Recovering it will create an other-participant transcript and preserve that audio, regardless of your normal retention setting."
            }
            if !systemValid, !microphoneValid, !assessments.isEmpty {
                return "This interrupted meeting has no playable tracks. Review each track below, then discard the capture if the originals are no longer useful."
            }
        }
        return nil
    }

    func dismissLibraryRecoveryWarning() {
        libraryRecoveryWarning = nil
    }

    func resetLibraryMetadataProtection() async {
        do {
            try await library.resetRecordsQuarantine()
            recordsQuarantineActive = false
            libraryRecoveryWarning = nil
            statusMessage = "Library metadata protection was reset. Evee did not delete any audio; future maintenance may reconcile unreferenced files."
        } catch {
            statusMessage = "Library metadata protection could not be reset: \(error.localizedDescription)"
        }
    }

    func revealPreservedLibraryFiles() {
        guard !preservedCorruptURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(preservedCorruptURLs)
    }

    private func startLiveMeetingTranscription() async {
        liveMeetingTranscript = []
        liveMeetingStatus = nil
        guard settings.liveMeetingTranscriptionEnabled else { return }
        guard settings.model == .parakeet else {
            liveMeetingStatus = "Live transcript preview requires the Parakeet model; the saved meeting will still be transcribed after recording."
            return
        }
        let live = LiveMeetingTranscriber()
        do {
            try await live.start(includeSystem: settings.meetingCaptureEnabled)
            liveMeetingTranscriber = live
            recorder.setBufferHandler { [weak live] buffer in
                live?.acceptMicrophone(buffer)
            }
            systemAudioRecorder.setBufferHandler { [weak live] buffer in
                live?.acceptSystem(buffer)
            }
            liveMeetingStatus = "Live local transcript is active. Final text is rebuilt from the saved tracks after you stop."
            liveMeetingUpdateTask = Task { @MainActor [weak self] in
                for await update in live.updates {
                    guard let self, !Task.isCancelled else { return }
                    if update.isFinal {
                        self.liveMeetingTranscript.removeAll { $0.channel == update.channel }
                    } else if update.isConfirmed {
                        self.liveMeetingTranscript.removeAll { !$0.isConfirmed && $0.channel == update.channel }
                    } else {
                        self.liveMeetingTranscript.removeAll { !$0.isConfirmed && $0.channel == update.channel }
                    }
                    self.liveMeetingTranscript.append(update)
                    if self.liveMeetingTranscript.count > 100 {
                        self.liveMeetingTranscript.removeFirst(self.liveMeetingTranscript.count - 100)
                    }
                }
            }
        } catch {
            liveMeetingStatus = "Live transcript preview is unavailable: \(error.localizedDescription). Recording and final transcription will continue."
            await live.stop(discardPendingAudio: true)
        }
    }

    private func startMicrophoneHealthMonitor(sessionID: UUID) {
        lastNonSilentAudioAt = .now
        microphoneHealthWarning = nil
        microphoneHealthTask?.cancel()
        microphoneHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.captureLifecycle == .recording(sessionID) else { return }
                if Date.now.timeIntervalSince(self.lastNonSilentAudioAt) >= 15 {
                    self.microphoneHealthWarning = "No microphone signal has been detected for 15 seconds. Check the selected input and its mute switch; the recording is still running."
                }
            }
        }
    }

    func updateHotMicState() async {
        let phrase = settings.wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isApplicationTerminationCheckpointing else {
            await stopHotMic()
            return
        }
        guard settings.hotMicEnabled else {
            await stopHotMic()
            return
        }
        guard settings.model == .parakeet else {
            await stopHotMic()
            statusMessage = "Wake-phrase listening requires the Parakeet model."
            return
        }
        guard phrase.count >= 3 else {
            await stopHotMic()
            statusMessage = "Choose a wake phrase containing at least three characters."
            return
        }
        guard captureLifecycle == .idle else {
            await stopHotMic()
            return
        }
        refreshPermissionState()
        guard microphonePermissionGranted else {
            await stopHotMic()
            statusMessage = "Grant Microphone permission before enabling wake-phrase listening."
            return
        }
        guard let operation = hotMicStateMachine.beginStart() else { return }
        publishHotMicState()

        let listener = wakeListenerFactory()
        guard hotMicStartIsCurrent(operation, phrase: phrase) else {
            await listener.stop()
            return
        }
        do {
            try await listener.start(
                deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID,
                lowLatency: true
            )
            guard hotMicStartIsCurrent(operation, phrase: phrase) else {
                await listener.stop()
                return
            }

            let transcriptTask = Task { @MainActor [weak self] in
                for await transcript in listener.transcripts {
                    guard let self, !Task.isCancelled else { return }
                    let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalized.contains(phrase.lowercased()) {
                        await self.handleWakePhrase(listener: listener)
                        return
                    }
                }
            }
            guard hotMicStartIsCurrent(operation, phrase: phrase), hotMicStateMachine.didStart(operation) else {
                transcriptTask.cancel()
                await listener.stop()
                return
            }
            wakePhraseListener = listener
            hotMicTranscriptTask = transcriptTask
            publishHotMicState()
        } catch {
            await listener.stop()
            if hotMicStateMachine.fail(operation, message: error.localizedDescription) {
                publishHotMicState()
                statusMessage = "Wake-phrase listening could not start: \(error.localizedDescription)"
            }
        }
    }

    func disableHotMic() async {
        settings.hotMicEnabled = false
        await stopHotMic()
    }

    private func stopHotMic() async {
        hotMicStateMachine.disable()
        publishHotMicState()
        hotMicTranscriptTask?.cancel()
        hotMicTranscriptTask = nil
        let listener = wakePhraseListener
        wakePhraseListener = nil
        if let listener { await listener.stop() }
    }

    private func hotMicStartIsCurrent(_ operation: LifecycleOperation, phrase: String) -> Bool {
        !isApplicationTerminationCheckpointing
            && settings.hotMicEnabled
            && settings.model == .parakeet
            && settings.wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines) == phrase
            && captureLifecycle == .idle
            && hotMicStateMachine.isCurrent(operation)
    }

    private func handleWakePhrase(listener: any WakePhraseListening) async {
        guard !isApplicationTerminationCheckpointing,
              hotMicState == .active,
              settings.hotMicEnabled,
              captureLifecycle == .idle else { return }
        hotMicStateMachine.disable()
        publishHotMicState()
        hotMicTranscriptTask = nil
        wakePhraseListener = nil
        await listener.stop()
        await beginDictation()
    }

    private func publishHotMicState() {
        hotMicState = hotMicStateMachine.state
    }

    private func stopLiveMeetingTranscription(discardPendingAudio: Bool = false) async {
        recorder.setBufferHandler(nil)
        systemAudioRecorder.setBufferHandler(nil)
        if let liveMeetingTranscriber {
            await liveMeetingTranscriber.stop(discardPendingAudio: discardPendingAudio)
        }
        if discardPendingAudio {
            liveMeetingUpdateTask?.cancel()
        }
        if let liveMeetingUpdateTask { await liveMeetingUpdateTask.value }
        liveMeetingUpdateTask = nil
        liveMeetingTranscriber = nil
    }

    func update(_ record: WorkspaceRecord) async {
        do {
            var changed = record
            changed.updatedAt = .now
            try await library.upsert(changed)
            if let index = records.firstIndex(where: { $0.id == changed.id }) {
                let previous = records[index]
                records[index] = changed
                if settings.learnCorrections,
                   previous.kind == .dictation,
                   previous.operation == .capture,
                   let term = CorrectionLearner().candidate(from: previous.text, edited: changed.text),
                   !settings.dictionary.contains(where: { $0.spoken.caseInsensitiveCompare(term.spoken) == .orderedSame }) {
                    settings.dictionary.append(term)
                    try await library.save(settings)
                    statusMessage = "Learned ‘\(term.spoken)’ → ‘\(term.replacement)’. You can review it in Dictionary."
                }
            }
        } catch { statusMessage = error.localizedDescription }
    }

    func delete(_ record: WorkspaceRecord) async {
        do {
            try await library.delete(id: record.id)
            records.removeAll { $0.id == record.id }
            if selectedRecordID == record.id { selectedRecordID = nil }
        } catch { statusMessage = error.localizedDescription }
    }

    func exportWorkspace(format: WorkspaceExportFormat) async {
        let panel = NSSavePanel()
        panel.title = "Export Evee workspace"
        panel.nameFieldStringValue = "Evee Workspace.\(format.fileExtension)"
        panel.allowedContentTypes = format == .json ? [.json] : [.plainText]
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let destination = panel.url else { return }
        do {
            let data = try WorkspaceExporter.data(for: records, format: format)
            try data.write(to: destination, options: .atomic)
            statusMessage = "Exported \(records.count) \(records.count == 1 ? "record" : "records") as \(format.title)."
        } catch {
            statusMessage = "The workspace could not be exported: \(error.localizedDescription)"
        }
    }

    func exportDiagnostics() async {
        let panel = NSSavePanel()
        panel.title = "Export Evee diagnostics"
        panel.nameFieldStringValue = "Evee Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard await panel.begin() == .OK, let destination = panel.url else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let report = DiagnosticsReport(
            appVersion: version,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            model: settings.model.title,
            language: settings.languageCode,
            recordCount: records.count,
            recoveryCount: recoverableCaptures.count,
            microphonePermission: microphonePermissionGranted,
            accessibilityPermission: accessibilityPermissionGranted,
            systemAudioEnabled: settings.meetingCaptureEnabled,
            liveMeetingEnabled: settings.liveMeetingTranscriptionEnabled,
            localAPIEnabled: settings.localAPIEnabled,
            webhookConfigured: !settings.webhookURL.isEmpty,
            inputDeviceSelected: !settings.inputDeviceUID.isEmpty
        )
        do {
            try Data(report.rendered().utf8).write(to: destination, options: .atomic)
            statusMessage = "Exported a redacted diagnostics report."
        } catch { statusMessage = "Diagnostics could not be exported: \(error.localizedDescription)" }
    }

    func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            let release = try await UpdateChecker().latestRelease()
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            if UpdateChecker().isNewer(release.version, than: installed) {
                availableUpdate = release
                statusMessage = "Evee \(release.version) is available. Open its release page to download it."
            } else {
                availableUpdate = nil
                statusMessage = "Evee is up to date."
            }
        } catch { statusMessage = "Update check failed: \(error.localizedDescription)" }
    }

    private func loadAndMigrateSecrets() async throws {
        let legacySecret = settings.webhookSecret
        if let stored = try secretStore.string(for: KeychainSecretStore.webhookSigningSecretAccount) {
            webhookSecret = stored
        } else if !legacySecret.isEmpty {
            try secretStore.set(legacySecret, for: KeychainSecretStore.webhookSigningSecretAccount)
            webhookSecret = legacySecret
        }
        if !legacySecret.isEmpty {
            settings.webhookSecret = ""
            try await library.save(settings)
        }
    }

    private func enqueueAndDeliverWebhook(record: WorkspaceRecord, destination: URL) async {
        let preparation = webhookOutboxTransactions.beginPreparation()
        var queued = record
        let delivery: WebhookDelivery
        do {
            delivery = WebhookDelivery(
                destination: destination.absoluteString,
                payloadBody: try MeetingWebhook.payload(for: record)
            )
        } catch {
            webhookOutboxTransactions.abandon(preparation)
            statusMessage = "The meeting was saved, but its webhook could not be queued: \(error.localizedDescription)"
            return
        }
        queued.webhookDeliveries.append(delivery)
        let transaction = await persistWebhookPreparation(preparation, records: [queued])
        switch transaction.decision {
        case .commit(let queuedRecords):
            let installation = webhookOutboxTransactions.claimInstallation(
                transaction.installationToken,
                records: queuedRecords
            )
            switch installation {
            case .commit:
                guard transaction.preparation.didPersist(recordID: queued.id) else {
                    statusMessage = WebhookOutboxPersistenceBatchError(
                        failures: transaction.preparation.failures
                    ).localizedDescription
                    return
                }
                replaceRecord(queued)
                await deliverWebhook(
                    recordID: queued.id,
                    deliveryID: delivery.id,
                    requiringGeneration: preparation.generation
                )
            case .cancel(let cancelledRecords):
                replaceWebhookRecords(cancelledRecords)
                let cancellation = await persistWebhookRecords(cancelledRecords)
                if !cancellation.failures.isEmpty {
                    statusMessage = WebhookOutboxPersistenceBatchError(
                        failures: cancellation.failures
                    ).localizedDescription
                }
            }
        case .cancel(let cancelledRecords):
            replaceWebhookRecords(cancelledRecords)
            if let cancellation = transaction.cancellation, !cancellation.failures.isEmpty {
                statusMessage = WebhookOutboxPersistenceBatchError(failures: cancellation.failures).localizedDescription
            }
        }
    }

    private func deliverWebhook(
        recordID: UUID,
        deliveryID: UUID,
        requiringGeneration generation: UInt64? = nil
    ) async {
        guard normalizedWebhookDestination(settings.webhookURL) != nil else { return }
        let token: WebhookDispatchToken?
        if let generation {
            token = await webhookOutboxCoordinator.begin(
                deliveryID: deliveryID,
                requiringGeneration: generation
            )
        } else {
            token = await webhookOutboxCoordinator.begin(deliveryID: deliveryID)
        }
        guard let token, normalizedWebhookDestination(settings.webhookURL) != nil else {
            if let token { await webhookOutboxCoordinator.finish(token) }
            return
        }
        guard webhookOutboxTransactions.mayCommit(token) else {
            await webhookOutboxCoordinator.finish(token)
            return
        }
        let coordinator = webhookOutboxCoordinator
        let task = webhookOutboxTransactions.startTask(for: token) { @MainActor [weak self] in
            if let self {
                await self.performWebhookDelivery(recordID: recordID, token: token)
            }
            await coordinator.finish(token)
        }
        await task.value
    }

    private func performWebhookDelivery(recordID: UUID, token: WebhookDispatchToken) async {
        do {
            guard webhookOutboxTransactions.mayCommit(token),
                  let record = records.first(where: { $0.id == recordID }),
                  let index = record.webhookDeliveries.firstIndex(where: { $0.id == token.deliveryID }) else { return }
            let existing = record.webhookDeliveries[index]
            guard existing.retryable,
                  existing.state == .pending || existing.state == .failed,
                  let payloadBody = existing.payloadBody,
                  MeetingWebhook.isCurrentPayload(payloadBody),
                  let configured = normalizedWebhookDestination(settings.webhookURL),
                  existing.destination == configured,
                  let destination = URL(string: existing.destination) else { return }
            try WebhookEndpointPolicy.validate(destination)
            let receipt = try await MeetingWebhook().sendWithStatus(
                record: record,
                destination: destination,
                secret: webhookSecret,
                deliveryID: token.deliveryID,
                payloadBody: payloadBody,
                startingAttemptCount: existing.attemptCount
            )
            await persistWebhookReceipt(recordID: recordID, token: token, receipt: receipt)
        } catch let failure as WebhookDeliveryFailure {
            await persistWebhookFailure(recordID: recordID, token: token, delivery: failure.delivery)
        } catch {
            var failure = WebhookDelivery(id: token.deliveryID, destination: "", state: .failed, attemptCount: 1, lastAttemptAt: .now, lastError: error.localizedDescription)
            if let record = records.first(where: { $0.id == recordID }),
               let existing = record.webhookDeliveries.first(where: { $0.id == token.deliveryID }) {
                failure = existing
                failure.state = .failed
                failure.attemptCount += 1
                failure.lastAttemptAt = .now
                failure.lastError = error.localizedDescription
                failure.retryable = true
                failure.nextAttemptAt = .now.addingTimeInterval(60)
            }
            await persistWebhookFailure(recordID: recordID, token: token, delivery: failure)
        }
    }

    private func persistWebhookReceipt(
        recordID: UUID,
        token: WebhookDispatchToken,
        receipt: WebhookDeliveryReceipt
    ) async {
        guard webhookOutboxTransactions.mayCommit(token),
              let recordIndex = records.firstIndex(where: { $0.id == recordID }),
              let deliveryIndex = records[recordIndex].webhookDeliveries.firstIndex(where: { $0.id == token.deliveryID }) else { return }
        records[recordIndex].webhookDeliveries[deliveryIndex].state = .delivered
        records[recordIndex].webhookDeliveries[deliveryIndex].attemptCount = receipt.attemptCount
        records[recordIndex].webhookDeliveries[deliveryIndex].lastAttemptAt = receipt.deliveredAt
        records[recordIndex].webhookDeliveries[deliveryIndex].deliveredAt = receipt.deliveredAt
        records[recordIndex].webhookDeliveries[deliveryIndex].responseStatusCode = receipt.statusCode
        records[recordIndex].webhookDeliveries[deliveryIndex].lastError = nil
        records[recordIndex].webhookDeliveries[deliveryIndex].retryable = false
        records[recordIndex].webhookDeliveries[deliveryIndex].nextAttemptAt = nil
        records[recordIndex].webhookDeliveries[deliveryIndex].payloadBody = nil
        records[recordIndex].updatedAt = .now
        let updated = records[recordIndex]
        do {
            try await library.upsert(updated)
        } catch {
            if webhookOutboxTransactions.mayCommit(token) {
                statusMessage = "Webhook delivery completed, but its outbox state could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func persistWebhookFailure(
        recordID: UUID,
        token: WebhookDispatchToken,
        delivery: WebhookDelivery
    ) async {
        guard webhookOutboxTransactions.mayCommit(token),
              let recordIndex = records.firstIndex(where: { $0.id == recordID }),
              let deliveryIndex = records[recordIndex].webhookDeliveries.firstIndex(where: { $0.id == delivery.id }) else { return }
        var storedDelivery = delivery
        if !storedDelivery.retryable { storedDelivery.payloadBody = nil }
        records[recordIndex].webhookDeliveries[deliveryIndex] = storedDelivery
        records[recordIndex].updatedAt = .now
        let updated = records[recordIndex]
        do {
            try await library.upsert(updated)
            guard webhookOutboxTransactions.mayCommit(token) else { return }
            statusMessage = "The meeting was saved. Its webhook remains in the delivery outbox: \(delivery.lastError ?? "Delivery failed.")"
            scheduleWebhookRetry()
        } catch {
            guard webhookOutboxTransactions.mayCommit(token) else { return }
            statusMessage = "Webhook delivery failed and its outbox state could not be saved: \(error.localizedDescription)"
        }
    }

    private func retryPendingWebhookDeliveries() async {
        guard let destination = normalizedWebhookDestination(settings.webhookURL) else { return }
        let operation = webhookOutboxTransactions.beginPreparation()
        defer { webhookOutboxTransactions.abandon(operation) }
        let queued = webhookOutboxTransactions.automaticRetryDeliveries(
            records: records,
            destination: destination
        )
        for delivery in queued {
            guard !Task.isCancelled else { return }
            await deliverWebhook(
                recordID: delivery.recordID,
                deliveryID: delivery.deliveryID,
                requiringGeneration: operation.generation
            )
        }
        scheduleWebhookRetry()
    }

    private func scheduleWebhookRetry() {
        webhookRetryTask?.cancel()
        let nextDate = records
            .flatMap(\.webhookDeliveries)
            .filter {
                $0.state == .failed && $0.retryable &&
                    $0.payloadBody.map(MeetingWebhook.isCurrentPayload) == true
            }
            .compactMap(\.nextAttemptAt)
            .min()
        guard let nextDate else { webhookRetryTask = nil; return }
        webhookRetryTask = Task { [weak self] in
            let delay = max(0, nextDate.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.retryPendingWebhookDeliveries()
        }
    }

    private var microphoneOffset: TimeInterval {
        guard let microphoneTrackStartedAt else { return 0 }
        let commonStart = [microphoneTrackStartedAt, systemTrackStartedAt].compactMap { $0 }.min() ?? microphoneTrackStartedAt
        return max(0, microphoneTrackStartedAt.timeIntervalSince(commonStart))
    }

    private var systemOffset: TimeInterval {
        guard let systemTrackStartedAt else { return 0 }
        let commonStart = [microphoneTrackStartedAt, systemTrackStartedAt].compactMap { $0 }.min() ?? systemTrackStartedAt
        return max(0, systemTrackStartedAt.timeIntervalSince(commonStart))
    }

    private func recoveryOffset(for track: WorkspaceAudioTrack, in capture: CaptureRecoveryManifest) -> TimeInterval {
        max(0, track.createdAt.timeIntervalSince(capture.startedAt))
    }

    /// Diarization is optional enrichment. A missing/corrupt model must never
    /// discard an otherwise complete dual-track transcript; the channel label
    /// remains truthful and the user gets a recoverable warning instead.
    private func speakerIntervalsIfAvailable(for fileURL: URL) async -> [SpeakerInterval] {
        guard settings.meetingDiarizationEnabled else { return [] }
        isPreparingMeetingDiarization = true
        defer { isPreparingMeetingDiarization = false }
        do {
            let intervals = try await meetingDiarizer.diarize(fileURL: fileURL)
            meetingDiarizationReady = true
            return intervals
        } catch {
            meetingDiarizationReady = false
            statusMessage = "The meeting was transcribed, but anonymous speaker separation was unavailable. The timeline uses microphone and system-audio labels instead. \(error.localizedDescription)"
            return []
        }
    }

    private func systemTrackFallbackMessage(_ error: Error) -> String {
        if let transcriptionError = error as? TranscriptionError,
           case .emptyResult = transcriptionError {
            return "No speech was recognised in the system-audio track. The microphone transcript was saved."
        }
        return "The system-audio track could not be transcribed, so the meeting was saved from the microphone track. The retained audio is still available from the meeting record. \(error.localizedDescription)"
    }

    private func canCommitMicrophoneFallback(after error: Error) -> Bool {
        if let transcriptionError = error as? TranscriptionError,
           case .emptyResult = transcriptionError {
            return true
        }
        if activeRecoveryTrackSelection != nil { return true }
        // When retention is disabled, committing a partial record would purge
        // the failed system track. Keep the recovery capture instead so the
        // user can retry or explicitly discard the original audio.
        return settings.retainMeetingAudio
    }

    private func chronologicalTranscript(_ segments: [TranscriptSegment]) -> String {
        segments.sorted { $0.start < $1.start }.map { segment in
            if let speaker = segment.speaker { return "\(speaker): \(segment.text)" }
            return segment.text
        }.joined(separator: "\n\n")
    }

    func retryWebhookDeliveriesNow() async {
        do {
            guard let configured = normalizedWebhookDestination(settings.webhookURL),
                  let destination = URL(string: configured) else { throw WebhookEndpointError.invalidURL }
            try WebhookEndpointPolicy.validate(destination)
            let token = webhookOutboxTransactions.beginPreparation()
            let preparation = webhookOutboxTransactions.prepareManualRetry(
                records: records,
                destination: configured
            )
            let transaction = await persistWebhookPreparation(token, records: preparation.records)
            switch transaction.decision {
            case .commit(let preparedRecords):
                let installation = webhookOutboxTransactions.claimInstallation(
                    transaction.installationToken,
                    records: preparedRecords
                )
                switch installation {
                case .commit(let installableRecords):
                    let persistedRecords = installableRecords.filter {
                        transaction.preparation.didPersist(recordID: $0.id)
                    }
                    replaceWebhookRecords(persistedRecords)
                    let persistedIDs = Set(transaction.preparation.persistedRecordIDs)
                    let queued = preparation.deliveries.filter { persistedIDs.contains($0.recordID) }
                    for delivery in queued {
                        await deliverWebhook(
                            recordID: delivery.recordID,
                            deliveryID: delivery.deliveryID,
                            requiringGeneration: token.generation
                        )
                    }
                    if queued.isEmpty && transaction.preparation.failures.isEmpty {
                        statusMessage = "The webhook outbox is already clear."
                    } else if !transaction.preparation.failures.isEmpty {
                        statusMessage = WebhookOutboxPersistenceBatchError(
                            failures: transaction.preparation.failures
                        ).localizedDescription
                    }
                case .cancel(let cancelledRecords):
                    replaceWebhookRecords(cancelledRecords)
                    let cancellation = await persistWebhookRecords(cancelledRecords)
                    if !cancellation.failures.isEmpty {
                        statusMessage = WebhookOutboxPersistenceBatchError(
                            failures: cancellation.failures
                        ).localizedDescription
                    }
                }
            case .cancel(let cancelledRecords):
                replaceWebhookRecords(cancelledRecords)
                if let cancellation = transaction.cancellation, !cancellation.failures.isEmpty {
                    statusMessage = WebhookOutboxPersistenceBatchError(
                        failures: cancellation.failures
                    ).localizedDescription
                }
            }
        } catch {
            statusMessage = "The webhook outbox could not be retried: \(error.localizedDescription)"
        }
    }

    func cancelWebhookOutbox() async {
        let cancelledRecords = invalidateWebhookOutbox()
        let persistence = await persistWebhookRecords(cancelledRecords)
        if !persistence.failures.isEmpty {
            statusMessage = WebhookOutboxPersistenceBatchError(failures: persistence.failures).localizedDescription
        }
    }

    private func retireUnsupportedWebhookPayloads() async {
        let retired = webhookOutboxTransactions.retireUnsupportedPayloads(records: records)
        guard !retired.isEmpty else { return }
        replaceWebhookRecords(retired)
        let persistence = await persistWebhookRecords(retired)
        if !persistence.failures.isEmpty {
            statusMessage = "Legacy webhook payloads were blocked, but their retired state could not be saved: \(WebhookOutboxPersistenceBatchError(failures: persistence.failures).localizedDescription)"
        }
    }

    /// The AppKit terminate-later checkpoint calls this after synchronous
    /// invalidation and does not reply until these writes complete.
    func persistWebhookOutboxTerminationCancellation() async throws {
        let pending = pendingWebhookTerminationRecords
        let persistence = await persistWebhookRecords(pending)
        let failedIDs = Set(persistence.failures.map(\.recordID))
        pendingWebhookTerminationRecords = pending.filter { failedIDs.contains($0.id) }
        guard persistence.failures.isEmpty else {
            throw WebhookOutboxPersistenceBatchError(failures: persistence.failures)
        }
    }

    func checkpointForTermination() async throws {
        _ = terminationWorkGate.prepareCheckpoint()
        let plan = captureShutdownPlan
        invalidateForApplicationTermination(plan: plan)

        do {
            if let deliveryTask {
                deliveryTask.cancel()
                _ = try? await deliveryTask.value
                if self.deliveryTask != nil { self.deliveryTask = nil }
            }
            if let microphoneStartTask {
                _ = try? await microphoneStartTask.value
                if self.microphoneStartTask != nil { self.microphoneStartTask = nil }
            }
            if let systemAudioStartTask {
                _ = try? await systemAudioStartTask.value
                if self.systemAudioStartTask != nil { self.systemAudioStartTask = nil }
            }

            var durableCommitWon = false
            if let operation = recordCommitOperation {
                do {
                    let record = try await operation.task.value
                    acceptDurableRecord(record, commitID: operation.id)
                    durableCommitWon = true
                    if try await library.clearMeetingDraft(
                        forCommitted: record,
                        recoveryID: operation.recoveryID
                    ), let recoveryID = operation.recoveryID {
                        if meetingDraftCaptureID == recoveryID {
                            suppressDraftAutosave = true
                            meetingDraftCaptureID = nil
                            meetingTitle = ""
                            meetingNotes = ""
                            suppressDraftAutosave = false
                        }
                    }
                    recordCommitOperation = nil
                } catch {
                    if durableCommitWon { throw error }
                    if recordCommitOperation?.id == operation.id {
                        recordCommitOperation = nil
                    }
                }
            }

            await stopHotMic()
            api.stop()
            localAPICredentials = nil

            var writerWarnings: [AudioTrackRole: String] = [:]
            if isMicrophoneRecording {
                do {
                    activeAudioURL = try await stopMicrophone()
                } catch {
                    writerWarnings[.microphone] = error.localizedDescription
                }
            }
            if isSystemAudioActive {
                do {
                    try await stopSystemAudio()
                } catch {
                    writerWarnings[.system] = error.localizedDescription
                }
                isSystemAudioActive = false
            }
            if activeKind == .meeting {
                await stopLiveMeetingTranscription(discardPendingAudio: true)
            }

            switch plan {
            case .cancelStartAndCheckpoint:
                if let captureID = terminationCheckpointRecoveryID ?? activeRecoveryID {
                    try await persistCaptureTerminationCheckpoint(
                        captureID: captureID,
                        kind: activeKind,
                        writerWarnings: writerWarnings
                    )
                }
            case .stopWritersAndCheckpoint(let kind, let recoveryID):
                try await persistCaptureTerminationCheckpoint(
                    captureID: recoveryID,
                    kind: kind,
                    writerWarnings: writerWarnings
                )
            case .awaitDurableCommitOrCheckpoint(let recoveryID):
                if !durableCommitWon {
                    try await persistCaptureTerminationCheckpoint(
                        captureID: recoveryID,
                        kind: activeKind,
                        writerWarnings: writerWarnings
                    )
                }
            case .awaitCancellationCleanup:
                removeActiveRecoveryFiles()
                if activeKind == .meeting {
                    try await library.saveMeetingDraft(nil)
                }
                resetSession(state: .idle)
            case .terminateImmediately,
                 .invalidateDeliveryAndAwaitCommit:
                break
            case .cancelTermination(let message):
                throw ApplicationTerminationPlanError(message: message)
            }

            try await persistWebhookOutboxTerminationCancellation()
            await refreshRecoverableCaptures()
            if plan != .terminateImmediately {
                captureState = .checkpointed(
                    durableCommitWon
                        ? "Capture saved. Quit again to close Evee, or open it to review the record."
                        : "Capture checkpointed for recovery. Quit again to close Evee, or open Recovery to review it."
                )
            }
        } catch {
            if let recoveryID = terminationCheckpointRecoveryID ?? activeRecoveryID {
                try? await library.updateRecoveryCapture(
                    id: recoveryID,
                    status: .failed,
                    failureReason: error.localizedDescription
                )
            }
            captureState = .checkpointed("Recovery checkpoint needs attention: \(error.localizedDescription)")
            statusMessage = "Quit was cancelled because Evee could not finish the recovery checkpoint. The app stayed open and retained any completed audio. Check available disk space and permissions, then quit again. \(error.localizedDescription)"
            captureLifecycle = .idle
            terminationCheckpointRecoveryID = nil
            terminationWorkGate.resumeAfterCheckpointFailure()
            await refreshRecoverableCaptures()
            throw error
        }
    }

    func checkpointForApplicationTermination() async throws {
        try await checkpointForTermination()
    }

    func reportApplicationTerminationCheckpointFailure(_ error: Error) {
        let message = "Evee protected the capture for recovery. Check available disk space and permissions, then retry Quit. \(error.localizedDescription)"
        captureState = captureState.protectedForTerminationFailure(message)
        statusMessage = message
    }

    private func invalidateForApplicationTermination(plan: CaptureShutdownPlan) {
        pushToTalkHeld = false
        transformShortcutHeld = false
        activeShortcut = nil
        stopRequestedDuringStart = nil
        microphoneHealthTask?.cancel()
        microphoneHealthTask = nil
        pendingDelivery = nil
        invalidateWebhookOutboxForTermination()

        switch plan {
        case .cancelStartAndCheckpoint:
            if case .starting(let sessionID) = captureLifecycle {
                terminationCheckpointRecoveryID = activeRecoveryID ?? sessionID
                captureLifecycle = .cancelling(sessionID)
            }
        case .stopWritersAndCheckpoint(_, let recoveryID),
             .awaitDurableCommitOrCheckpoint(let recoveryID):
            terminationCheckpointRecoveryID = recoveryID
            captureLifecycle = .cancelling(recoveryID)
        case .invalidateDeliveryAndAwaitCommit:
            if case .finishing(let sessionID) = captureLifecycle {
                captureLifecycle = .cancelling(sessionID)
            }
        case .terminateImmediately, .awaitCancellationCleanup, .cancelTermination:
            break
        }
    }

    private func persistCaptureTerminationCheckpoint(
        captureID: UUID,
        kind: WorkspaceRecordKind,
        writerWarnings: [AudioTrackRole: String] = [:]
    ) async throws {
        activeRecoveryID = captureID
        activeRecoveryDirectory = await library.recoveryURL.appendingPathComponent(captureID.uuidString, isDirectory: true)
        var manifest = try await library.beginRecoveryCapture(kind: kind, id: captureID)

        if kind == .meeting {
            meetingDraftCaptureID = captureID
            try await library.saveMeetingDraft(MeetingDraft(
                captureID: captureID,
                title: meetingTitle,
                notes: meetingNotes
            ))
        }

        var trackFailures = writerWarnings
        var validRoles: Set<AudioTrackRole> = []
        let inputs: [(AudioTrackRole, URL?, Date?)] = [
            (.microphone, activeAudioURL, microphoneTrackStartedAt),
            (.system, activeSystemAudioURL, systemTrackStartedAt),
        ]
        for (role, sourceURL, startedAt) in inputs {
            do {
                manifest = try await checkpointTrack(
                    role: role,
                    sourceURL: sourceURL,
                    startedAt: startedAt,
                    captureID: captureID,
                    kind: kind,
                    manifest: manifest
                )
                if manifest.tracks.contains(where: { $0.role == role }) {
                    validRoles.insert(role)
                }
            } catch {
                trackFailures[role] = error.localizedDescription
            }
        }
        do {
            try CaptureCheckpointTrackPolicy.validate(kind: kind, validRoles: validRoles)
        } catch {
            let detail = trackFailures
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue): \($0.value)" }
                .joined(separator: " ")
            throw CaptureTerminationCheckpointError.requiredTracksUnavailable(
                kind,
                detail.isEmpty ? error.localizedDescription : detail
            )
        }
        if !trackFailures.isEmpty {
            let missing = trackFailures.keys.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: " and ")
            let retained = validRoles.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: " and ")
            statusMessage = "Evee checkpointed the \(retained) track, but the \(missing) channel was degraded. Its original file was left in recovery for review."
        }
        try await library.updateRecoveryCapture(id: captureID, status: .captured)
    }

    private func checkpointTrack(
        role: AudioTrackRole,
        sourceURL: URL?,
        startedAt: Date?,
        captureID: UUID,
        kind: WorkspaceRecordKind,
        manifest: CaptureRecoveryManifest
    ) async throws -> CaptureRecoveryManifest {
        if let existing = manifest.tracks.first(where: { $0.role == role }) {
            do {
                let existingURL = try await library.safeURL(forRelativePath: existing.relativePath)
                try await validateCheckpointAudio(at: existingURL)
                if role == .microphone { activeAudioURL = existingURL }
                if role == .system { activeSystemAudioURL = existingURL }
                return manifest
            } catch {
                guard sourceURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true else {
                    throw error
                }
            }
        }
        guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) else { return manifest }
        try await validateCheckpointAudio(at: sourceURL)
        let updated = try await library.addRecoveryTrack(
            captureID: captureID,
            kind: kind,
            role: role,
            sourceURL: sourceURL,
            startedAt: startedAt
        )
        guard let stored = updated.tracks.first(where: { $0.role == role }) else {
            throw CaptureTerminationCheckpointError.missingTrack(role)
        }
        let storedURL = try await library.safeURL(forRelativePath: stored.relativePath)
        if role == .microphone { activeAudioURL = storedURL }
        if role == .system { activeSystemAudioURL = storedURL }
        return updated
    }

    private func validateCheckpointAudio(at url: URL) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else { throw CaptureTerminationCheckpointError.invalidAudio(url) }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard playable, !tracks.isEmpty else {
            throw CaptureTerminationCheckpointError.invalidAudio(url)
        }
    }

    private func invalidateWebhookOutboxForTermination() {
        pendingWebhookTerminationRecords = mergeWebhookRecords(
            pendingWebhookTerminationRecords,
            replacingWith: invalidateWebhookOutbox()
        )
    }

    private func invalidateWebhookOutbox() -> [WorkspaceRecord] {
        webhookRetryTask?.cancel()
        webhookRetryTask = nil
        _ = webhookOutboxCoordinator.invalidateSynchronously()
        let cancelledRecords = webhookOutboxTransactions.terminallyCancelledRecords(records)
        replaceWebhookRecords(cancelledRecords)
        return cancelledRecords
    }

    private func persistWebhookRecords(_ records: [WorkspaceRecord]) async -> WebhookOutboxPersistenceResult {
        await webhookOutboxTransactions.persistAll(records) { [library] record in
            try await library.upsert(record)
        }
    }

    private func persistWebhookPreparation(
        _ token: WebhookOutboxPreparationToken,
        records: [WorkspaceRecord]
    ) async -> WebhookOutboxPreparationPersistence {
        await webhookOutboxTransactions.persistPreparation(token, records: records) { [library] record in
            try await library.upsert(record)
        }
    }

    private func replaceWebhookRecords(_ replacements: [WorkspaceRecord]) {
        for record in replacements {
            replaceRecord(record)
        }
    }

    private func mergeWebhookRecords(
        _ existing: [WorkspaceRecord],
        replacingWith replacements: [WorkspaceRecord]
    ) -> [WorkspaceRecord] {
        var recordsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for record in replacements { recordsByID[record.id] = record }
        return recordsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func normalizedWebhookDestination(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func replaceRecord(_ record: WorkspaceRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
    }

    private func styleForActiveApplication() -> AppWritingStyle? {
        guard let id = activeApplication?.bundleIdentifier else { return nil }
        return settings.appStyles.first { $0.bundleIdentifier == id }
    }

    private func persistedActiveContext() -> WorkspaceContext? {
        guard let application = activeApplication else { return nil }
        let target = application.focusedTarget
        guard settings.retainContextMetadata || settings.retainSelectedText || settings.captureVisibleContext else { return nil }
        return WorkspaceContext(
            bundleIdentifier: settings.retainContextMetadata ? application.bundleIdentifier : nil,
            applicationName: settings.retainContextMetadata ? application.name : nil,
            windowTitle: settings.retainContextMetadata ? target?.windowTitle : nil,
            document: settings.retainContextMetadata ? target?.document : nil,
            focusedRole: settings.retainContextMetadata ? target?.role : nil,
            selectedText: settings.retainSelectedText ? activeSelectedText : nil,
            url: settings.retainContextMetadata ? target?.url : nil,
            codeFile: settings.retainContextMetadata ? target?.codeFile : nil,
            recipient: settings.retainContextMetadata ? target?.recipient : nil,
            visibleText: settings.captureVisibleContext ? target?.visibleText : nil
        )
    }

    private func activeWorkspaceContext() -> WorkspaceContext? {
        guard let application = activeApplication else { return nil }
        let target = application.focusedTarget
        return WorkspaceContext(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.name,
            windowTitle: target?.windowTitle,
            document: target?.document,
            focusedRole: target?.role,
            selectedText: activeSelectedText,
            url: target?.url,
            codeFile: target?.codeFile,
            recipient: target?.recipient,
            visibleText: target?.visibleText
        )
    }
}
