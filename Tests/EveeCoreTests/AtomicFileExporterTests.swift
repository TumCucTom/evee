import Foundation
import XCTest
@testable import EveeCore

final class AtomicFileExporterTests: XCTestCase {
    enum SyntheticExportError: Error, Equatable { case copy, verification, replacement }

    final class Operations: FileExportOperations, @unchecked Sendable {
        let failure: SyntheticExportError?
        init(failure: SyntheticExportError? = nil) { self.failure = failure }

        func copy(_ source: URL, _ destination: URL) throws {
            if failure == .copy { throw SyntheticExportError.copy }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        func verifySameBytes(_ source: URL, _ destination: URL) throws {
            if failure == .verification { throw SyntheticExportError.verification }
            guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
                throw AtomicFileExportError.verificationFailed
            }
        }

        func replaceAtomically(_ destination: URL, with replacement: URL) throws {
            if failure == .replacement { throw SyntheticExportError.replacement }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
            } else {
                try FileManager.default.moveItem(at: replacement, to: destination)
            }
        }

        func removeIfPresent(_ url: URL) throws {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func testExportPreservesExistingDestinationAndCleansStagingFileAfterEveryFailure() async throws {
        for failure in [SyntheticExportError.copy, .verification, .replacement] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try Data("new source".utf8).write(to: source)
            try Data("old destination".utf8).write(to: destination)

            do {
                try await AtomicFileExporter(operations: Operations(failure: failure)).export(source: source, to: destination)
                XCTFail("Expected \(failure)")
            } catch {
                XCTAssertEqual(error as? SyntheticExportError, failure)
            }
            XCTAssertEqual(try Data(contentsOf: destination), Data("old destination".utf8))
            XCTAssertTrue(try siblingTemporaryFiles(of: destination).isEmpty)
        }
    }

    func testSuccessfulExportReplacesDestinationWithVerifiedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let sourceData = Data((0..<4096).map { UInt8($0 % 251) })
        try sourceData.write(to: source)
        try Data("old destination".utf8).write(to: destination)

        try await AtomicFileExporter(operations: Operations()).export(source: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), sourceData)
        XCTAssertTrue(try siblingTemporaryFiles(of: destination).isEmpty)
    }

    private func siblingTemporaryFiles(of destination: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".evee-export-") }
    }
}
