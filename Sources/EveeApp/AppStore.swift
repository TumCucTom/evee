import AppKit
import Combine
import EveeCore
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.command, .option]))
    static let transformSelection = Self("transformSelection", default: .init(.space, modifiers: [.command, .option, .shift]))
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
    @Published var captureState: CaptureState = .idle
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
    @Published private(set) var accessibilityPermissionGranted = TextDelivery.isAccessibilityTrusted
    @Published private(set) var microphonePermissionGranted = MicrophoneRecorder.isPermissionGranted

    let recorder = MicrophoneRecorder()
    private let systemAudioRecorder = SystemAudioRecorder()
    private let library = LibraryStore.shared
    private let cleanup = TextCleanupPipeline()
    private let selectionTransform = SelectionTransformPipeline()
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
    private var cancellables = Set<AnyCancellable>()
    private var pushToTalkHeld = false
    private var transformShortcutHeld = false
    private var activeShortcut: CaptureShortcut?
    private var stopRequestedDuringStart: UUID?
    private var shortcutTask: Task<Void, Never>?
    private var meetingDraftCaptureID: UUID?
    private var didBootstrap = false
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
        let eventPair = AsyncStream<PushToTalkEvent>.makeStream()
        shortcutEvents = eventPair.stream
        shortcutContinuation = eventPair.continuation

        recorder.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self, case .recording(let startedAt, _) = self.captureState else { return }
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
            try await loadAndMigrateSecrets()
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
            await retryPendingWebhookDeliveries()
        } catch {
            didBootstrap = false
            statusMessage = error.localizedDescription
        }
    }

    func saveSettings() async {
        do {
            if !settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let destination = URL(string: settings.webhookURL) else { throw WebhookEndpointError.invalidURL }
                try WebhookEndpointPolicy.validate(destination)
            }
            if webhookSecret.isEmpty {
                try secretStore.delete(KeychainSecretStore.webhookSigningSecretAccount)
            } else {
                try secretStore.set(webhookSecret, for: KeychainSecretStore.webhookSigningSecretAccount)
            }
            settings.webhookSecret = ""
            try await library.save(settings)
            transcriber?.unload()
            transcriber = try TranscriberFactory.make(settings.model)
            modelReady = transcriber?.isDownloaded == true
            if settings.localAPIEnabled {
                localAPICredentials = try await api.startWithCredentials(port: settings.localAPIPort)
            } else {
                api.stop()
                localAPICredentials = nil
            }
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
        activeApplication = TextDelivery.frontmostApplication()
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
        guard let target = TextDelivery.frontmostApplication(),
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
            _ = try await library.beginRecoveryCapture(kind: activeKind, id: sessionID)
            let directory = await library.recoveryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            activeRecoveryID = sessionID
            activeRecoveryDirectory = directory
            await refreshRecoverableCaptures()
            let url = directory.appendingPathComponent("microphone.caf")
            activeAudioURL = url
            try await recorder.start(at: url)

            guard captureLifecycle == .starting(sessionID) else {
                await cleanUpCancelledStart(sessionID: sessionID)
                return
            }

            if activeKind == .meeting {
                let systemURL = directory.appendingPathComponent("system.m4a")
                activeSystemAudioURL = systemURL
                do {
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
                    isSystemAudioActive = false
                    statusMessage = "Meeting capture is using your microphone only. Enable Screen Recording permission to include everyone else."
                }
            }

            let startedAt = Date.now
            captureStartedAt = startedAt
            captureLifecycle = .recording(sessionID)
            captureState = .recording(startedAt: startedAt, level: 0)

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

            guard let recoveryID = activeRecoveryID else {
                throw NSError(domain: "Evee.Recovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "The capture recovery session is unavailable."])
            }
            var recovery = try await library.addRecoveryTrack(
                captureID: recoveryID,
                kind: activeKind,
                role: .microphone,
                sourceURL: stoppedMicrophoneURL
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
                    sourceURL: systemURL
                )
                if let systemTrack = recovery.tracks.first(where: { $0.role == .system }) {
                    activeSystemAudioURL = try await library.safeURL(forRelativePath: systemTrack.relativePath)
                }
            }

            guard captureLifecycle == .finishing(sessionID) else { return }
            captureState = .transcribing
            let engine = try transcriber ?? TranscriberFactory.make(settings.model)
            transcriber = engine
            let micText = try await engine.transcribe(fileURL: audioURL, languageCode: settings.languageCode)
            guard captureLifecycle == .finishing(sessionID) else { return }

            var raw = micText
            var segments = [TranscriptSegment(start: 0, end: Date.now.timeIntervalSince(captureStartedAt ?? .now), speaker: activeKind == .meeting ? "You" : nil, text: micText)]
            if activeKind == .meeting,
               let systemURL = activeSystemAudioURL,
               FileManager.default.fileExists(atPath: systemURL.path),
               let otherText = try? await engine.transcribe(fileURL: systemURL, languageCode: settings.languageCode) {
                guard captureLifecycle == .finishing(sessionID) else { return }
                raw = "You: \(micText)\n\nOthers: \(otherText)"
                segments.append(TranscriptSegment(start: 0, end: Date.now.timeIntervalSince(captureStartedAt ?? .now), speaker: "Others", text: otherText))
            }
            let polished: String
            if activeOperation == .selectionTransform {
                polished = try selectionTransform.transform(
                    selectedText: activeSelectedText ?? "",
                    instruction: micText,
                    terms: settings.dictionary
                )
            } else {
                let style = styleForActiveApplication()
                polished = cleanup.clean(
                    raw,
                    terms: settings.dictionary,
                    tone: style?.tone ?? settings.defaultTone,
                    appendPeriod: style?.appendPeriod ?? true,
                    useParagraphs: style?.useParagraphs ?? true
                )
            }
            try await completeRecord(sessionID: sessionID, raw: raw, polished: polished, segments: segments)
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
    }

    private func completeRecord(sessionID: UUID, raw: String, polished: String, segments: [TranscriptSegment]) async throws {
        guard captureLifecycle == .finishing(sessionID) else { return }
        let duration = captureStartedAt.map { Date.now.timeIntervalSince($0) }
        let keepAudio = switch activeKind {
        case .dictation: settings.retainDictationAudio
        case .meeting: settings.retainMeetingAudio
        case .memo: settings.retainMemoAudio
        }
        let recordKind = activeKind
        let title: String = switch activeKind {
        case .dictation where activeOperation == .selectionTransform: "Transform · \(String(polished.prefix(60)))"
        case .dictation: String(polished.prefix(72))
        case .meeting: meetingTitle.isEmpty ? "Meeting · \(Date.now.formatted(date: .abbreviated, time: .shortened))" : meetingTitle
        case .memo: String(polished.prefix(72))
        }
        var record = WorkspaceRecord(
            kind: activeKind,
            title: title,
            text: polished,
            rawText: raw,
            sourceApplication: settings.retainContextMetadata ? activeApplication?.name : nil,
            duration: duration,
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
        isSystemAudioActive = false
        stopRequestedDuringStart = nil
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
            let microphoneText = try await engine.transcribe(fileURL: microphoneURL, languageCode: settings.languageCode)
            guard captureLifecycle == .finishing(sessionID) else { return }

            let duration = max(0, Date.now.timeIntervalSince(capture.startedAt))
            var raw = microphoneText
            var segments = [TranscriptSegment(
                start: 0,
                end: duration,
                speaker: capture.kind == .meeting ? "You" : nil,
                text: microphoneText
            )]
            if capture.kind == .meeting,
               let systemURL = activeSystemAudioURL,
               FileManager.default.fileExists(atPath: systemURL.path),
               let systemText = try? await engine.transcribe(fileURL: systemURL, languageCode: settings.languageCode) {
                guard captureLifecycle == .finishing(sessionID) else { return }
                raw = "You: \(microphoneText)\n\nOthers: \(systemText)"
                segments.append(TranscriptSegment(start: 0, end: duration, speaker: "Others", text: systemText))
            }

            let polished = cleanup.clean(
                raw,
                terms: settings.dictionary,
                tone: settings.defaultTone,
                appendPeriod: true,
                useParagraphs: true
            )
            try await completeRecord(sessionID: sessionID, raw: raw, polished: polished, segments: segments)
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

    func update(_ record: WorkspaceRecord) async {
        do {
            var changed = record
            changed.updatedAt = .now
            try await library.upsert(changed)
            if let index = records.firstIndex(where: { $0.id == changed.id }) { records[index] = changed }
        } catch { statusMessage = error.localizedDescription }
    }

    func delete(_ record: WorkspaceRecord) async {
        do {
            try await library.delete(id: record.id)
            records.removeAll { $0.id == record.id }
            if selectedRecordID == record.id { selectedRecordID = nil }
        } catch { statusMessage = error.localizedDescription }
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
        var queued = record
        let delivery = WebhookDelivery(destination: destination.absoluteString)
        queued.webhookDeliveries.append(delivery)
        do {
            try await library.upsert(queued)
            replaceRecord(queued)
            await deliverWebhook(recordID: queued.id, deliveryID: delivery.id)
        } catch {
            statusMessage = "The meeting was saved, but its webhook could not be queued: \(error.localizedDescription)"
        }
    }

    private func deliverWebhook(recordID: UUID, deliveryID: UUID) async {
        do {
            guard var record = try await library.record(id: recordID),
                  let index = record.webhookDeliveries.firstIndex(where: { $0.id == deliveryID }),
                  let destination = URL(string: record.webhookDeliveries[index].destination) else { return }
            let receipt = try await MeetingWebhook().sendWithStatus(
                record: record,
                destination: destination,
                secret: webhookSecret,
                deliveryID: deliveryID
            )
            record.webhookDeliveries[index].state = .delivered
            record.webhookDeliveries[index].attemptCount = receipt.attemptCount
            record.webhookDeliveries[index].lastAttemptAt = receipt.deliveredAt
            record.webhookDeliveries[index].deliveredAt = receipt.deliveredAt
            record.webhookDeliveries[index].responseStatusCode = receipt.statusCode
            record.webhookDeliveries[index].lastError = nil
            record.updatedAt = .now
            try await library.upsert(record)
            replaceRecord(record)
        } catch let failure as WebhookDeliveryFailure {
            await persistWebhookFailure(recordID: recordID, delivery: failure.delivery)
            statusMessage = "The meeting was saved. Its webhook remains in the delivery outbox: \(failure.localizedDescription)"
        } catch {
            var failure = WebhookDelivery(id: deliveryID, destination: "", state: .failed, attemptCount: 1, lastAttemptAt: .now, lastError: error.localizedDescription)
            if let record = try? await library.record(id: recordID),
               let existing = record.webhookDeliveries.first(where: { $0.id == deliveryID }) {
                failure.destination = existing.destination
            }
            await persistWebhookFailure(recordID: recordID, delivery: failure)
            statusMessage = "The meeting was saved. Its webhook remains in the delivery outbox: \(error.localizedDescription)"
        }
    }

    private func persistWebhookFailure(recordID: UUID, delivery: WebhookDelivery) async {
        do {
            guard var record = try await library.record(id: recordID),
                  let index = record.webhookDeliveries.firstIndex(where: { $0.id == delivery.id }) else { return }
            record.webhookDeliveries[index] = delivery
            record.updatedAt = .now
            try await library.upsert(record)
            replaceRecord(record)
        } catch {
            statusMessage = "Webhook delivery failed and its outbox state could not be saved: \(error.localizedDescription)"
        }
    }

    private func retryPendingWebhookDeliveries() async {
        let queued = records.flatMap { record in
            record.webhookDeliveries.filter { $0.state == .pending || $0.state == .failed }.map { (record.id, $0.id) }
        }
        for (recordID, deliveryID) in queued {
            await deliverWebhook(recordID: recordID, deliveryID: deliveryID)
        }
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
        guard settings.retainContextMetadata || settings.retainSelectedText else { return nil }
        return WorkspaceContext(
            bundleIdentifier: settings.retainContextMetadata ? application.bundleIdentifier : nil,
            applicationName: settings.retainContextMetadata ? application.name : nil,
            windowTitle: settings.retainContextMetadata ? target?.windowTitle : nil,
            document: settings.retainContextMetadata ? target?.document : nil,
            focusedRole: settings.retainContextMetadata ? target?.role : nil,
            selectedText: settings.retainSelectedText ? activeSelectedText : nil
        )
    }
}
