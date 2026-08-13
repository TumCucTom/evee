import Foundation

/// A synchronous-producer, single-consumer mailbox that keeps the newest values.
///
/// Only one call to `next()` may be suspended at a time. Starting a second
/// suspended read is a programmer error and traps in debug builds.
public final class BoundedAudioMailbox<Element: Sendable>: @unchecked Sendable {
    public enum CloseMode: Sendable {
        case drain
        case discard
    }

    private let lock = NSLock()
    private var storage: [Element?]
    private var readIndex = 0
    private var storedCount = 0
    private var maximumDepth = 0
    private var overwrittenCount = 0
    private var isClosed = false
    private var waiter: CheckedContinuation<Element?, Never>?

    public init(capacity: Int) {
        precondition(capacity >= 1, "BoundedAudioMailbox capacity must be at least one")
        storage = Array(repeating: nil, count: capacity)
    }

    /// Publishes without an actor hop. Sending after close has no effect.
    public func send(_ element: Element) {
        let suspendedConsumer: CheckedContinuation<Element?, Never>?

        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if let waiter {
            suspendedConsumer = waiter
            self.waiter = nil
        } else {
            suspendedConsumer = nil
            if storedCount == storage.count {
                storage[readIndex] = element
                readIndex = (readIndex + 1) % storage.count
                overwrittenCount += 1
            } else {
                let writeIndex = (readIndex + storedCount) % storage.count
                storage[writeIndex] = element
                storedCount += 1
                maximumDepth = max(maximumDepth, storedCount)
            }
        }
        lock.unlock()

        suspendedConsumer?.resume(returning: element)
    }

    /// Returns the next retained value, or `nil` after the mailbox closes and drains.
    /// Only one caller may wait here at a time.
    public func next() async -> Element? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if storedCount > 0 {
                let element = removeFirstLocked()
                lock.unlock()
                continuation.resume(returning: element)
                return
            }
            if isClosed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            precondition(waiter == nil, "BoundedAudioMailbox supports one suspended consumer")
            waiter = continuation
            lock.unlock()
        }
    }

    /// Closes the mailbox. The first close determines whether retained values drain.
    public func close(mode: CloseMode) {
        let suspendedConsumer: CheckedContinuation<Element?, Never>?

        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        if mode == .discard {
            discardAllLocked()
        }
        suspendedConsumer = waiter
        waiter = nil
        lock.unlock()

        suspendedConsumer?.resume(returning: nil)
    }

    public var depth: Int {
        lock.withLock { storedCount }
    }

    public var peakDepth: Int {
        lock.withLock { maximumDepth }
    }

    public var droppedCount: Int {
        lock.withLock { overwrittenCount }
    }

    private func removeFirstLocked() -> Element {
        let element = storage[readIndex]!
        storage[readIndex] = nil
        readIndex = (readIndex + 1) % storage.count
        storedCount -= 1
        return element
    }

    private func discardAllLocked() {
        for index in storage.indices { storage[index] = nil }
        readIndex = 0
        storedCount = 0
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
