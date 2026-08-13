import Darwin
import Foundation

public struct MCPRegistrationCleanupFailure: Equatable, Sendable {
    public let configurationURL: URL
    public let message: String

    public init(configurationURL: URL, message: String) {
        self.configurationURL = configurationURL
        self.message = message
    }
}

public struct MCPRevocationOutcome: Equatable, Sendable {
    public let authorizationDisabled: Bool
    public let removals: [MCPRemovalResult]
    public let cleanupWarnings: [MCPRegistrationCleanupFailure]
    public let cleanupFailures: [MCPRegistrationCleanupFailure]

    public init(
        authorizationDisabled: Bool,
        removals: [MCPRemovalResult],
        cleanupWarnings: [MCPRegistrationCleanupFailure],
        cleanupFailures: [MCPRegistrationCleanupFailure]
    ) {
        self.authorizationDisabled = authorizationDisabled
        self.removals = removals
        self.cleanupWarnings = cleanupWarnings
        self.cleanupFailures = cleanupFailures
    }
}

public typealias MCPRecoveryOutcome = MCPRevocationOutcome

public enum MCPRegistrationDisposition: String, Equatable, Sendable {
    case unregistered
    case ownedCurrent
    case recognizedLegacy
    case ambiguous
}

public struct MCPClientRegistrationInspection: Identifiable, Equatable, Sendable {
    public var id: String { client.id }
    public let client: MCPClientConfiguration
    public let disposition: MCPRegistrationDisposition

    public init(client: MCPClientConfiguration, disposition: MCPRegistrationDisposition) {
        self.client = client
        self.disposition = disposition
    }
}

public enum MCPOwnedRegistrationError: LocalizedError, Sendable {
    case manifestAlreadyExists(URL)
    case invalidManifest(URL)
    case unsafeConfiguration(URL)
    case conflict(URL)
    case legacyEntryNotRecognized(URL)
    case legacyRegistrationSelectionRequired([URL])
    case recoveryRequired([String])
    case rollbackFailed(primary: String, failures: [String])

    public var errorDescription: String? {
        switch self {
        case .manifestAlreadyExists:
            return "Local helper access already has an owned registration record. Revoke it before enabling again."
        case .invalidManifest:
            return "The local helper registration record is invalid, so no client configuration was changed."
        case .unsafeConfiguration:
            return "A selected client configuration no longer resolves to its validated local target."
        case .conflict:
            return "The Evee-owned client entry has a cleanup conflict. It was left unchanged and needs manual cleanup."
        case .legacyEntryNotRecognized:
            return "The existing Evee client entry is manual or ambiguous. Review it in the client configuration before enabling local helper access."
        case .legacyRegistrationSelectionRequired(let urls):
            return "Local helper access remains disabled until every existing Evee registration is explicitly adopted or removed: \(urls.map(\.path).joined(separator: "; "))"
        case .recoveryRequired(let failures):
            return "An unfinished local helper transaction needs manual cleanup: \(failures.joined(separator: "; "))"
        case .rollbackFailed(let primary, let failures):
            return "Registration failed: \(primary) Rollback also failed: \(failures.joined(separator: "; "))"
        }
    }
}

public final class MCPAuthorizationLease: @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var released = false

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

    public func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        released = true
    }

    deinit { release() }
}

public enum MCPAuthorization {
    public static func lockURL(storageRootURL: URL) -> URL {
        storageRootURL.appendingPathComponent("local-helper-authorization.lock")
    }

    public static func sharedLease(storageRootURL: URL) throws -> MCPAuthorizationLease {
        try lease(storageRootURL: storageRootURL, operation: LOCK_SH)
    }

    public static func exclusiveLease(storageRootURL: URL) throws -> MCPAuthorizationLease {
        try lease(storageRootURL: storageRootURL, operation: LOCK_EX)
    }

    private static func lease(storageRootURL: URL, operation: Int32) throws -> MCPAuthorizationLease {
        try FileManager.default.createDirectory(
            at: storageRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(lockURL(storageRootURL: storageRootURL).path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        guard flock(descriptor, operation) == 0 else {
            let error = posixError()
            _ = close(descriptor)
            throw error
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let error = posixError()
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw error
        }
        return MCPAuthorizationLease(descriptor: descriptor)
    }
}

@_spi(Testing)
public enum MCPRegistrationCheckpoint: String, Sendable {
    case transactionLeaseAcquired
    case beforeTargetMutation
    case afterMutationIntent
    case afterDirectoryCreationBeforeIdentity
    case afterAbsentTargetCreation
    case beforeTargetWrite
    case duringExistingTargetWrite
    case afterTargetWriteBeforeBindingCheck
    case beforeRetainedFileRewrite
    case afterRevokeJournal
    case afterDisabledSettingsPersistence
    case afterFirstClientMutation
    case beforeManifestWrite
    case beforeDirectoryCleanup
}

@_spi(Testing)
public enum MCPRegistrationInjectedCrash: Error, Equatable, Sendable {
    case checkpoint(MCPRegistrationCheckpoint)
}

@_spi(Testing)
public struct MCPRegistrationTesting: Sendable {
    public var beforeRestore: @Sendable (URL) throws -> Void
    public var checkpoint: @Sendable (MCPRegistrationCheckpoint, URL?) throws -> Void
    public var crashAt: MCPRegistrationCheckpoint?

    public init(beforeRestore: @escaping @Sendable (URL) throws -> Void) {
        self.beforeRestore = beforeRestore
        self.checkpoint = { _, _ in }
        self.crashAt = nil
    }

    public init(checkpoint: @escaping @Sendable (MCPRegistrationCheckpoint, URL?) throws -> Void) {
        self.beforeRestore = { _ in }
        self.checkpoint = checkpoint
        self.crashAt = nil
    }

    public init(crashAt: MCPRegistrationCheckpoint) {
        self.beforeRestore = { _ in }
        self.checkpoint = { _, _ in }
        self.crashAt = crashAt
    }

    fileprivate func hit(_ value: MCPRegistrationCheckpoint, url: URL? = nil) throws {
        try checkpoint(value, url)
        if crashAt == value { throw MCPRegistrationInjectedCrash.checkpoint(value) }
    }
}

public enum MCPOwnedRegistration {
    private static let manifestName = "local-helper-registrations.json"
    private static let journalName = "local-helper-transaction.json"

    public static func manifestURL(storageRootURL: URL) -> URL {
        storageRootURL.appendingPathComponent(manifestName)
    }

    public static func journalURL(storageRootURL: URL) -> URL {
        storageRootURL.appendingPathComponent(journalName)
    }

    public static func inspectSupportedClients(
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        applicationSupportURL: URL? = nil,
        storageRootURL: URL,
        expectedExecutableURL: URL,
        allowedRootURLs: [URL]
    ) throws -> [MCPClientRegistrationInspection] {
        let lease = try MCPAuthorization.sharedLease(storageRootURL: storageRootURL)
        defer { lease.release() }
        let manifestURL = manifestURL(storageRootURL: storageRootURL)
        let manifest: OwnedRegistrationManifest? = try loadDurableIfPresent(
            OwnedRegistrationManifest.self,
            from: manifestURL
        )
        if let manifest {
            try validate(manifest: manifest, allowedRootURLs: allowedRootURLs, sourceURL: manifestURL)
        }
        return try MCPRegistration.detectedClients(
            fileManager: fileManager,
            homeURL: homeURL,
            applicationSupportURL: applicationSupportURL
        ).map { client in
            let plan = try AnchoredTarget.plan(
                selectedURL: client.configurationURL,
                allowedRootURLs: allowedRootURLs,
                executableURL: expectedExecutableURL.standardizedFileURL
            )
            return MCPClientRegistrationInspection(
                client: client,
                disposition: try disposition(
                    snapshot: plan.snapshot,
                    manifest: manifest,
                    expectedExecutableURL: expectedExecutableURL.standardizedFileURL
                )
            )
        }
    }

    public static func adoptRecognizedLegacy(
        clients: [MCPClientConfiguration],
        expectedExecutableURL: URL,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        applicationSupportURL: URL? = nil
    ) async throws -> [MCPRegistrationResult] {
        guard !clients.isEmpty else { return [] }
        let executable = expectedExecutableURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw MCPRegistrationError.executableMissing(executable)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPRegistrationError.executableNotRunnable(executable)
        }

        let lease = try MCPAuthorization.exclusiveLease(storageRootURL: storageRootURL)
        defer { lease.release() }
        let recovery = try await recoverLocked(
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            testing: nil
        )
        guard recovery.cleanupFailures.isEmpty else {
            throw MCPOwnedRegistrationError.recoveryRequired(recovery.cleanupFailures.map(\.message))
        }
        let manifestURL = manifestURL(storageRootURL: storageRootURL)
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MCPOwnedRegistrationError.manifestAlreadyExists(manifestURL)
        }
        let blocking = try unselectedExistingRegistrations(
            selectedClients: clients,
            expectedExecutableURL: executable,
            allowedRootURLs: allowedRootURLs,
            fileManager: fileManager,
            homeURL: homeURL,
            applicationSupportURL: applicationSupportURL
        )
        guard blocking.isEmpty else {
            throw MCPOwnedRegistrationError.legacyRegistrationSelectionRequired(blocking)
        }

        let snapshots = try clients.map { client in
            let plan = try AnchoredTarget.plan(
                selectedURL: client.configurationURL,
                allowedRootURLs: allowedRootURLs,
                executableURL: executable
            )
            guard try disposition(
                snapshot: plan.snapshot,
                manifest: nil,
                expectedExecutableURL: executable
            ) == .recognizedLegacy else {
                throw MCPOwnedRegistrationError.legacyEntryNotRecognized(client.configurationURL)
            }
            return try adoptedSnapshot(from: plan.snapshot)
        }
        guard Set(snapshots.map { $0.rootPath + "/" + $0.targetRelativePath }).count == snapshots.count else {
            throw MCPOwnedRegistrationError.invalidManifest(manifestURL)
        }

        var journal = RegistrationTransactionJournal(
            version: 2,
            operation: .enable,
            phase: .clientsMutated,
            snapshots: snapshots,
            createdDirectories: [],
            requiresManifestLoad: false
        )
        try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
        do {
            try writeDurable(
                OwnedRegistrationManifest(version: 2, snapshots: snapshots, createdDirectories: []),
                to: manifestURL
            )
            journal.phase = .manifestDurable
            try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
            var enabled = settings
            enabled.mcpEnabled = true
            try await saveSettings(enabled)
            journal.phase = .committed
            try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
            try removeDurable(journalURL(storageRootURL: storageRootURL))
            return clients.map {
                MCPRegistrationResult(
                    configurationURL: $0.configurationURL,
                    executableURL: executable,
                    replacedExistingRegistration: true
                )
            }
        } catch {
            let primary = error
            var disabled = settings
            disabled.mcpEnabled = false
            var failures: [String] = []
            do { try await saveSettings(disabled) } catch {
                failures.append("Fail-closed authorization restore: \(error.localizedDescription)")
            }
            let outcome = try reverseLocked(
                journal: journal,
                allowedRootURLs: allowedRootURLs,
                storageRootURL: storageRootURL,
                testing: nil
            )
            failures.append(contentsOf: outcome.cleanupFailures.map { "\($0.configurationURL.path): \($0.message)" })
            guard !failures.isEmpty else { throw primary }
            throw MCPOwnedRegistrationError.rollbackFailed(
                primary: primary.localizedDescription,
                failures: failures
            )
        }
    }

    public static func removeRecognizedLegacy(
        clients: [MCPClientConfiguration],
        expectedExecutableURL: URL,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void
    ) async throws -> MCPRevocationOutcome {
        guard !clients.isEmpty else {
            return MCPRevocationOutcome(
                authorizationDisabled: !settings.mcpEnabled,
                removals: [],
                cleanupWarnings: [],
                cleanupFailures: []
            )
        }
        let executable = expectedExecutableURL.standardizedFileURL
        let lease = try MCPAuthorization.exclusiveLease(storageRootURL: storageRootURL)
        defer { lease.release() }
        let recovery = try await recoverLocked(
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            testing: nil
        )
        guard recovery.cleanupFailures.isEmpty else { return recovery }
        let manifest = manifestURL(storageRootURL: storageRootURL)
        guard !FileManager.default.fileExists(atPath: manifest.path) else {
            throw MCPOwnedRegistrationError.manifestAlreadyExists(manifest)
        }
        let snapshots = try clients.map { client in
            let plan = try AnchoredTarget.plan(
                selectedURL: client.configurationURL,
                allowedRootURLs: allowedRootURLs,
                executableURL: executable
            )
            guard try disposition(
                snapshot: plan.snapshot,
                manifest: nil,
                expectedExecutableURL: executable
            ) == .recognizedLegacy else {
                throw MCPOwnedRegistrationError.legacyEntryNotRecognized(client.configurationURL)
            }
            return try adoptedSnapshot(from: plan.snapshot)
        }
        let journal = RegistrationTransactionJournal(
            version: 2,
            operation: .revoke,
            phase: .prepared,
            snapshots: snapshots,
            createdDirectories: [],
            requiresManifestLoad: false
        )
        let transactionURL = journalURL(storageRootURL: storageRootURL)
        try writeDurable(journal, to: transactionURL)
        var disabled = settings
        disabled.mcpEnabled = false
        do {
            try await saveSettings(disabled)
        } catch {
            let primary = error
            try? removeDurable(transactionURL)
            throw primary
        }
        return try reverseLocked(
            journal: journal,
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            testing: nil
        )
    }

    private static func disposition(
        snapshot: ManagedTargetSnapshot,
        manifest: OwnedRegistrationManifest?,
        expectedExecutableURL: URL
    ) throws -> MCPRegistrationDisposition {
        if let owned = manifest?.snapshots.first(where: {
            $0.rootPath == snapshot.rootPath && $0.targetRelativePath == snapshot.targetRelativePath
        }), snapshot.beforeOwned == owned.afterOwned {
            return .ownedCurrent
        }
        guard let currentOwned = snapshot.beforeOwned else { return .unregistered }
        return try ConfigurationImage.isRecognizedLegacyOwned(
            format: snapshot.format,
            owned: currentOwned,
            executableURL: expectedExecutableURL
        ) ? .recognizedLegacy : .ambiguous
    }

    private static func adoptedSnapshot(from source: ManagedTargetSnapshot) throws -> ManagedTargetSnapshot {
        guard let currentData = source.beforeData, let currentOwned = source.beforeOwned else {
            throw MCPOwnedRegistrationError.legacyEntryNotRecognized(source.selectedURL)
        }
        var snapshot = source
        snapshot.beforeData = try ConfigurationImage.reversingOwned(
            format: source.format,
            currentData: currentData,
            beforeOwned: nil,
            sourceURL: source.selectedURL
        )
        snapshot.beforeOwned = nil
        snapshot.afterData = currentData
        snapshot.afterOwned = currentOwned
        snapshot.mutationApplied = true
        snapshot.mutationState = .complete
        snapshot.registeredIdentity = source.originalIdentity
        return snapshot
    }

    private static func unselectedExistingRegistrations(
        selectedClients: [MCPClientConfiguration],
        expectedExecutableURL: URL,
        allowedRootURLs: [URL],
        fileManager: FileManager,
        homeURL: URL?,
        applicationSupportURL: URL?
    ) throws -> [URL] {
        let selectedURLs = Set(selectedClients.map { $0.configurationURL.standardizedFileURL.path })
        return try MCPRegistration.detectedClients(
            fileManager: fileManager,
            homeURL: homeURL,
            applicationSupportURL: applicationSupportURL
        ).compactMap { client in
            guard !selectedURLs.contains(client.configurationURL.standardizedFileURL.path) else { return nil }
            let clientPath = client.configurationURL.standardizedFileURL.path
            guard allowedRootURLs.contains(where: { root in
                let rootPath = root.standardizedFileURL.path
                return clientPath == rootPath || clientPath.hasPrefix(rootPath + "/")
            }) else {
                return nil
            }
            let plan = try AnchoredTarget.plan(
                selectedURL: client.configurationURL,
                allowedRootURLs: allowedRootURLs,
                executableURL: expectedExecutableURL
            )
            switch try disposition(
                snapshot: plan.snapshot,
                manifest: nil,
                expectedExecutableURL: expectedExecutableURL
            ) {
            case .recognizedLegacy, .ambiguous:
                return client.configurationURL
            case .unregistered, .ownedCurrent:
                return nil
            }
        }.sorted { $0.path < $1.path }
    }

    public static func enable(
        clients: [MCPClientConfiguration],
        executableURL: URL,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        applicationSupportURL: URL? = nil
    ) async throws -> [MCPRegistrationResult] {
        try await enableImpl(
            clients: clients,
            executableURL: executableURL,
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            fileManager: fileManager,
            homeURL: homeURL,
            applicationSupportURL: applicationSupportURL,
            testing: nil
        )
    }

    @_spi(Testing)
    public static func enable(
        clients: [MCPClientConfiguration],
        executableURL: URL,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        applicationSupportURL: URL? = nil,
        testing: MCPRegistrationTesting
    ) async throws -> [MCPRegistrationResult] {
        try await enableImpl(
            clients: clients,
            executableURL: executableURL,
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            fileManager: fileManager,
            homeURL: homeURL,
            applicationSupportURL: applicationSupportURL,
            testing: testing
        )
    }

    public static func revoke(
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void
    ) async throws -> MCPRevocationOutcome {
        try await revokeImpl(
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            testing: nil
        )
    }

    @_spi(Testing)
    public static func revoke(
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        testing: MCPRegistrationTesting
    ) async throws -> MCPRevocationOutcome {
        try await revokeImpl(
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            testing: testing
        )
    }

    public static func recover(
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void
    ) async throws -> MCPRecoveryOutcome {
        let lease = try MCPAuthorization.exclusiveLease(storageRootURL: storageRootURL)
        defer { lease.release() }
        return try await recoverLocked(
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            testing: nil
        )
    }

    private static func enableImpl(
        clients: [MCPClientConfiguration],
        executableURL: URL,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        fileManager: FileManager,
        homeURL: URL?,
        applicationSupportURL: URL?,
        testing: MCPRegistrationTesting?
    ) async throws -> [MCPRegistrationResult] {
        guard !clients.isEmpty else { return [] }
        let executable = executableURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw MCPRegistrationError.executableMissing(executable)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPRegistrationError.executableNotRunnable(executable)
        }

        let lease = try MCPAuthorization.exclusiveLease(storageRootURL: storageRootURL)
        defer { lease.release() }
        try testing?.hit(.transactionLeaseAcquired)

        let recovery = try await recoverLocked(
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            testing: testing
        )
        guard recovery.cleanupFailures.isEmpty else {
            throw MCPOwnedRegistrationError.recoveryRequired(recovery.cleanupFailures.map(\.message))
        }
        let manifestURL = manifestURL(storageRootURL: storageRootURL)
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MCPOwnedRegistrationError.manifestAlreadyExists(manifestURL)
        }
        let blocking = try unselectedExistingRegistrations(
            selectedClients: clients,
            expectedExecutableURL: executable,
            allowedRootURLs: allowedRootURLs,
            fileManager: fileManager,
            homeURL: homeURL,
            applicationSupportURL: applicationSupportURL
        )
        guard blocking.isEmpty else {
            throw MCPOwnedRegistrationError.legacyRegistrationSelectionRequired(blocking)
        }

        var handles: [AnchoredTarget] = []
        var snapshots: [ManagedTargetSnapshot] = []
        for client in clients {
            let plan = try AnchoredTarget.plan(
                selectedURL: client.configurationURL,
                allowedRootURLs: allowedRootURLs,
                executableURL: executable
            )
            guard plan.snapshot.beforeOwned == nil else {
                throw MCPOwnedRegistrationError.legacyEntryNotRecognized(client.configurationURL)
            }
            handles.append(plan.handle)
            snapshots.append(plan.snapshot)
        }
        guard Set(snapshots.map { $0.rootPath + "/" + $0.targetRelativePath }).count == snapshots.count else {
            throw MCPOwnedRegistrationError.invalidManifest(manifestURL)
        }

        let plannedDirectories = handles.flatMap(\.plannedCreatedDirectories).reduce(into: [CreatedDirectoryRecord]()) { result, record in
            if !result.contains(where: { $0.rootPath == record.rootPath && $0.relativePath == record.relativePath }) {
                result.append(record)
            }
        }
        var journal = RegistrationTransactionJournal(
            version: 2,
            operation: .enable,
            phase: .prepared,
            snapshots: snapshots,
            createdDirectories: plannedDirectories,
            requiresManifestLoad: false
        )
        try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))

        do {
            for index in handles.indices {
                try handles[index].prepareMissingDirectories(
                    beforeCreate: { record in
                        if let existing = journal.createdDirectories.firstIndex(where: {
                            $0.rootPath == record.rootPath && $0.relativePath == record.relativePath
                        }) {
                            journal.createdDirectories[existing] = record
                        } else {
                            journal.createdDirectories.append(record)
                        }
                        try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
                    },
                    afterCreate: { record in
                        if let existing = journal.createdDirectories.firstIndex(where: {
                            $0.rootPath == record.rootPath && $0.relativePath == record.relativePath
                        }) {
                            journal.createdDirectories[existing] = record
                        } else {
                            journal.createdDirectories.append(record)
                        }
                        try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
                    },
                    testing: testing
                )
                snapshots[index].parentIdentities = handles[index].parentIdentities
                journal.snapshots = snapshots
                try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))

                try testing?.hit(.beforeTargetMutation, url: snapshots[index].selectedURL)
                try handles[index].verifyCurrentBinding(snapshot: snapshots[index])
                snapshots[index].mutationState = .intent
                journal.snapshots = snapshots
                try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
                try testing?.hit(.afterMutationIntent, url: snapshots[index].selectedURL)
                try handles[index].prepareTarget(snapshot: &snapshots[index])
                journal.snapshots = snapshots
                try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
                if !snapshots[index].existed {
                    try testing?.hit(.afterAbsentTargetCreation, url: snapshots[index].selectedURL)
                }
                try testing?.hit(.beforeTargetWrite, url: snapshots[index].selectedURL)
                try handles[index].writeRegistration(snapshot: &snapshots[index], testing: testing)
                snapshots[index].mutationState = .complete
                journal.snapshots = snapshots
                journal.phase = .clientsMutated
                try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
                if index == handles.startIndex {
                    try testing?.hit(.afterFirstClientMutation, url: snapshots[index].selectedURL)
                }
            }
            try testing?.hit(.beforeManifestWrite)
            let manifest = OwnedRegistrationManifest(
                version: 2,
                snapshots: snapshots,
                createdDirectories: journal.createdDirectories
            )
            try writeDurable(manifest, to: manifestURL)
            journal.phase = .manifestDurable
            journal.snapshots = snapshots
            try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))

            var enabled = settings
            enabled.mcpEnabled = true
            try await saveSettings(enabled)
            journal.phase = .committed
            try writeDurable(journal, to: journalURL(storageRootURL: storageRootURL))
            try removeDurable(journalURL(storageRootURL: storageRootURL))
            return zip(clients, snapshots).map { client, snapshot in
                MCPRegistrationResult(
                    configurationURL: client.configurationURL,
                    executableURL: executable,
                    replacedExistingRegistration: snapshot.beforeOwned != nil
                )
            }
        } catch let crash as MCPRegistrationInjectedCrash {
            throw crash
        } catch {
            let primary = error
            var disabled = settings
            disabled.mcpEnabled = false
            var failures: [String] = []
            do { try await saveSettings(disabled) } catch {
                failures.append("Fail-closed authorization restore: \(error.localizedDescription)")
            }
            let outcome = try await recoverLocked(
                allowedRootURLs: allowedRootURLs,
                storageRootURL: storageRootURL,
                settings: disabled,
                saveSettings: saveSettings,
                testing: testing
            )
            failures.append(contentsOf: outcome.cleanupFailures.map { "\($0.configurationURL.path): \($0.message)" })
            guard !failures.isEmpty else { throw primary }
            throw MCPOwnedRegistrationError.rollbackFailed(primary: primary.localizedDescription, failures: failures)
        }
    }

    private static func revokeImpl(
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        testing: MCPRegistrationTesting?
    ) async throws -> MCPRevocationOutcome {
        let lease = try MCPAuthorization.exclusiveLease(storageRootURL: storageRootURL)
        defer { lease.release() }
        try testing?.hit(.transactionLeaseAcquired)

        let recovery: MCPRecoveryOutcome
        do {
            recovery = try await recoverLocked(
                allowedRootURLs: allowedRootURLs,
                storageRootURL: storageRootURL,
                settings: settings,
                saveSettings: saveSettings,
                testing: testing
            )
        } catch {
            return MCPRevocationOutcome(
                authorizationDisabled: false,
                removals: [],
                cleanupWarnings: [],
                cleanupFailures: [MCPRegistrationCleanupFailure(
                    configurationURL: journalURL(storageRootURL: storageRootURL),
                    message: error.localizedDescription
                )]
            )
        }
        guard recovery.cleanupFailures.isEmpty else { return recovery }
        let recoveryWarnings = recovery.cleanupWarnings

        let manifestURL = manifestURL(storageRootURL: storageRootURL)
        let transactionURL = journalURL(storageRootURL: storageRootURL)
        let authorizationBarrier = RegistrationTransactionJournal(
            version: 2,
            operation: .revoke,
            phase: .prepared,
            snapshots: [],
            createdDirectories: [],
            requiresManifestLoad: true
        )
        try writeDurable(authorizationBarrier, to: transactionURL)
        try testing?.hit(.afterRevokeJournal)

        let manifestResult: Result<OwnedRegistrationManifest?, Error>
        do {
            let loaded: OwnedRegistrationManifest? = try loadDurableIfPresent(
                OwnedRegistrationManifest.self,
                from: manifestURL
            )
            if let loaded {
                try validate(manifest: loaded, allowedRootURLs: allowedRootURLs, sourceURL: manifestURL)
            }
            manifestResult = .success(loaded)
        } catch {
            manifestResult = .failure(error)
        }

        var disabled = settings
        disabled.mcpEnabled = false
        do {
            try await saveSettings(disabled)
        } catch {
            let primary = error
            do {
                try removeDurable(transactionURL)
            } catch {
                throw MCPOwnedRegistrationError.rollbackFailed(
                    primary: primary.localizedDescription,
                    failures: ["Fail-closed revoke journal cleanup: \(error.localizedDescription)"]
                )
            }
            throw primary
        }
        try testing?.hit(.afterDisabledSettingsPersistence)

        let manifest: OwnedRegistrationManifest
        switch manifestResult {
        case .failure(let error):
            return MCPRevocationOutcome(
                authorizationDisabled: true,
                removals: recovery.removals,
                cleanupWarnings: recoveryWarnings,
                cleanupFailures: [MCPRegistrationCleanupFailure(
                    configurationURL: manifestURL,
                    message: error.localizedDescription
                )]
            )
        case .success(nil):
            do {
                try removeDurable(transactionURL)
                return MCPRevocationOutcome(
                    authorizationDisabled: true,
                    removals: recovery.removals,
                    cleanupWarnings: recoveryWarnings,
                    cleanupFailures: []
                )
            } catch {
                return MCPRevocationOutcome(
                    authorizationDisabled: true,
                    removals: recovery.removals,
                    cleanupWarnings: recoveryWarnings,
                    cleanupFailures: [MCPRegistrationCleanupFailure(
                        configurationURL: transactionURL,
                        message: error.localizedDescription
                    )]
                )
            }
        case .success(.some(let loaded)):
            manifest = loaded
        }

        let journal = RegistrationTransactionJournal(
            version: 2,
            operation: .revoke,
            phase: .prepared,
            snapshots: manifest.snapshots,
            createdDirectories: manifest.createdDirectories,
            requiresManifestLoad: false
        )
        do {
            try writeDurable(journal, to: transactionURL)
        } catch {
            return MCPRevocationOutcome(
                authorizationDisabled: true,
                removals: recovery.removals,
                cleanupWarnings: recoveryWarnings,
                cleanupFailures: [MCPRegistrationCleanupFailure(
                    configurationURL: transactionURL,
                    message: error.localizedDescription
                )]
            )
        }

        do {
            let outcome = try reverseLocked(
                journal: journal,
                allowedRootURLs: allowedRootURLs,
                storageRootURL: storageRootURL,
                testing: testing
            )
            return MCPRevocationOutcome(
                authorizationDisabled: outcome.authorizationDisabled,
                removals: recovery.removals + outcome.removals,
                cleanupWarnings: recoveryWarnings + outcome.cleanupWarnings,
                cleanupFailures: outcome.cleanupFailures
            )
        } catch {
            return MCPRevocationOutcome(
                authorizationDisabled: true,
                removals: [],
                cleanupWarnings: recoveryWarnings,
                cleanupFailures: [MCPRegistrationCleanupFailure(
                    configurationURL: transactionURL,
                    message: error.localizedDescription
                )]
            )
        }
    }

    private static func recoverLocked(
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        testing: MCPRegistrationTesting?
    ) async throws -> MCPRecoveryOutcome {
        let url = journalURL(storageRootURL: storageRootURL)
        guard let journal: RegistrationTransactionJournal = try loadDurableIfPresent(
            RegistrationTransactionJournal.self,
            from: url
        ) else {
            return MCPRecoveryOutcome(
                authorizationDisabled: !settings.mcpEnabled,
                removals: [],
                cleanupWarnings: [],
                cleanupFailures: []
            )
        }
        try validate(journal: journal, allowedRootURLs: allowedRootURLs, sourceURL: url)
        if journal.operation == .enable, journal.phase == .committed {
            try removeDurable(url)
            return MCPRecoveryOutcome(
                authorizationDisabled: !settings.mcpEnabled,
                removals: [],
                cleanupWarnings: [],
                cleanupFailures: []
            )
        }
        var disabled = settings
        disabled.mcpEnabled = false
        do {
            try await saveSettings(disabled)
        } catch {
            return MCPRecoveryOutcome(
                authorizationDisabled: false,
                removals: [],
                cleanupWarnings: [],
                cleanupFailures: [MCPRegistrationCleanupFailure(configurationURL: url, message: error.localizedDescription)]
            )
        }
        if journal.operation == .revoke, journal.requiresManifestLoad == true {
            let manifestURL = manifestURL(storageRootURL: storageRootURL)
            let manifest: OwnedRegistrationManifest?
            do {
                manifest = try loadDurableIfPresent(OwnedRegistrationManifest.self, from: manifestURL)
                if let manifest {
                    try validate(manifest: manifest, allowedRootURLs: allowedRootURLs, sourceURL: manifestURL)
                }
            } catch {
                return MCPRecoveryOutcome(
                    authorizationDisabled: true,
                    removals: [],
                    cleanupWarnings: [],
                    cleanupFailures: [MCPRegistrationCleanupFailure(
                        configurationURL: manifestURL,
                        message: error.localizedDescription
                    )]
                )
            }
            guard let manifest else {
                do {
                    try removeDurable(url)
                    return MCPRecoveryOutcome(
                        authorizationDisabled: true,
                        removals: [],
                        cleanupWarnings: [],
                        cleanupFailures: []
                    )
                } catch {
                    return MCPRecoveryOutcome(
                        authorizationDisabled: true,
                        removals: [],
                        cleanupWarnings: [],
                        cleanupFailures: [MCPRegistrationCleanupFailure(
                            configurationURL: url,
                            message: error.localizedDescription
                        )]
                    )
                }
            }
            let cleanupJournal = RegistrationTransactionJournal(
                version: 2,
                operation: .revoke,
                phase: .prepared,
                snapshots: manifest.snapshots,
                createdDirectories: manifest.createdDirectories,
                requiresManifestLoad: false
            )
            do {
                try writeDurable(cleanupJournal, to: url)
            } catch {
                return MCPRecoveryOutcome(
                    authorizationDisabled: true,
                    removals: [],
                    cleanupWarnings: [],
                    cleanupFailures: [MCPRegistrationCleanupFailure(
                        configurationURL: url,
                        message: error.localizedDescription
                    )]
                )
            }
            return try reverseLocked(
                journal: cleanupJournal,
                allowedRootURLs: allowedRootURLs,
                storageRootURL: storageRootURL,
                testing: testing
            )
        }
        return try reverseLocked(
            journal: journal,
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            testing: testing
        )
    }

    private static func reverseLocked(
        journal: RegistrationTransactionJournal,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        testing: MCPRegistrationTesting?
    ) throws -> MCPRevocationOutcome {
        var removals: [MCPRemovalResult] = []
        var warnings: [MCPRegistrationCleanupFailure] = []
        var failures: [MCPRegistrationCleanupFailure] = []
        for snapshot in journal.snapshots.reversed() where snapshot.effectiveMutationState != .planned {
            do {
                try testing?.beforeRestore(snapshot.selectedURL)
                if !snapshot.existed,
                   try AnchoredTarget.targetIsAbsent(snapshot: snapshot, allowedRootURLs: allowedRootURLs) {
                    continue
                }
                let handle = try AnchoredTarget.reopen(snapshot: snapshot, allowedRootURLs: allowedRootURLs)
                let result = try handle.reverse(snapshot: snapshot, testing: testing)
                if result.removedRegistration {
                    removals.append(MCPRemovalResult(configurationURL: snapshot.selectedURL, removedRegistration: true))
                }
                if let warning = result.warning { warnings.append(warning) }
            } catch {
                failures.append(MCPRegistrationCleanupFailure(
                    configurationURL: snapshot.selectedURL,
                    message: error.localizedDescription
                ))
            }
        }
        if failures.isEmpty {
            for directory in journal.createdDirectories.reversed() {
                do {
                    try testing?.hit(.beforeDirectoryCleanup, url: directory.url)
                    if let warning = try inspectCreatedDirectory(
                        directory,
                        allowedRootURLs: allowedRootURLs
                    ) {
                        warnings.append(warning)
                    }
                } catch {
                    failures.append(MCPRegistrationCleanupFailure(
                        configurationURL: directory.url,
                        message: error.localizedDescription
                    ))
                }
            }
        }
        guard failures.isEmpty else {
            return MCPRevocationOutcome(
                authorizationDisabled: true,
                removals: removals.reversed(),
                cleanupWarnings: warnings,
                cleanupFailures: failures
            )
        }
        let manifest = manifestURL(storageRootURL: storageRootURL)
        if FileManager.default.fileExists(atPath: manifest.path) {
            do { try removeDurable(manifest) } catch {
                return MCPRevocationOutcome(
                    authorizationDisabled: true,
                    removals: removals.reversed(),
                    cleanupWarnings: warnings,
                    cleanupFailures: [MCPRegistrationCleanupFailure(configurationURL: manifest, message: error.localizedDescription)]
                )
            }
        }
        let journalURL = journalURL(storageRootURL: storageRootURL)
        do { try removeDurable(journalURL) } catch {
            return MCPRevocationOutcome(
                authorizationDisabled: true,
                removals: removals.reversed(),
                cleanupWarnings: warnings,
                cleanupFailures: [MCPRegistrationCleanupFailure(configurationURL: journalURL, message: error.localizedDescription)]
            )
        }
        return MCPRevocationOutcome(
            authorizationDisabled: true,
            removals: removals.reversed(),
            cleanupWarnings: warnings,
            cleanupFailures: []
        )
    }

    private static func validate(
        manifest: OwnedRegistrationManifest,
        allowedRootURLs: [URL],
        sourceURL: URL
    ) throws {
        guard manifest.version == 2 else { throw MCPOwnedRegistrationError.invalidManifest(sourceURL) }
        try validateRecords(
            snapshots: manifest.snapshots,
            directories: manifest.createdDirectories,
            allowedRootURLs: allowedRootURLs,
            sourceURL: sourceURL
        )
    }

    private static func validate(
        journal: RegistrationTransactionJournal,
        allowedRootURLs: [URL],
        sourceURL: URL
    ) throws {
        guard journal.version == 2 else { throw MCPOwnedRegistrationError.invalidManifest(sourceURL) }
        try validateRecords(
            snapshots: journal.snapshots,
            directories: journal.createdDirectories,
            allowedRootURLs: allowedRootURLs,
            sourceURL: sourceURL
        )
    }

    private static func validateRecords(
        snapshots: [ManagedTargetSnapshot],
        directories: [CreatedDirectoryRecord],
        allowedRootURLs: [URL],
        sourceURL: URL
    ) throws {
        let allowed = Set(allowedRootURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        guard snapshots.allSatisfy({ snapshot in
            allowed.contains(snapshot.rootPath)
                && safeRelativePath(snapshot.targetRelativePath)
                && safeRelativePath(snapshot.selectedRelativePath)
        }), Set(snapshots.map { $0.rootPath + "/" + $0.targetRelativePath }).count == snapshots.count,
        directories.allSatisfy({ allowed.contains($0.rootPath) && safeRelativePath($0.relativePath) }) else {
            throw MCPOwnedRegistrationError.invalidManifest(sourceURL)
        }
    }

    private static func inspectCreatedDirectory(
        _ record: CreatedDirectoryRecord,
        allowedRootURLs: [URL]
    ) throws -> MCPRegistrationCleanupFailure? {
        guard allowedRootURLs.map({ $0.resolvingSymlinksInPath().standardizedFileURL.path }).contains(record.rootPath) else {
            throw MCPOwnedRegistrationError.invalidManifest(record.url)
        }
        let traversal = try DirectoryTraversal(rootPath: record.rootPath)
        let planned = try traversal.openDeepestDirectory(relativePath: record.relativePath)
        guard planned.missing.isEmpty else {
            _ = close(planned.descriptor)
            return nil
        }
        defer { _ = close(planned.descriptor) }
        guard record.effectiveState != .planned else { return nil }
        let observedIdentity = try descriptorIdentity(planned.descriptor)
        guard let identity = record.identity else {
            return MCPRegistrationCleanupFailure(
                configurationURL: record.url,
                message: "A directory created during local helper registration was retained for manual cleanup (device \(observedIdentity.deviceID), inode \(observedIdentity.fileID))."
            )
        }
        guard observedIdentity == identity else {
            throw MCPOwnedRegistrationError.rollbackFailed(
                primary: "Created-directory identity conflict.",
                failures: [record.url.path]
            )
        }
        return MCPRegistrationCleanupFailure(
            configurationURL: record.url,
            message: "A directory created during local helper registration was retained for manual cleanup."
        )
    }
}

private enum TransactionOperation: String, Codable { case enable, revoke }
private enum TransactionPhase: String, Codable { case prepared, clientsMutated, manifestDurable, committed }

private struct RegistrationTransactionJournal: Codable {
    var version: Int
    var operation: TransactionOperation
    var phase: TransactionPhase
    var snapshots: [ManagedTargetSnapshot]
    var createdDirectories: [CreatedDirectoryRecord]
    var requiresManifestLoad: Bool?
}

private struct OwnedRegistrationManifest: Codable {
    var version: Int
    var snapshots: [ManagedTargetSnapshot]
    var createdDirectories: [CreatedDirectoryRecord]
}

private struct FileIdentity: Codable, Equatable {
    var deviceID: UInt64
    var fileID: UInt64

    init(_ info: stat) {
        deviceID = UInt64(info.st_dev)
        fileID = UInt64(info.st_ino)
    }
}

private struct ParentIdentity: Codable, Equatable {
    var relativePath: String
    var identity: FileIdentity
}

private struct CreatedDirectoryRecord: Codable {
    var rootPath: String
    var relativePath: String
    var identity: FileIdentity?
    var state: DirectoryMutationState?
    var url: URL { URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath, isDirectory: true) }

    var effectiveState: DirectoryMutationState {
        state ?? (identity == nil ? .planned : .complete)
    }
}

private enum ConfigurationFormat: String, Codable { case json, toml }
private enum TargetMutationState: String, Codable { case planned, intent, complete }
private enum DirectoryMutationState: String, Codable { case planned, intent, complete }

private struct ManagedTargetSnapshot: Codable {
    var clientName: String
    var rootPath: String
    var selectedRelativePath: String
    var targetRelativePath: String
    var symlinkDestination: String?
    var symlinkIdentity: FileIdentity?
    var parentIdentities: [ParentIdentity]
    var format: ConfigurationFormat
    var existed: Bool
    var mutationApplied: Bool
    var mutationState: TargetMutationState?
    var originalIdentity: FileIdentity?
    var registeredIdentity: FileIdentity?
    var beforeData: Data?
    var afterData: Data
    var beforeOwned: Data?
    var afterOwned: Data
    var permissions: UInt16?
    var ownerID: UInt32?
    var groupID: UInt32?
    var accessTimeSeconds: Int64?
    var accessTimeNanoseconds: Int64?
    var modificationTimeSeconds: Int64?
    var modificationTimeNanoseconds: Int64?
    var accessControlList: String?
    var extendedAttributes: [String: Data]

    var selectedURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent(selectedRelativePath)
    }

    var effectiveMutationState: TargetMutationState {
        mutationState ?? (mutationApplied ? .complete : .planned)
    }
}

private struct ReverseResult {
    var removedRegistration: Bool
    var warning: MCPRegistrationCleanupFailure?
}

private final class AnchoredTarget {
    let rootPath: String
    let selectedRelativePath: String
    let targetRelativePath: String
    let traversal: DirectoryTraversal
    var parentDescriptor: Int32
    var targetDescriptor: Int32?
    var parentIdentities: [ParentIdentity]
    private let missingDirectories: [String]
    private let symlinkIdentity: FileIdentity?
    private let symlinkDestination: String?

    var plannedCreatedDirectories: [CreatedDirectoryRecord] {
        var relative = parentIdentities.last?.relativePath ?? ""
        return missingDirectories.map { component in
            relative = relative.isEmpty ? component : relative + "/" + component
            return CreatedDirectoryRecord(rootPath: rootPath, relativePath: relative, identity: nil, state: .planned)
        }
    }

    private init(
        rootPath: String,
        selectedRelativePath: String,
        targetRelativePath: String,
        traversal: DirectoryTraversal,
        parentDescriptor: Int32,
        targetDescriptor: Int32?,
        parentIdentities: [ParentIdentity],
        missingDirectories: [String],
        symlinkIdentity: FileIdentity?,
        symlinkDestination: String?
    ) {
        self.rootPath = rootPath
        self.selectedRelativePath = selectedRelativePath
        self.targetRelativePath = targetRelativePath
        self.traversal = traversal
        self.parentDescriptor = parentDescriptor
        self.targetDescriptor = targetDescriptor
        self.parentIdentities = parentIdentities
        self.missingDirectories = missingDirectories
        self.symlinkIdentity = symlinkIdentity
        self.symlinkDestination = symlinkDestination
    }

    deinit {
        if parentDescriptor >= 0 { _ = close(parentDescriptor) }
        if let targetDescriptor { _ = close(targetDescriptor) }
    }

    static func plan(
        selectedURL: URL,
        allowedRootURLs: [URL],
        executableURL: URL
    ) throws -> (handle: AnchoredTarget, snapshot: ManagedTargetSnapshot) {
        let selected = selectedURL.standardizedFileURL
        let roots = allowedRootURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard let root = roots.first(where: { contains(path: selected.path, root: $0.path) }) else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(selected)
        }
        let selectedRelative = relativePath(selected.path, root: root.path)
        guard safeRelativePath(selectedRelative), let selectedName = pathComponents(selectedRelative).last else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(selected)
        }
        let traversal = try DirectoryTraversal(rootPath: root.path)
        let selectedParentPath = pathComponents(selectedRelative).dropLast().joined(separator: "/")
        let parentPlan = try traversal.openDeepestDirectory(relativePath: selectedParentPath)
        var targetRelative = selectedRelative
        var linkIdentity: FileIdentity?
        var linkDestination: String?
        if parentPlan.missing.isEmpty {
            var linkInfo = stat()
            let linkResult = fstatat(parentPlan.descriptor, selectedName, &linkInfo, AT_SYMLINK_NOFOLLOW)
            if linkResult == 0, linkInfo.st_mode & S_IFMT == S_IFLNK {
                linkIdentity = FileIdentity(linkInfo)
                linkDestination = try readLink(at: parentPlan.descriptor, name: selectedName)
                let targetURL: URL
                if linkDestination!.hasPrefix("/") {
                    targetURL = URL(fileURLWithPath: linkDestination!).standardizedFileURL
                } else {
                    targetURL = selected.deletingLastPathComponent().appendingPathComponent(linkDestination!).standardizedFileURL
                }
                guard contains(path: targetURL.path, root: root.path) else {
                    throw MCPOwnedRegistrationError.unsafeConfiguration(selected)
                }
                targetRelative = relativePath(targetURL.path, root: root.path)
            } else if linkResult != 0, errno != ENOENT {
                throw posixError()
            }
        }

        let targetParts = pathComponents(targetRelative)
        guard let targetName = targetParts.last else { throw MCPOwnedRegistrationError.unsafeConfiguration(selected) }
        let targetParentPath = targetParts.dropLast().joined(separator: "/")
        let targetParentPlan = try traversal.openDeepestDirectory(relativePath: targetParentPath)
        var descriptor: Int32?
        var info = stat()
        var data: Data?
        var metadata = FileMetadata.empty
        if targetParentPlan.missing.isEmpty {
            let fd = openat(targetParentPlan.descriptor, targetName, O_RDWR | O_NOFOLLOW)
            if fd >= 0 {
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                    _ = close(fd)
                    throw MCPOwnedRegistrationError.unsafeConfiguration(selected)
                }
                descriptor = fd
                data = try readAll(fd)
                metadata = try FileMetadata(descriptor: fd, info: info)
            } else if errno != ENOENT {
                throw posixError()
            }
        }
        let format: ConfigurationFormat = selected.pathExtension.lowercased() == "toml" ? .toml : .json
        let image = try ConfigurationImage.make(format: format, before: data, executableURL: executableURL, sourceURL: selected)
        let handle = AnchoredTarget(
            rootPath: root.path,
            selectedRelativePath: selectedRelative,
            targetRelativePath: targetRelative,
            traversal: traversal,
            parentDescriptor: targetParentPlan.descriptor,
            targetDescriptor: descriptor,
            parentIdentities: targetParentPlan.identities,
            missingDirectories: targetParentPlan.missing,
            symlinkIdentity: linkIdentity,
            symlinkDestination: linkDestination
        )
        let snapshot = ManagedTargetSnapshot(
            clientName: selectedURL.lastPathComponent,
            rootPath: root.path,
            selectedRelativePath: selectedRelative,
            targetRelativePath: targetRelative,
            symlinkDestination: linkDestination,
            symlinkIdentity: linkIdentity,
            parentIdentities: targetParentPlan.identities,
            format: format,
            existed: data != nil,
            mutationApplied: false,
            mutationState: .planned,
            originalIdentity: descriptor == nil ? nil : FileIdentity(info),
            registeredIdentity: nil,
            beforeData: data,
            afterData: image.afterData,
            beforeOwned: image.beforeOwned,
            afterOwned: image.afterOwned,
            permissions: metadata.permissions,
            ownerID: metadata.ownerID,
            groupID: metadata.groupID,
            accessTimeSeconds: metadata.accessTimeSeconds,
            accessTimeNanoseconds: metadata.accessTimeNanoseconds,
            modificationTimeSeconds: metadata.modificationTimeSeconds,
            modificationTimeNanoseconds: metadata.modificationTimeNanoseconds,
            accessControlList: metadata.accessControlList,
            extendedAttributes: metadata.extendedAttributes
        )
        return (handle, snapshot)
    }

    static func reopen(snapshot: ManagedTargetSnapshot, allowedRootURLs: [URL]) throws -> AnchoredTarget {
        guard allowedRootURLs.map({ $0.resolvingSymlinksInPath().standardizedFileURL.path }).contains(snapshot.rootPath) else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
        }
        let traversal = try DirectoryTraversal(rootPath: snapshot.rootPath)
        let targetParts = pathComponents(snapshot.targetRelativePath)
        guard let targetName = targetParts.last else { throw MCPOwnedRegistrationError.invalidManifest(snapshot.selectedURL) }
        let parentPath = targetParts.dropLast().joined(separator: "/")
        let parent = try traversal.openDirectory(relativePath: parentPath, verify: snapshot.parentIdentities)
        let fd = openat(parent.descriptor, targetName, O_RDWR | O_NOFOLLOW)
        var descriptor: Int32?
        if fd >= 0 { descriptor = fd } else if errno != ENOENT { _ = close(parent.descriptor); throw posixError() }
        let handle = AnchoredTarget(
            rootPath: snapshot.rootPath,
            selectedRelativePath: snapshot.selectedRelativePath,
            targetRelativePath: snapshot.targetRelativePath,
            traversal: traversal,
            parentDescriptor: parent.descriptor,
            targetDescriptor: descriptor,
            parentIdentities: parent.identities,
            missingDirectories: [],
            symlinkIdentity: snapshot.symlinkIdentity,
            symlinkDestination: snapshot.symlinkDestination
        )
        try handle.verifyCurrentBinding(snapshot: snapshot)
        return handle
    }

    static func targetIsAbsent(
        snapshot: ManagedTargetSnapshot,
        allowedRootURLs: [URL]
    ) throws -> Bool {
        guard allowedRootURLs.map({ $0.resolvingSymlinksInPath().standardizedFileURL.path }).contains(snapshot.rootPath) else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
        }
        let traversal = try DirectoryTraversal(rootPath: snapshot.rootPath)
        let targetParts = pathComponents(snapshot.targetRelativePath)
        guard let targetName = targetParts.last else {
            throw MCPOwnedRegistrationError.invalidManifest(snapshot.selectedURL)
        }
        let parent = try traversal.openDeepestDirectory(
            relativePath: targetParts.dropLast().joined(separator: "/")
        )
        defer { _ = close(parent.descriptor) }
        if !parent.missing.isEmpty { return true }
        var info = stat()
        if fstatat(parent.descriptor, targetName, &info, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        if errno == ENOENT { return true }
        throw posixError()
    }

    func prepareMissingDirectories(
        beforeCreate: (CreatedDirectoryRecord) throws -> Void,
        afterCreate: (CreatedDirectoryRecord) throws -> Void,
        testing: MCPRegistrationTesting?
    ) throws {
        guard !missingDirectories.isEmpty else { return }
        _ = close(parentDescriptor)
        var current = try traversal.duplicateRoot()
        var relative = ""
        var identities: [ParentIdentity] = [ParentIdentity(relativePath: "", identity: try descriptorIdentity(current))]
        let allParentComponents = pathComponents(targetRelativePath).dropLast()
        for component in allParentComponents {
            relative = relative.isEmpty ? component : relative + "/" + component
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0, errno == ENOENT {
                let intent = CreatedDirectoryRecord(
                    rootPath: rootPath,
                    relativePath: relative,
                    identity: nil,
                    state: .intent
                )
                try beforeCreate(intent)
                guard mkdirat(current, component, 0o700) == 0, fsync(current) == 0 else { _ = close(current); throw posixError() }
                try testing?.hit(.afterDirectoryCreationBeforeIdentity, url: intent.url)
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { _ = close(current); throw posixError() }
                let identity = try descriptorIdentity(next)
                try afterCreate(CreatedDirectoryRecord(
                    rootPath: rootPath,
                    relativePath: relative,
                    identity: identity,
                    state: .complete
                ))
            } else if next < 0 {
                _ = close(current)
                throw posixError()
            }
            _ = close(current)
            current = next
            identities.append(ParentIdentity(relativePath: relative, identity: try descriptorIdentity(current)))
        }
        parentDescriptor = current
        parentIdentities = identities
    }

    func verifyCurrentBinding(snapshot: ManagedTargetSnapshot) throws {
        if let expectedLink = snapshot.symlinkIdentity {
            let selectedParts = pathComponents(snapshot.selectedRelativePath)
            guard let name = selectedParts.last else { throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL) }
            let parentPath = selectedParts.dropLast().joined(separator: "/")
            let parent = try traversal.openDirectory(relativePath: parentPath, verify: nil)
            defer { _ = close(parent.descriptor) }
            var info = stat()
            guard fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFLNK,
                  FileIdentity(info) == expectedLink,
                  try readLink(at: parent.descriptor, name: name) == snapshot.symlinkDestination else {
                throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
            }
        }
        _ = try traversal.openDirectory(relativePath: pathComponents(snapshot.targetRelativePath).dropLast().joined(separator: "/"), verify: snapshot.parentIdentities, closeResult: true)
        if let fd = targetDescriptor {
            let identity = try descriptorIdentity(fd)
            let expected = snapshot.mutationApplied ? snapshot.registeredIdentity : snapshot.originalIdentity
            if let expected, identity != expected {
                throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
            }
            try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expected)
        }
    }

    func writeRegistration(
        snapshot: inout ManagedTargetSnapshot,
        testing: MCPRegistrationTesting?
    ) throws {
        guard let fd = targetDescriptor else { throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL) }
        try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: snapshot.registeredIdentity)
        if snapshot.existed, let testing {
            try writeWithPartialCheckpoint(
                snapshot.afterData,
                descriptor: fd,
                url: snapshot.selectedURL,
                testing: testing
            )
        } else {
            try writeAll(snapshot.afterData, descriptor: fd)
        }
        guard fchmod(fd, 0o600) == 0 else { throw posixError("fchmod client") }
        guard fsync(fd) == 0 else { throw posixError("fsync client") }
        try testing?.hit(.afterTargetWriteBeforeBindingCheck, url: snapshot.selectedURL)
        do {
            try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: snapshot.registeredIdentity)
        } catch {
            if let beforeData = snapshot.beforeData {
                try writeAll(beforeData, descriptor: fd)
                try restoreMetadata(snapshot: snapshot, descriptor: fd)
            } else {
                guard ftruncate(fd, 0) == 0 else { throw posixError("restore created client") }
            }
            guard fsync(fd) == 0, fsync(parentDescriptor) == 0 else { throw posixError("restore client") }
            throw MCPOwnedRegistrationError.conflict(snapshot.selectedURL)
        }
        guard fsync(parentDescriptor) == 0 else { throw posixError("fsync client directory") }
        snapshot.registeredIdentity = try descriptorIdentity(fd)
        if snapshot.existed, snapshot.registeredIdentity != snapshot.originalIdentity {
            throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
        }
    }

    func prepareTarget(snapshot: inout ManagedTargetSnapshot) throws {
        if targetDescriptor == nil {
            let targetName = pathComponents(targetRelativePath).last!
            let fd = openat(parentDescriptor, targetName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw posixError() }
            targetDescriptor = fd
            guard fsync(fd) == 0, fsync(parentDescriptor) == 0 else { throw posixError() }
        }
        guard let fd = targetDescriptor else { throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL) }
        snapshot.registeredIdentity = try descriptorIdentity(fd)
        if snapshot.existed, snapshot.registeredIdentity != snapshot.originalIdentity {
            throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
        }
        snapshot.mutationApplied = true
    }

    private func verifyTargetNameBinding(
        snapshot: ManagedTargetSnapshot,
        expectedIdentity: FileIdentity?
    ) throws {
        if let expectedLink = snapshot.symlinkIdentity {
            let selectedParts = pathComponents(snapshot.selectedRelativePath)
            guard let selectedName = selectedParts.last else {
                throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
            }
            let selectedParent = try traversal.openDirectory(
                relativePath: selectedParts.dropLast().joined(separator: "/"),
                verify: nil
            )
            defer { _ = close(selectedParent.descriptor) }
            var linkInfo = stat()
            guard fstatat(selectedParent.descriptor, selectedName, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  linkInfo.st_mode & S_IFMT == S_IFLNK,
                  FileIdentity(linkInfo) == expectedLink,
                  try readLink(at: selectedParent.descriptor, name: selectedName) == snapshot.symlinkDestination else {
                throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
            }
        }
        _ = try traversal.openDirectory(
            relativePath: pathComponents(snapshot.targetRelativePath).dropLast().joined(separator: "/"),
            verify: snapshot.parentIdentities,
            closeResult: true
        )
        guard let fd = targetDescriptor, let expectedIdentity else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
        }
        let targetName = pathComponents(targetRelativePath).last!
        var namedInfo = stat()
        guard fstatat(parentDescriptor, targetName, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              namedInfo.st_mode & S_IFMT == S_IFREG,
              FileIdentity(namedInfo) == expectedIdentity,
              try descriptorIdentity(fd) == expectedIdentity else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
        }
        let reopened = openat(parentDescriptor, targetName, O_RDONLY | O_NOFOLLOW)
        guard reopened >= 0 else { throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL) }
        defer { _ = close(reopened) }
        guard try descriptorIdentity(reopened) == expectedIdentity else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(snapshot.selectedURL)
        }
    }

    func reverse(
        snapshot: ManagedTargetSnapshot,
        testing: MCPRegistrationTesting?
    ) throws -> ReverseResult {
        guard let fd = targetDescriptor else {
            if !snapshot.existed { return ReverseResult(removedRegistration: false, warning: nil) }
            throw MCPOwnedRegistrationError.conflict(snapshot.selectedURL)
        }
        let current = try readAll(fd)
        if current == snapshot.beforeData {
            return ReverseResult(removedRegistration: false, warning: retainedFileWarning(snapshot: snapshot))
        }
        let expectedIdentity = snapshot.registeredIdentity ?? snapshot.originalIdentity
        guard try descriptorIdentity(fd) == expectedIdentity else {
            throw MCPOwnedRegistrationError.conflict(snapshot.selectedURL)
        }
        if snapshot.effectiveMutationState == .intent,
           snapshot.afterData.starts(with: current) {
            try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
            if snapshot.existed, let beforeData = snapshot.beforeData {
                try writeAll(beforeData, descriptor: fd)
                try restoreMetadata(snapshot: snapshot, descriptor: fd)
                guard fsync(fd) == 0 else { throw posixError() }
                try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
                guard fsync(parentDescriptor) == 0 else { throw posixError() }
            } else {
                try testing?.hit(.beforeRetainedFileRewrite, url: snapshot.selectedURL)
                try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
                try writeAll(ConfigurationImage.minimalData(format: snapshot.format), descriptor: fd)
                guard fsync(fd) == 0 else { throw posixError() }
                try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
                guard fsync(parentDescriptor) == 0 else { throw posixError() }
            }
            return ReverseResult(removedRegistration: true, warning: retainedFileWarning(snapshot: snapshot))
        }
        let currentOwned: Data?
        do {
            currentOwned = try ConfigurationImage.ownedRepresentation(
                format: snapshot.format,
                data: current,
                sourceURL: snapshot.selectedURL
            )
        } catch {
            try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
            if snapshot.effectiveMutationState == .intent,
               snapshot.existed,
               let beforeData = snapshot.beforeData {
                try writeAll(beforeData, descriptor: fd)
                try restoreMetadata(snapshot: snapshot, descriptor: fd)
                guard fsync(fd) == 0 else { throw posixError() }
                try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
                guard fsync(parentDescriptor) == 0 else { throw posixError() }
                return ReverseResult(removedRegistration: true, warning: nil)
            }
            throw error
        }
        if currentOwned == snapshot.beforeOwned {
            return ReverseResult(removedRegistration: false, warning: retainedFileWarning(snapshot: snapshot))
        }
        guard currentOwned == snapshot.afterOwned else {
            throw MCPOwnedRegistrationError.conflict(snapshot.selectedURL)
        }
        let fullRestore = current == snapshot.afterData
        let restored: Data
        if fullRestore, let before = snapshot.beforeData {
            restored = before
        } else {
            restored = try ConfigurationImage.reversingOwned(
                format: snapshot.format,
                currentData: current,
                beforeOwned: snapshot.beforeOwned,
                sourceURL: snapshot.selectedURL
            )
        }
        if !snapshot.existed {
            try testing?.hit(.beforeRetainedFileRewrite, url: snapshot.selectedURL)
        }
        try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
        try writeAll(restored, descriptor: fd)
        if fullRestore { try restoreMetadata(snapshot: snapshot, descriptor: fd) }
        guard fsync(fd) == 0 else { throw posixError() }
        try verifyTargetNameBinding(snapshot: snapshot, expectedIdentity: expectedIdentity)
        guard fsync(parentDescriptor) == 0 else { throw posixError() }
        return ReverseResult(removedRegistration: true, warning: retainedFileWarning(snapshot: snapshot))
    }

    private func retainedFileWarning(snapshot: ManagedTargetSnapshot) -> MCPRegistrationCleanupFailure? {
        guard !snapshot.existed else { return nil }
        return MCPRegistrationCleanupFailure(
            configurationURL: snapshot.selectedURL,
            message: "The client configuration file was retained after removing Evee's entry. Remove the file manually if it is no longer needed."
        )
    }
}

private final class DirectoryTraversal {
    let rootPath: String
    private let rootDescriptor: Int32

    init(rootPath: String) throws {
        self.rootPath = rootPath
        rootDescriptor = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw posixError() }
    }

    deinit { _ = close(rootDescriptor) }

    func duplicateRoot() throws -> Int32 {
        let value = dup(rootDescriptor)
        guard value >= 0 else { throw posixError() }
        return value
    }

    func openDeepestDirectory(relativePath: String) throws -> (descriptor: Int32, identities: [ParentIdentity], missing: [String]) {
        var current = try duplicateRoot()
        var identities = [ParentIdentity(relativePath: "", identity: try descriptorIdentity(current))]
        let components = pathComponents(relativePath)
        for (index, component) in components.enumerated() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0, errno == ENOENT {
                return (current, identities, Array(components[index...]))
            }
            guard next >= 0 else {
                _ = close(current)
                throw MCPOwnedRegistrationError.unsafeConfiguration(
                    URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath)
                )
            }
            _ = close(current)
            current = next
            let path = components[...index].joined(separator: "/")
            identities.append(ParentIdentity(relativePath: path, identity: try descriptorIdentity(current)))
        }
        return (current, identities, [])
    }

    func openDirectory(
        relativePath: String,
        verify expected: [ParentIdentity]?,
        closeResult: Bool = false
    ) throws -> (descriptor: Int32, identities: [ParentIdentity], identity: FileIdentity) {
        let opened = try openDeepestDirectory(relativePath: relativePath)
        guard opened.missing.isEmpty else { _ = close(opened.descriptor); throw MCPOwnedRegistrationError.unsafeConfiguration(URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath)) }
        if let expected, opened.identities != expected {
            _ = close(opened.descriptor)
            throw MCPOwnedRegistrationError.unsafeConfiguration(URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath))
        }
        let identity = try descriptorIdentity(opened.descriptor)
        if closeResult { _ = close(opened.descriptor); return (-1, opened.identities, identity) }
        return (opened.descriptor, opened.identities, identity)
    }
}

private struct ConfigurationImage {
    var afterData: Data
    var beforeOwned: Data?
    var afterOwned: Data

    static func minimalData(format: ConfigurationFormat) -> Data {
        switch format {
        case .json: Data("{\n  \"mcpServers\" : {\n\n  }\n}".utf8)
        case .toml: Data()
        }
    }

    static func isRecognizedLegacyOwned(
        format: ConfigurationFormat,
        owned: Data,
        executableURL: URL
    ) throws -> Bool {
        switch format {
        case .json:
            let expected: [String: Any] = ["command": executableURL.path, "args": []]
            return owned == (try canonicalJSON(expected))
        case .toml:
            let source = normalizedTOMLOwned(String(decoding: owned, as: UTF8.self))
            let legacy = normalizedTOMLOwned(
                "[mcp_servers.evee]\ncommand = \"\(tomlEscaped(executableURL.path))\"\nargs = []\n"
            )
            let current = normalizedTOMLOwned(
                "# Managed by Evee local helper access.\n[mcp_servers.evee]\ncommand = \"\(tomlEscaped(executableURL.path))\"\nargs = []\n"
            )
            return source == legacy || source == current
        }
    }

    static func make(
        format: ConfigurationFormat,
        before: Data?,
        executableURL: URL,
        sourceURL: URL
    ) throws -> ConfigurationImage {
        switch format {
        case .json:
            var root: [String: Any] = [:]
            if let before {
                guard let decoded = try JSONSerialization.jsonObject(with: before) as? [String: Any] else {
                    throw MCPRegistrationError.invalidConfiguration(sourceURL)
                }
                root = decoded
            }
            if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
                throw MCPRegistrationError.invalidConfiguration(sourceURL)
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            let beforeOwned = try servers["evee"].map(canonicalJSON)
            let registered: [String: Any] = ["command": executableURL.path, "args": []]
            servers["evee"] = registered
            root["mcpServers"] = servers
            return ConfigurationImage(
                afterData: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                beforeOwned: beforeOwned,
                afterOwned: try canonicalJSON(registered)
            )
        case .toml:
            let source = before.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let split = splitTOML(source)
            let table = "# Managed by Evee local helper access.\n[mcp_servers.evee]\ncommand = \"\(tomlEscaped(executableURL.path))\"\nargs = []\n"
            let separator = split.base.isEmpty || split.base.hasSuffix("\n") ? "" : "\n"
            return ConfigurationImage(
                afterData: Data((split.base + separator + table).utf8),
                beforeOwned: split.owned.isEmpty ? nil : Data(normalizedTOMLOwned(split.owned).utf8),
                afterOwned: Data(normalizedTOMLOwned(table).utf8)
            )
        }
    }

    static func ownedRepresentation(format: ConfigurationFormat, data: Data, sourceURL: URL) throws -> Data? {
        switch format {
        case .json:
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any] else {
                throw MCPRegistrationError.invalidConfiguration(sourceURL)
            }
            return try servers["evee"].map(canonicalJSON)
        case .toml:
            let split = splitTOML(String(decoding: data, as: UTF8.self))
            return split.owned.isEmpty ? nil : Data(normalizedTOMLOwned(split.owned).utf8)
        }
    }

    static func reversingOwned(
        format: ConfigurationFormat,
        currentData: Data,
        beforeOwned: Data?,
        sourceURL: URL
    ) throws -> Data {
        switch format {
        case .json:
            guard var root = try JSONSerialization.jsonObject(with: currentData) as? [String: Any],
                  var servers = root["mcpServers"] as? [String: Any] else {
                throw MCPRegistrationError.invalidConfiguration(sourceURL)
            }
            if let beforeOwned {
                servers["evee"] = try JSONSerialization.jsonObject(with: beforeOwned)
            } else {
                servers.removeValue(forKey: "evee")
            }
            root["mcpServers"] = servers
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        case .toml:
            let split = splitTOML(String(decoding: currentData, as: UTF8.self))
            guard let beforeOwned else { return Data(split.base.utf8) }
            let before = String(decoding: beforeOwned, as: UTF8.self)
            let separator = split.base.isEmpty || split.base.hasSuffix("\n") ? "" : "\n"
            return Data((split.base + separator + before).utf8)
        }
    }
}

private struct FileMetadata {
    var permissions: UInt16?
    var ownerID: UInt32?
    var groupID: UInt32?
    var accessTimeSeconds: Int64?
    var accessTimeNanoseconds: Int64?
    var modificationTimeSeconds: Int64?
    var modificationTimeNanoseconds: Int64?
    var accessControlList: String?
    var extendedAttributes: [String: Data]

    static let empty = FileMetadata(
        permissions: nil, ownerID: nil, groupID: nil,
        accessTimeSeconds: nil, accessTimeNanoseconds: nil,
        modificationTimeSeconds: nil, modificationTimeNanoseconds: nil,
        accessControlList: nil, extendedAttributes: [:]
    )

    init(descriptor: Int32, info: stat) throws {
        permissions = UInt16(info.st_mode & 0o7777)
        ownerID = info.st_uid
        groupID = info.st_gid
        accessTimeSeconds = Int64(info.st_atimespec.tv_sec)
        accessTimeNanoseconds = Int64(info.st_atimespec.tv_nsec)
        modificationTimeSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationTimeNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        accessControlList = try readACL(descriptor)
        extendedAttributes = try readExtendedAttributes(descriptor)
    }

    private init(
        permissions: UInt16?, ownerID: UInt32?, groupID: UInt32?,
        accessTimeSeconds: Int64?, accessTimeNanoseconds: Int64?,
        modificationTimeSeconds: Int64?, modificationTimeNanoseconds: Int64?,
        accessControlList: String?, extendedAttributes: [String: Data]
    ) {
        self.permissions = permissions
        self.ownerID = ownerID
        self.groupID = groupID
        self.accessTimeSeconds = accessTimeSeconds
        self.accessTimeNanoseconds = accessTimeNanoseconds
        self.modificationTimeSeconds = modificationTimeSeconds
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.accessControlList = accessControlList
        self.extendedAttributes = extendedAttributes
    }
}

private func restoreMetadata(snapshot: ManagedTargetSnapshot, descriptor: Int32) throws {
    guard let permissions = snapshot.permissions,
          let ownerID = snapshot.ownerID,
          let groupID = snapshot.groupID,
          let accessSeconds = snapshot.accessTimeSeconds,
          let accessNanos = snapshot.accessTimeNanoseconds,
          let modificationSeconds = snapshot.modificationTimeSeconds,
          let modificationNanos = snapshot.modificationTimeNanoseconds else { return }
    guard fchown(descriptor, uid_t(ownerID), gid_t(groupID)) == 0,
          fchmod(descriptor, mode_t(permissions)) == 0 else { throw posixError() }
    try restoreACL(snapshot.accessControlList, descriptor: descriptor)
    try restoreExtendedAttributes(snapshot.extendedAttributes, descriptor: descriptor)
    var times = [
        timespec(tv_sec: time_t(accessSeconds), tv_nsec: Int(accessNanos)),
        timespec(tv_sec: time_t(modificationSeconds), tv_nsec: Int(modificationNanos)),
    ]
    guard futimens(descriptor, &times) == 0 else { throw posixError() }
}

private func readExtendedAttributes(_ descriptor: Int32) throws -> [String: Data] {
    let size = flistxattr(descriptor, nil, 0, 0)
    guard size >= 0 else { throw posixError() }
    guard size > 0 else { return [:] }
    var buffer = [CChar](repeating: 0, count: size)
    let read = buffer.withUnsafeMutableBufferPointer { flistxattr(descriptor, $0.baseAddress, size, 0) }
    guard read >= 0 else { throw posixError() }
    let names = Data(bytes: buffer, count: read).split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    var result: [String: Data] = [:]
    for name in names {
        let valueSize = fgetxattr(descriptor, name, nil, 0, 0, 0)
        guard valueSize >= 0 else { throw posixError() }
        var value = Data(count: valueSize)
        let valueRead = value.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, valueSize, 0, 0) }
        guard valueRead >= 0 else { throw posixError() }
        result[name] = value
    }
    return result
}

private func restoreExtendedAttributes(_ attributes: [String: Data], descriptor: Int32) throws {
    let current = try readExtendedAttributes(descriptor)
    for name in current.keys where attributes[name] == nil {
        guard fremovexattr(descriptor, name, 0) == 0 else { throw posixError() }
    }
    for (name, value) in attributes {
        let result = value.withUnsafeBytes { fsetxattr(descriptor, name, $0.baseAddress, value.count, 0, 0) }
        guard result == 0 else { throw posixError() }
    }
}

private func readACL(_ descriptor: Int32) throws -> String? {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        if errno == 0 || errno == ENOENT { return nil }
        throw posixError()
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var length: ssize_t = 0
    guard let text = acl_to_text(acl, &length) else { throw posixError() }
    defer { acl_free(text) }
    return String(bytes: UnsafeRawBufferPointer(start: text, count: length), encoding: .utf8)
}

private func restoreACL(_ text: String?, descriptor: Int32) throws {
    let acl = text?.withCString { acl_from_text($0) } ?? acl_init(0)
    guard let acl else { throw posixError() }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { throw posixError() }
}

private func writeDurable<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw posixError() }
    defer { _ = close(directory) }
    let name = url.lastPathComponent
    let temporary = ".\(name).\(UUID().uuidString).tmp"
    let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw posixError() }
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAll(encoder.encode(value), descriptor: descriptor)
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else { throw posixError() }
        _ = close(descriptor)
        guard renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else { throw posixError() }
    } catch {
        _ = close(descriptor)
        _ = unlinkat(directory, temporary, 0)
        throw error
    }
}

private func loadDurableIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        if errno == ENOENT { return nil }
        throw posixError()
    }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        throw MCPOwnedRegistrationError.invalidManifest(url)
    }
    do { return try JSONDecoder().decode(T.self, from: readAll(descriptor)) }
    catch { throw MCPOwnedRegistrationError.invalidManifest(url) }
}

private func removeDurable(_ url: URL) throws {
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw posixError() }
    defer { _ = close(directory) }
    guard unlinkat(directory, url.lastPathComponent, 0) == 0, fsync(directory) == 0 else {
        if errno == ENOENT { return }
        throw posixError()
    }
}

private func readAll(_ descriptor: Int32) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count >= 0 else { throw posixError() }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private func writeAll(_ data: Data, descriptor: Int32) throws {
    guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
    try writeBuffer(data, descriptor: descriptor)
}

private func writeWithPartialCheckpoint(
    _ data: Data,
    descriptor: Int32,
    url: URL,
    testing: MCPRegistrationTesting
) throws {
    guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
    let split = max(1, data.count / 2)
    try writeBuffer(data.prefix(split), descriptor: descriptor)
    guard fsync(descriptor) == 0 else { throw posixError("fsync partial client") }
    try testing.hit(.duringExistingTargetWrite, url: url)
    try writeBuffer(data.dropFirst(split), descriptor: descriptor)
}

private func writeBuffer<C: Collection>(_ data: C, descriptor: Int32) throws where C.Element == UInt8 {
    let bytes = Data(data)
    try bytes.withUnsafeBytes { rawBuffer in
        guard var pointer = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        while remaining > 0 {
            let count = Darwin.write(descriptor, pointer, remaining)
            guard count >= 0 else { throw posixError() }
            remaining -= count
            pointer = pointer.advanced(by: count)
        }
    }
}

private func descriptorIdentity(_ descriptor: Int32) throws -> FileIdentity {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixError() }
    return FileIdentity(info)
}

private func readLink(at descriptor: Int32, name: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlinkat(descriptor, name, &buffer, buffer.count - 1)
    guard count >= 0 else { throw posixError() }
    return String(decoding: buffer.prefix(count).map(UInt8.init(bitPattern:)), as: UTF8.self)
}

private func canonicalJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}

private func splitTOML(_ source: String) -> (base: String, owned: String) {
    let pattern = #"(?m)^[ \t]*\[([^\]\r\n]+)\][ \t]*(?:#[^\r\n]*)?(?:\r?\n|$)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return (source, "") }
    let full = NSRange(source.startIndex..<source.endIndex, in: source)
    let headers = expression.matches(in: source, range: full)
    var ranges: [NSRange] = []
    let nsSource = source as NSString
    for (index, header) in headers.enumerated() {
        guard let nameRange = Range(header.range(at: 1), in: source) else { continue }
        let name = source[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == "mcp_servers.evee" || name.hasPrefix("mcp_servers.evee.")
                || name == "mcp_servers.\"evee\"" || name.hasPrefix("mcp_servers.\"evee\".") else { continue }
        let end = index + 1 < headers.count ? headers[index + 1].range.location : full.length
        var start = header.range.location
        let marker = "# Managed by Evee local helper access.\n" as NSString
        if start >= marker.length,
           nsSource.substring(with: NSRange(location: start - marker.length, length: marker.length)) == marker as String {
            start -= marker.length
        }
        ranges.append(NSRange(location: start, length: end - start))
    }
    guard !ranges.isEmpty else { return (source, "") }
    let owned = ranges.map { nsSource.substring(with: $0) }.joined()
    let mutable = NSMutableString(string: source)
    for range in ranges.reversed() { mutable.deleteCharacters(in: range) }
    return (mutable as String, owned)
}

private func tomlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func normalizedTOMLOwned(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
}

private func pathComponents(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init)
}

private func safeRelativePath(_ path: String) -> Bool {
    !path.hasPrefix("/") && pathComponents(path).allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
}

private func contains(path: String, root: String) -> Bool {
    path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}

private func relativePath(_ path: String, root: String) -> String {
    guard path != root else { return "" }
    return String(path.dropFirst((root.hasSuffix("/") ? root : root + "/").count))
}

private func posixError(_ context: String? = nil) -> Error {
    let code = errno
    guard let context else { return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    return NSError(
        domain: "Evee.MCPRegistration.\(context)",
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: strerror(code)))"]
    )
}
