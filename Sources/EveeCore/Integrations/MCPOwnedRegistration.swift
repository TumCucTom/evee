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
    public let removals: [MCPRemovalResult]
    public let cleanupFailures: [MCPRegistrationCleanupFailure]

    public init(removals: [MCPRemovalResult], cleanupFailures: [MCPRegistrationCleanupFailure]) {
        self.removals = removals
        self.cleanupFailures = cleanupFailures
    }
}

public enum MCPOwnedRegistrationError: LocalizedError, Sendable {
    case manifestAlreadyExists(URL)
    case invalidManifest(URL)
    case unsafeConfiguration(URL)
    case rollbackFailed(primary: String, failures: [String])

    public var errorDescription: String? {
        switch self {
        case .manifestAlreadyExists:
            return "Local helper access already has an owned registration record. Revoke it before enabling again."
        case .invalidManifest:
            return "The local helper registration record is invalid, so no client configuration was changed."
        case .unsafeConfiguration:
            return "A selected client configuration resolves outside its approved local configuration area."
        case .rollbackFailed(let primary, let failures):
            return "Registration failed: \(primary) Rollback also failed: \(failures.joined(separator: "; "))"
        }
    }
}

public final class MCPAuthorizationLease: @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var released = false

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

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
        let path = lockURL(storageRootURL: storageRootURL).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, operation) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return MCPAuthorizationLease(descriptor: descriptor)
    }
}

@_spi(Testing)
public struct MCPRegistrationTesting: Sendable {
    public var beforeRestore: @Sendable (URL) throws -> Void

    public init(beforeRestore: @escaping @Sendable (URL) throws -> Void) {
        self.beforeRestore = beforeRestore
    }
}

public enum MCPOwnedRegistration {
    private static let manifestName = "local-helper-registrations.json"

    public static func manifestURL(storageRootURL: URL) -> URL {
        storageRootURL.appendingPathComponent(manifestName)
    }

    public static func enable(
        clients: [MCPClientConfiguration],
        executableURL: URL,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void
    ) async throws -> [MCPRegistrationResult] {
        try await enableImpl(
            clients: clients,
            executableURL: executableURL,
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
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
        testing: MCPRegistrationTesting
    ) async throws -> [MCPRegistrationResult] {
        try await enableImpl(
            clients: clients,
            executableURL: executableURL,
            allowedRootURLs: allowedRootURLs,
            storageRootURL: storageRootURL,
            settings: settings,
            saveSettings: saveSettings,
            testing: testing
        )
    }

    public static func revoke(
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void
    ) async throws -> MCPRevocationOutcome {
        let url = manifestURL(storageRootURL: storageRootURL)
        var disabled = settings
        disabled.mcpEnabled = false
        let lease = try MCPAuthorization.exclusiveLease(storageRootURL: storageRootURL)
        do {
            try await saveSettings(disabled)
        } catch {
            lease.release()
            throw error
        }
        lease.release()

        let manifest: OwnedRegistrationManifest?
        do {
            manifest = try loadManifest(at: url, allowedRootURLs: allowedRootURLs)
        } catch {
            return MCPRevocationOutcome(
                removals: [],
                cleanupFailures: [MCPRegistrationCleanupFailure(configurationURL: url, message: error.localizedDescription)]
            )
        }
        guard let manifest else { return MCPRevocationOutcome(removals: [], cleanupFailures: []) }
        var removals: [MCPRemovalResult] = []
        var failures: [MCPRegistrationCleanupFailure] = []
        for snapshot in manifest.snapshots.reversed() {
            do {
                try snapshot.restore(allowedRootURLs: allowedRootURLs)
                removals.append(MCPRemovalResult(configurationURL: snapshot.selectedURL, removedRegistration: true))
            } catch {
                failures.append(MCPRegistrationCleanupFailure(
                    configurationURL: snapshot.selectedURL,
                    message: error.localizedDescription
                ))
            }
        }
        for directoryFailure in cleanupCreatedDirectories(manifest.createdDirectories) {
            failures.append(MCPRegistrationCleanupFailure(
                configurationURL: URL(fileURLWithPath: directoryFailure.path, isDirectory: true),
                message: directoryFailure.message
            ))
        }
        if failures.isEmpty {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append(MCPRegistrationCleanupFailure(
                    configurationURL: url,
                    message: error.localizedDescription
                ))
            }
        }
        return MCPRevocationOutcome(removals: removals.reversed(), cleanupFailures: failures)
    }

    private static func enableImpl(
        clients: [MCPClientConfiguration],
        executableURL: URL,
        allowedRootURLs: [URL],
        storageRootURL: URL,
        settings: EveeSettings,
        saveSettings: @escaping @Sendable (EveeSettings) async throws -> Void,
        testing: MCPRegistrationTesting?
    ) async throws -> [MCPRegistrationResult] {
        guard !clients.isEmpty else { return [] }
        let url = manifestURL(storageRootURL: storageRootURL)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MCPOwnedRegistrationError.manifestAlreadyExists(url)
        }
        let executable = executableURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw MCPRegistrationError.executableMissing(executable)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPRegistrationError.executableNotRunnable(executable)
        }
        var snapshots = try clients.map {
            try ManagedConfigurationSnapshot(selectedURL: $0.configurationURL, allowedRootURLs: allowedRootURLs)
        }
        guard Set(snapshots.map(\.canonicalTargetPath)).count == snapshots.count else {
            throw MCPOwnedRegistrationError.invalidManifest(url)
        }
        let createdDirectories = transactionCreatedDirectories(for: snapshots.map(\.canonicalTargetURL))
        let results: [MCPRegistrationResult]
        do {
            var completed: [MCPRegistrationResult] = []
            for index in clients.indices {
                snapshots[index].wasWritten = true
                do {
                    let result = try MCPRegistration.writeConfiguration(
                        at: snapshots[index].canonicalTargetURL,
                        executableURL: executable
                    ).withConfigurationURL(clients[index].configurationURL)
                    try snapshots[index].recordRegisteredIdentity()
                    completed.append(result)
                } catch {
                    let writeError = error
                    do {
                        try snapshots[index].recordRegisteredIdentity()
                    } catch {
                        throw MCPOwnedRegistrationError.rollbackFailed(
                            primary: writeError.localizedDescription,
                            failures: ["Could not bind the touched configuration for rollback: \(error.localizedDescription)"]
                        )
                    }
                    throw writeError
                }
            }
            results = completed
            let manifest = OwnedRegistrationManifest(
                version: 1,
                snapshots: snapshots,
                createdDirectories: createdDirectories.map(\.path)
            )
            try writeManifest(manifest, at: url)
        } catch {
            var failures = restoreForRollback(
                snapshots: snapshots,
                createdDirectories: createdDirectories.map(\.path),
                testing: testing
            )
            if failures.isEmpty { failures.append(contentsOf: removeManifestForRollback(at: url)) }
            guard !failures.isEmpty else {
                throw error
            }
            throw MCPOwnedRegistrationError.rollbackFailed(
                primary: error.localizedDescription,
                failures: failures
            )
        }

        let lease: MCPAuthorizationLease
        do {
            lease = try MCPAuthorization.exclusiveLease(storageRootURL: storageRootURL)
        } catch {
            var failures = restoreForRollback(
                snapshots: snapshots,
                createdDirectories: createdDirectories.map(\.path),
                testing: testing
            )
            if failures.isEmpty { failures.append(contentsOf: removeManifestForRollback(at: url)) }
            guard !failures.isEmpty else { throw error }
            throw MCPOwnedRegistrationError.rollbackFailed(primary: error.localizedDescription, failures: failures)
        }

        var enabled = settings
        enabled.mcpEnabled = true
        do {
            try await saveSettings(enabled)
            lease.release()
            return results
        } catch {
            let primary = error
            var failures: [String] = []
            var disabled = settings
            disabled.mcpEnabled = false
            do {
                try await saveSettings(disabled)
            } catch {
                failures.append("Fail-closed authorization restore: \(error.localizedDescription)")
            }
            failures.append(contentsOf: restoreForRollback(
                snapshots: snapshots,
                createdDirectories: createdDirectories.map(\.path),
                testing: testing
            ))
            if failures.isEmpty { failures.append(contentsOf: removeManifestForRollback(at: url)) }
            lease.release()
            guard !failures.isEmpty else { throw primary }
            throw MCPOwnedRegistrationError.rollbackFailed(
                primary: primary.localizedDescription,
                failures: failures
            )
        }
    }

    private static func restoreForRollback(
        snapshots: [ManagedConfigurationSnapshot],
        createdDirectories: [String],
        testing: MCPRegistrationTesting?
    ) -> [String] {
        var failures: [String] = []
        for snapshot in snapshots.reversed() where snapshot.wasWritten {
            do {
                try testing?.beforeRestore(snapshot.selectedURL)
                try snapshot.restoreWithoutRootRevalidation()
            } catch {
                failures.append("\(snapshot.selectedURL.path): \(error.localizedDescription)")
            }
        }
        failures.append(contentsOf: cleanupCreatedDirectories(createdDirectories).map {
            "\($0.path): \($0.message)"
        })
        return failures
    }

    private static func removeManifestForRollback(at url: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            try FileManager.default.removeItem(at: url)
            return []
        } catch {
            return ["\(url.path): \(error.localizedDescription)"]
        }
    }

    private static func transactionCreatedDirectories(for targets: [URL]) -> [URL] {
        var paths = Set<String>()
        for target in targets {
            var directory = target.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
                paths.insert(directory.path)
                directory.deleteLastPathComponent()
            }
        }
        return paths.sorted { $0.count < $1.count }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func cleanupCreatedDirectories(_ paths: [String]) -> [(path: String, message: String)] {
        var failures: [(path: String, message: String)] = []
        for path in paths.sorted(by: { $0.count > $1.count }) {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno != ENOENT {
                    failures.append((path, POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription))
                }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                failures.append((path, "The transaction-created path is no longer an ordinary directory."))
                continue
            }
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                guard contents.isEmpty else { continue }
                try FileManager.default.removeItem(atPath: path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                failures.append((path, error.localizedDescription))
            }
        }
        return failures
    }

    private static func writeManifest(_ manifest: OwnedRegistrationManifest, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func loadManifest(at url: URL, allowedRootURLs: [URL]) throws -> OwnedRegistrationManifest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let manifest = try JSONDecoder().decode(OwnedRegistrationManifest.self, from: Data(contentsOf: url))
            guard manifest.version == 1,
                  Set(manifest.snapshots.map(\.canonicalTargetPath)).count == manifest.snapshots.count else {
                throw MCPOwnedRegistrationError.invalidManifest(url)
            }
            for snapshot in manifest.snapshots {
                try snapshot.validateStoredTarget(allowedRootURLs: allowedRootURLs)
            }
            for directoryPath in manifest.createdDirectories {
                let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
                guard directoryURL.path == directoryPath,
                      isPath(directoryURL.path, allowedBy: allowedRootURLs),
                      manifest.snapshots.contains(where: {
                          $0.canonicalTargetPath.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/")
                      }) else {
                    throw MCPOwnedRegistrationError.invalidManifest(url)
                }
            }
            return manifest
        } catch let error as MCPOwnedRegistrationError {
            throw error
        } catch {
            throw MCPOwnedRegistrationError.invalidManifest(url)
        }
    }

    private static func isPath(_ path: String, allowedBy roots: [URL]) -> Bool {
        roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }
}

private struct OwnedRegistrationManifest: Codable {
    var version: Int
    var snapshots: [ManagedConfigurationSnapshot]
    var createdDirectories: [String]
}

private struct ManagedConfigurationSnapshot: Codable {
    var selectedPath: String
    var canonicalTargetPath: String
    var symbolicLinkDestination: String?
    var existed: Bool
    var wasWritten: Bool
    var originalDeviceID: UInt64?
    var originalFileID: UInt64?
    var registeredDeviceID: UInt64?
    var registeredFileID: UInt64?
    var data: Data?
    var permissions: UInt16?
    var ownerID: UInt32?
    var groupID: UInt32?
    var accessTimeSeconds: Int64?
    var accessTimeNanoseconds: Int64?
    var modificationTimeSeconds: Int64?
    var modificationTimeNanoseconds: Int64?
    var accessControlList: String?
    var extendedAttributes: [String: Data]

    var selectedURL: URL { URL(fileURLWithPath: selectedPath) }
    var canonicalTargetURL: URL { URL(fileURLWithPath: canonicalTargetPath) }

    init(selectedURL: URL, allowedRootURLs: [URL]) throws {
        let selected = selectedURL.standardizedFileURL
        self.selectedPath = selected.path
        let linkDestination = try Self.symbolicLinkDestination(at: selected)
        self.symbolicLinkDestination = linkDestination
        let canonical: URL
        if linkDestination != nil {
            canonical = selected.resolvingSymlinksInPath().standardizedFileURL
        } else {
            canonical = selected.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(selected.lastPathComponent).standardizedFileURL
        }
        guard Self.isAllowed(selected, roots: allowedRootURLs),
              Self.isAllowed(canonical, roots: allowedRootURLs) else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(selected)
        }
        self.canonicalTargetPath = canonical.path

        var info = stat()
        if lstat(canonical.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw MCPOwnedRegistrationError.unsafeConfiguration(selected)
            }
            existed = true
            wasWritten = false
            originalDeviceID = UInt64(info.st_dev)
            originalFileID = UInt64(info.st_ino)
            registeredDeviceID = nil
            registeredFileID = nil
            data = try Data(contentsOf: canonical)
            permissions = UInt16(info.st_mode & 0o7777)
            ownerID = info.st_uid
            groupID = info.st_gid
            accessTimeSeconds = Int64(info.st_atimespec.tv_sec)
            accessTimeNanoseconds = Int64(info.st_atimespec.tv_nsec)
            modificationTimeSeconds = Int64(info.st_mtimespec.tv_sec)
            modificationTimeNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            accessControlList = try Self.readACL(at: canonical.path)
            extendedAttributes = try Self.readExtendedAttributes(at: canonical.path)
            var verifiedInfo = stat()
            guard lstat(canonical.path, &verifiedInfo) == 0,
                  verifiedInfo.st_mode & S_IFMT == S_IFREG,
                  UInt64(verifiedInfo.st_dev) == originalDeviceID,
                  UInt64(verifiedInfo.st_ino) == originalFileID else {
                throw MCPOwnedRegistrationError.unsafeConfiguration(selected)
            }
        } else if errno == ENOENT {
            existed = false
            wasWritten = false
            originalDeviceID = nil
            originalFileID = nil
            registeredDeviceID = nil
            registeredFileID = nil
            data = nil
            permissions = nil
            ownerID = nil
            groupID = nil
            accessTimeSeconds = nil
            accessTimeNanoseconds = nil
            modificationTimeSeconds = nil
            modificationTimeNanoseconds = nil
            accessControlList = nil
            extendedAttributes = [:]
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    mutating func recordRegisteredIdentity() throws {
        var info = stat()
        guard lstat(canonicalTargetPath, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(selectedURL)
        }
        registeredDeviceID = UInt64(info.st_dev)
        registeredFileID = UInt64(info.st_ino)
        if existed,
           (registeredDeviceID != originalDeviceID || registeredFileID != originalFileID) {
            throw MCPOwnedRegistrationError.unsafeConfiguration(selectedURL)
        }
    }

    func validateBinding(allowedRootURLs: [URL]) throws {
        try validateStoredTarget(allowedRootURLs: allowedRootURLs)
        let currentLink = try Self.symbolicLinkDestination(at: selectedURL)
        guard currentLink == symbolicLinkDestination else {
            throw MCPOwnedRegistrationError.invalidManifest(selectedURL)
        }
        let currentCanonical: URL
        if symbolicLinkDestination != nil {
            currentCanonical = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        } else {
            currentCanonical = selectedURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(selectedURL.lastPathComponent).standardizedFileURL
        }
        guard currentCanonical.path == canonicalTargetPath else {
            throw MCPOwnedRegistrationError.invalidManifest(selectedURL)
        }
    }

    func validateStoredTarget(allowedRootURLs: [URL]) throws {
        guard selectedURL.path == selectedPath,
              canonicalTargetURL.path == canonicalTargetPath,
              Self.isAllowed(selectedURL, roots: allowedRootURLs),
              Self.isAllowed(canonicalTargetURL, roots: allowedRootURLs) else {
            throw MCPOwnedRegistrationError.unsafeConfiguration(selectedURL)
        }
    }

    func restore(allowedRootURLs: [URL]) throws {
        try validateBinding(allowedRootURLs: allowedRootURLs)
        try restoreWithoutRootRevalidation()
    }

    func restoreWithoutRootRevalidation() throws {
        var currentInfo = stat()
        let currentExists = lstat(canonicalTargetPath, &currentInfo) == 0
        if currentExists {
            guard currentInfo.st_mode & S_IFMT == S_IFREG,
                  currentInfo.st_nlink == 1,
                  UInt64(currentInfo.st_dev) == registeredDeviceID,
                  UInt64(currentInfo.st_ino) == registeredFileID else {
                throw MCPOwnedRegistrationError.invalidManifest(selectedURL)
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if existed {
            guard currentExists,
                  originalDeviceID == registeredDeviceID,
                  originalFileID == registeredFileID else {
                throw MCPOwnedRegistrationError.invalidManifest(selectedURL)
            }
            guard let data, let permissions, let ownerID, let groupID,
                  let accessTimeSeconds, let accessTimeNanoseconds,
                  let modificationTimeSeconds, let modificationTimeNanoseconds else {
                throw MCPOwnedRegistrationError.invalidManifest(selectedURL)
            }
            try Self.writeInPlace(
                data,
                to: canonicalTargetURL,
                expectedDeviceID: registeredDeviceID,
                expectedFileID: registeredFileID
            )
            guard chown(canonicalTargetPath, uid_t(ownerID), gid_t(groupID)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard chmod(canonicalTargetPath, mode_t(permissions)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try Self.restoreACL(accessControlList, at: canonicalTargetPath)
            try Self.restoreExtendedAttributes(extendedAttributes, at: canonicalTargetPath)
            var times = [
                timespec(tv_sec: time_t(accessTimeSeconds), tv_nsec: Int(accessTimeNanoseconds)),
                timespec(tv_sec: time_t(modificationTimeSeconds), tv_nsec: Int(modificationTimeNanoseconds)),
            ]
            guard utimensat(AT_FDCWD, canonicalTargetPath, &times, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            if currentExists {
                guard unlink(canonicalTargetPath) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private static func symbolicLinkDestination(at url: URL) throws -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFLNK else { return nil }
        return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    private static func isAllowed(_ url: URL, roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    private static func writeInPlace(
        _ data: Data,
        to url: URL,
        expectedDeviceID: UInt64?,
        expectedFileID: UInt64?
    ) throws {
        let descriptor = open(url.path, O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              UInt64(info.st_dev) == expectedDeviceID,
              UInt64(info.st_ino) == expectedFileID else {
            throw MCPOwnedRegistrationError.invalidManifest(url)
        }
        guard ftruncate(descriptor, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func readExtendedAttributes(at path: String) throws -> [String: Data] {
        let size = listxattr(path, nil, 0, 0)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard size > 0 else { return [:] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBufferPointer { listxattr(path, $0.baseAddress, size, 0) }
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let names = Data(bytes: buffer, count: read).split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
        var result: [String: Data] = [:]
        for name in names {
            let valueSize = getxattr(path, name, nil, 0, 0, 0)
            guard valueSize >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var value = Data(count: valueSize)
            let valueRead = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, valueSize, 0, 0) }
            guard valueRead >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            result[name] = value
        }
        return result
    }

    private static func restoreExtendedAttributes(_ attributes: [String: Data], at path: String) throws {
        let current = try readExtendedAttributes(at: path)
        for name in current.keys where attributes[name] == nil {
            guard removexattr(path, name, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        for (name, value) in attributes {
            let result = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private static func readACL(at path: String) throws -> String? {
        errno = 0
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(text) }
        return String(bytes: UnsafeRawBufferPointer(start: text, count: length), encoding: .utf8)
    }

    private static func restoreACL(_ text: String?, at path: String) throws {
        let acl: acl_t?
        if let text {
            acl = text.withCString { acl_from_text($0) }
        } else {
            acl = acl_init(0)
        }
        guard let acl else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private extension MCPRegistrationResult {
    func withConfigurationURL(_ url: URL) -> MCPRegistrationResult {
        MCPRegistrationResult(
            configurationURL: url,
            executableURL: executableURL,
            replacedExistingRegistration: replacedExistingRegistration
        )
    }
}
