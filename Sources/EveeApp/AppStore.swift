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

    let recorder = MicrophoneRecorder()
    private let systemAudioRecorder = SystemAudioRecorder()
    private let library = LibraryStore.shared
    private let cleanup = TextCleanupPipeline()
    private let api = LocalAPIServer()
    private var transcriber: (any LocalTranscriber)?
    private var activeAudioURL: URL?
    private var activeSystemAudioURL: URL?
    private var isCapturingSystemAudio = false
    private var activeApplication: FrontmostApplication?
    private var activeKind: WorkspaceRecordKind = .dictation
    private var captureStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()

    init() {
        recorder.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self, case .recording(let startedAt, _) = self.captureState else { return }
                self.captureState = .recording(startedAt: startedAt, level: level)
            }
            .store(in: &cancellables)

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { @MainActor in await self?.beginDictation() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { @MainActor in await self?.finishCapture() }
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

    func beginDictation() async {
        guard case .idle = captureState else { return }
        activeApplication = TextDelivery.frontmostApplication()
        activeKind = .dictation
        await beginCapture(prefix: "dictation")
    }

    func beginMeeting() async {
        guard case .idle = captureState else { return }
        activeApplication = nil
        activeKind = .meeting
        await beginCapture(prefix: "meeting")
    }

    func beginMemo() async {
        guard case .idle = captureState else { return }
        activeApplication = nil
        activeKind = .memo
        await beginCapture(prefix: "memo")
    }

    private func beginCapture(prefix: String) async {
        do {
            let directory = await library.audioURL.appendingPathComponent("Recovery", isDirectory: true)
            let url = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).caf")
            try await recorder.start(at: url)
            if activeKind == .meeting {
                let systemURL = directory.appendingPathComponent("meeting-system-\(UUID().uuidString).m4a")
                do {
                    try await systemAudioRecorder.start(at: systemURL)
                    activeSystemAudioURL = systemURL
                    isCapturingSystemAudio = true
                } catch {
                    activeSystemAudioURL = nil
                    isCapturingSystemAudio = false
                    statusMessage = "Meeting capture is using your microphone only. Enable Screen Recording permission to include everyone else."
                }
            }
            activeAudioURL = url
            captureStartedAt = .now
            captureState = .recording(startedAt: .now, level: 0)
        } catch {
            captureState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func finishCapture() async {
        guard case .recording = captureState else { return }
        do {
            let audioURL = try recorder.stop()
            activeAudioURL = audioURL
            if isCapturingSystemAudio { try await systemAudioRecorder.stop() }
            captureState = .transcribing
            let engine = try transcriber ?? TranscriberFactory.make(settings.model)
            transcriber = engine
            let micText = try await engine.transcribe(fileURL: audioURL, languageCode: settings.languageCode)
            var raw = micText
            var segments = [TranscriptSegment(start: 0, end: Date.now.timeIntervalSince(captureStartedAt ?? .now), speaker: activeKind == .meeting ? "You" : nil, text: micText)]
            if activeKind == .meeting,
               let systemURL = activeSystemAudioURL,
               FileManager.default.fileExists(atPath: systemURL.path),
               let otherText = try? await engine.transcribe(fileURL: systemURL, languageCode: settings.languageCode) {
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
            try await completeRecord(raw: raw, polished: polished, audioURL: audioURL, segments: segments)
        } catch {
            captureState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func completeRecord(raw: String, polished: String, audioURL: URL, segments: [TranscriptSegment]) async throws {
        let duration = captureStartedAt.map { Date.now.timeIntervalSince($0) }
        let keepAudio = activeKind == .meeting ? settings.retainMeetingAudio : settings.retainDictationAudio
        var relativeAudioPath: String?
        if keepAudio {
            let name = "\(activeKind.rawValue)-\(UUID().uuidString).caf"
            let finalURL = await library.audioURL.appendingPathComponent(name)
            try FileManager.default.moveItem(at: audioURL, to: finalURL)
            relativeAudioPath = "Audio/\(name)"
        } else {
            try? FileManager.default.removeItem(at: audioURL)
        }

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
            audioRelativePath: relativeAudioPath,
            duration: duration,
            notes: activeKind == .meeting ? meetingNotes : ""
        )
        if activeKind == .meeting { record.segments = segments }

        captureState = activeKind == .dictation ? .delivering : .idle
        if activeKind == .dictation { try await TextDelivery.paste(polished) }
        try await library.upsert(record)
        records.insert(record, at: 0)
        selectedRecordID = record.id
        captureState = .idle
        meetingTitle = ""
        meetingNotes = ""
        if let systemURL = activeSystemAudioURL { try? FileManager.default.removeItem(at: systemURL) }
        activeSystemAudioURL = nil
        isCapturingSystemAudio = false

        if activeKind == .meeting,
           let destination = URL(string: settings.webhookURL),
           !settings.webhookURL.isEmpty {
            try await MeetingWebhook().send(record: record, destination: destination, secret: settings.webhookSecret)
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

    private func styleForActiveApplication() -> AppWritingStyle? {
        guard let id = activeApplication?.bundleIdentifier else { return nil }
        return settings.appStyles.first { $0.bundleIdentifier == id }
    }
}
