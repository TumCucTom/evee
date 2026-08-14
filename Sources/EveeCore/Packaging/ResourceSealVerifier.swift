import CryptoKit
import Foundation

public enum ResourceSealError: Error, Equatable {
    case missingSeal
    case fileSetMismatch
    case malformedEntry(String)
    case unsafePath(String)
    case duplicatePath(String)
    case missingResource(String)
    case digestMismatch(String)
    case symbolicLink(String)
}

public enum ResourceSealVerifier {
    public static func verify(
        resourcesURL: URL,
        sealName: String = ".evee-resource-seal.sha256"
    ) throws {
        guard isSafeRelativePath(sealName) else { throw ResourceSealError.unsafePath(sealName) }
        let rootURL = resourcesURL.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let sealURL = rootURL.appendingPathComponent(sealName).standardizedFileURL
        let sealValues = try? sealURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sealValues?.isRegularFile == true, sealValues?.isSymbolicLink != true,
              let text = try? String(contentsOf: sealURL, encoding: .utf8) else {
            throw ResourceSealError.missingSeal
        }

        var sealed = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) where !rawLine.isEmpty {
            let line = String(rawLine)
            guard line.count > 66 else { throw ResourceSealError.malformedEntry(line) }
            let digest = String(line.prefix(64))
            let separator = line.dropFirst(64).prefix(2)
            let relativePath = String(line.dropFirst(66))
            guard digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  separator == "  ", isSafeRelativePath(relativePath) else {
                throw ResourceSealError.malformedEntry(line)
            }
            guard sealed.insert(relativePath).inserted else {
                throw ResourceSealError.duplicatePath(relativePath)
            }

            let fileURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
            guard fileURL.path.hasPrefix(rootPath) else { throw ResourceSealError.unsafePath(relativePath) }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { throw ResourceSealError.symbolicLink(relativePath) }
            guard values?.isRegularFile == true else { throw ResourceSealError.missingResource(relativePath) }
            let actualDigest = SHA256.hash(data: try Data(contentsOf: fileURL))
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualDigest == digest else { throw ResourceSealError.digestMismatch(relativePath) }
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var actual = Set<String>()
        while let fileURL = enumerator?.nextObject() as? URL {
            let standardized = fileURL.standardizedFileURL
            guard standardized.path.hasPrefix(rootPath) else { throw ResourceSealError.unsafePath(fileURL.path) }
            let values = try? standardized.resourceValues(forKeys: keys)
            let relativePath = String(standardized.path.dropFirst(rootPath.count))
            if values?.isSymbolicLink == true { throw ResourceSealError.symbolicLink(relativePath) }
            guard values?.isRegularFile == true, standardized != sealURL else { continue }
            actual.insert(relativePath)
        }
        guard actual == sealed else { throw ResourceSealError.fileSetMismatch }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { component in
            component.isEmpty || component == "." || component == ".."
        }
    }
}
