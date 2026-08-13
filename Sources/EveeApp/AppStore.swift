import AppKit
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

@MainActor
final class AppStore: ObservableObject {
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
    @Published var modelProgress: ModelProgress?
    @Published var modelReady = false
    @Published var statusMessage: String?
    @Published var meetingTitle = ""
    @Published var meetingNotes = ""
    @Published var webhookSecret = ""
    @Published private var indexedSearchResults: [WorkspaceRecord]?
    @Published private(set) var localAPICredentials: LocalAPICredentials?
    @Published private(set) var pendingDelivery: PendingTextDelivery?
    @Published private(set) var recoverableCaptures: [CaptureRecoveryManifest] = []
    @Published private(set) var captureKind: WorkspaceRecordKind?
    @Published private(set) var captureOperation: WorkspaceRecordOperation?
    @Published private(set) var isSystemAudioActive = false
    @Published private(set) var isPreparingMeetingDiarization = false
    @Published private(set) var meetingDiarizationReady = false
    @Published private(set) var accessibilityPermissionGranted = TextDelivery.isAccessibilityTrusted
    @Published private(set) var microphonePermissionGranted = MicrophoneRecorder.isPermissionGranted
    @Published private(set) var liveMeetingTranscript: [LiveMeetingTranscriptUpdate] = []
    @Published private(set) var liveMeetingStatus: String?
    @Published private(set) var availableUpdate: EveeRelease?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var microphoneHealthWarning: String?
    @Published private(set) var hotMicActive = false

    var webhookOutboxCount: Int {
        records.reduce(into: 0) { count, record in
            count += record.webhookDeliveries.filter { $0.state != .delivered && $0.state != .cancelled }.count
        }
    }

    let recorder = MicrophoneRecorder()
    private let systemAudioRecorder = SystemAudioRecorder()
    private let library = LibraryStore.shared
    private let cleanup = TextCleanupPipeline()
    private let selectionTransform = SelectionTransformPipeline()
    private let writingEnhancements = WritingEnhancementPipeline()
    private let meetingDiarizer = FluidOfflineMeetingDiarizer()
    private let api = LocalAPIServer()
    private let secretStore = KeychainSecretStore()
    private var transcriber: (any LocalTranscriber)?
    private var activeAudioURL: URL?
    private var activeSystemAudioURL: URL?
    private var activeRecoveryID: UUID?
    private var activeRecoveryDirectory: URL?
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
    private var terminationObserver: NSObjectProtocol?
    private var pendingWebhookTerminationRecords: [WorkspaceRecord] = []
    private var liveMeetingTranscriber: LiveMeetingTranscriber?
    private var liveMeetingUpdateTask: Task<Void, Never>?
    private var microphoneHealthTask: Task<Void, Never>?
    private var lastNonSilentAudioAt = Date.distantPast
    private var wakePhraseListener: WakePhraseListener?
    private var hotMicTask: Task<Void, Never>?
    private var suppressDraftAutosave = false

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

    init() {
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
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateWebhookOutboxForTermination()
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
            settings = try await library.loadSettings()
            configuredWebhookDestination = normalizedWebhookDestination(settings.webhookURL)
            try await loadAndMigrateSecrets()
            if settings.historyRetentionDays > 0 {
                let cutoff = Calendar.current.date(byAdding: .day, value: -settings.historyRetentionDays, to: .now) ?? .distantPast
                _ = try await library.purgeRecords(olderThan: cutoff)
            }
            records = try await library.loadRecords().sorted { $0.createdAt > $1.createdAt }
            try await library.reconcileAudioStorage()
            if let draft = try await library.loadMeetingDraft() {
                suppressDraftAutosave = true
                meetingDraftCaptureID = draft.captureID
                meetingTitle = draft.title
                meetingNotes = draft.notes
                suppressDraftAutosave = false
            }
            recoverableCaptures = try await library.recoverableCaptures()
            transcriber = try TranscriberFactory.make(settings.model)
            modelReady = transcriber?.isDownloaded == true
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
            transcriber?.unload()
            transcriber = try TranscriberFactory.make(settings.model)
            modelReady = transcriber?.isDownloaded == true
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

    func revokeLocalHelperAccess() async throws -> MCPRevocationOutcome {
        let rootURL = await library.rootURL
        let outcome = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [FileManager.default.homeDirectoryForCurrentUser],
            storageRootURL: rootURL,
            settings: settings,
            saveSettings: { [library] settings in try await library.save(settings) }
        )
        settings.mcpEnabled = false
        return outcome
    }

    func downloadSelectedModel() async {
        do {
            let selected = try TranscriberFactory.make(settings.model)
            transcriber = selected
            try await selected.download { [weak self] progress in
                Task { @MainActor in self?.modelProgress = progress }
            }
            try await selected.load()
            modelReady = true
            modelProgress = ModelProgress(fraction: 1, status: "Ready")
        } catch {
            modelProgress = nil
            statusMessage = error.localizedDescription
        }
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
        microphonePermissionGranted = MicrophoneRecorder.isPermissionGranted
    }

    func requestAccessibilityPermission() {
        _ = TextDelivery.requestAccessibility()
        refreshPermissionState()
    }

    func requestMicrophonePermission() async {
        microphonePermissionGranted = await recorder.requestPermission()
    }

    func beginDictation() async {
        guard captureLifecycle == .idle else { return }
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
        guard captureLifecycle == .idle else { return }
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
        guard captureLifecycle == .idle else { return }
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
        guard captureLifecycle == .idle else { return }
        activeApplication = nil
        activeKind = .memo
        activeOperation = .capture
        activeSelectedText = nil
        await beginCapture(prefix: "memo")
    }

    func toggleHandsFreeDictation() async {
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
        guard captureLifecycle == .idle else { return }
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
            try await recorder.start(
                at: url,
                deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID,
                lowLatency: settings.lowLatencyMode
            )

            guard captureLifecycle == .starting(sessionID) else {
                await cleanUpCancelledStart(sessionID: sessionID)
                return
            }

            if activeKind == .meeting && settings.meetingCaptureEnabled {
                let systemURL = directory.appendingPathComponent("system.m4a")
                activeSystemAudioURL = systemURL
                do {
                    systemTrackStartedAt = .now
                    try await systemAudioRecorder.start(at: systemURL)
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
            let stoppedMicrophoneURL = try recorder.stop()
            activeAudioURL = stoppedMicrophoneURL
            if isSystemAudioActive {
                do {
                    try await systemAudioRecorder.stop()
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
            let engine = try transcriber ?? TranscriberFactory.make(settings.model)
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

        if recorder.isRecording, let stoppedURL = try? recorder.stop() {
            activeAudioURL = stoppedURL
        }
        if isSystemAudioActive {
            try? await systemAudioRecorder.stop()
            isSystemAudioActive = false
        }
        if activeKind == .meeting { await stopLiveMeetingTranscription() }
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
        let keepAudio = switch activeKind {
        case .dictation: settings.retainDictationAudio
        case .meeting: settings.retainMeetingAudio
        case .memo: settings.retainMemoAudio
        }
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

        record = try await library.commitRecoveredRecord(
            record,
            recoveryID: activeRecoveryID,
            keepAudio: keepAudio
        )

        guard captureLifecycle == .finishing(sessionID) else {
            try? await library.delete(id: record.id)
            return
        }
        records.insert(record, at: 0)
        selectedRecordID = record.id
        await refreshRecoverableCaptures()

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
                try await TextDelivery.deliver(
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

        if recordKind == .meeting,
           let destination = URL(string: settings.webhookURL),
           !settings.webhookURL.isEmpty {
            await enqueueAndDeliverWebhook(record: record, destination: destination)
        }
    }

    func retryPendingTextDelivery() async {
        guard let pendingDelivery, let target = pendingDelivery.target else {
            statusMessage = "The original destination is unavailable. Copy the text and paste it manually."
            return
        }
        do {
            try await TextDelivery.deliver(
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
        guard let pendingDelivery else { return }
        do {
            try TextDelivery.copyToClipboard(pendingDelivery.text)
            self.pendingDelivery = nil
            statusMessage = "Dictation copied. Paste it wherever you choose."
        } catch { statusMessage = error.localizedDescription }
    }

    private func cleanUpCancelledStart(sessionID: UUID) async {
        if recorder.isRecording, let stoppedURL = try? recorder.stop() {
            activeAudioURL = stoppedURL
        }
        try? await systemAudioRecorder.stop()
        if activeKind == .meeting { await stopLiveMeetingTranscription() }
        removeActiveRecoveryFiles()
        if activeKind == .meeting { await clearMeetingDraft() }
        await refreshRecoverableCaptures()
        if captureLifecycle == .cancelling(sessionID) || captureLifecycle == .starting(sessionID) {
            resetSession(state: .idle)
        }
    }

    private func failSession(sessionID: UUID, error: Error, preserveRecoveryAudio: Bool) async {
        if recorder.isRecording, let stoppedURL = try? recorder.stop() {
            activeAudioURL = stoppedURL
        }
        try? await systemAudioRecorder.stop()
        if activeKind == .meeting { await stopLiveMeetingTranscription() }
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
        if state == .idle, settings.hotMicEnabled {
            Task { @MainActor [weak self] in await self?.updateHotMicState() }
        }
    }

    var hasMeetingDraft: Bool {
        !meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !meetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func recover(_ capture: CaptureRecoveryManifest) async {
        guard captureLifecycle == .idle else { return }
        if capture.kind == .meeting, let draftID = meetingDraftCaptureID, draftID != capture.id {
            statusMessage = "These notes belong to a different interrupted meeting. Recover or discard that meeting first."
            return
        }
        guard let microphoneTrack = capture.tracks.first(where: { $0.role == .microphone }) else {
            statusMessage = "This recovery does not contain a microphone recording. You can discard it if the source audio is no longer available."
            return
        }

        let sessionID = capture.id
        do {
            activeKind = capture.kind
            activeOperation = .capture
            activeSelectedText = nil
            captureKind = capture.kind
            activeRecoveryID = sessionID
            activeRecoveryDirectory = await library.recoveryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            captureStartedAt = capture.startedAt
            captureLifecycle = .finishing(sessionID)
            captureState = .transcribing
            try? await library.updateRecoveryCapture(id: sessionID, status: .processing)

            let microphoneURL = try await library.safeURL(forRelativePath: microphoneTrack.relativePath)
            activeAudioURL = microphoneURL
            if let systemTrack = capture.tracks.first(where: { $0.role == .system }) {
                activeSystemAudioURL = try await library.safeURL(forRelativePath: systemTrack.relativePath)
            }

            let engine = try transcriber ?? TranscriberFactory.make(settings.model)
            transcriber = engine
            let microphoneTranscript = try await engine.transcribeDetailed(fileURL: microphoneURL, languageCode: settings.languageCode)
            guard captureLifecycle == .finishing(sessionID) else { return }

            var raw = microphoneTranscript.text
            var segments: [TranscriptSegment] = capture.kind == .meeting
                ? MeetingTranscriptAssembler().assemble(microphone: microphoneTranscript, system: nil)
                : [TranscriptSegment(start: 0, end: microphoneTranscript.duration, text: microphoneTranscript.text)]
            if capture.kind == .meeting,
               let systemURL = activeSystemAudioURL,
               FileManager.default.fileExists(atPath: systemURL.path) {
                do {
                    let systemTranscript = try await engine.transcribeDetailed(fileURL: systemURL, languageCode: settings.languageCode)
                    guard captureLifecycle == .finishing(sessionID) else { return }
                    let speakerIntervals = await speakerIntervalsIfAvailable(for: systemURL)
                    let microphoneOffset = recoveryOffset(for: microphoneTrack, in: capture)
                    let systemOffset = capture.tracks.first(where: { $0.role == .system }).map { recoveryOffset(for: $0, in: capture) } ?? 0
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

            let polished = cleanup.clean(
                raw,
                terms: settings.dictionary,
                tone: settings.defaultTone,
                appendPeriod: true,
                useParagraphs: true
            )
            let intelligence = capture.kind == .meeting ? MeetingIntelligencePipeline().generate(from: segments) : nil
            try await completeRecord(sessionID: sessionID, raw: raw, polished: polished, segments: segments, meetingIntelligence: intelligence)
        } catch {
            guard captureLifecycle == .finishing(sessionID) else { return }
            try? await library.updateRecoveryCapture(id: sessionID, status: .failed, failureReason: error.localizedDescription)
            await failSession(sessionID: sessionID, error: error, preserveRecoveryAudio: true)
        }
    }

    func discardRecovery(_ capture: CaptureRecoveryManifest) async {
        guard captureLifecycle == .idle else { return }
        do {
            try await library.discardRecoveryCapture(id: capture.id)
            if meetingDraftCaptureID == capture.id { await clearMeetingDraft() }
            await refreshRecoverableCaptures()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func discardMeetingDraft() async {
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
            recoverableCaptures = try await library.recoverableCaptures()
        } catch {
            statusMessage = "Recovery recordings could not be loaded: \(error.localizedDescription)"
        }
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
                Task { await live?.acceptMicrophone(buffer) }
            }
            systemAudioRecorder.setBufferHandler { [weak live] buffer in
                Task { await live?.acceptSystem(buffer) }
            }
            liveMeetingStatus = "Live local transcript is active. Final text is rebuilt from the saved tracks after you stop."
            liveMeetingUpdateTask = Task { @MainActor [weak self] in
                for await update in live.updates {
                    guard let self, !Task.isCancelled else { return }
                    if update.isConfirmed {
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
            await live.stop()
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
        guard captureLifecycle == .idle, !hotMicActive else { return }
        refreshPermissionState()
        guard microphonePermissionGranted else {
            statusMessage = "Grant Microphone permission before enabling wake-phrase listening."
            return
        }

        let listener = WakePhraseListener()
        do {
            try await listener.start(
                deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID,
                lowLatency: true
            )
            wakePhraseListener = listener
            hotMicActive = true
            hotMicTask = Task { @MainActor [weak self] in
                for await transcript in listener.transcripts {
                    guard let self, !Task.isCancelled else { return }
                    let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalized.contains(phrase.lowercased()) {
                        self.hotMicTask = nil
                        self.hotMicActive = false
                        await listener.stop()
                        self.wakePhraseListener = nil
                        await self.beginDictation()
                        return
                    }
                }
            }
        } catch {
            hotMicActive = false
            wakePhraseListener = nil
            statusMessage = "Wake-phrase listening could not start: \(error.localizedDescription)"
        }
    }

    private func stopHotMic() async {
        hotMicTask?.cancel()
        hotMicTask = nil
        if let wakePhraseListener { await wakePhraseListener.stop() }
        wakePhraseListener = nil
        hotMicActive = false
    }

    private func stopLiveMeetingTranscription() async {
        recorder.setBufferHandler(nil)
        systemAudioRecorder.setBufferHandler(nil)
        if let liveMeetingTranscriber { await liveMeetingTranscriber.stop() }
        liveMeetingUpdateTask?.cancel()
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
        guard normalizedWebhookDestination(settings.webhookURL) != nil else { return }
        let operation = webhookOutboxTransactions.beginPreparation()
        defer { webhookOutboxTransactions.abandon(operation) }
        let now = Date.now
        let queued = records.flatMap { record in
            record.webhookDeliveries.filter {
                $0.retryable && ($0.state == .pending || ($0.state == .failed && ($0.nextAttemptAt ?? .distantPast) <= now))
            }.map { (record.id, $0.id) }
        }
        for (recordID, deliveryID) in queued {
            guard !Task.isCancelled else { return }
            await deliverWebhook(
                recordID: recordID,
                deliveryID: deliveryID,
                requiringGeneration: operation.generation
            )
        }
        scheduleWebhookRetry()
    }

    private func scheduleWebhookRetry() {
        webhookRetryTask?.cancel()
        let nextDate = records
            .flatMap(\.webhookDeliveries)
            .filter { $0.state == .failed && $0.retryable }
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

    /// Task 5's terminate-later checkpoint calls this after synchronous
    /// invalidation. The notification observer deliberately does not launch or
    /// claim completion of this durable phase.
    func persistWebhookOutboxTerminationCancellation() async throws {
        let pending = pendingWebhookTerminationRecords
        let persistence = await persistWebhookRecords(pending)
        let failedIDs = Set(persistence.failures.map(\.recordID))
        pendingWebhookTerminationRecords = pending.filter { failedIDs.contains($0.id) }
        guard persistence.failures.isEmpty else {
            throw WebhookOutboxPersistenceBatchError(failures: persistence.failures)
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
