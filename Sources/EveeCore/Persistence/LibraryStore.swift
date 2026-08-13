import Darwin
import Foundation

public enum LibraryStoreError: LocalizedError, Sendable {
    case corruptFile(URL)
    case unsafeRelativePath(String)
    case missingAudioSource(URL)
    case missingRecoveryCapture(UUID)
    case emptyRecoverySelection
    case invalidRecoveryTrack(AudioTrackRole, String)
    case unsupportedSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .corruptFile(let backup):
            return "Evee preserved an unreadable library file at \(backup.path)."
        case .unsafeRelativePath(let path):
            return "The library rejected an unsafe relative path: \(path)"
        case .missingAudioSource(let url):
            return "The audio source no longer exists at \(url.path)."
        case .missingRecoveryCapture(let id):
            return "The recovery capture \(id.uuidString) is unavailable, so retained audio was not committed."
        case .emptyRecoverySelection:
            return "Choose at least one valid recovery track."
        case .invalidRecoveryTrack(let role, let reason):
            return "The \(role.rawValue) recovery track cannot be saved. \(reason)"
        case .unsupportedSchema(let found, let supported):
            return "This Evee library uses schema \(found), but this version supports up to schema \(supported)."
        }
    }
}

@_spi(Testing) public enum LibraryStoreWritePoint: Hashable, Sendable {
    case recordMetadata
}

private struct RecordsEnvelope: Codable {
    var schemaVersion: Int
    var updatedAt: Date
    var records: [WorkspaceRecord]
}

private struct SettingsEnvelope: Codable {
    var schemaVersion: Int
    var updatedAt: Date
    var settings: EveeSettings
}

public actor LibraryStore {
    public static let shared = LibraryStore()
    public static let currentSchemaVersion = 2

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public let rootURL: URL
    public let audioURL: URL
    public let recoveryURL: URL
    private let recordsURL: URL
    private let settingsURL: URL
    private let meetingDraftURL: URL
    private let searchIndexURL: URL
    private var searchIndex: WorkspaceSearchIndex?
    private var failNextWritesAt: Set<LibraryStoreWritePoint>

    public init(rootURL: URL? = nil) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = (rootURL ?? applicationSupport.appendingPathComponent("Evee", isDirectory: true)).standardizedFileURL
        self.audioURL = self.rootURL.appendingPathComponent("Audio", isDirectory: true)
        self.recoveryURL = self.audioURL.appendingPathComponent("Recovery", isDirectory: true)
        self.recordsURL = self.rootURL.appendingPathComponent("records.json")
        self.settingsURL = self.rootURL.appendingPathComponent("settings.json")
        self.meetingDraftURL = self.rootURL.appendingPathComponent("meeting-draft.json")
        self.searchIndexURL = self.rootURL.appendingPathComponent("workspace-index.sqlite3")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.failNextWritesAt = []
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    @_spi(Testing) public init(rootURL: URL, failNextWritesAt: Set<LibraryStoreWritePoint>) {
        self.rootURL = rootURL.standardizedFileURL
        self.audioURL = self.rootURL.appendingPathComponent("Audio", isDirectory: true)
        self.recoveryURL = self.audioURL.appendingPathComponent("Recovery", isDirectory: true)
        self.recordsURL = self.rootURL.appendingPathComponent("records.json")
        self.settingsURL = self.rootURL.appendingPathComponent("settings.json")
        self.meetingDraftURL = self.rootURL.appendingPathComponent("meeting-draft.json")
        self.searchIndexURL = self.rootURL.appendingPathComponent("workspace-index.sqlite3")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.failNextWritesAt = failNextWritesAt
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func prepare() throws {
        try createPrivateDirectory(rootURL)
        try createPrivateDirectory(audioURL)
        try createPrivateDirectory(recoveryURL)
    }

    public func loadRecords() throws -> [WorkspaceRecord] {
        try prepare()
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return [] }
        let data = try Data(contentsOf: recordsURL)
        do {
            if let envelope = try? decoder.decode(RecordsEnvelope.self, from: data) {
                guard envelope.schemaVersion <= Self.currentSchemaVersion else {
                    throw LibraryStoreError.unsupportedSchema(found: envelope.schemaVersion, supported: Self.currentSchemaVersion)
                }
                return envelope.records
            }

            // Version 1 stored the records array directly. Upgrade it on the first successful read.
            let legacy = try decoder.decode([WorkspaceRecord].self, from: data)
            try save(legacy)
            return legacy
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            let backup = try preserveCorruptFile(recordsURL)
            throw LibraryStoreError.corruptFile(backup)
        }
    }

    public func loadRecordsRecoveringCorruption() throws -> RecoveredLibraryLoad<[WorkspaceRecord]> {
        try prepare()
        guard FileManager.default.fileExists(atPath: recordsURL.path) else {
            return RecoveredLibraryLoad(value: [])
        }
        let data = try Data(contentsOf: recordsURL)
        do {
            return RecoveredLibraryLoad(value: try decodeRecords(data))
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            let preserved = try preserveCorruptCanonicalFile(recordsURL, expectedData: data)
            return RecoveredLibraryLoad(value: [], preservedCorruptURL: preserved)
        }
    }

    private func decodeRecords(_ data: Data) throws -> [WorkspaceRecord] {
        if let envelope = try? decoder.decode(RecordsEnvelope.self, from: data) {
            guard envelope.schemaVersion <= Self.currentSchemaVersion else {
                throw LibraryStoreError.unsupportedSchema(found: envelope.schemaVersion, supported: Self.currentSchemaVersion)
            }
            return envelope.records
        }
        let legacy = try decoder.decode([WorkspaceRecord].self, from: data)
        try save(legacy)
        return legacy
    }

    public func save(_ records: [WorkspaceRecord]) throws {
        try prepare()
        let envelope = RecordsEnvelope(schemaVersion: Self.currentSchemaVersion, updatedAt: .now, records: records)
        try writePrivate(encoder.encode(envelope), to: recordsURL, point: .recordMetadata)
        do {
            try synchronizeSearchIndex(records)
        } catch {
            // Search is a rebuildable projection. Never turn a successfully
            // committed transcript into a failed capture because its index is
            // temporarily unavailable.
            invalidateSearchIndex()
        }
    }

    public func loadSettings() throws -> EveeSettings {
        try prepare()
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return EveeSettings() }
        let data = try Data(contentsOf: settingsURL)
        do {
            if let envelope = try? decoder.decode(SettingsEnvelope.self, from: data) {
                guard envelope.schemaVersion <= Self.currentSchemaVersion else {
                    throw LibraryStoreError.unsupportedSchema(found: envelope.schemaVersion, supported: Self.currentSchemaVersion)
                }
                return envelope.settings
            }

            let legacy = try decoder.decode(EveeSettings.self, from: data)
            try save(legacy)
            return legacy
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            let backup = try preserveCorruptFile(settingsURL)
            throw LibraryStoreError.corruptFile(backup)
        }
    }

    public func loadSettingsRecoveringCorruption() throws -> RecoveredLibraryLoad<EveeSettings> {
        try prepare()
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return RecoveredLibraryLoad(value: EveeSettings())
        }
        let data = try Data(contentsOf: settingsURL)
        do {
            return RecoveredLibraryLoad(value: try decodeSettings(data))
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            let preserved = try preserveCorruptCanonicalFile(settingsURL, expectedData: data)
            return RecoveredLibraryLoad(value: EveeSettings(), preservedCorruptURL: preserved)
        }
    }

    private func decodeSettings(_ data: Data) throws -> EveeSettings {
        if let envelope = try? decoder.decode(SettingsEnvelope.self, from: data) {
            guard envelope.schemaVersion <= Self.currentSchemaVersion else {
                throw LibraryStoreError.unsupportedSchema(found: envelope.schemaVersion, supported: Self.currentSchemaVersion)
            }
            return envelope.settings
        }
        let legacy = try decoder.decode(EveeSettings.self, from: data)
        try save(legacy)
        return legacy
    }

    public func save(_ settings: EveeSettings) throws {
        try prepare()
        let envelope = SettingsEnvelope(schemaVersion: Self.currentSchemaVersion, updatedAt: .now, settings: settings)
        try writePrivate(encoder.encode(envelope), to: settingsURL)
    }

    public func loadMeetingDraft() throws -> MeetingDraft? {
        try prepare()
        guard FileManager.default.fileExists(atPath: meetingDraftURL.path) else { return nil }
        return try decoder.decode(MeetingDraft.self, from: Data(contentsOf: meetingDraftURL))
    }

    public func loadMeetingDraftRecoveringCorruption() throws -> RecoveredLibraryLoad<MeetingDraft?> {
        try prepare()
        guard FileManager.default.fileExists(atPath: meetingDraftURL.path) else {
            return RecoveredLibraryLoad(value: nil)
        }
        let data = try Data(contentsOf: meetingDraftURL)
        do {
            return RecoveredLibraryLoad(value: try decoder.decode(MeetingDraft.self, from: data))
        } catch {
            let preserved = try preserveCorruptCanonicalFile(meetingDraftURL, expectedData: data)
            return RecoveredLibraryLoad(value: nil, preservedCorruptURL: preserved)
        }
    }

    public func saveMeetingDraft(_ draft: MeetingDraft?) throws {
        try prepare()
        guard let draft else {
            if FileManager.default.fileExists(atPath: meetingDraftURL.path) {
                try FileManager.default.removeItem(at: meetingDraftURL)
            }
            return
        }
        try writePrivate(encoder.encode(draft), to: meetingDraftURL)
    }

    @discardableResult
    public func clearMeetingDraft(matching captureID: UUID) throws -> Bool {
        guard let draft = try loadMeetingDraft(), draft.captureID == captureID else { return false }
        try saveMeetingDraft(nil)
        return true
    }

    @discardableResult
    public func clearMeetingDraft(
        forCommitted record: WorkspaceRecord,
        recoveryID: UUID?
    ) throws -> Bool {
        guard record.kind == .meeting, let recoveryID else { return false }
        return try clearMeetingDraft(matching: recoveryID)
    }

    public func search(_ query: String, kind: WorkspaceRecordKind? = nil, limit: Int = 50) throws -> [WorkspaceRecord] {
        let records = try loadRecords()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedLimit = max(1, min(limit, 500))
        if !needle.isEmpty {
            let ids: [UUID]
            do {
                let index = try workspaceSearchIndex()
                if try !index.isCurrent(records: records) { try index.rebuild(records: records) }
                ids = try index.matchingIDs(query: needle, kind: kind, limit: boundedLimit)
            } catch {
                invalidateSearchIndex()
                let rebuilt = try workspaceSearchIndex()
                try rebuilt.rebuild(records: records)
                ids = try rebuilt.matchingIDs(query: needle, kind: kind, limit: boundedLimit)
            }
            let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            return ids.compactMap { recordsByID[$0] }
        }
        return records
            .filter { record in
                (kind == nil || record.kind == kind) &&
                (needle.isEmpty || [record.title, record.text, record.notes, record.tags.joined(separator: " ")]
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains(needle))
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(boundedLimit)
            .map { $0 }
    }

    private func workspaceSearchIndex() throws -> WorkspaceSearchIndex {
        if let searchIndex { return searchIndex }
        try prepare()
        let index = try WorkspaceSearchIndex(url: searchIndexURL)
        searchIndex = index
        return index
    }

    private func synchronizeSearchIndex(_ records: [WorkspaceRecord]) throws {
        try workspaceSearchIndex().rebuild(records: records)
    }

    private func invalidateSearchIndex() {
        searchIndex = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: searchIndexURL.path + suffix)
        }
    }

    public func recent(kind: WorkspaceRecordKind? = nil, limit: Int = 50, since: Date? = nil) throws -> [WorkspaceRecord] {
        try loadRecords()
            .filter { record in
                guard kind == nil || record.kind == kind else { return false }
                guard let since else { return true }
                return record.createdAt >= since
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(1, min(limit, 500)))
            .map { $0 }
    }

    public func record(id: UUID) throws -> WorkspaceRecord? {
        try loadRecords().first { $0.id == id }
    }

    public func upsert(_ record: WorkspaceRecord) throws {
        var records = try loadRecords()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records)
    }

    public func delete(id: UUID) throws {
        var records = try loadRecords()
        guard let record = records.first(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }

        // Metadata is the source of ownership. Commit its removal before deleting
        // audio so a failed save cannot leave a record pointing at missing files.
        try save(records)

        let paths = [record.audioRelativePath].compactMap { $0 } + record.audioTracks.map(\.relativePath)
        for relativePath in Set(paths) {
            if let url = try? safeURL(forRelativePath: relativePath) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? reconcileRecordAudio(using: records)
    }

    @discardableResult
    public func purgeRecords(olderThan cutoff: Date) throws -> Int {
        let records = try loadRecords()
        let removed = records.filter { $0.createdAt < cutoff }
        guard !removed.isEmpty else { return 0 }
        let retained = records.filter { $0.createdAt >= cutoff }

        // Commit metadata first so an interrupted purge can leave only harmless
        // orphaned audio, never records pointing at files we already removed.
        try save(retained)
        let paths = removed.flatMap { record in
            [record.audioRelativePath].compactMap { $0 } + record.audioTracks.map(\.relativePath)
        }
        for relativePath in Set(paths) {
            if let url = try? safeURL(forRelativePath: relativePath) { try? FileManager.default.removeItem(at: url) }
        }
        try? reconcileRecordAudio(using: retained)
        return removed.count
    }

    // MARK: - Durable dual-track audio and crash recovery

    @discardableResult
    public func beginRecoveryCapture(kind: WorkspaceRecordKind, id: UUID = UUID()) throws -> CaptureRecoveryManifest {
        try prepare()
        let directory = recoveryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try createPrivateDirectory(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try readRecoveryManifest(directory: directory)
        }
        let manifest = CaptureRecoveryManifest(id: id, kind: kind)
        try writeRecoveryManifest(manifest, directory: directory)
        return manifest
    }

    public func addRecoveryTrack(
        captureID: UUID,
        kind: WorkspaceRecordKind,
        role: AudioTrackRole,
        sourceURL: URL,
        moveSource: Bool = true,
        duration: TimeInterval? = nil,
        startedAt: Date? = nil
    ) throws -> CaptureRecoveryManifest {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LibraryStoreError.missingAudioSource(sourceURL)
        }
        try prepare()
        let directory = recoveryURL.appendingPathComponent(captureID.uuidString, isDirectory: true)
        try createPrivateDirectory(directory)
        let destination = directory.appendingPathComponent("\(role.rawValue)-\(UUID().uuidString).\(sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension)")
        do {
            // Keep the recorder's source path intact until both the copied bytes
            // and their manifest entry are durable. A normal write failure can
            // therefore retry without reconstructing an already-stopped writer.
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try makePrivate(destination)
            try synchronizeFile(at: destination)

            var manifest = (try? readRecoveryManifest(directory: directory))
                ?? CaptureRecoveryManifest(id: captureID, kind: kind)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value
            let relativePath = relativePath(for: destination)
            manifest.tracks.removeAll { $0.role == role }
            manifest.tracks.append(WorkspaceAudioTrack(
                role: role,
                relativePath: relativePath,
                createdAt: startedAt ?? .now,
                duration: duration,
                byteCount: byteCount
            ))
            manifest.status = .captured
            manifest.updatedAt = .now
            manifest.failureReason = nil
            try writeRecoveryManifest(manifest, directory: directory)
            if moveSource {
                do {
                    try FileManager.default.removeItem(at: sourceURL)
                } catch {
                    // The manifest and copied track are already durable. Leaving
                    // the recorder source as an orphan is safer than reporting a
                    // retryable checkpoint failure that could duplicate tracks.
                }
            }
            return manifest
        } catch {
            let durableManifestOwnsDestination = (try? readRecoveryManifest(directory: directory))?
                .tracks
                .contains(where: { $0.relativePath == relativePath(for: destination) }) == true
            if !durableManifestOwnsDestination {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    public func updateRecoveryCapture(id: UUID, status: CaptureRecoveryStatus, failureReason: String? = nil) throws {
        let directory = recoveryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        var manifest = try readRecoveryManifest(directory: directory)
        manifest.status = status
        manifest.failureReason = failureReason
        manifest.updatedAt = .now
        try writeRecoveryManifest(manifest, directory: directory)
    }

    public func recoverableCaptures() throws -> [CaptureRecoveryManifest] {
        try prepare()
        let children = try FileManager.default.contentsOfDirectory(
            at: recoveryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var manifests: [CaptureRecoveryManifest] = []
        var looseTracks: [UUID: [WorkspaceAudioTrack]] = [:]

        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if values.isDirectory == true {
                guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
                var manifest = (try? readRecoveryManifest(directory: child))
                    ?? CaptureRecoveryManifest(id: id, kind: .dictation, startedAt: values.contentModificationDate ?? .now)
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for file in files where file.lastPathComponent != "manifest.json" {
                    let relative = relativePath(for: file)
                    guard !manifest.tracks.contains(where: { $0.relativePath == relative }) else { continue }
                    let fileValues = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    manifest.tracks.append(WorkspaceAudioTrack(
                        role: inferredTrackRole(for: file),
                        relativePath: relative,
                        createdAt: fileValues?.contentModificationDate ?? manifest.startedAt,
                        byteCount: fileValues?.fileSize.map(Int64.init)
                    ))
                }
                if manifest.tracks.contains(where: { $0.role == .system }) { manifest.kind = .meeting }
                if !manifest.tracks.isEmpty, manifest.status == .recording { manifest.status = .captured }
                if manifest.status != .committed, manifest.status != .purging {
                    manifests.append(manifest)
                }
                continue
            }

            // Compatibility with captures written before recovery manifests existed.
            let stem = child.deletingPathExtension().lastPathComponent
            let isSystem = stem.hasSuffix("-system")
            let idText = isSystem ? String(stem.dropLast("-system".count)) : stem
            guard let id = UUID(uuidString: idText) else { continue }
            let track = WorkspaceAudioTrack(
                role: isSystem ? .system : .microphone,
                relativePath: relativePath(for: child),
                createdAt: values.contentModificationDate ?? .now,
                byteCount: values.fileSize.map { Int64($0) }
            )
            looseTracks[id, default: []].append(track)
        }

        manifests.append(contentsOf: looseTracks.map { id, tracks in
            CaptureRecoveryManifest(id: id, kind: tracks.contains(where: { $0.role == .system }) ? .meeting : .dictation, status: .captured, tracks: tracks)
        })
        return manifests.sorted { $0.startedAt > $1.startedAt }
    }

    public func assessRecoveryTracks(captureID: UUID) throws -> [RecoveryTrackAssessment] {
        guard let capture = try recoverableCaptures().first(where: { $0.id == captureID }) else {
            throw LibraryStoreError.missingRecoveryCapture(captureID)
        }
        return capture.tracks.map(assessRecoveryTrack)
    }

    /// Establishes durable record metadata before removing its recovery copy.
    /// Retained-file moves are rolled back if the metadata write fails.
    public func commitRecoveredRecord(
        _ proposedRecord: WorkspaceRecord,
        recoveryID: UUID?,
        trackSelection: RecoveryTrackSelection? = nil,
        keepAudio: Bool
    ) throws -> WorkspaceRecord {
        var record = proposedRecord
        guard let recoveryID else {
            try upsert(record)
            return record
        }

        let capture = try recoverableCaptures().first { $0.id == recoveryID }
        record.recoverySourceID = recoveryID
        var copies: [URL] = []

        if keepAudio {
            guard let capture else { throw LibraryStoreError.missingRecoveryCapture(recoveryID) }
            let assessments = capture.tracks.map(assessRecoveryTrack)
            let requestedRoles: Set<AudioTrackRole> = switch trackSelection {
            case .allValid:
                Set(assessments.filter(\.isValid).map(\.role))
            case .roles(let roles):
                roles
            case nil:
                Set(capture.tracks.map(\.role))
            }
            guard !requestedRoles.isEmpty else { throw LibraryStoreError.emptyRecoverySelection }
            for role in requestedRoles {
                if let selectedTrack = capture.tracks.first(where: { $0.role == role }) {
                    let source = try safeURL(forRelativePath: selectedTrack.relativePath)
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw LibraryStoreError.missingAudioSource(source)
                    }
                }
                guard let assessment = assessments.first(where: { $0.role == role }) else {
                    throw LibraryStoreError.invalidRecoveryTrack(role, "The selected source is missing.")
                }
                guard assessment.isValid else {
                    throw LibraryStoreError.invalidRecoveryTrack(role, assessment.failureReason ?? "The selected source is not playable.")
                }
            }
            let selectedTracks = capture.tracks.filter { requestedRoles.contains($0.role) }
            guard !selectedTracks.isEmpty else { throw LibraryStoreError.emptyRecoverySelection }

            var records = try loadRecords()
            let previousRecord = records.first(where: { $0.id == record.id })
            let destinationDirectory = audioURL
                .appendingPathComponent("Records", isDirectory: true)
                .appendingPathComponent(record.id.uuidString, isDirectory: true)
            try createPrivateDirectory(destinationDirectory)
            var retained: [WorkspaceAudioTrack] = []

            do {
                for track in selectedTracks {
                    let source = try safeURL(forRelativePath: track.relativePath)
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw LibraryStoreError.missingAudioSource(source)
                    }
                    let pathExtension = source.pathExtension.isEmpty ? "audio" : source.pathExtension
                    let destination = uniqueDestination(
                        in: destinationDirectory,
                        prefix: track.role.rawValue,
                        pathExtension: pathExtension
                    )
                    // Copy first: the recovery capture remains the crash-safe source of
                    // truth until record metadata has durably committed.
                    try FileManager.default.copyItem(at: source, to: destination)
                    copies.append(destination)
                    try makePrivate(destination)
                    try synchronizeFile(at: destination)
                    let sourceBytes = try fileByteCount(at: source)
                    let destinationBytes = try fileByteCount(at: destination)
                    guard sourceBytes == destinationBytes else {
                        throw LibraryStoreError.invalidRecoveryTrack(track.role, "The retained copy did not match the recovery source.")
                    }
                    var updated = track
                    updated.relativePath = relativePath(for: destination)
                    updated.byteCount = destinationBytes
                    let copiedAssessment = RecoveryTrackValidator().assess(
                        updated,
                        sourceURL: destination,
                        resolvedURL: destination
                    )
                    guard copiedAssessment.isValid else {
                        throw LibraryStoreError.invalidRecoveryTrack(
                            track.role,
                            copiedAssessment.failureReason ?? "The retained copy is not playable."
                        )
                    }
                    retained.append(updated)
                }
                record.audioTracks = retained
                guard retained.count == selectedTracks.count, !retained.isEmpty else {
                    throw LibraryStoreError.missingRecoveryCapture(recoveryID)
                }
                record.audioRelativePath = retained.first(where: { $0.role == .microphone })?.relativePath
                    ?? retained.first?.relativePath
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index] = record
                } else {
                    records.append(record)
                }
                try save(records)

                let referencedPaths = Set(records.flatMap(recordAudioPaths))
                for oldPath in previousRecord.map(recordAudioPaths) ?? [] where !referencedPaths.contains(oldPath) {
                    removeOwnedRecordAudioIfPresent(relativePath: oldPath, recordID: record.id)
                }
                try? reconcileRecordAudio(using: records)
            } catch {
                for copy in copies.reversed() where FileManager.default.fileExists(atPath: copy.path) {
                    try? FileManager.default.removeItem(at: copy)
                }
                throw error
            }
            // Metadata now durably owns the retained copies. Cleanup failures
            // must never roll back those copies or turn a saved capture into an
            // error; launch reconciliation uses `recoverySourceID` to finish.
            try? updateRecoveryCapture(id: recoveryID, status: .committed)
        } else {
            // Commit metadata first. `recoverySourceID` is the durable cleanup
            // ownership marker, so a crash before this write leaves the capture
            // recoverable while a crash after it causes launch reconciliation to
            // purge the raw files without risking a lost record.
            try upsert(record)
            try? updateRecoveryCapture(id: recoveryID, status: .purging)
        }

        // Metadata now owns the result (or intentionally owns no audio), so the
        // recovery copy is safe to remove. Failed cleanup is reconciled on launch.
        try? removeRecoveryArtifacts(id: recoveryID, tracks: capture?.tracks ?? [])
        return record
    }

    public func discardRecoveryCapture(id: UUID) throws {
        let capture = try recoverableCaptures().first { $0.id == id }
        try removeRecoveryArtifacts(id: id, tracks: capture?.tracks ?? [])
    }

    public func reconcileAudioStorage() throws {
        let records = try loadRecords()
        try reconcileRecordAudio(using: records)
        try reconcileRecoveryAudio(using: records)
    }

    public func safeURL(forRelativePath relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw LibraryStoreError.unsafeRelativePath(relativePath)
        }
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        let lexicalCandidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let lexicalRootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard lexicalCandidate.path.hasPrefix(lexicalRootPath) else {
            throw LibraryStoreError.unsafeRelativePath(relativePath)
        }

        let suffix = lexicalCandidate.path.dropFirst(lexicalRootPath.count)
        var resolvedCandidate = resolvedRoot
        for component in suffix.split(separator: "/") {
            let next = resolvedCandidate.appendingPathComponent(String(component))
            let attributes = try? FileManager.default.attributesOfItem(atPath: next.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                resolvedCandidate = next.resolvingSymlinksInPath()
            } else {
                resolvedCandidate = next
            }
            let path = resolvedCandidate.standardizedFileURL.path
            guard path == resolvedRoot.path || path.hasPrefix(rootPath) else {
                throw LibraryStoreError.unsafeRelativePath(relativePath)
            }
        }
        return resolvedCandidate.standardizedFileURL
    }

    private func readRecoveryManifest(directory: URL) throws -> CaptureRecoveryManifest {
        try decoder.decode(CaptureRecoveryManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    private func writeRecoveryManifest(_ manifest: CaptureRecoveryManifest, directory: URL) throws {
        try createPrivateDirectory(directory)
        try writePrivate(encoder.encode(manifest), to: directory.appendingPathComponent("manifest.json"))
    }

    private func relativePath(for url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(rootURL.path.count + 1))
    }

    private func inferredTrackRole(for url: URL) -> AudioTrackRole {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("system") { return .system }
        if name.contains("mixed") { return .mixed }
        return .microphone
    }

    private func assessRecoveryTrack(_ track: WorkspaceAudioTrack) -> RecoveryTrackAssessment {
        let sourceURL = rootURL.appendingPathComponent(track.relativePath).standardizedFileURL
        do {
            let resolvedURL = try safeURL(forRelativePath: track.relativePath)
            return RecoveryTrackValidator().assess(track, sourceURL: sourceURL, resolvedURL: resolvedURL)
        } catch {
            return RecoveryTrackAssessment(
                track: track,
                isValid: false,
                failureReason: error.localizedDescription
            )
        }
    }

    private func uniqueDestination(in directory: URL, prefix: String, pathExtension: String) -> URL {
        while true {
            let candidate = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func recordAudioPaths(_ record: WorkspaceRecord) -> [String] {
        Array(Set([record.audioRelativePath].compactMap { $0 } + record.audioTracks.map(\.relativePath)))
    }

    private func removeOwnedRecordAudioIfPresent(relativePath: String, recordID: UUID) {
        guard let url = try? safeURL(forRelativePath: relativePath) else { return }
        let ownedDirectory = audioURL
            .appendingPathComponent("Records", isDirectory: true)
            .appendingPathComponent(recordID.uuidString, isDirectory: true)
            .standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(ownedDirectory) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func reconcileRecordAudio(using records: [WorkspaceRecord]) throws {
        let recordsDirectory = audioURL.appendingPathComponent("Records", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordsDirectory.path) else { return }
        let ownedIDs = Set(records.map { $0.id.uuidString })
        let children = try FileManager.default.contentsOfDirectory(
            at: recordsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let isDirectory = try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if isDirectory,
               UUID(uuidString: child.lastPathComponent) != nil,
               !ownedIDs.contains(child.lastPathComponent) {
                try? FileManager.default.removeItem(at: child)
            } else if isDirectory,
                      let record = records.first(where: { $0.id.uuidString == child.lastPathComponent }) {
                let referenced = Set(recordAudioPaths(record))
                let files = try FileManager.default.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                for file in files where !referenced.contains(relativePath(for: file)) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private func reconcileRecoveryAudio(using records: [WorkspaceRecord]) throws {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        let directories = try FileManager.default.contentsOfDirectory(
            at: recoveryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let manifest = try? readRecoveryManifest(directory: directory) else { continue }
            if manifest.status == .committed || manifest.status == .purging || records.contains(where: { $0.recoverySourceID == manifest.id }) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let ownedRecoveryIDs = Set(records.compactMap(\.recoverySourceID))
        for capture in try recoverableCaptures() where ownedRecoveryIDs.contains(capture.id) {
            try? removeRecoveryArtifacts(id: capture.id, tracks: capture.tracks)
        }
    }

    private func removeRecoveryArtifacts(id: UUID, tracks: [WorkspaceAudioTrack]) throws {
        let recoveryRoot = recoveryURL.standardizedFileURL.path + "/"
        for track in tracks {
            let source = try safeURL(forRelativePath: track.relativePath)
            guard source.standardizedFileURL.path.hasPrefix(recoveryRoot) else { continue }
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        }
        let directory = recoveryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writePrivate(
        _ data: Data,
        to url: URL,
        point: LibraryStoreWritePoint? = nil
    ) throws {
        if let point, failNextWritesAt.remove(point) != nil {
            throw POSIXError(.EIO)
        }
        try data.write(to: url, options: .atomic)
        try makePrivate(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func makePrivate(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func synchronizeFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func preserveCorruptFile(_ url: URL) throws -> URL {
        let directory = rootURL.appendingPathComponent("Corrupt", isDirectory: true)
        try createPrivateDirectory(directory)
        let backup = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: url, to: backup)
        try makePrivate(backup)
        return backup
    }

    private func preserveCorruptCanonicalFile(_ url: URL, expectedData: Data) throws -> URL {
        let directory = rootURL.appendingPathComponent("Corrupt", isDirectory: true)
        try createPrivateDirectory(directory)
        let destination = uniqueDestination(
            in: directory,
            prefix: url.deletingPathExtension().lastPathComponent,
            pathExtension: url.pathExtension.isEmpty ? "data" : url.pathExtension
        )
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            try makePrivate(destination)
            try synchronizeFile(at: destination)
            let preservedData = try Data(contentsOf: destination)
            guard preservedData == expectedData else { throw POSIXError(.EIO) }
            let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
            guard let permissions, permissions.intValue & 0o077 == 0 else { throw POSIXError(.EPERM) }
            try synchronizeDirectory(at: directory)
            try synchronizeDirectory(at: rootURL)
            return destination
        } catch {
            if FileManager.default.fileExists(atPath: destination.path),
               !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.moveItem(at: destination, to: url)
            }
            throw error
        }
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
