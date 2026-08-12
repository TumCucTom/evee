import AppKit
import Combine
import EveeCore
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.command, .option]))
}

@MainActor
final class AppStore: ObservableObject {
    enum Route: Hashable { case library, meetings, memos, dictionary, settings }

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
    @Published private(set) var captureKind: WorkspaceRecordKind?
    @Published private(set) var isSystemAudioActive = false
    @Published private(set) var accessibilityPermissionGranted = TextDelivery.isAccessibilityTrusted
    @Published private(set) var microphonePermissionGranted = MicrophoneRecorder.isPermissionGranted

    let recorder = MicrophoneRecorder()
    private let systemAudioRecorder = SystemAudioRecorder()
    private let library = LibraryStore.shared
    private let cleanup = TextCleanupPipeline()
    private let api = LocalAPIServer()
    private var transcriber: (any LocalTranscriber)?
    private var activeAudioURL: URL?
    private var activeSystemAudioURL: URL?
    private var activeRecoveryID: UUID?
    private var activeRecoveryDirectory: URL?
    private var activeApplication: FrontmostApplication?
    private var activeKind: WorkspaceRecordKind = .dictation
    private var captureStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var pushToTalkHeld = false
    private var pushToTalkReleasedWhileStarting = false
    private var stopRequestedDuringStart: UUID?

    private enum CaptureLifecycle: Equatable {
        case idle
        case starting(UUID)
        case recording(UUID)
        case finishing(UUID)
        case cancelling(UUID)
    }

    private var captureLifecycle: CaptureLifecycle = .idle

    init() {
        recorder.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self, case .recording(let startedAt, _) = self.captureState else { return }
                self.captureState = .recording(startedAt: startedAt, level: level)
            }
            .store(in: &cancellables)

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { @MainActor in
                guard let self, !self.pushToTalkHeld else { return }
                self.pushToTalkHeld = true
                self.pushToTalkReleasedWhileStarting = false
                await self.beginDictation()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pushToTalkHeld = false
                if case .idle = self.captureLifecycle {
                    self.pushToTalkReleasedWhileStarting = true
                }
                await self.finishCapture()
            }
        }
    }

    var filteredRecords: [WorkspaceRecord] {
        records.filter { record in
            let kindMatches: Bool = switch route {
            case .meetings: record.kind == .meeting
            case .memos: record.kind == .memo
            default: true
            }
            return kindMatches && (search.isEmpty || [record.title, record.text, record.notes].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    var selectedRecord: WorkspaceRecord? {
        get { selectedRecordID.flatMap { id in records.first(where: { $0.id == id }) } }
        set { selectedRecordID = newValue?.id }
    }

    func bootstrap() async {
        do {
            try await library.prepare()
            settings = try await library.loadSettings()
            records = try await library.loadRecords().sorted { $0.createdAt > $1.createdAt }
            transcriber = try TranscriberFactory.make(settings.model)
            modelReady = transcriber?.isDownloaded == true
            refreshPermissionState()
            if settings.localAPIEnabled { _ = try await api.start(port: settings.localAPIPort) }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveSettings() async {
        do {
            try await library.save(settings)
            transcriber?.unload()
            transcriber = try TranscriberFactory.make(settings.model)
            modelReady = transcriber?.isDownloaded == true
            if settings.localAPIEnabled { _ = try await api.start(port: settings.localAPIPort) } else { api.stop() }
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
        await beginCapture(prefix: "dictation")
    }

    func beginMeeting() async {
        guard captureLifecycle == .idle else { return }
        activeApplication = nil
        activeKind = .meeting
        await beginCapture(prefix: "meeting")
    }

    func beginMemo() async {
        guard captureLifecycle == .idle else { return }
        activeApplication = nil
        activeKind = .memo
        await beginCapture(prefix: "memo")
    }

    private func beginCapture(prefix: String) async {
        guard captureLifecycle == .idle else { return }
        let sessionID = UUID()
        captureLifecycle = .starting(sessionID)
        captureKind = activeKind
        stopRequestedDuringStart = pushToTalkReleasedWhileStarting && activeKind == .dictation ? sessionID : nil
        pushToTalkReleasedWhileStarting = false

        do {
            _ = try await library.beginRecoveryCapture(kind: activeKind, id: sessionID)
            let directory = await library.recoveryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            activeRecoveryID = sessionID
            activeRecoveryDirectory = directory
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
            let style = styleForActiveApplication()
            let polished = cleanup.clean(
                raw,
                terms: settings.dictionary,
                tone: style?.tone ?? settings.defaultTone,
                appendPeriod: style?.appendPeriod ?? true,
                useParagraphs: style?.useParagraphs ?? true
            )
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
        let keepAudio = activeKind == .meeting ? settings.retainMeetingAudio : settings.retainDictationAudio
        let recordKind = activeKind
        let title: String = switch activeKind {
        case .dictation: String(polished.prefix(72))
        case .meeting: meetingTitle.isEmpty ? "Meeting · \(Date.now.formatted(date: .abbreviated, time: .shortened))" : meetingTitle
        case .memo: String(polished.prefix(72))
        }
        var record = WorkspaceRecord(
            kind: activeKind,
            title: title,
            text: polished,
            rawText: raw,
            sourceApplication: activeApplication?.name,
            duration: duration,
            notes: activeKind == .meeting ? meetingNotes : ""
        )
        if activeKind == .meeting { record.segments = segments }

        if keepAudio, let recoveryID = activeRecoveryID {
            let tracks = try await library.retainRecoveryCapture(id: recoveryID, for: record.id)
            record.audioTracks = tracks
            record.audioRelativePath = tracks.first(where: { $0.role == .microphone })?.relativePath
        }

        do {
            try await library.upsert(record)
        } catch {
            throw error
        }

        guard captureLifecycle == .finishing(sessionID) else {
            try? await library.delete(id: record.id)
            return
        }
        records.insert(record, at: 0)
        selectedRecordID = record.id
        if !keepAudio { removeActiveRecoveryFiles() }

        if recordKind == .dictation {
            captureState = .delivering
            if let target = activeApplication {
                do {
                    try await TextDelivery.paste(polished, to: target)
                } catch {
                    statusMessage = error.localizedDescription
                }
            } else {
                statusMessage = "Evee saved the dictation but did not paste it because the destination app was unavailable."
            }
        }

        meetingTitle = ""
        meetingNotes = ""
        resetSession(state: .idle)

        if recordKind == .meeting,
           let destination = URL(string: settings.webhookURL),
           !settings.webhookURL.isEmpty {
            do {
                try await MeetingWebhook().send(record: record, destination: destination, secret: settings.webhookSecret)
            } catch {
                statusMessage = "The meeting was saved, but its webhook could not be delivered: \(error.localizedDescription)"
            }
        }
    }

    private func cleanUpCancelledStart(sessionID: UUID) async {
        if recorder.isRecording, let stoppedURL = try? recorder.stop() {
            activeAudioURL = stoppedURL
        }
        try? await systemAudioRecorder.stop()
        removeActiveRecoveryFiles()
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
        if !preserveRecoveryAudio { removeActiveRecoveryFiles() }
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
        activeAudioURL = nil
        activeSystemAudioURL = nil
        activeRecoveryID = nil
        activeRecoveryDirectory = nil
        activeApplication = nil
        captureStartedAt = nil
        isSystemAudioActive = false
        stopRequestedDuringStart = nil
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

    private func styleForActiveApplication() -> AppWritingStyle? {
        guard let id = activeApplication?.bundleIdentifier else { return nil }
        return settings.appStyles.first { $0.bundleIdentifier == id }
    }
}
