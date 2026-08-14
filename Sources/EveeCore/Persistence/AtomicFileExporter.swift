import CryptoKit
import Foundation

public enum AtomicFileExportError: Error, Equatable {
    case verificationFailed
}

public protocol FileExportOperations: Sendable {
    func copy(_ source: URL, _ destination: URL) throws
    func verifySameBytes(_ source: URL, _ destination: URL) throws
    func replaceAtomically(_ destination: URL, with replacement: URL) throws
    func removeIfPresent(_ url: URL) throws
}

public struct FoundationFileExportOperations: FileExportOperations {
    public init() {}

    public func copy(_ source: URL, _ destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func verifySameBytes(_ source: URL, _ destination: URL) throws {
        let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let destinationSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard sourceSize == destinationSize, try digest(source) == digest(destination) else {
            throw AtomicFileExportError.verificationFailed
        }
    }

    public func replaceAtomically(_ destination: URL, with replacement: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: destination)
        }
    }

    public func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}

public struct AtomicFileExporter: Sendable {
    private let operations: any FileExportOperations

    public init(operations: any FileExportOperations = FoundationFileExportOperations()) {
        self.operations = operations
    }

    public func export(source: URL, to destination: URL) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".evee-export-\(UUID().uuidString)")
        defer { try? operations.removeIfPresent(temporary) }
        try operations.copy(source, temporary)
        try operations.verifySameBytes(source, temporary)
        try operations.replaceAtomically(destination, with: temporary)
    }
}
