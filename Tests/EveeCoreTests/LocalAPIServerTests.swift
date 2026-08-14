import Darwin
import XCTest
@testable import EveeCore

final class LocalAPIServerTests: XCTestCase {
    func testPublicRecordExcludesPrivatePersistenceFields() throws {
        let privateRecord = WorkspaceRecord(
            kind: .meeting,
            title: "Synthetic",
            text: "Visible",
            rawText: "Private raw",
            audioRelativePath: "Audio/private.caf",
            recoverySourceID: UUID(),
            context: WorkspaceContext(selectedText: "Private selection")
        )

        let encoded = try JSONEncoder().encode(PublicWorkspaceRecord(privateRecord))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(json.contains("Visible"))
        XCTAssertFalse(json.contains("private.caf"))
        XCTAssertFalse(json.contains("Private raw"))
        XCTAssertFalse(json.contains("Private selection"))
        XCTAssertFalse(json.contains("recoverySourceID"))
        XCTAssertFalse(json.contains("webhookDeliveries"))
        XCTAssertFalse(json.contains("context"))
    }

    func testRevocationReplacesTokenBeforeFailedDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let secrets = FailingDeleteSecretStore(value: "old-revoked-token")
        let server = LocalAPIServer(store: store, secretStore: secrets)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        _ = try await server.startWithCredentials(port: try availablePort())
        XCTAssertThrowsError(try server.revokeToken())

        let restarted = LocalAPIServer(store: store, secretStore: secrets)
        defer { restarted.stop() }
        let credentials = try await restarted.startWithCredentials(port: try availablePort())
        XCTAssertNotEqual(credentials.token, "old-revoked-token")
    }

    func testCancelledStartCannotPublishCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let secrets = BlockingTestSecretStore(value: "synthetic-token")
        let server = LocalAPIServer(store: store, secretStore: secrets)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let start = Task { try await server.startWithCredentials(port: try availablePort()) }
        let readStarted = await secrets.waitForRead()
        XCTAssertTrue(readStarted)
        start.cancel()
        secrets.resumeRead()

        do {
            _ = try await start.value
            XCTFail("A cancelled start published credentials")
        } catch is CancellationError {
            XCTAssertNil(server.credentials())
        }
    }
}

private final class FailingDeleteSecretStore: LocalAPISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(value: String?) {
        self.value = value
    }

    func string(for account: String) throws -> String? { lock.withLock { value } }
    func set(_ value: String, for account: String) throws { lock.withLock { self.value = value } }
    func delete(_ account: String) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class BlockingTestSecretStore: LocalAPISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var value: String?
    private var readStarted = false

    init(value: String?) {
        self.value = value
    }

    func string(for account: String) throws -> String? {
        lock.withLock { readStarted = true }
        release.wait()
        return lock.withLock { value }
    }

    func set(_ value: String, for account: String) throws { lock.withLock { self.value = value } }
    func delete(_ account: String) throws { lock.withLock { value = nil } }

    func waitForRead() async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ readStarted }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func resumeRead() { release.signal() }
}

private func availablePort() throws -> UInt16 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw CocoaError(.fileNoSuchFile) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else { throw CocoaError(.fileNoSuchFile) }
    return UInt16(bigEndian: address.sin_port)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
