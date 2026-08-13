import Foundation

public protocol WakePhraseListening: Sendable {
    var transcripts: AsyncStream<String> { get }
    func start(deviceUID: String?, lowLatency: Bool) async throws
    func stop() async
}
