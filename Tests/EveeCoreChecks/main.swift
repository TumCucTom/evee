@_spi(Testing) import EveeCore
@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation
import Network

private enum CoreCheckError: Error {
    case assertionFailed(String)
    case connectionFailed(String)
    case listenerFailed(String)
    case timedOut
}

private enum SyntheticSecretStoreError: Error {
    case deletionFailed
}

private enum SyntheticWebhookPersistenceError: Error {
    case rejected
}

private enum SyntheticMCPPersistenceError: Error {
    case rejected
    case restoreRejected
}

private enum SyntheticModelReadinessError: Error {
    case invalidCache
}

private enum SyntheticExportFailure: Error {
    case verification
}

private struct SyntheticFailingExportOperations: FileExportOperations {
    func copy(_ source: URL, _ destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func verifySameBytes(_ source: URL, _ destination: URL) throws {
        throw SyntheticExportFailure.verification
    }

    func replaceAtomically(_ destination: URL, with replacement: URL) throws {
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

private actor SyntheticRepairableModelProvider: LocalModelDownloading {
    nonisolated var isDownloaded: Bool { true }
    private var repaired = false
    private(set) var downloadCount = 0
    private(set) var loadCount = 0

    func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        downloadCount += 1
        repaired = true
    }

    func load() async throws {
        loadCount += 1
        if !repaired { throw SyntheticModelReadinessError.invalidCache }
    }
}

@MainActor
private final class SyntheticTerminationCheckpoint: CaptureCheckpointing {
    private let operation: @MainActor () async throws -> Void
    private(set) var callCount = 0

    init(operation: @escaping @MainActor () async throws -> Void) {
        self.operation = operation
    }

    func checkpointForTermination() async throws {
        callCount += 1
        try await operation()
    }
}

@MainActor
private final class SyntheticGenerationCheckpoint: CaptureCheckpointing {
    private(set) var terminationWorkGeneration: UInt64 = 0
    private(set) var callCount = 0

    func prepareForTerminationCheckpoint() -> UInt64 { terminationWorkGeneration }
    func checkpointForTermination() async throws { callCount += 1 }
    func beginNewWork() { terminationWorkGeneration &+= 1 }
}

@MainActor
private final class SuspendedGenerationCheckpoint: CaptureCheckpointing {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var terminationWorkGeneration: UInt64 = 0
    private(set) var callCount = 0
    private(set) var activeCallCount = 0
    private(set) var maximumActiveCallCount = 0
    func prepareForTerminationCheckpoint() -> UInt64 { terminationWorkGeneration }
    func checkpointForTermination() async throws {
        callCount += 1
        activeCallCount += 1
        maximumActiveCallCount = max(maximumActiveCallCount, activeCallCount)
        defer { activeCallCount -= 1 }
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func beginNewWork() { terminationWorkGeneration &+= 1 }
    func succeed() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor SyntheticOperationGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private actor SyntheticCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}

@MainActor
private final class SyntheticClipboard {
    private(set) var value = "original"
    private(set) var revision = 0
    private(set) var restoreCount = 0
    func writeTemporaryValue() { value = "temporary"; revision += 1 }
    func restoreSnapshot() { value = "original"; revision += 1; restoreCount += 1 }
}

private final class BlockingSecretStore: LocalAPISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let enteredRead = DispatchSemaphore(value: 0)
    private let releaseRead = DispatchSemaphore(value: 0)
    private var value: String?
    private let failsDeletion: Bool

    init(value: String?, failsDeletion: Bool = false) {
        self.value = value
        self.failsDeletion = failsDeletion
    }

    func string(for account: String) throws -> String? {
        enteredRead.signal()
        releaseRead.wait()
        return lock.withLock { value }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock { self.value = value }
    }

    func delete(_ account: String) throws {
        if failsDeletion { throw SyntheticSecretStoreError.deletionFailed }
        lock.withLock { value = nil }
    }

    func waitForRead() -> Bool {
        enteredRead.wait(timeout: .now() + 2) == .success
    }

    func resumeRead() {
        releaseRead.signal()
    }
}

private final class MemorySecretStore: LocalAPISecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private let failsDeletion: Bool

    init(value: String?, failsDeletion: Bool = false) {
        self.value = value
        self.failsDeletion = failsDeletion
    }

    func string(for account: String) throws -> String? {
        lock.withLock { value }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock { self.value = value }
    }

    func delete(_ account: String) throws {
        if failsDeletion { throw SyntheticSecretStoreError.deletionFailed }
        lock.withLock { value = nil }
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private actor SyntheticLiveAudioRecognizer: LiveAudioRecognizing {
    nonisolated let transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>
    private nonisolated let updateContinuation: AsyncStream<SlidingWindowTranscriptionUpdate>.Continuation
    private var audioWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockAudio = false
    private(set) var receivedBufferCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private let finalText: String

    init(finalText: String = "Synthetic final transcript") {
        self.finalText = finalText
        let pair = AsyncStream<SlidingWindowTranscriptionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(4))
        transcriptionUpdates = pair.stream
        updateContinuation = pair.continuation
    }

    func setAudioBlocked(_ blocked: Bool) {
        shouldBlockAudio = blocked
        guard !blocked else { return }
        let waiters = audioWaiters
        audioWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func streamAudio(_ buffer: AVAudioPCMBuffer) async {
        receivedBufferCount += 1
        if shouldBlockAudio {
            await withCheckedContinuation { audioWaiters.append($0) }
        }
    }

    func finish() async throws -> String {
        finishCount += 1
        updateContinuation.finish()
        return finalText
    }

    func cancel() async {
        cancelCount += 1
        setAudioBlocked(false)
        updateContinuation.finish()
    }
}

private final class SuspendedCoreCheckURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var suspended: SuspendedCoreCheckURLProtocol?
    private static var capturedRequest: URLRequest?
    private static var startedHandler: (@Sendable (URLRequest) -> Void)?

    static func prepare(started: @escaping @Sendable (URLRequest) -> Void) {
        lock.lock()
        suspended = nil
        capturedRequest = nil
        startedHandler = started
        lock.unlock()
    }

    static func release() {
        lock.lock()
        let current = suspended
        suspended = nil
        capturedRequest = nil
        startedHandler = nil
        lock.unlock()
        guard let current,
              let response = HTTPURLResponse(
                url: current.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else { return }
        current.client?.urlProtocol(current, didReceive: response, cacheStoragePolicy: .notAllowed)
        current.client?.urlProtocol(current, didLoad: Data("{}".utf8))
        current.client?.urlProtocolDidFinishLoading(current)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        capturedRequest = requestWithReadableBody(request)
        lock.unlock()
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.suspended = self
        let handler = Self.startedHandler
        let captured = Self.capturedRequest ?? request
        Self.lock.unlock()
        handler?(captured)
    }

    override func stopLoading() {
        // The response is released after task cancellation to exercise a stale
        // local transport callback without opening an external connection.
    }

    private static func requestWithReadableBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        var captured = request
        captured.httpBody = body
        return captured
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CoreCheckError.assertionFailed(message) }
}

private func requireThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        return
    }
    throw CoreCheckError.assertionFailed(message)
}

private func unwrapped<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw CoreCheckError.assertionFailed(message) }
    return value
}

private func checkActionContrast() throws {
    var minimumEnabledContrast = Double.greatestFiniteMagnitude
    for appearance in InterfaceAppearance.allCases {
        let foreground = EveeVisualPalette.rgb(.primaryActionForeground, appearance: appearance)
        for stop in AccessibleActionPalette.gradientStops(for: appearance) {
            let ratio = foreground.contrastRatio(with: stop)
            try require(ratio >= 4.5, "\(appearance) action stop contrast was \(ratio)")
            minimumEnabledContrast = min(minimumEnabledContrast, ratio)
        }
        let disabledRatio = AccessibleActionPalette.disabledBorder.contrastRatio(
            with: AccessibleActionPalette.paper(for: appearance)
        )
        try require(disabledRatio >= 3, "\(appearance) disabled border contrast was \(disabledRatio)")
    }
    let formattedMinimum = String(format: "%.2f", minimumEnabledContrast)
    print("action-contrast: passed (minimum enabled \(formattedMinimum):1)")
}

private func checkVisualPresentation() throws {
    for appearance in InterfaceAppearance.allCases {
        let canvas = EveeVisualPalette.rgb(.canvas, appearance: appearance)
        let surface = EveeVisualPalette.rgb(.surface, appearance: appearance)
        try require(
            EveeVisualPalette.rgb(.primaryText, appearance: appearance).contrastRatio(with: canvas) >= 4.5,
            "\(appearance) primary text does not meet AA against canvas"
        )
        try require(
            EveeVisualPalette.rgb(.secondaryText, appearance: appearance).contrastRatio(with: surface) >= 4.5,
            "\(appearance) secondary text does not meet AA against surface"
        )
        try require(
            EveeVisualPalette.rgb(.accent, appearance: appearance).contrastRatio(with: surface) >= 3,
            "\(appearance) accent does not meet non-text contrast against surface"
        )
    }

    try require(VoiceThreadPresentation.make(phase: .recording, level: -1).level == 0, "voice level was not clamped low")
    try require(VoiceThreadPresentation.make(phase: .recording, level: 2).level == 1, "voice level was not clamped high")
    try require(VoiceThreadPresentation.make(phase: .recording, level: nil).level == 0.08, "missing listening level was not quiet")
    try require(VoiceThreadPresentation.make(phase: .processing, level: 1).mode == .processing, "processing phase had the wrong voice mode")
    try require(VoiceThreadPresentation.make(phase: .protected, level: nil).mode == .resolved, "protected phase had the wrong voice mode")

    let reducedMotion = EveeMotionPolicy(reduceMotion: true)
    let standardMotion = EveeMotionPolicy(reduceMotion: false)
    try require(reducedMotion.duration(for: .route) == 0, "reduced motion retained route duration")
    try require(reducedMotion.duration(for: .voiceSettlement) == 0, "reduced motion retained voice-settlement duration")
    try require(standardMotion.duration(for: .selection) == 0.2, "selection duration changed")
    try require(standardMotion.duration(for: .route) == 0.26, "route duration changed")

    let enabledDestructiveButton = EveeButtonStatePresentation.destructive(isEnabled: true)
    let disabledDestructiveButton = EveeButtonStatePresentation.destructive(isEnabled: false)
    try require(!enabledDestructiveButton.showsDisabledBoundary, "enabled destructive button showed disabled boundary")
    try require(disabledDestructiveButton.showsDisabledBoundary, "disabled destructive button lacked redundant boundary")
    try require(disabledDestructiveButton.opacity < enabledDestructiveButton.opacity, "disabled destructive button opacity did not change")
    try require(disabledDestructiveButton.saturation < enabledDestructiveButton.saturation, "disabled destructive button saturation did not change")

    try require(
        EveeSettingsCategory.allCases == [.voice, .writing, .meetings, .privacyAndStorage, .integrations, .application],
        "settings categories changed"
    )
    print("visual-presentation: passed")
}

private func checkOnboardingPresentation() throws {
    let denied = OnboardingPresentation(
        microphone: .denied,
        accessibility: .granted,
        model: .idle
    )
    try require(denied.focusTarget == .microphoneRecovery, "denied microphone did not focus recovery")
    try require(denied.microphoneActionTitle == "Open Microphone Settings", "denied microphone repeated permission request")

    let downloading = OnboardingPresentation(
        microphone: .granted,
        accessibility: .granted,
        model: .downloading(fraction: 0.42, status: "Downloading")
    )
    try require(downloading.modelAction == .cancel, "download did not expose cancel as its only action")
    try require(downloading.modelAccessibilityValue == "42 percent, Downloading", "download status was not explicit")

    let failed = OnboardingPresentation(
        microphone: .granted,
        accessibility: .granted,
        model: .failed("The previous model download did not finish.")
    )
    try require(failed.modelAction == .retry, "interrupted download did not expose retry")
    try require(OnboardingLayoutMode.forViewportHeight(640) == .compact, "short viewport did not choose compact onboarding")
    try require(OnboardingLayoutMode.forViewportHeight(720) == .spacious, "tall viewport did not choose spacious onboarding")
    try require(
        downloading.focusRestorationTarget(previousModelAction: .download) == .modelAction,
        "download-to-cancel transition did not restore stable model focus"
    )
    try require(
        failed.focusRestorationTarget(previousModelAction: .none) == .modelAction,
        "cancelling-to-retry transition did not restore stable model focus"
    )
    print("onboarding-presentation: passed")
}

private func checkOnboardingActionAccessibility() throws {
    let states: [(OnboardingModelState, ModelOnboardingAction, String, String)] = [
        (.idle, .download, "Download local model", "Not downloaded"),
        (.downloading(fraction: 0.42, status: "Downloading"), .cancel, "Cancel local model download", "42 percent, Downloading"),
        (.cancelling, .none, "Cancelling local model download", "Cancelling"),
        (.failed("Interrupted"), .retry, "Retry local model download", "Interrupted"),
    ]

    for (modelState, expectedAction, expectedLabel, expectedValue) in states {
        let presentation = OnboardingPresentation(
            microphone: .granted,
            accessibility: .granted,
            model: modelState
        )
        try require(presentation.modelAction == expectedAction, "model state exposed the wrong action")
        try require(presentation.modelAccessibilityLabel == expectedLabel, "model action lacked an accessible name")
        try require(presentation.modelAccessibilityValue == expectedValue, "model action exposed the wrong accessible value")
    }

    let viewURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/EveeApp/UI/OnboardingView.swift")
    let source = try String(contentsOf: viewURL, encoding: .utf8)
    guard let actionStart = source.range(of: "    private var modelActionButton: some View {")?.lowerBound,
          let actionEnd = source.range(of: "    private var onboardingModelState: OnboardingModelState {")?.lowerBound else {
        throw CoreCheckError.assertionFailed("could not inspect the onboarding model action")
    }

    let actionSource = String(source[actionStart..<actionEnd])
    guard actionSource.contains("NativeOnboardingActionButton("),
          actionSource.contains("title: presentation.modelActionTitle ?? \"Download\""),
          actionSource.contains("accessibilityLabel: presentation.modelAccessibilityLabel"),
          actionSource.contains("accessibilityHelp: presentation.modelAccessibilityHint"),
          actionSource.contains("isEnabled: store.microphonePermissionGranted && store.accessibilityPermissionGranted"),
          actionSource.contains("action: activateModelAction"),
          actionSource.contains(".focused($focusedTarget, equals: .modelAction)"),
          actionSource.contains("store.startModelDownload()"),
          actionSource.contains("store.cancelModelDownload()"),
          !actionSource.contains(".accessibilityRepresentation") else {
        throw CoreCheckError.assertionFailed("model action is not hosted by the native AppKit button")
    }

    guard source.contains("Text(presentation.modelAccessibilityValue ?? \"\")"),
          source.contains(".accessibilityLabel(\"Local model download status\")") else {
        throw CoreCheckError.assertionFailed("model action does not preserve a separate named download status")
    }

    guard let bridgeStart = source.range(
        of: "private struct NativeOnboardingActionButton: NSViewRepresentable {"
    )?.lowerBound else {
        throw CoreCheckError.assertionFailed("native onboarding action bridge is missing")
    }
    let bridgeSource = String(source[bridgeStart...])
    let updateCallCount = bridgeSource.components(
        separatedBy: "configure(button, coordinator: context.coordinator)"
    ).count - 1
    guard bridgeSource.contains("func makeNSView(context: Context) -> NSButton"),
          bridgeSource.contains("func updateNSView(_ button: NSButton, context: Context)"),
          updateCallCount == 2,
          bridgeSource.contains("button.title = title"),
          bridgeSource.contains("button.setAccessibilityLabel(accessibilityLabel)"),
          bridgeSource.contains("button.setAccessibilityHelp(accessibilityHelp)"),
          bridgeSource.contains("button.isEnabled = isEnabled"),
          bridgeSource.contains("coordinator.action = action"),
          bridgeSource.contains("let action: @MainActor () -> Void"),
          bridgeSource.contains("action: #selector(Coordinator.activate(_:))"),
          bridgeSource.contains("@objc func activate(_ sender: NSButton)"),
          bridgeSource.contains("action()") else {
        throw CoreCheckError.assertionFailed(
            "native onboarding action does not update its title, accessibility metadata, enabled state, and MainActor action"
        )
    }
    print("onboarding-action-accessibility: passed")
}

private func checkShortcutDefaults() throws {
    let appStoreURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/EveeApp/AppStore.swift")
    let source = try String(contentsOf: appStoreURL, encoding: .utf8)

    try require(
        source.contains("static let pushToTalk = Self(\"pushToTalk\", default: .init(.space, modifiers: [.command, .shift]))"),
        "push-to-talk does not use the non-reserved default"
    )
    try require(
        !source.contains("static let pushToTalk = Self(\"pushToTalk\", default: .init(.space, modifiers: [.command, .option]))"),
        "push-to-talk still collides with the macOS Finder search shortcut"
    )
    print("shortcut-defaults: passed")
}

private func checkMenuWindowRecovery() throws {
    let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let menuSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Sources/EveeApp/UI/MenuBarView.swift"),
        encoding: .utf8
    )

    try require(
        menuSource.contains("$0.title == \"Evee\" && $0.styleMask.contains(.titled)") &&
            menuSource.contains("NSApp.mainMenu") &&
            menuSource.contains("item.keyEquivalent.lowercased() == \"n\"") &&
            menuSource.contains("menu.performActionForItem(at: index)"),
        "the menu-bar action cannot recreate a closed main window"
    )
    print("menu-window-recovery: passed")
}

private func checkAccessibilityCopy() throws {
    let syntheticMeeting = WorkspaceRecord(
        kind: .meeting,
        title: "Weekly review",
        text: "Full transcript",
        sourceApplication: "Meet"
    )
    let label = AccessibilityCopy.recordRow(
        record: syntheticMeeting,
        snippet: "…matched decision text…"
    )
    try require(label.contains("matched decision text"), "record row omitted its visible search match")
    try require(AccessibilityCopy.removeAppStyle(named: "Mail") == "Remove writing style for Mail", "app-style removal lacked context")
    try require(AccessibilityCopy.clearSearch == "Clear workspace search", "search clear label lacked context")
    try require(AccessibilityCopy.exportRetainedTrack(named: "Microphone") == "Export retained Microphone audio", "audio export label lacked track context")
    try require(AccessibilityCopy.speakerLabel(start: 125, currentLabel: nil).contains("2 minutes 5 seconds"), "speaker label omitted timestamp")
    let startedAt = Date(timeIntervalSince1970: 1_786_616_100)
    try require(
        AccessibilityCopy.elapsedRecordingTime(startedAt: startedAt, now: startedAt.addingTimeInterval(61)) == "1 minute 1 second elapsed",
        "elapsed recording time omitted its spoken minute/second value"
    )
    try require(
        AccessibilityCopy.elapsedRecordingTime(startedAt: startedAt, now: startedAt.addingTimeInterval(-30)) == "0 seconds elapsed",
        "elapsed recording time did not clamp negative clock skew"
    )
    try require(AccessibilityCopy.helperRevocation.contains("registered clients"), "helper revocation omitted consequence")
    try require(RootLayoutMode.route(.settings, captureState: .idle) == .sidebarAndDetail, "settings retained a wasted detail column")
    try require(RootLayoutMode.route(.library, captureState: .idle) == .threeColumn, "library lost browse/detail layout")

    let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let meetingSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Sources/EveeApp/UI/MeetingWorkspaceView.swift"),
        encoding: .utf8
    )
    let librarySource = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Sources/EveeApp/UI/LibraryView.swift"),
        encoding: .utf8
    )
    let elapsedValueCall = "AccessibilityCopy.elapsedRecordingTime(startedAt: startedAt, now: .now)"
    try require(
        meetingSource.components(separatedBy: elapsedValueCall).count - 1 == 2,
        "meeting elapsed timers do not both expose authoritative accessibility values"
    )
    try require(
        librarySource.components(separatedBy: elapsedValueCall).count - 1 == 1,
        "memo elapsed timer does not expose an authoritative accessibility value"
    )
    print("accessibility-copy: passed")
}

private func checkWebhookGeneration() async throws {
    let deliveryID = UUID(uuidString: "75B09B72-BC3F-4939-9F81-E6B7C814A552")!
    let coordinator = WebhookOutboxCoordinator()
    let token = await coordinator.begin(deliveryID: deliveryID)
    let task = Task<Void, Never> {
        try? await Task.sleep(for: .seconds(30))
    }
    await coordinator.register(task, for: token)

    let activeBeforeCancellation = await coordinator.mayCommit(token)
    let cancelled = await coordinator.cancelAll()
    let activeAfterCancellation = await coordinator.mayCommit(token)

    try require(activeBeforeCancellation, "registered webhook dispatch was not allowed to commit")
    try require(cancelled == [deliveryID], "webhook cancellation did not return the active delivery")
    try require(!activeAfterCancellation, "cancelled webhook dispatch remained able to commit")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(rootURL: root)
    let suspendedDeliveryID = UUID(uuidString: "19CF6CE4-3841-4CF7-9888-679CC63B3364")!
    let destination = URL(string: "https://example.invalid/webhook")!
    var storedRecord = WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Local test")
    let body = try MeetingWebhook.payload(for: storedRecord)
    storedRecord.webhookDeliveries = [WebhookDelivery(
        id: suspendedDeliveryID,
        destination: destination.absoluteString,
        payloadBody: body,
        nextAttemptAt: Date(timeIntervalSince1970: 1_786_616_100)
    )]
    try await store.upsert(storedRecord)

    let started = AsyncStream<URLRequest>.makeStream()
    SuspendedCoreCheckURLProtocol.prepare { request in
        started.continuation.yield(request)
        started.continuation.finish()
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SuspendedCoreCheckURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let suspendedCoordinator = WebhookOutboxCoordinator()
    let suspendedToken = await suspendedCoordinator.begin(deliveryID: suspendedDeliveryID)
    let suspendedTask = Task<Void, Never> {
        do {
            _ = try await MeetingWebhook(session: session).sendWithStatus(
                record: storedRecord,
                destination: destination,
                secret: "synthetic-secret",
                deliveryID: suspendedDeliveryID,
                maxAttempts: 1,
                payloadBody: body
            )
            if await suspendedCoordinator.mayCommit(suspendedToken),
               var current = try await store.record(id: storedRecord.id),
               let index = current.webhookDeliveries.firstIndex(where: { $0.id == suspendedDeliveryID }) {
                current.webhookDeliveries[index].state = .delivered
                try await store.upsert(current)
            }
        } catch {
            if await suspendedCoordinator.mayCommit(suspendedToken),
               var current = try? await store.record(id: storedRecord.id),
               let index = current.webhookDeliveries.firstIndex(where: { $0.id == suspendedDeliveryID }) {
                current.webhookDeliveries[index].state = .failed
                try? await store.upsert(current)
            }
        }
        await suspendedCoordinator.finish(suspendedToken)
    }
    await suspendedCoordinator.register(suspendedTask, for: suspendedToken)

    let request = try await withTimeout(seconds: 2, onTimeout: { session.invalidateAndCancel() }) {
        var iterator = started.stream.makeAsyncIterator()
        guard let request = await iterator.next() else { throw CoreCheckError.timedOut }
        return request
    }
    try require(request.httpBody == body, "webhook transport did not send the stored payload bytes")

    _ = await suspendedCoordinator.cancelAll()
    let persistedBeforeCancellation = try await store.record(id: storedRecord.id)
    guard var cancelledRecord = persistedBeforeCancellation,
          let cancelledIndex = cancelledRecord.webhookDeliveries.firstIndex(where: { $0.id == suspendedDeliveryID }) else {
        throw CoreCheckError.assertionFailed("synthetic webhook row was not stored")
    }
    cancelledRecord.webhookDeliveries[cancelledIndex].state = .cancelled
    cancelledRecord.webhookDeliveries[cancelledIndex].retryable = false
    cancelledRecord.webhookDeliveries[cancelledIndex].nextAttemptAt = nil
    cancelledRecord.webhookDeliveries[cancelledIndex].payloadBody = nil
    try await store.upsert(cancelledRecord)
    SuspendedCoreCheckURLProtocol.release()
    await suspendedTask.value

    let persistedAfterLateResponse = try await store.record(id: storedRecord.id)
    guard let final = persistedAfterLateResponse?.webhookDeliveries.first(where: { $0.id == suspendedDeliveryID }) else {
        throw CoreCheckError.assertionFailed("synthetic webhook row disappeared")
    }
    try require(final.state == .cancelled, "late webhook response replaced terminal cancellation")
    try require(!final.retryable && final.nextAttemptAt == nil, "cancelled webhook remained retryable")
    try require(final.payloadBody == nil, "cancelled webhook retained payload bytes")
    print("webhook-generation: passed")
}

private func checkWebhookSignature() throws {
    let body = Data("{\"meeting\":\"synthetic\"}".utf8)
    let deliveryID = UUID(uuidString: "D5881780-29A4-4D3A-84A6-3FB7DD77CA94")!
    let timestamp = "2026-08-13T10:15:00Z"
    let first = MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: deliveryID,
        timestamp: timestamp
    )

    try require(first != MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: UUID(uuidString: "3E165D7B-D650-420D-9537-B86CB074074C")!,
        timestamp: timestamp
    ), "webhook signature omitted the delivery identifier")
    try require(first != MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.updated",
        deliveryID: deliveryID,
        timestamp: timestamp
    ), "webhook signature omitted the event")
    try require(first != MeetingWebhook.signature(
        body: body,
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: deliveryID,
        timestamp: "2026-08-13T10:15:01Z"
    ), "webhook signature omitted the timestamp")
    try require(first != MeetingWebhook.signature(
        body: Data("{\"meeting\":\"changed\"}".utf8),
        secret: "synthetic-secret",
        event: "meeting.completed",
        deliveryID: deliveryID,
        timestamp: timestamp
    ), "webhook signature omitted the body")
    print("webhook-signature: passed")
}

private func checkWebhookPayload() throws {
    let recoveryID = UUID(uuidString: "EBBDA6A3-47DF-42A2-BD44-8A6DE8C12B8D")!
    let recordID = UUID(uuidString: "2C89F637-C572-4395-83FE-C9434685FD36")!
    let createdAt = Date(timeIntervalSince1970: 1_786_616_400)
    let updatedAt = Date(timeIntervalSince1970: 1_786_616_460)
    let segmentID = UUID(uuidString: "08F9AE87-7CF3-491D-8A52-7472A69C3377")!
    let record = WorkspaceRecord(
        id: recordID,
        kind: .meeting,
        createdAt: createdAt,
        updatedAt: updatedAt,
        title: "Synthetic review",
        text: "Allowlisted transcript",
        rawText: "PRIVATE-RAW-SENTINEL",
        sourceApplication: "Synthetic Meetings",
        audioRelativePath: "PRIVATE-AUDIO-PATH.caf",
        audioTracks: [WorkspaceAudioTrack(
            role: .system,
            relativePath: "PRIVATE-SYSTEM-TRACK.caf"
        )],
        duration: 60,
        segments: [TranscriptSegment(
            id: segmentID,
            start: 1,
            end: 3,
            speaker: "Speaker 1",
            text: "Evidence-backed segment"
        )],
        notes: "Synthetic notes",
        tags: ["review"],
        webhookDeliveries: [WebhookDelivery(
            destination: "https://example.invalid/private-webhook-state"
        )],
        recoverySourceID: recoveryID,
        operation: .selectionTransform,
        context: WorkspaceContext(
            windowTitle: "PRIVATE-WINDOW-CONTEXT",
            selectedText: "PRIVATE-SELECTION-CONTEXT"
        )
    )

    let body = try MeetingWebhook.payload(for: record)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(MeetingWebhookPayload.self, from: body)
    try require(decoded.schema == MeetingWebhookPayload.schemaIdentifier, "meeting webhook payload omitted its schema")
    try require(decoded.version == MeetingWebhookPayload.currentVersion, "meeting webhook payload omitted its version")
    try require(decoded.meetingID == recordID, "meeting webhook payload changed the record identifier")
    try require(decoded.transcript == "Allowlisted transcript", "meeting webhook payload omitted the transcript")
    try require(decoded.segments.map(\.id) == [segmentID], "meeting webhook payload omitted meeting segments")
    try require(MeetingWebhook.isCurrentPayload(body), "new meeting webhook bytes were not recognized as current")

    let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let expectedKeys: Set<String> = [
        "schema", "version", "meetingID", "createdAt", "updatedAt", "title",
        "transcript", "sourceApplication", "duration", "segments", "notes", "tags",
    ]
    try require(Set(object.keys) == expectedKeys, "meeting webhook payload fields were not an exact allowlist: \(object.keys.sorted())")
    let text = String(decoding: body, as: UTF8.self)
    for sentinel in [
        "PRIVATE-RAW-SENTINEL", "PRIVATE-AUDIO-PATH.caf", "PRIVATE-SYSTEM-TRACK.caf",
        recoveryID.uuidString, "selectionTransform", "PRIVATE-WINDOW-CONTEXT",
        "PRIVATE-SELECTION-CONTEXT", "private-webhook-state",
    ] {
        try require(!text.contains(sentinel), "meeting webhook payload leaked \(sentinel)")
    }
    let legacyBody = try JSONEncoder().encode(record)
    try require(!MeetingWebhook.isCurrentPayload(legacyBody), "legacy full-record payload was accepted as current")
    try require(!MeetingWebhook.isCurrentPayload(Data("{\"schema\":\"evee.meeting.completed\",\"version\":999}".utf8)), "unknown webhook payload version was accepted")

    print("webhook-payload: passed")
}

private func checkWebhookLegacyRows() async throws {
    let destination = "https://example.invalid/webhook"
    let now = Date(timeIntervalSince1970: 1_786_616_800)
    let nilID = UUID(uuidString: "427AD9DC-B219-44C7-8A0A-C3FF49798231")!
    let privateID = UUID(uuidString: "FC0A8397-6B2C-4744-AF6D-D6A1FA0D37A9")!
    let currentID = UUID(uuidString: "F0D174D0-816C-4C4F-96F9-C1FAB6D5F19E")!
    var record = WorkspaceRecord(
        id: UUID(uuidString: "6A6F69A9-FEE5-44FD-802D-D54BA73C3DB0")!,
        kind: .meeting,
        createdAt: Date(timeIntervalSince1970: 1_786_616_000),
        updatedAt: Date(timeIntervalSince1970: 1_786_616_100),
        title: "Synthetic migration",
        text: "Allowlisted transcript",
        rawText: "PRIVATE-LEGACY-RAW",
        audioRelativePath: "PRIVATE-LEGACY-AUDIO.caf"
    )
    let fullRecordBody = try JSONEncoder().encode(record)
    let currentBody = try MeetingWebhook.payload(for: record)
    record.webhookDeliveries = [
        WebhookDelivery(
            id: nilID,
            destination: destination,
            state: .pending,
            payloadBody: nil,
            retryable: true
        ),
        WebhookDelivery(
            id: privateID,
            destination: destination,
            state: .failed,
            payloadBody: fullRecordBody,
            retryable: true,
            nextAttemptAt: now.addingTimeInterval(-1)
        ),
        WebhookDelivery(
            id: currentID,
            destination: destination,
            state: .failed,
            payloadBody: currentBody,
            retryable: true,
            nextAttemptAt: now.addingTimeInterval(-1)
        ),
    ]

    let transactions = WebhookOutboxTransactions()
    let automatic = transactions.automaticRetryDeliveries(
        records: [record],
        destination: destination,
        at: now
    )
    try require(automatic == [WebhookDeliveryReference(recordID: record.id, deliveryID: currentID)], "automatic retry included a nil or legacy payload")

    let retired = transactions.retireUnsupportedPayloads(records: [record], at: now)
    let migrated = try unwrapped(retired.first, "legacy webhook migration did not produce a record")
    let migratedNil = try unwrapped(migrated.webhookDeliveries.first(where: { $0.id == nilID }), "nil legacy row disappeared")
    let migratedPrivate = try unwrapped(migrated.webhookDeliveries.first(where: { $0.id == privateID }), "private legacy row disappeared")
    let migratedCurrent = try unwrapped(migrated.webhookDeliveries.first(where: { $0.id == currentID }), "current row disappeared")
    for delivery in [migratedNil, migratedPrivate] {
        try require(delivery.state == .cancelled, "legacy webhook row was not terminally retired")
        try require(!delivery.retryable && delivery.nextAttemptAt == nil, "legacy webhook row remained retryable")
        try require(delivery.payloadBody == nil, "legacy webhook row retained payload bytes")
        try require(delivery.requiresExplicitReplacement, "legacy webhook row did not retain an explicit replacement action")
    }
    try require(migratedCurrent.state == .failed && migratedCurrent.payloadBody == currentBody, "migration changed a current payload")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("evee-webhook-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(rootURL: root)
    try await store.upsert(migrated)
    let relaunched = try await store.loadRecords()
    try require(transactions.retireUnsupportedPayloads(records: relaunched, at: now.addingTimeInterval(30)).isEmpty, "relaunch repeatedly migrated terminal legacy rows")
    try require(transactions.automaticRetryDeliveries(records: relaunched, destination: destination, at: now).map(\.deliveryID) == [currentID], "relaunch made a legacy row automatically actionable")

    let freshID = UUID(uuidString: "CB3818DB-0648-4198-976A-67259E28E570")!
    var retrySource = record
    retrySource.webhookDeliveries = [record.webhookDeliveries[0]]
    let retry = transactions.prepareManualRetry(
        records: [retrySource],
        destination: destination,
        at: now,
        makeDeliveryID: { freshID }
    )
    let retryRecord = try unwrapped(retry.records.first, "legacy explicit retry did not produce an atomic record update")
    try require(retryRecord.webhookDeliveries.count == 2, "legacy explicit retry did not keep the terminal audit row")
    let retiredOld = try unwrapped(retryRecord.webhookDeliveries.first(where: { $0.id == nilID }), "legacy explicit retry rewrote the old identifier")
    let fresh = try unwrapped(retryRecord.webhookDeliveries.first(where: { $0.id == freshID }), "legacy explicit retry did not create a fresh identifier")
    try require(retiredOld.state == .cancelled && retiredOld.payloadBody == nil && !retiredOld.retryable && !retiredOld.requiresExplicitReplacement, "legacy explicit retry did not terminally retire the old row")
    try require(fresh.state == .pending && fresh.retryable, "legacy explicit retry did not create an actionable row")
    let expectedFreshBody = try MeetingWebhook.payload(for: retrySource)
    try require(fresh.payloadBody == expectedFreshBody, "legacy explicit retry did not queue exact allowlisted bytes")
    try require(retry.deliveries == [WebhookDeliveryReference(recordID: retrySource.id, deliveryID: freshID)], "legacy explicit retry dispatched the old identifier")

    let persistence = await transactions.persistAll(retry.records) { proposed in
        try await store.upsert(proposed)
    }
    try require(persistence.failures.isEmpty, "legacy retry atomic snapshot failed to persist")
    let persisted = try await store.record(id: retrySource.id)
    try require(persisted?.webhookDeliveries.map(\.id) == [nilID, freshID], "legacy retry transitions were not persisted together")

    print("webhook-legacy: passed")
}

@MainActor
private func checkTerminationCheckpoint() async throws {
    var suspendedRecoveryGate = TerminationWorkGate()
    let suspendedRecoveryGeneration = suspendedRecoveryGate.prepareCheckpoint()
    try require(!suspendedRecoveryGate.beginWork(), "recovery began during a suspended checkpoint")
    try require(suspendedRecoveryGate.generation == suspendedRecoveryGeneration, "rejected recovery changed termination generation")
    var availableRecoveryGate = TerminationWorkGate()
    let recoveryGeneration = availableRecoveryGate.generation
    try require(availableRecoveryGate.beginWork(), "recovery was rejected without a checkpoint")
    try require(availableRecoveryGate.generation > recoveryGeneration, "accepted recovery did not advance termination generation")
    let admittedRecoveryID = UUID()
    let admittedRecoveryPlan = CaptureShutdownPlan.make(for: .finishing(recoveryID: admittedRecoveryID))
    try require(
        admittedRecoveryPlan == .awaitDurableCommitOrCheckpoint(recoveryID: admittedRecoveryID),
        "admitted recovery appeared idle before transcription suspended"
    )

    let protectedPresentation = CaptureState.recording(startedAt: .now, level: 0.5)
        .protectedForTerminationFailure("Synthetic protected recovery")
    guard case .checkpointed = protectedPresentation else {
        throw CoreCheckError.assertionFailed("termination failure left live capture controls visible")
    }
    let successfulCheckpoint = SyntheticTerminationCheckpoint {
        try await Task.sleep(for: .milliseconds(10))
    }
    let coordinator = TerminationCheckpointCoordinator(checkpointer: successfulCheckpoint)
    async let first: Void = coordinator.checkpoint()
    async let repeated: Void = coordinator.checkpoint()
    _ = try await (first, repeated)
    try require(successfulCheckpoint.callCount == 1, "successful checkpoint ran more than once")

    var shouldFail = true
    let persistenceFailure = SyntheticTerminationCheckpoint {
        if shouldFail { throw SyntheticWebhookPersistenceError.rejected }
    }
    let failedCoordinator = TerminationCheckpointCoordinator(checkpointer: persistenceFailure)
    do {
        try await failedCoordinator.checkpoint()
        throw CoreCheckError.assertionFailed("failing persistence checkpoint succeeded")
    } catch is SyntheticWebhookPersistenceError {}
    do {
        try await failedCoordinator.checkpoint()
        throw CoreCheckError.assertionFailed("cached persistence failure succeeded")
    } catch is SyntheticWebhookPersistenceError {}
    try require(persistenceFailure.callCount == 1, "failing persistence checkpoint ran more than once")
    shouldFail = false
    try await failedCoordinator.retry()
    try require(persistenceFailure.callCount == 2, "explicit retry did not start exactly one new checkpoint")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("evee-termination-manifest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(rootURL: root)
    let capture = try await store.beginRecoveryCapture(kind: .meeting)
    let microphone = root.appendingPathComponent("synthetic-microphone.caf")
    try Data("synthetic audio".utf8).write(to: microphone)
    _ = try await store.addRecoveryTrack(
        captureID: capture.id,
        kind: .meeting,
        role: .microphone,
        sourceURL: microphone
    )
    let repeatedCapture = try await store.beginRecoveryCapture(kind: .meeting, id: capture.id)
    try require(repeatedCapture.tracks.map(\.role) == [.microphone], "repeated recovery begin erased a checkpointed track")
    try require(repeatedCapture.status == .captured, "repeated recovery begin reset checkpoint status")

    let delayedCheckpoint = SyntheticTerminationCheckpoint {
        try await Task.sleep(for: .milliseconds(100))
    }
    let replies = LockedValues<Bool>()
    let deadlineFailures = LockedValues<String>()
    let applicationCoordinator = ApplicationTerminationCoordinator(deadline: .milliseconds(20))
    let decision = applicationCoordinator.requestTermination(
        plan: .stopWritersAndCheckpoint(kind: .meeting, recoveryID: capture.id),
        checkpoint: delayedCheckpoint,
        reply: { replies.append($0) },
        reportFailure: { deadlineFailures.append($0.localizedDescription) }
    )
    try require(decision == .terminateLater, "active capture did not return terminate-later")
    let deadline = Date().addingTimeInterval(1)
    while replies.values.isEmpty, Date() < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try require(replies.values == [false], "checkpoint deadline did not cancel termination exactly once")
    try require(deadlineFailures.values.count == 1, "checkpoint deadline was not surfaced")
    try await Task.sleep(for: .milliseconds(120))
    try require(replies.values == [false], "late durability completion replied to AppKit twice")

    let generationCheckpoint = SyntheticGenerationCheckpoint()
    let generationCoordinator = ApplicationTerminationCoordinator(deadline: .seconds(1))
    let firstGenerationReplies = LockedValues<Bool>()
    _ = generationCoordinator.requestTermination(
        plan: .invalidateDeliveryAndAwaitCommit,
        checkpoint: generationCheckpoint,
        reply: { firstGenerationReplies.append($0) },
        reportFailure: { _ in }
    )
    while firstGenerationReplies.values.isEmpty { await Task.yield() }
    try require(firstGenerationReplies.values == [true], "initial generation did not checkpoint")
    generationCheckpoint.beginNewWork()
    let secondGenerationReplies = LockedValues<Bool>()
    let secondGenerationDecision = generationCoordinator.requestTermination(
        plan: .invalidateDeliveryAndAwaitCommit,
        checkpoint: generationCheckpoint,
        reply: { secondGenerationReplies.append($0) },
        reportFailure: { _ in }
    )
    try require(secondGenerationDecision == .terminateLater, "new work reused a stale successful checkpoint")
    while secondGenerationReplies.values.isEmpty { await Task.yield() }
    try require(generationCheckpoint.callCount == 2, "new work did not run a new checkpoint")

    let serializedGeneration = SuspendedGenerationCheckpoint()
    let serializedDurability = TerminationCheckpointCoordinator(checkpointer: serializedGeneration)
    let oldGeneration = Task { try await serializedDurability.checkpoint(for: 0) }
    let oldGenerationDeadline = Date().addingTimeInterval(1)
    while serializedGeneration.callCount < 1, Date() < oldGenerationDeadline { await Task.yield() }
    try require(serializedGeneration.callCount == 1, "old generation checkpoint did not start")
    let freshGeneration = Task { try await serializedDurability.checkpoint(for: 1) }
    try await Task.sleep(for: .milliseconds(10))
    try require(serializedGeneration.callCount == 1, "new generation overlapped an active checkpoint")
    serializedGeneration.succeed()
    let freshGenerationDeadline = Date().addingTimeInterval(1)
    while serializedGeneration.callCount < 2, Date() < freshGenerationDeadline { await Task.yield() }
    try require(serializedGeneration.callCount == 2, "new generation reused an old checkpoint")
    try require(serializedGeneration.maximumActiveCallCount == 1, "generation checkpoints overlapped")
    serializedGeneration.succeed()
    _ = try await (oldGeneration.value, freshGeneration.value)

    let suspendedGeneration = SuspendedGenerationCheckpoint()
    let suspendedReplies = LockedValues<Bool>()
    let suspendedFailures = LockedValues<String>()
    let suspendedCoordinator = ApplicationTerminationCoordinator(deadline: .seconds(1))
    _ = suspendedCoordinator.requestTermination(
        plan: .invalidateDeliveryAndAwaitCommit,
        checkpoint: suspendedGeneration,
        reply: { suspendedReplies.append($0) },
        reportFailure: { suspendedFailures.append($0.localizedDescription) }
    )
    await Task.yield()
    suspendedGeneration.beginNewWork()
    suspendedGeneration.succeed()
    while suspendedReplies.values.isEmpty { await Task.yield() }
    try require(suspendedReplies.values == [false], "generation changed during checkpoint still terminated")
    try require(suspendedFailures.values.count == 1, "changed generation was not surfaced")

    let commitStoreRoot = root.appendingPathComponent("suspended-commit")
    let commitStore = LibraryStore(rootURL: commitStoreRoot)
    let commitRecovery = try await commitStore.beginRecoveryCapture(kind: .memo)
    let commitSource = root.appendingPathComponent("synthetic-commit.caf")
    try coreCheckSilentWAV().write(to: commitSource)
    _ = try await commitStore.addRecoveryTrack(
        captureID: commitRecovery.id,
        kind: .memo,
        role: .microphone,
        sourceURL: commitSource
    )
    let commitGate = SyntheticOperationGate<Void>()
    let commitOperation = TerminationOwnedOperation<WorkspaceRecord>()
    let committedRecord = WorkspaceRecord(kind: .memo, title: "Synthetic", text: "Saved")
    _ = await commitOperation.begin {
        try await commitGate.wait()
        return try await commitStore.commitRecoveredRecord(
            committedRecord,
            recoveryID: commitRecovery.id,
            keepAudio: true
        )
    }
    let commitJoin = Task { try await commitOperation.join() }
    await commitGate.release(())
    let joinedRecord = try await commitJoin.value
    try require(joinedRecord?.id == committedRecord.id, "quit did not join the suspended commit")
    let repeatedCommit = try await commitOperation.join()
    try require(repeatedCommit == nil, "joined commit was repeated")
    let committedRecords = try await commitStore.loadRecords()
    let committedRecoveries = try await commitStore.recoverableCaptures()
    try require(committedRecords.map(\.id) == [committedRecord.id], "suspended commit was not retained exactly once")
    try require(committedRecoveries.isEmpty, "durable commit left an empty recovery behind")

    let startGate = SyntheticOperationGate<URL>()
    let startOperation = TerminationOwnedOperation<URL>()
    let syntheticOutput = root.appendingPathComponent("delayed-start.caf")
    _ = await startOperation.begin { try await startGate.wait() }
    let startJoin = Task { try await startOperation.join() }
    await startGate.release(syntheticOutput)
    let startedOutput = try await startJoin.value
    try require(startedOutput == syntheticOutput, "quit did not join delayed recorder start")
    let startIsActive = await startOperation.isActive
    try require(!startIsActive, "recorder start remained active after checkpoint")

    let deliveryGate = SyntheticOperationGate<Void>()
    let deliveryOperation = TerminationOwnedOperation<Void>()
    let sendCounter = SyntheticCounter()
    _ = await deliveryOperation.begin {
        try await deliveryGate.wait()
        try Task.checkCancellation()
        await sendCounter.increment()
    }
    await deliveryGate.waitUntilStarted()
    await deliveryOperation.cancel()
    let deliveryJoin = Task { try? await deliveryOperation.join() }
    await deliveryGate.release(())
    _ = await deliveryJoin.value
    let sendCount = await sendCounter.value
    try require(sendCount == 0, "cancelled delivery auto-sent after checkpoint began")

    let clipboard = SyntheticClipboard()
    let clipboardGate = SyntheticOperationGate<Void>()
    let clipboardTask = Task { @MainActor in
        try await TemporaryClipboardTransaction.withRestoration(
            currentRevision: { clipboard.revision },
            restore: { clipboard.restoreSnapshot() }
        ) { markOwned in
            clipboard.writeTemporaryValue()
            markOwned(clipboard.revision)
            try await clipboardGate.wait()
            try Task.checkCancellation()
        }
    }
    await clipboardGate.waitUntilStarted()
    clipboardTask.cancel()
    await clipboardGate.release(())
    _ = try? await clipboardTask.value
    try require(clipboard.restoreCount == 1 && clipboard.value == "original", "clipboard snapshot was not restored after cancellation")

    let meetingRoot = root.appendingPathComponent("meeting-commit")
    let meetingStore = LibraryStore(rootURL: meetingRoot)
    let meetingRecovery = try await meetingStore.beginRecoveryCapture(kind: .meeting)
    try await meetingStore.saveMeetingDraft(MeetingDraft(captureID: meetingRecovery.id, title: "Synthetic", notes: "Retain until commit"))
    _ = try await meetingStore.commitRecoveredRecord(
        WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Saved"),
        recoveryID: meetingRecovery.id,
        keepAudio: false
    )
    let committedMeeting = try unwrapped(
        try await meetingStore.loadRecords().first,
        "committed meeting was not durable"
    )
    let clearedMeetingDraft = try await meetingStore.clearMeetingDraft(
        forCommitted: committedMeeting,
        recoveryID: meetingRecovery.id
    )
    try require(clearedMeetingDraft, "matching committed meeting did not clear its draft")
    let relaunchedMeetingStore = LibraryStore(rootURL: meetingRoot)
    let relaunchedMeetingDraft = try await relaunchedMeetingStore.loadMeetingDraft()
    try require(relaunchedMeetingDraft == nil, "meeting draft returned after relaunch")

    print("termination-checkpoint: passed")
}

private func checkLifecycleState() throws {
    var download = ModelDownloadStateMachine()
    let first = try unwrapped(download.begin(model: .parakeet), "model download did not start")
    try require(download.begin(model: .parakeet) == nil, "model download allowed a concurrent operation")
    try require(download.requestCancellation(first), "model download did not publish cancellation")
    try require(download.state == .cancelling(model: .parakeet), "model cancellation was not visible")
    try require(download.begin(model: .parakeet) == nil, "model download restarted before cancellation acknowledgement")
    try require(!download.update(first, progress: ModelProgress(fraction: 0.5, status: "Synthetic progress")), "cancelled model download accepted stale progress")
    try require(!download.complete(first), "cancelled model download accepted stale completion")
    try require(download.acknowledgeCancellation(first, message: "Interrupted"), "model cancellation was not acknowledged")

    var hotMic = HotMicStateMachine()
    let start = try unwrapped(hotMic.beginStart(), "hot mic did not begin starting")
    hotMic.disable()
    try require(!hotMic.didStart(start), "disabled hot mic accepted a stale start")

    let recoveryID = UUID()
    try require(CaptureShutdownPlan.make(for: .idle) == .terminateImmediately, "idle capture did not terminate immediately")
    try require(CaptureShutdownPlan.make(for: .failed) == .terminateImmediately, "failed capture did not terminate immediately")
    try require(CaptureShutdownPlan.make(for: .starting(kind: .dictation, recoveryID: recoveryID)) == .cancelStartAndCheckpoint, "starting capture did not checkpoint")
    try require(CaptureShutdownPlan.make(for: .recording(kind: .meeting, recoveryID: recoveryID)) == .stopWritersAndCheckpoint(kind: .meeting, recoveryID: recoveryID), "recording capture did not stop writers")
    try require(CaptureShutdownPlan.make(for: .finishing(recoveryID: recoveryID)) == .awaitDurableCommitOrCheckpoint(recoveryID: recoveryID), "finishing capture did not await durable commit")
    try require(CaptureShutdownPlan.make(for: .delivering) == .invalidateDeliveryAndAwaitCommit, "delivery did not await commit")
    try require(CaptureShutdownPlan.make(for: .cancelling) == .awaitCancellationCleanup, "cancelling capture did not await cleanup")

    let unsafeSnapshots: [CaptureLifecycleSnapshot] = [
        .starting(kind: .memo, recoveryID: nil),
        .recording(kind: .dictation, recoveryID: nil),
        .finishing(recoveryID: nil),
    ]
    for snapshot in unsafeSnapshots {
        guard case .cancelTermination(let message) = CaptureShutdownPlan.make(for: snapshot), !message.isEmpty else {
            throw CoreCheckError.assertionFailed("active capture without recovery ID allowed immediate termination")
        }
    }

    print("lifecycle-state: passed")
}

private func checkModelDownloadLifecycle() throws {
    var download = ModelDownloadStateMachine()
    let cancelled = try unwrapped(download.begin(model: .parakeet), "model download did not start")
    try require(download.begin(model: .parakeet) == nil, "model download allowed a concurrent operation")

    try require(download.requestCancellation(cancelled), "model download did not enter cancelling")
    try require(download.state == .cancelling(model: .parakeet), "model download did not publish cancelling")
    try require(download.begin(model: .parakeet) == nil, "model download allowed retry before cancellation acknowledgement")
    try require(
        !download.update(cancelled, progress: ModelProgress(fraction: 0.5, status: "Synthetic late progress")),
        "cancelled model download accepted late progress"
    )
    try require(!download.complete(cancelled), "cancelled model download accepted late completion")
    try require(download.acknowledgeCancellation(cancelled, message: "Download interrupted. Retry when ready."), "model download did not acknowledge cancellation")
    try require(download.begin(model: .parakeet) != nil, "acknowledged cancellation did not permit retry")

    var failedDownload = ModelDownloadStateMachine()
    let failed = try unwrapped(failedDownload.begin(model: .qwen3), "model download retry setup did not start")
    try require(failedDownload.fail(failed, message: "Synthetic failure"), "model download failure was not recorded")
    try require(failedDownload.begin(model: .qwen3) != nil, "model download failure did not permit retry")

    var modelSwitch = ModelDownloadStateMachine()
    let readyA = try unwrapped(modelSwitch.begin(model: .parakeet), "model A did not start")
    try require(modelSwitch.complete(readyA), "model A did not become ready")
    let selectedB = try unwrapped(
        modelSwitch.begin(model: .qwen3),
        "ready model A blocked selected model B"
    )
    try require(
        modelSwitch.state == .downloading(model: .qwen3, progress: nil),
        "model switch did not publish selected model B"
    )
    try require(modelSwitch.begin(model: .qwen3) == nil, "model B switch was not single-flight")
    try require(modelSwitch.complete(selectedB), "model B did not become ready")

    print("model-download: passed")
}

private func checkModelReadiness() async throws {
    let provider = SyntheticRepairableModelProvider()
    do {
        try await LocalModelReadiness.prepare(provider, mode: .validateExisting) { _ in }
        throw CoreCheckError.assertionFailed("shallow invalid cache was published ready")
    } catch is SyntheticModelReadinessError {}
    try await LocalModelReadiness.prepare(provider, mode: .downloadOrRepair) { _ in }
    let downloads = await provider.downloadCount
    let loads = await provider.loadCount
    try require(downloads == 1, "invalid cache repair downloaded \(downloads) times")
    try require(loads == 2, "invalid cache did not validate before and after repair")
    print("model-readiness: passed")
}

@MainActor
private func checkMicrophoneMeter() async throws {
    var received: [Float] = []
    let meter = MicrophoneLevelMeter(updateInterval: .milliseconds(1)) { received.append($0) }
    meter.start()
    for value in 0..<10_000 { meter.offer(Float(value) / 10_000) }
    try require(meter.metrics.depth <= 1, "microphone meter exceeded capacity one")
    try require(meter.metrics.peakDepth == 1, "microphone meter did not report bounded peak depth")
    try require(meter.metrics.droppedCount > 0, "microphone meter did not coalesce high-rate updates")
    try require(meter.consumerStartCount == 1, "microphone meter created more than one consumer")
    await meter.finish()
    try require(!meter.isConsumerActive, "microphone meter consumer survived stop")
    try require(received.last == 0, "microphone meter did not publish final stopped level")
    print("microphone-meter: passed")
}

private func checkQuitTrackIndependence() throws {
    try CaptureCheckpointTrackPolicy.validate(kind: .meeting, validRoles: [.system])
    try CaptureCheckpointTrackPolicy.validate(kind: .meeting, validRoles: [.microphone])
    do {
        try CaptureCheckpointTrackPolicy.validate(kind: .memo, validRoles: [.system])
        throw CoreCheckError.assertionFailed("memo accepted a system-only checkpoint")
    } catch is CaptureCheckpointTrackPolicyError {}
    var gate = TerminationWorkGate()
    _ = gate.prepareCheckpoint()
    gate.resumeAfterCheckpointFailure()
    try require(gate.beginWork(), "failed quit checkpoint left recovery admission closed")
    print("quit-track-independence: passed")
}

private func checkModelAvailability() throws {
    let macOS14 = SpeechModelAvailability(
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)
    )
    try require(macOS14.isSupported(.parakeet), "macOS 14 rejected Parakeet")
    try require(!macOS14.isSupported(.qwen3), "macOS 14 accepted Qwen3")
    try require(macOS14.safeSelection(for: .qwen3) == .parakeet, "macOS 14 did not choose safe fallback")
    try require(macOS14.unavailableReason(for: .qwen3) != nil, "unsupported model had no explanation")
    let macOS15 = SpeechModelAvailability(
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    )
    try require(macOS15.isSupported(.qwen3), "macOS 15 rejected Qwen3")
    print("model-availability: passed")
}

private func checkHotMicRace() throws {
    var hotMic = HotMicStateMachine()
    let disabledStart = try unwrapped(hotMic.beginStart(), "hot mic did not begin starting")
    try require(hotMic.beginStart() == nil, "hot mic allowed a repeated concurrent start")
    hotMic.disable()
    try require(!hotMic.didStart(disabledStart), "disabled hot mic accepted a stale start")
    try require(hotMic.isDisabled, "disabled hot mic did not publish disabled state")

    let captureStart = try unwrapped(hotMic.beginStart(), "hot mic did not restart before capture")
    try require(hotMic.beginStop(), "hot mic did not publish cleanup in progress")
    try require(hotMic.state == .stopping, "hot mic cleanup was not visible")
    try require(!hotMic.didStart(captureStart), "foreground capture accepted a stale hot mic start")
    try require(hotMic.completeStop(), "hot mic cleanup did not publish completion")
    try require(hotMic.isDisabled, "completed hot mic cleanup did not close the microphone")

    let failingStart = try unwrapped(hotMic.beginStart(), "hot mic did not restart before failure")
    try require(hotMic.fail(failingStart, message: "Synthetic failure"), "hot mic failure was not recorded")
    try require(hotMic.state == .failed(message: "Synthetic failure"), "hot mic failure state was not published")

    hotMic.disable()
    hotMic.disable()
    try require(hotMic.isDisabled, "repeated hot mic disable was not idempotent")

    print("hot-mic-race: passed")
}

private func checkBoundedMailbox() async throws {
    let mailbox = BoundedAudioMailbox<Int>(capacity: 3)
    let consumer = Task {
        var received: [Int] = []
        while let value = await mailbox.next() {
            received.append(value)
            try? await Task.sleep(for: .milliseconds(5))
        }
        return received
    }

    for value in 0..<100 { mailbox.send(value) }
    try require(mailbox.depth <= 3, "mailbox exceeded its configured capacity")
    try require(mailbox.peakDepth == 3, "mailbox did not report its bounded peak depth")
    try require(mailbox.droppedCount > 0, "mailbox did not report overwritten audio")
    mailbox.close(mode: .drain)

    let received = await consumer.value
    try require(received.suffix(3) == [97, 98, 99], "mailbox did not retain the newest buffered values in order")

    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ), let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2) else {
        throw CoreCheckError.assertionFailed("synthetic PCM setup failed")
    }
    source.frameLength = 2
    guard let sourceSamples = source.floatChannelData?[0] else {
        throw CoreCheckError.assertionFailed("synthetic PCM samples were unavailable")
    }
    sourceSamples[0] = 0.25
    sourceSamples[1] = -0.5
    guard let copied = CopiedAudioBuffer(copying: source),
          let copiedSamples = copied.buffer.floatChannelData?[0] else {
        throw CoreCheckError.assertionFailed("PCM copy failed")
    }
    sourceSamples[0] = 1
    sourceSamples[1] = 1
    try require(copiedSamples[0] == 0.25 && copiedSamples[1] == -0.5, "PCM copy shared source storage")

    print("bounded-mailbox: passed (peak=\(mailbox.peakDepth), dropped=\(mailbox.droppedCount))")
}

private func checkAudioPipeline() async throws {
    let recognizer = SyntheticLiveAudioRecognizer()
    await recognizer.setAudioBlocked(true)
    let transcriber = LiveMeetingTranscriber(testingMicrophone: recognizer)
    try await transcriber.start(includeSystem: false)

    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ), let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2) else {
        throw CoreCheckError.assertionFailed("synthetic live PCM setup failed")
    }
    source.frameLength = 2
    guard let copied = CopiedAudioBuffer(copying: source) else {
        throw CoreCheckError.assertionFailed("synthetic live PCM copy failed")
    }

    transcriber.acceptMicrophone(copied)
    let receiveDeadline = Date().addingTimeInterval(1)
    while await recognizer.receivedBufferCount == 0, Date() < receiveDeadline {
        await Task.yield()
    }
    for _ in 0..<100 { transcriber.acceptMicrophone(copied) }
    let metrics = transcriber.microphoneMailboxMetrics
    try require(metrics.depth <= 32, "slow recognizer allowed Evee's mailbox past capacity")
    try require(metrics.peakDepth == 32, "slow recognizer did not exercise the configured capacity")
    try require(metrics.droppedCount > 0, "slow recognizer did not report dropped buffers")

    let forwarded = Task {
        var updates: [LiveMeetingTranscriptUpdate] = []
        for await update in transcriber.updates { updates.append(update) }
        return updates
    }
    await recognizer.setAudioBlocked(false)
    await transcriber.stop()
    let updates = await forwarded.value
    try require(updates.last?.text == "Synthetic final transcript", "graceful finish lost the final recognizer transcript")
    try require(updates.last?.isConfirmed == true, "graceful finish did not confirm the final transcript")
    try require(updates.last?.isFinal == true, "graceful finish did not mark the channel replacement update")
    let gracefulFinishCount = await recognizer.finishCount
    let gracefulCancelCount = await recognizer.cancelCount
    try require(gracefulFinishCount == 1 && gracefulCancelCount == 0, "graceful stop did not use recognizer finish exclusively")

    let cancelledRecognizer = SyntheticLiveAudioRecognizer()
    let cancelledTranscriber = LiveMeetingTranscriber(testingMicrophone: cancelledRecognizer)
    try await cancelledTranscriber.start(includeSystem: false)
    await cancelledTranscriber.stop(discardPendingAudio: true)
    let discardFinishCount = await cancelledRecognizer.finishCount
    let discardCancelCount = await cancelledRecognizer.cancelCount
    try require(discardFinishCount == 0 && discardCancelCount == 1, "discard stop did not use recognizer cancellation exclusively")

    print("audio-pipeline: passed (peak=\(metrics.peakDepth), dropped=\(metrics.droppedCount))")
}

private func checkAudioRelay() async throws {
    let relay = AudioBufferRelay()
    let mailbox = BoundedAudioMailbox<CopiedAudioBuffer>(capacity: 1)
    let handlerEntered = DispatchSemaphore(value: 0)
    let releaseHandler = DispatchSemaphore(value: 0)
    let detachReturned = DispatchSemaphore(value: 0)
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ), let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
        throw CoreCheckError.assertionFailed("synthetic relay PCM setup failed")
    }
    source.frameLength = 1

    relay.set { copied in
        handlerEntered.signal()
        releaseHandler.wait()
        mailbox.send(copied)
    }
    DispatchQueue.global().async { relay.publishCopy(of: source) }
    try require(handlerEntered.wait(timeout: .now() + 1) == .success, "relay handler did not take its producer snapshot")
    DispatchQueue.global().async {
        relay.detachAndWait()
        detachReturned.signal()
    }
    try require(detachReturned.wait(timeout: .now() + 0.05) == .timedOut, "relay detach returned before its snapshotted handler")

    releaseHandler.signal()
    try require(detachReturned.wait(timeout: .now() + 1) == .success, "relay detach did not return after handler completion")
    mailbox.close(mode: .drain)
    let retained = await mailbox.next()
    try require(retained != nil, "relay drain lost the snapshotted final buffer")
    print("audio-relay: passed")
}

private func checkWebhookTransactions() async throws {
    let queueRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: queueRoot) }
    let queueStore = LibraryStore(rootURL: queueRoot)
    let queueTransactions = WebhookOutboxTransactions()
    var queuedRecord = WorkspaceRecord(kind: .meeting, title: "Queue race", text: "Synthetic")
    let queuedPayload = try MeetingWebhook.payload(for: queuedRecord)
    let queuedDelivery = WebhookDelivery(
        id: UUID(uuidString: "57CBE526-0514-48B0-9C18-42EE74653CA5")!,
        destination: "https://example.invalid/webhook",
        payloadBody: queuedPayload
    )
    queuedRecord.webhookDeliveries = [queuedDelivery]
    let queueToken = queueTransactions.beginPreparation()
    let queueAttempts = LockedValues<UUID>()
    let queueTransaction = await queueTransactions.persistPreparation(
        queueToken,
        records: [queuedRecord]
    ) { record in
        queueAttempts.append(record.id)
        try await queueStore.upsert(record)
        if queueAttempts.values.count == 1 { _ = queueTransactions.invalidate() }
    }
    guard case .cancel = queueTransaction.decision else {
        throw CoreCheckError.assertionFailed("invalidated queue preparation committed")
    }
    try require(queueTransaction.cancellation?.failures.isEmpty == true, "queue cancellation compensation failed")
    try require(queueAttempts.values == [queuedRecord.id, queuedRecord.id], "queue cancellation compensation was not persisted")
    let storedQueue = try await queueStore.record(id: queuedRecord.id)
    let storedQueueDelivery = storedQueue?.webhookDeliveries.first(where: { $0.id == queuedDelivery.id })
    try require(storedQueueDelivery?.state == .cancelled, "queue race left a pending delivery")
    try require(storedQueueDelivery?.payloadBody == nil, "queue race retained payload bytes")

    let queueInstallRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: queueInstallRoot) }
    let queueInstallStore = LibraryStore(rootURL: queueInstallRoot)
    let queueInstallTransactions = WebhookOutboxTransactions()
    let queueInstallToken = queueInstallTransactions.beginPreparation()
    let queueInstallTransaction = await queueInstallTransactions.persistPreparation(
        queueInstallToken,
        records: [queuedRecord]
    ) { record in
        try await queueInstallStore.upsert(record)
    }
    guard case .commit = queueInstallTransaction.decision else {
        throw CoreCheckError.assertionFailed("current queue preparation did not commit")
    }
    _ = queueInstallTransactions.invalidate()
    let queueInstallation = queueInstallTransactions.claimInstallation(
        queueInstallTransaction.installationToken,
        records: [queuedRecord]
    )
    guard case .cancel(let cancelledQueueInstallation) = queueInstallation else {
        throw CoreCheckError.assertionFailed("invalidated queue installation was accepted")
    }
    _ = await queueInstallTransactions.persistAll(cancelledQueueInstallation) { record in
        try await queueInstallStore.upsert(record)
    }
    let storedQueueInstallation = try await queueInstallStore.record(id: queuedRecord.id)
    let storedQueueInstallationDelivery = storedQueueInstallation?.webhookDeliveries.first
    try require(storedQueueInstallationDelivery?.state == .cancelled, "queue installation race left a pending delivery")
    try require(storedQueueInstallationDelivery?.payloadBody == nil, "queue installation race retained payload bytes")
    try require(storedQueueInstallationDelivery?.retryable == false, "queue installation race remained retryable")
    try require(storedQueueInstallationDelivery?.nextAttemptAt == nil, "queue installation race retained retry timing")

    let retryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: retryRoot) }
    let retryStore = LibraryStore(rootURL: retryRoot)
    let retryTransactions = WebhookOutboxTransactions()
    let retryDeliveryID = UUID(uuidString: "546290F6-C799-4967-AC9C-B6CAF86726D7")!
    let destination = "https://example.invalid/webhook"
    var failedRecord = WorkspaceRecord(kind: .meeting, title: "Retry race", text: "Synthetic")
    let retryPayload = try MeetingWebhook.payload(for: failedRecord)
    failedRecord.webhookDeliveries = [WebhookDelivery(
        id: retryDeliveryID,
        destination: destination,
        state: .failed,
        attemptCount: 1,
        payloadBody: retryPayload,
        retryable: true,
        nextAttemptAt: .now
    )]
    try await retryStore.upsert(failedRecord)
    let retryToken = retryTransactions.beginPreparation()
    let retryPreparation = retryTransactions.prepareManualRetry(
        records: [failedRecord],
        destination: destination,
        at: Date(timeIntervalSince1970: 1_786_616_200)
    )
    let retryAttempts = LockedValues<UUID>()
    let retryTransaction = await retryTransactions.persistPreparation(
        retryToken,
        records: retryPreparation.records
    ) { record in
        retryAttempts.append(record.id)
        try await retryStore.upsert(record)
        if retryAttempts.values.count == 1 { _ = retryTransactions.invalidate() }
    }
    guard case .cancel = retryTransaction.decision else {
        throw CoreCheckError.assertionFailed("invalidated manual retry committed")
    }
    try require(retryTransaction.cancellation?.failures.isEmpty == true, "manual retry cancellation compensation failed")
    try require(retryAttempts.values == [failedRecord.id, failedRecord.id], "manual retry cancellation compensation was not persisted")
    let storedRetry = try await retryStore.record(id: failedRecord.id)
    let storedRetryDelivery = storedRetry?.webhookDeliveries.first(where: { $0.id == retryDeliveryID })
    try require(storedRetryDelivery?.state == .cancelled, "manual retry race revived a cancelled delivery")
    try require(storedRetryDelivery?.payloadBody == nil, "manual retry race retained payload bytes")

    let retryInstallRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: retryInstallRoot) }
    let retryInstallStore = LibraryStore(rootURL: retryInstallRoot)
    try await retryInstallStore.upsert(failedRecord)
    let retryInstallTransactions = WebhookOutboxTransactions()
    let retryInstallToken = retryInstallTransactions.beginPreparation()
    let retryInstallPreparation = retryInstallTransactions.prepareManualRetry(
        records: [failedRecord],
        destination: destination
    )
    let retryInstallTransaction = await retryInstallTransactions.persistPreparation(
        retryInstallToken,
        records: retryInstallPreparation.records
    ) { record in
        try await retryInstallStore.upsert(record)
    }
    guard case .commit = retryInstallTransaction.decision else {
        throw CoreCheckError.assertionFailed("current manual retry preparation did not commit")
    }
    _ = retryInstallTransactions.invalidate()
    let retryInstallation = retryInstallTransactions.claimInstallation(
        retryInstallTransaction.installationToken,
        records: retryInstallPreparation.records
    )
    guard case .cancel(let cancelledRetryInstallation) = retryInstallation else {
        throw CoreCheckError.assertionFailed("invalidated manual retry installation was accepted")
    }
    _ = await retryInstallTransactions.persistAll(cancelledRetryInstallation) { record in
        try await retryInstallStore.upsert(record)
    }
    let storedRetryInstallation = try await retryInstallStore.record(id: failedRecord.id)
    let storedRetryInstallationDelivery = storedRetryInstallation?.webhookDeliveries.first
    try require(storedRetryInstallationDelivery?.state == .cancelled, "manual retry installation race revived a pending delivery")
    try require(storedRetryInstallationDelivery?.payloadBody == nil, "manual retry installation race retained payload bytes")
    try require(storedRetryInstallationDelivery?.retryable == false, "manual retry installation race remained retryable")
    try require(storedRetryInstallationDelivery?.nextAttemptAt == nil, "manual retry installation race retained retry timing")

    let partialTransactions = WebhookOutboxTransactions()
    let partialRecords = [
        WorkspaceRecord(id: UUID(uuidString: "EE6C5238-D656-4591-9496-4AFBFC27CC8B")!, kind: .meeting, title: "First", text: "Synthetic"),
        WorkspaceRecord(id: UUID(uuidString: "73DF5302-12BE-45D6-B7D8-7973394654DE")!, kind: .meeting, title: "Second", text: "Synthetic"),
        WorkspaceRecord(id: UUID(uuidString: "AF38DCD7-E785-42F0-B646-97425F20C66E")!, kind: .meeting, title: "Third", text: "Synthetic"),
    ]
    let attempted = LockedValues<UUID>()
    let partialResult = await partialTransactions.persistAll(partialRecords) { record in
        attempted.append(record.id)
        if record.id == partialRecords[1].id { throw SyntheticWebhookPersistenceError.rejected }
    }
    try require(attempted.values == partialRecords.map(\.id), "batch persistence stopped before later records")
    try require(partialResult.persistedRecordIDs == [partialRecords[0].id, partialRecords[2].id], "batch persistence reported the wrong successes")
    try require(partialResult.failures.map(\.recordID) == [partialRecords[1].id], "batch persistence reported the wrong failure")

    let terminationTransactions = WebhookOutboxTransactions()
    let preparation = terminationTransactions.beginPreparation()
    let terminationDeliveryID = UUID(uuidString: "FEABF695-DAD7-4FC5-95B5-F5653C9A2D5E")!
    guard let dispatch = terminationTransactions.beginDispatch(deliveryID: terminationDeliveryID) else {
        throw CoreCheckError.assertionFailed("termination dispatch did not start")
    }
    let activeTask = terminationTransactions.startTask(for: dispatch) {
        try? await Task.sleep(for: .seconds(30))
    }
    let invalidation = terminationTransactions.invalidate()
    let preparationDecision = terminationTransactions.finalize(preparation, records: [failedRecord])
    try require(activeTask.isCancelled, "synchronous termination invalidation left the task active")
    try require(!terminationTransactions.mayCommit(dispatch), "termination invalidation left the dispatch current")
    try require(
        terminationTransactions.beginDispatch(
            deliveryID: UUID(),
            requiringGeneration: preparation.generation
        ) == nil,
        "termination invalidation allowed stale work to start"
    )
    guard case .cancel = preparationDecision else {
        throw CoreCheckError.assertionFailed("termination invalidation left the preparation current")
    }
    try require(invalidation.deliveryIDs == [terminationDeliveryID], "termination invalidation omitted the active delivery")
    print("webhook-transactions: passed")
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    onTimeout: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw CoreCheckError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func availablePort() throws -> UInt16 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CoreCheckError.listenerFailed(String(cString: strerror(errno))) }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw CoreCheckError.listenerFailed(String(cString: strerror(errno))) }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else { throw CoreCheckError.listenerFailed(String(cString: strerror(errno))) }
    return UInt16(bigEndian: address.sin_port)
}

private func connect(to credentials: LocalAPICredentials, label: String) async throws -> NWConnection {
    let port = NWEndpoint.Port(rawValue: UInt16(credentials.baseURL.port!))!
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    let queue = DispatchQueue(label: label)
    try await withCheckedThrowingContinuation { continuation in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                continuation.resume()
            case .failed(let error):
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: CoreCheckError.connectionFailed(error.localizedDescription))
            case .cancelled:
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: CoreCheckError.connectionFailed("Cancelled before ready"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    return connection
}

private func send(_ data: Data, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: CoreCheckError.connectionFailed(error.localizedDescription))
            } else {
                continuation.resume()
            }
        })
    }
}

private func sendBestEffort(_ data: Data, on connection: NWConnection) async {
    await withCheckedContinuation { continuation in
        connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
    }
}

private func receiveAll(on connection: NWConnection, accumulated: Data = Data()) async -> Data {
    await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, isComplete, error in
            var received = accumulated
            if let data { received.append(data) }
            if isComplete || error != nil {
                continuation.resume(returning: received)
            } else {
                Task { continuation.resume(returning: await receiveAll(on: connection, accumulated: received)) }
            }
        }
    }
}

private func makeSyntheticServer() async throws -> (LocalAPIServer, LocalAPICredentials, URL, LibraryStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-check-\(UUID().uuidString)", isDirectory: true)
    let store = LibraryStore(rootURL: root)
    let secretStore = KeychainSecretStore(service: "com.tumcuctom.evee.core-checks.synthetic")
    try? secretStore.delete(KeychainSecretStore.localAPITokenAccount)
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    let credentials = try await server.startWithCredentials(port: try availablePort())
    return (server, credentials, root, store)
}

private func checkContextPolicy() {
    let ordinary = ContextCollectionPolicy.ordinaryDictation(
        retainMetadata: false,
        captureVisibleText: false
    )
    precondition(ordinary.collectsDeliveryIdentity)
    precondition(!ordinary.collectsSelectedText)
    precondition(!ordinary.collectsWindowMetadata)
    precondition(!ordinary.collectsVisibleText)

    let transform = ContextCollectionPolicy.selectionTransformation(retainMetadata: false)
    precondition(transform.collectsSelectedText)

    print("context-policy: passed")
}

private func checkPublicRecord() throws {
    let privateRecord = WorkspaceRecord(
        kind: .meeting,
        title: "Synthetic",
        text: "Visible",
        rawText: "Private raw",
        audioRelativePath: "Audio/private.caf",
        recoverySourceID: UUID()
    )
    let encoded = try JSONEncoder().encode(PublicWorkspaceRecord(privateRecord))
    let json = String(decoding: encoded, as: UTF8.self)
    precondition(!json.contains("private.caf"))
    precondition(!json.contains("Private raw"))
    precondition(!json.contains("recoverySourceID"))
    precondition(!json.contains("webhookDeliveries"))
    precondition(!json.contains("context"))

    print("public-record: passed")
}

private func checkMeetingRelabel() async throws {
    let draftSegmentID = UUID()
    let draftSource = WorkspaceRecord(
        kind: .meeting,
        title: "Draft label",
        text: "Participant 1: First statement",
        segments: [TranscriptSegment(
            id: draftSegmentID,
            start: 0,
            end: 5,
            speaker: "Participant 1",
            text: "First statement",
            attribution: .diarized,
            diarizationClusterID: "cluster-a"
        )]
    )
    var labelDraft = MeetingSpeakerLabelDraft(segmentID: draftSegmentID, text: "Participant 1")
    labelDraft.text = "Product "
    try require(labelDraft.text == "Product ", "speaker label draft normalized trailing space while typing")
    try require(draftSource.segments.first?.speaker == "Participant 1", "speaker label draft mutated the record before commit")
    labelDraft.text.append("Lead")
    let appliedDraft = try labelDraft.applying(to: draftSource)
    try require(appliedDraft.segments.first?.speaker == "Product Lead", "speaker label draft did not commit Product Lead")

    let multiClassSegment = TranscriptSegment(
        id: UUID(uuidString: "F5DD635B-003E-43C5-A43D-1C59A9F14C88")!,
        start: 0,
        end: 5,
        speaker: "Facilitator",
        text: "We decided I will follow up by Friday."
    )
    let generatedAt = Date(timeIntervalSince1970: 100)
    let firstIntelligence = MeetingIntelligencePipeline().generate(from: [multiClassSegment], generatedAt: generatedAt)
    let secondIntelligence = MeetingIntelligencePipeline().generate(from: [multiClassSegment], generatedAt: generatedAt)
    let firstEvidenceIDs = [
        try unwrapped(firstIntelligence.topics?.first?.id, "multi-class topic was absent"),
        try unwrapped(firstIntelligence.decisions.first?.id, "multi-class decision was absent"),
        try unwrapped(firstIntelligence.actionItems.first?.id, "multi-class action was absent"),
    ]
    let secondEvidenceIDs = [
        try unwrapped(secondIntelligence.topics?.first?.id, "regenerated topic was absent"),
        try unwrapped(secondIntelligence.decisions.first?.id, "regenerated decision was absent"),
        try unwrapped(secondIntelligence.actionItems.first?.id, "regenerated action was absent"),
    ]
    try require(Set(firstEvidenceIDs).count == 3, "evidence IDs collided across topic, decision, and action classes")
    try require(firstEvidenceIDs == secondEvidenceIDs, "evidence IDs changed across regeneration")

    let firstID = UUID()
    let secondID = UUID()
    let unrelatedID = UUID()
    let original = WorkspaceRecord(
        kind: .meeting,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100),
        title: "Synthetic meeting",
        text: "stale transcript",
        rawText: "stale raw transcript",
        segments: [
            TranscriptSegment(
                id: secondID,
                start: 20,
                end: 25,
                speaker: "Participant 1",
                text: "I will send the release notes.",
                channel: .system,
                attribution: .diarized
            ),
            TranscriptSegment(
                id: unrelatedID,
                start: 10,
                end: 15,
                speaker: "Participant 2",
                text: "We decided to ship on Friday.",
                channel: .system,
                attribution: .diarized
            ),
            TranscriptSegment(
                id: firstID,
                start: 0,
                end: 5,
                speaker: "Participant 1",
                text: "First statement",
                channel: .system,
                attribution: .diarized
            ),
        ]
    )

    let changed = try MeetingRecordProjection().relabel(
        record: original,
        segmentID: firstID,
        label: " Facilitator "
    )
    try require(changed.segments.filter { $0.speaker == "Facilitator" }.count == 2, "diarized cluster relabel was partial")
    let changedClusterIDs = changed.segments.filter { $0.speaker == "Facilitator" }.compactMap(\.diarizationClusterID)
    try require(changedClusterIDs.count == 2 && Set(changedClusterIDs).count == 1, "legacy labelled cluster identity was not persisted")
    try require(changed.segments.map(\.id) == [firstID, unrelatedID, secondID], "segments were not chronological after relabel")
    try require(changed.text.contains("Facilitator: First statement"), "finished transcript retained the stale speaker")
    try require(changed.rawText?.contains("Facilitator: First statement") == true, "raw transcript retained the stale speaker")
    try require(
        changed.meetingIntelligence == MeetingIntelligencePipeline().generate(from: changed.segments, generatedAt: changed.updatedAt),
        "meeting intelligence was not regenerated from relabelled segments"
    )
    try require(original.text == "stale transcript", "relabel mutated the source record")
    let markdown = String(decoding: try WorkspaceExporter.data(for: [changed], format: .markdown), as: UTF8.self)
    try require(markdown.contains("Facilitator"), "markdown export retained the stale speaker")
    let publicJSON = String(decoding: try JSONEncoder().encode(PublicWorkspaceRecord(changed)), as: UTF8.self)
    try require(publicJSON.contains("Facilitator"), "API/helper public projection retained the stale speaker")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-meeting-relabel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(rootURL: root)
    try await store.upsert(original)
    try await store.upsert(changed)
    let newLabelResults = try await store.search("Facilitator")
    let oldLabelResults = try await store.search("Participant 1")
    try require(newLabelResults.map(\.id) == [changed.id], "search omitted the new speaker label")
    try require(oldLabelResults.isEmpty, "search retained the stale speaker label")

    let cleared = try MeetingRecordProjection().relabel(record: original, segmentID: firstID, label: " \n ")
    try require(cleared.segments.filter { $0.id == firstID || $0.id == secondID }.allSatisfy { $0.speaker == nil }, "whitespace label did not clear the diarized cluster")
    do {
        _ = try MeetingRecordProjection().relabel(record: original, segmentID: UUID(), label: "Facilitator")
        throw CoreCheckError.assertionFailed("missing segment relabel succeeded")
    } catch MeetingRecordProjectionError.segmentNotFound {
        // Expected.
    }
    try require(original.segments.first(where: { $0.id == firstID })?.speaker == "Participant 1", "failed relabel mutated the source record")

    let channelFirstID = UUID()
    let channelSecondID = UUID()
    let channelRecord = WorkspaceRecord(
        kind: .meeting,
        title: "Channel meeting",
        text: "Other participant: First\nOther participant: Second",
        segments: [
            TranscriptSegment(id: channelFirstID, start: 0, end: 2, speaker: "Other participant", text: "First", channel: .system, attribution: .channel),
            TranscriptSegment(id: channelSecondID, start: 3, end: 5, speaker: "Other participant", text: "Second", channel: .system, attribution: .channel),
        ]
    )
    let channelChanged = try MeetingRecordProjection().relabel(record: channelRecord, segmentID: channelFirstID, label: "Guest")
    try require(channelChanged.segments.first(where: { $0.id == channelFirstID })?.speaker == "Guest", "selected channel segment was not relabelled")
    try require(channelChanged.segments.first(where: { $0.id == channelSecondID })?.speaker == "Other participant", "channel relabel changed an unrelated segment")
    try require(channelChanged.segments.allSatisfy { $0.diarizationClusterID == nil }, "channel segments received diarization cluster identity")

    let sharedLabelFirstID = UUID()
    let sharedLabelPeerID = UUID()
    let sharedLabelOtherID = UUID()
    let sharedLabelRecord = WorkspaceRecord(
        kind: .meeting,
        title: "Shared labels",
        text: "Participant: First\nParticipant: Second\nParticipant: Third",
        segments: [
            TranscriptSegment(id: sharedLabelFirstID, start: 0, end: 2, speaker: "Participant", text: "First", channel: .system, attribution: .diarized, diarizationClusterID: "cluster-a"),
            TranscriptSegment(id: sharedLabelPeerID, start: 3, end: 5, speaker: "Participant", text: "Second", channel: .system, attribution: .diarized, diarizationClusterID: "cluster-a"),
            TranscriptSegment(id: sharedLabelOtherID, start: 6, end: 8, speaker: "Participant", text: "Third", channel: .system, attribution: .diarized, diarizationClusterID: "cluster-b"),
        ]
    )
    let sharedLabelChanged = try MeetingRecordProjection().relabel(record: sharedLabelRecord, segmentID: sharedLabelFirstID, label: nil)
    try require(sharedLabelChanged.segments.first(where: { $0.id == sharedLabelFirstID })?.speaker == nil, "selected shared-label cluster was not cleared")
    try require(sharedLabelChanged.segments.first(where: { $0.id == sharedLabelPeerID })?.speaker == nil, "selected shared-label cluster peer was not cleared")
    try require(sharedLabelChanged.segments.first(where: { $0.id == sharedLabelOtherID })?.speaker == "Participant", "matching display label merged a distinct cluster")
    let sharedLabelRenamed = try MeetingRecordProjection().relabel(record: sharedLabelChanged, segmentID: sharedLabelFirstID, label: "Product Lead")
    try require(sharedLabelRenamed.segments.first(where: { $0.id == sharedLabelPeerID })?.speaker == "Product Lead", "cleared cluster could not be renamed independently")
    try require(sharedLabelRenamed.segments.first(where: { $0.id == sharedLabelOtherID })?.speaker == "Participant", "cleared cluster merged with another cluster")

    let legacyNilFirstID = UUID()
    let legacyNilSecondID = UUID()
    let legacyNilRecord = WorkspaceRecord(
        kind: .meeting,
        title: "Legacy unlabelled",
        text: "First\nSecond",
        segments: [
            TranscriptSegment(id: legacyNilFirstID, start: 0, end: 2, text: "First", channel: .system, attribution: .diarized),
            TranscriptSegment(id: legacyNilSecondID, start: 3, end: 5, text: "Second", channel: .system, attribution: .diarized),
        ]
    )
    let legacyNilChanged = try MeetingRecordProjection().relabel(record: legacyNilRecord, segmentID: legacyNilFirstID, label: "Product Lead")
    let legacyNilFirstCluster = legacyNilChanged.segments.first(where: { $0.id == legacyNilFirstID })?.diarizationClusterID
    let legacyNilSecondCluster = legacyNilChanged.segments.first(where: { $0.id == legacyNilSecondID })?.diarizationClusterID
    try require(legacyNilChanged.segments.first(where: { $0.id == legacyNilSecondID })?.speaker == nil, "legacy nil labels merged unrelated segments")
    try require(legacyNilFirstCluster != nil && legacyNilSecondCluster != nil && legacyNilFirstCluster != legacyNilSecondCluster, "legacy nil segments did not receive separate cluster identities")

    print("meeting-relabel: passed")
}

private func checkAPIRevocation() async throws {
    let (server, credentials, root, store) = try await makeSyntheticServer()
    defer {
        try? server.revokeToken()
        try? FileManager.default.removeItem(at: root)
    }
    let record = WorkspaceRecord(kind: .meeting, title: "Synthetic", text: "Visible")
    try await store.upsert(record)
    let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.revoke")
    defer { connection.cancel() }

    let firstFragment = "GET /v1/records/\(record.id.uuidString) HTTP/1.1\r\nAuthorization: Bearer "
    try await send(Data(firstFragment.utf8), on: connection)
    try await Task.sleep(nanoseconds: 100_000_000)
    server.stop()
    await sendBestEffort(Data("\(credentials.token)\r\n\r\n".utf8), on: connection)

    let response = try await withTimeout(seconds: 2, onTimeout: { connection.cancel() }) {
        await receiveAll(on: connection)
    }
    precondition(!String(decoding: response, as: UTF8.self).contains("Visible"))

    print("api-revoke: passed")
}

private func checkAPIRotation() async throws {
    let (server, credentials, root, _) = try await makeSyntheticServer()
    defer {
        try? server.revokeToken()
        try? FileManager.default.removeItem(at: root)
    }

    let stale = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.rotate.stale")
    defer { stale.cancel() }
    try await send(Data("GET /health HTTP/1.1\r\nAuthorization: Bearer ".utf8), on: stale)
    let rotated = try server.rotateToken()!
    await sendBestEffort(Data("\(credentials.token)\r\n\r\n".utf8), on: stale)
    let staleResponse = try await withTimeout(seconds: 2, onTimeout: { stale.cancel() }) {
        await receiveAll(on: stale)
    }
    precondition(!String(decoding: staleResponse, as: UTF8.self).contains("ok"))

    let fresh = try await connect(to: rotated, label: "com.tumcuctom.evee.core-checks.rotate.fresh")
    defer { fresh.cancel() }
    let request = "GET /health HTTP/1.1\r\nAuthorization: Bearer \(rotated.token)\r\n\r\n"
    try await send(Data(request.utf8), on: fresh)
    let freshResponse = try await withTimeout(seconds: 2, onTimeout: { fresh.cancel() }) {
        await receiveAll(on: fresh)
    }
    precondition(String(decoding: freshResponse, as: UTF8.self).contains("\"status\":\"ok\""))

    print("api-rotate: passed")
}

private func checkAPILimits() async throws {
    let (server, credentials, root, _) = try await makeSyntheticServer()
    defer {
        try? server.revokeToken()
        try? FileManager.default.removeItem(at: root)
    }

    let timeoutConnection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.timeout")
    try await send(Data("GET /health HTTP/1.1\r\nAuthorization: Bearer ".utf8), on: timeoutConnection)
    let timeoutStartedAt = Date()
    _ = try await withTimeout(seconds: 7, onTimeout: { timeoutConnection.cancel() }) {
        await receiveAll(on: timeoutConnection)
    }
    precondition(Date().timeIntervalSince(timeoutStartedAt) >= 4.5)
    timeoutConnection.cancel()

    var retainedConnections: [NWConnection] = []
    defer { retainedConnections.forEach { $0.cancel() } }
    for index in 0..<32 {
        let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.cap.\(index)")
        try await send(Data("GET /health HTTP/1.1\r\nX-Fragment: \(index)".utf8), on: connection)
        retainedConnections.append(connection)
    }

    let excess = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.cap.excess")
    defer { excess.cancel() }
    let response = try await withTimeout(seconds: 2, onTimeout: { excess.cancel() }) {
        await receiveAll(on: excess)
    }
    precondition(response.isEmpty)

    let lastRetained = retainedConnections[31]
    try await send(Data("\r\n\r\n".utf8), on: lastRetained)
    let retainedResponse = try await withTimeout(seconds: 2, onTimeout: { lastRetained.cancel() }) {
        await receiveAll(on: lastRetained)
    }
    precondition(String(decoding: retainedResponse, as: UTF8.self).contains("401 Unauthorised"))

    let oversized = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.oversized")
    defer { oversized.cancel() }
    let oversizedHeader = "GET /health HTTP/1.1\r\nX-Fill: " + String(repeating: "x", count: 129 * 1_024)
    await sendBestEffort(Data(oversizedHeader.utf8), on: oversized)
    let oversizedResponse = try await withTimeout(seconds: 2, onTimeout: { oversized.cancel() }) {
        await receiveAll(on: oversized)
    }
    precondition(String(decoding: oversizedResponse, as: UTF8.self).contains("431 Request Header Fields Too Large"))

    print("api-limits: passed")
}

private func checkAPIStartRaces() async throws {
    for action in ["cancel", "stop", "revoke"] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-api-start-race-\(UUID().uuidString)", isDirectory: true)
        let store = LibraryStore(rootURL: root)
        let secretStore = BlockingSecretStore(value: "old-token")
        let server = LocalAPIServer(store: store, secretStore: secretStore)
        let port = try availablePort()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let startTask = Task { try await server.startWithCredentials(port: port) }
        let didEnterRead = await Task.detached { secretStore.waitForRead() }.value
        try require(didEnterRead, "start did not reach credential loading")

        var revokeTask: Task<Void, Error>?
        switch action {
        case "cancel":
            startTask.cancel()
        case "stop":
            server.stop()
        default:
            revokeTask = Task.detached { try server.revokeToken() }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        secretStore.resumeRead()

        let startResult = await startTask.result
        if let revokeTask { _ = try await revokeTask.value }
        if case .success = startResult {
            throw CoreCheckError.assertionFailed("\(action) allowed an in-flight start to publish credentials")
        }
        try require(server.credentials() == nil, "\(action) left credentials active")
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-start-superseded-\(UUID().uuidString)", isDirectory: true)
    let store = LibraryStore(rootURL: root)
    let secretStore = BlockingSecretStore(value: "old-token")
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let firstStart = Task { try await server.startWithCredentials(port: try availablePort()) }
    let firstReadStarted = await Task.detached { secretStore.waitForRead() }.value
    try require(firstReadStarted, "first start did not reach credential loading")
    let secondStart = Task { try await server.startWithCredentials(port: try availablePort()) }
    try await Task.sleep(nanoseconds: 100_000_000)
    secretStore.resumeRead()
    let firstResult = await firstStart.result
    let secondReadStarted = await Task.detached { secretStore.waitForRead() }.value
    try require(secondReadStarted, "second start did not reach credential loading")
    secretStore.resumeRead()
    let secondResult = await secondStart.result
    if case .success = firstResult {
        throw CoreCheckError.assertionFailed("a superseded start published credentials")
    }
    if case .failure(let error) = secondResult { throw error }

    print("api-start-races: passed")
}

private func checkAPIRevocationPersistence() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-revoke-persistence-\(UUID().uuidString)", isDirectory: true)
    let store = LibraryStore(rootURL: root)
    let oldToken = "old-revoked-token"
    let secretStore = MemorySecretStore(value: oldToken, failsDeletion: true)
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    _ = try await server.startWithCredentials(port: try availablePort())
    do {
        try server.revokeToken()
        throw CoreCheckError.assertionFailed("synthetic deletion failure was not surfaced")
    } catch SyntheticSecretStoreError.deletionFailed {
        // Expected: the durable token must still have been replaced first.
    }

    let restarted = LocalAPIServer(store: store, secretStore: secretStore)
    defer { restarted.stop() }
    let credentials = try await restarted.startWithCredentials(port: try availablePort())
    try require(credentials.token != oldToken, "failed deletion allowed the revoked token to be reused")

    let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.revoke-persistence")
    defer { connection.cancel() }
    let request = "GET /health HTTP/1.1\r\nAuthorization: Bearer \(oldToken)\r\n\r\n"
    try await send(Data(request.utf8), on: connection)
    let response = try await withTimeout(seconds: 2, onTimeout: { connection.cancel() }) {
        await receiveAll(on: connection)
    }
    try require(String(decoding: response, as: UTF8.self).contains("401 Unauthorised"), "old token was accepted")

    print("api-revoke-persistence: passed")
}

private func checkAPIPublicErrors() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-error-\(UUID().uuidString)")
    try Data("synthetic obstruction".utf8).write(to: root)
    let store = LibraryStore(rootURL: root)
    let secretStore = MemorySecretStore(value: "synthetic-token")
    let server = LocalAPIServer(store: store, secretStore: secretStore)
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let credentials = try await server.startWithCredentials(port: try availablePort())
    let connection = try await connect(to: credentials, label: "com.tumcuctom.evee.core-checks.public-error")
    defer { connection.cancel() }
    let request = "GET /v1/records?q=synthetic HTTP/1.1\r\nAuthorization: Bearer \(credentials.token)\r\n\r\n"
    try await send(Data(request.utf8), on: connection)
    let response = try await withTimeout(seconds: 2, onTimeout: { connection.cancel() }) {
        await receiveAll(on: connection)
    }
    let responseText = String(decoding: response, as: UTF8.self)
    try require(responseText.contains("\"error\":\"Internal server error\""), "500 response did not use fixed public text")
    try require(!responseText.contains(root.path), "500 response exposed a storage path")

    let validationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-api-parameters-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: validationRoot) }
    let validationStore = LibraryStore(rootURL: validationRoot)
    try await validationStore.upsert(WorkspaceRecord(
        kind: .meeting,
        title: "Synthetic parameter record",
        text: "parameter sentinel"
    ))
    let validationServer = LocalAPIServer(
        store: validationStore,
        secretStore: MemorySecretStore(value: "parameter-token")
    )
    defer { validationServer.stop() }
    let validationCredentials = try await validationServer.startWithCredentials(port: try availablePort())

    func parameterResponse(for target: String) async throws -> String {
        let connection = try await connect(
            to: validationCredentials,
            label: "com.tumcuctom.evee.core-checks.parameters.\(UUID().uuidString)"
        )
        defer { connection.cancel() }
        let request = "GET \(target) HTTP/1.1\r\nAuthorization: Bearer \(validationCredentials.token)\r\n\r\n"
        try await send(Data(request.utf8), on: connection)
        let data = try await withTimeout(seconds: 2, onTimeout: { connection.cancel() }) {
            await receiveAll(on: connection)
        }
        return String(decoding: data, as: UTF8.self)
    }

    for target in [
        "/v1/records?q=parameter&kind=unknown",
        "/v1/records?q=parameter&limit=many",
        "/v1/records?q=parameter&limit=0",
        "/v1/records?q=parameter&limit=201",
    ] {
        let malformed = try await parameterResponse(for: target)
        try require(malformed.contains("400 Bad Request"), "malformed supplied API filter did not return 400: \(target)")
        try require(!malformed.contains("parameter sentinel"), "malformed supplied API filter broadened into workspace records")
    }
    let defaulted = try await parameterResponse(for: "/v1/records?q=parameter")
    try require(defaulted.contains("200 OK") && defaulted.contains("parameter sentinel"), "absent API filters did not retain valid defaults")
    let valid = try await parameterResponse(for: "/v1/records?q=parameter&kind=meeting&limit=1")
    try require(valid.contains("200 OK") && valid.contains("parameter sentinel"), "valid supplied API filters were rejected")

    print("api-public-errors: passed")
}

private func checkMCPPublicOutput() async throws {
    let syntheticHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-mcp-output-\(UUID().uuidString)", isDirectory: true)
    let libraryRoot = syntheticHome
        .appendingPathComponent("Library/Application Support/Evee", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: syntheticHome) }

    let visibleText = String(repeating: "a", count: 110)
        + " boundary "
        + String(repeating: "b", count: 180)
    let record = WorkspaceRecord(
        kind: .meeting,
        title: "Synthetic MCP",
        text: visibleText,
        rawText: "Private raw",
        audioRelativePath: "Audio/private.caf",
        notes: "Allowed notes outside snippet",
        recoverySourceID: UUID(),
        context: WorkspaceContext(selectedText: "Private selection")
    )
    let library = LibraryStore(rootURL: libraryRoot)
    var settings = EveeSettings()
    settings.mcpEnabled = true
    try await library.save(settings)
    try await library.upsert(record)

    let executable = Bundle.main.executableURL!
        .deletingLastPathComponent()
        .appendingPathComponent("evee-mcp")
    try require(FileManager.default.isExecutableFile(atPath: executable.path), "build evee-mcp before running mcp-public-output")

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["CFFIXED_USER_HOME"] = syntheticHome.path
    process.environment = environment
    try process.run()

    let request: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": [
            "name": "search",
            "arguments": ["query": "boundary", "limit": 5],
        ],
    ]
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
    try input.fileHandleForWriting.close()
    let responseData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "evee-mcp failed: \(String(decoding: errorData, as: UTF8.self))")

    let response = try JSONSerialization.jsonObject(with: responseData) as! [String: Any]
    let result = response["result"] as! [String: Any]
    let content = result["content"] as! [[String: Any]]
    let publicText = content[0]["text"] as! String
    let hits = try JSONSerialization.jsonObject(with: Data(publicText.utf8)) as! [[String: Any]]
    try require(hits.count == 1, "MCP search did not return the synthetic record")
    let hit = hits[0]
    let publicRecord = hit["record"] as! [String: Any]
    let snippet = hit["snippet"] as! String

    for forbidden in ["rawText", "audioRelativePath", "audioTracks", "recoverySourceID", "webhookDeliveries", "operation", "context"] {
        try require(publicRecord[forbidden] == nil, "MCP output exposed \(forbidden)")
    }
    try require(publicRecord["text"] as? String == visibleText, "MCP output omitted requested record text")
    try require(snippet.contains("boundary"), "MCP snippet omitted the query boundary")
    try require(snippet.count <= 248, "MCP snippet exceeded its public boundary")
    try require(!snippet.contains("Allowed notes outside snippet"), "MCP snippet crossed its query boundary")
    try require(!publicText.contains("Private raw") && !publicText.contains("private.caf") && !publicText.contains("Private selection"), "MCP output exposed private persistence data")

    print("mcp-public-output: passed")
}

private func readMCPResponse(from handle: FileHandle) throws -> [String: Any] {
    let data = handle.availableData
    try require(!data.isEmpty, "evee-mcp closed without a response")
    let line: Data
    if let newline = data.firstIndex(of: 0x0A) {
        line = data.subdata(in: data.startIndex..<newline)
    } else {
        line = data
    }
    guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw CoreCheckError.assertionFailed("evee-mcp returned a non-object response")
    }
    return response
}

private func writeMCPRequest(_ request: [String: Any], to handle: FileHandle) throws {
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
}

private func checkMCPRevocation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-mcp-revocation-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
    let codexConfiguration = codexDirectory.appendingPathComponent("config.toml")
    let jsonConfiguration = root.appendingPathComponent("client/config.json")
    let executable = root.appendingPathComponent("Helpers/evee-mcp")
    defer { try? FileManager.default.removeItem(at: root) }

    let legacy = try JSONDecoder().decode(EveeSettings.self, from: Data("{}".utf8))
    try require(!legacy.mcpEnabled, "legacy settings enabled local helper access")

    try FileManager.default.createDirectory(at: jsonConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"display\":\"compact\",\"mcpServers\":{\"evee\":{\"command\":\"old\"},\"other\":{\"command\":\"other\"}}}".utf8).write(to: jsonConfiguration)
    let removal = try MCPRegistration.removeConfiguration(at: jsonConfiguration)
    try require(removal.removedRegistration, "JSON Evee registration was not removed")
    let jsonRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonConfiguration)) as! [String: Any]
    let servers = jsonRoot["mcpServers"] as! [String: Any]
    try require(servers["evee"] == nil, "JSON Evee registration remained")
    try require(servers["other"] != nil && jsonRoot["display"] as? String == "compact", "JSON removal changed unrelated configuration")

    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let noClients = MCPRegistration.detectedClients(fileManager: .default, homeURL: home, applicationSupportURL: support)
    try require(noClients.isEmpty, "empty synthetic home detected a fallback MCP client")
    let noWrites = try MCPRegistration.writeDetectedClientConfigurations(fileManager: .default, homeURL: home, applicationSupportURL: support)
    try require(noWrites.isEmpty, "empty synthetic home produced fallback registration results")
    try require(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Claude/claude_desktop_config.json").path), "fallback Claude configuration was written")

    try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let originalCodex = "model = \"gpt-test\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"
    try Data(originalCodex.utf8).write(to: codexConfiguration)
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let registrationRoot = support.appendingPathComponent("Evee", isDirectory: true)
    let selectedConfiguration = home.appendingPathComponent(".selected/mcp.json")
    let manualConfiguration = home.appendingPathComponent(".manual/mcp.json")
    try FileManager.default.createDirectory(at: selectedConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: manualConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let selectedOriginal = Data("{\"theme\":\"dark\",\"mcpServers\":{\"other\":{\"command\":\"other\"}}}".utf8)
    let manualOriginal = Data("{\"mcpServers\":{\"evee\":{\"command\":\"manual\"}}}".utf8)
    try selectedOriginal.write(to: selectedConfiguration)
    try manualOriginal.write(to: manualConfiguration)
    var accessSettings = EveeSettings()
    let ownedResults = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Selected", configurationURL: selectedConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { settings in
            try require(settings.mcpEnabled, "enable persisted disabled authorization")
        }
    )
    try require(ownedResults.count == 1 && !ownedResults[0].replacedExistingRegistration, "selected absent registration was not recorded")
    accessSettings.mcpEnabled = true
    let ownedRevocation = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { settings in
            try require(!settings.mcpEnabled, "revoke did not persist fail-closed authorization first")
        }
    )
    try require(ownedRevocation.cleanupFailures.isEmpty, "selected registration cleanup failed")
    let selectedRestored = try Data(contentsOf: selectedConfiguration)
    let manualRestored = try Data(contentsOf: manualConfiguration)
    try require(selectedRestored == selectedOriginal, "selected configuration was not restored exactly")
    try require(manualRestored == manualOriginal, "unselected markerless registration was changed")
    try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "owned manifest remained after successful revoke")

    let failedSaveConfiguration = home.appendingPathComponent(".save-failure/new/client.json")
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Save failure", configurationURL: failedSaveConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { settings in
                if settings.mcpEnabled { throw SyntheticMCPPersistenceError.rejected }
            }
        )
        throw CoreCheckError.assertionFailed("enable settings save failure was ignored")
    } catch SyntheticMCPPersistenceError.rejected {
        // Expected: benign retained files/directories do not replace the primary save error.
    }
    let failedSaveRetained = try JSONSerialization.jsonObject(with: Data(contentsOf: failedSaveConfiguration)) as! [String: Any]
    let failedSaveServers = failedSaveRetained["mcpServers"] as! [String: Any]
    try require(failedSaveServers["evee"] == nil, "enable save failure left an Evee registration")
    try require(FileManager.default.fileExists(atPath: failedSaveConfiguration.deletingLastPathComponent().path), "enable rollback unsafely removed a transaction-created directory by name")
    try FileManager.default.removeItem(at: home.appendingPathComponent(".save-failure", isDirectory: true))
    let failedSaveRecovery = try await MCPOwnedRegistration.recover(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    try require(failedSaveRecovery.cleanupFailures.isEmpty, "manual directory cleanup did not complete enable-save recovery: \(failedSaveRecovery.cleanupFailures)")

    let failedRestoreConfiguration = home.appendingPathComponent(".restore-failure/new/client.json")
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Restore failure", configurationURL: failedRestoreConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { settings in
                if settings.mcpEnabled { throw SyntheticMCPPersistenceError.rejected }
            },
            testing: MCPRegistrationTesting(beforeRestore: { _ in throw SyntheticMCPPersistenceError.restoreRejected })
        )
        throw CoreCheckError.assertionFailed("injected rollback failure was ignored")
    } catch MCPOwnedRegistrationError.rollbackFailed(_, let failures) {
        try require(failures.count == 1 && failures[0].contains(failedRestoreConfiguration.path), "rollback did not aggregate the restore failure")
    }
    try require(FileManager.default.fileExists(atPath: failedRestoreConfiguration.path), "failed rollback was reported without its unrestored file")
    var rollbackCleanupSettings = EveeSettings()
    rollbackCleanupSettings.mcpEnabled = true
    let rollbackCleanup = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: rollbackCleanupSettings,
        saveSettings: { _ in }
    )
    try require(rollbackCleanup.cleanupFailures.isEmpty, "later rollback treated benign residue as a destructive cleanup failure")
    try require(rollbackCleanup.cleanupWarnings.contains(where: { $0.message.localizedCaseInsensitiveContains("manual") }), "later rollback did not report retained transaction-created directories")
    try require(FileManager.default.fileExists(atPath: failedRestoreConfiguration.deletingLastPathComponent().path), "later cleanup unsafely removed a transaction-created directory by name")
    try FileManager.default.removeItem(at: home.appendingPathComponent(".restore-failure", isDirectory: true))
    let completedRollbackCleanup = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: rollbackCleanupSettings,
        saveSettings: { _ in }
    )
    try require(completedRollbackCleanup.cleanupFailures.isEmpty, "manual directory cleanup did not finish rollback recovery")

    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Selected", configurationURL: selectedConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    do {
        _ = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: accessSettings,
            saveSettings: { _ in throw SyntheticMCPPersistenceError.rejected }
        )
        throw CoreCheckError.assertionFailed("disable settings save failure was ignored")
    } catch SyntheticMCPPersistenceError.rejected {
        // Expected.
    }
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "failed disable discarded ownership manifest")
    let stillRegisteredRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: selectedConfiguration)) as! [String: Any]
    let stillRegisteredServers = stillRegisteredRoot["mcpServers"] as! [String: Any]
    let stillRegisteredEvee = stillRegisteredServers["evee"] as! [String: Any]
    try require(stillRegisteredEvee["command"] as? String == executable.path, "failed disable cleaned registration despite remaining enabled")
    _ = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )

    let metadataDirectory = home.appendingPathComponent(".metadata", isDirectory: true)
    let metadataTarget = metadataDirectory.appendingPathComponent("actual.json")
    let metadataLink = metadataDirectory.appendingPathComponent("linked.json")
    try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
    let metadataOriginal = Data("{\"mcpServers\":{\"other\":{\"command\":\"other\"}}}".utf8)
    try metadataOriginal.write(to: metadataTarget)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: metadataTarget.path)
    let metadataAttributeName = "user.evee.core-check"
    let metadataAttributeValue = Data("preserved".utf8)
    let metadataAttributeWrite = metadataAttributeValue.withUnsafeBytes {
        setxattr(metadataTarget.path, metadataAttributeName, $0.baseAddress, metadataAttributeValue.count, 0, 0)
    }
    try require(metadataAttributeWrite == 0, "test could not set synthetic configuration metadata")
    try FileManager.default.createSymbolicLink(atPath: metadataLink.path, withDestinationPath: "actual.json")
    let targetAttributes = try FileManager.default.attributesOfItem(atPath: metadataTarget.path)
    let targetInode = targetAttributes[.systemFileNumber] as? NSNumber
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Linked", configurationURL: metadataLink)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    _ = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )
    let restoredAttributes = try FileManager.default.attributesOfItem(atPath: metadataTarget.path)
    try require((restoredAttributes[.systemFileNumber] as? NSNumber) == targetInode, "registration replaced the existing target file identity")
    try require((restoredAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, "registration did not restore the target mode")
    let restoredLinkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: metadataLink.path)
    let restoredMetadata = try Data(contentsOf: metadataTarget)
    let restoredAttributeSize = getxattr(metadataTarget.path, metadataAttributeName, nil, 0, 0, 0)
    var restoredAttribute = Data(count: max(0, restoredAttributeSize))
    let restoredAttributeCapacity = restoredAttribute.count
    let restoredAttributeRead = restoredAttribute.withUnsafeMutableBytes {
        getxattr(metadataTarget.path, metadataAttributeName, $0.baseAddress, restoredAttributeCapacity, 0, 0)
    }
    try require(restoredLinkDestination == "actual.json", "registration replaced or changed the configuration symlink")
    try require(restoredMetadata == metadataOriginal, "symlink target content was not restored")
    try require(restoredAttributeRead == metadataAttributeValue.count && restoredAttribute == metadataAttributeValue, "registration did not preserve target extended attributes")

    let escapedTarget = root.appendingPathComponent("outside-home.json")
    let escapedLink = metadataDirectory.appendingPathComponent("escaped.json")
    let escapedOriginal = Data("{\"outside\":true}".utf8)
    try escapedOriginal.write(to: escapedTarget)
    try FileManager.default.createSymbolicLink(atPath: escapedLink.path, withDestinationPath: escapedTarget.path)
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Escaped", configurationURL: escapedLink)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in }
        )
        throw CoreCheckError.assertionFailed("registration accepted a symlink escaping the approved configuration root")
    } catch MCPOwnedRegistrationError.unsafeConfiguration {
        // Expected.
    }
    let escapedRestored = try Data(contentsOf: escapedTarget)
    try require(escapedRestored == escapedOriginal, "rejected symlink escape changed its target")

    let concurrentEditConfiguration = home.appendingPathComponent(".concurrent/mcp.json")
    try FileManager.default.createDirectory(at: concurrentEditConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let concurrentBefore = Data("{\"display\":\"compact\",\"mcpServers\":{\"other\":{\"command\":\"before\"}}}".utf8)
    try concurrentBefore.write(to: concurrentEditConfiguration)
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Concurrent edits", configurationURL: concurrentEditConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    var concurrentRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: concurrentEditConfiguration)) as! [String: Any]
    concurrentRoot["display"] = "expanded"
    var concurrentServers = concurrentRoot["mcpServers"] as! [String: Any]
    concurrentServers["other"] = ["command": "after"]
    concurrentServers["new"] = ["command": "new"]
    concurrentRoot["mcpServers"] = concurrentServers
    try JSONSerialization.data(withJSONObject: concurrentRoot, options: [.prettyPrinted, .sortedKeys]).write(to: concurrentEditConfiguration)
    let concurrentRevoke = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )
    try require(concurrentRevoke.cleanupFailures.isEmpty, "unrelated concurrent edits caused a cleanup conflict")
    let concurrentRestored = try JSONSerialization.jsonObject(with: Data(contentsOf: concurrentEditConfiguration)) as! [String: Any]
    let concurrentRestoredServers = concurrentRestored["mcpServers"] as! [String: Any]
    try require(concurrentRestored["display"] as? String == "expanded", "revoke discarded an unrelated root edit")
    try require((concurrentRestoredServers["other"] as? [String: Any])?["command"] as? String == "after" && concurrentRestoredServers["new"] != nil, "revoke discarded unrelated server edits")
    try require(concurrentRestoredServers["evee"] == nil, "revoke left the owned Evee entry")

    let concurrentTOMLBefore = "model = \"before\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"
    try Data(concurrentTOMLBefore.utf8).write(to: codexConfiguration)
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Codex concurrent", configurationURL: codexConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    var concurrentTOML = try String(contentsOf: codexConfiguration)
    concurrentTOML = concurrentTOML.replacingOccurrences(of: "model = \"before\"", with: "model = \"after\"")
    concurrentTOML += "\n[features]\nnew_option = true\n"
    try Data(concurrentTOML.utf8).write(to: codexConfiguration)
    let tomlRevoke = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )
    try require(tomlRevoke.cleanupFailures.isEmpty, "unrelated TOML edits caused a cleanup conflict")
    let concurrentTOMLRestored = try String(contentsOf: codexConfiguration)
    try require(concurrentTOMLRestored.contains("model = \"after\"") && concurrentTOMLRestored.contains("new_option = true"), "revoke discarded unrelated TOML edits")
    try require(!concurrentTOMLRestored.contains("mcp_servers.evee"), "revoke left the owned TOML table")
    try Data(originalCodex.utf8).write(to: codexConfiguration)

    let createdEditDirectory = home.appendingPathComponent(".created-edits", isDirectory: true)
    try FileManager.default.createDirectory(at: createdEditDirectory, withIntermediateDirectories: true)
    let createdJSONConfiguration = createdEditDirectory.appendingPathComponent("new.json")
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Created JSON", configurationURL: createdJSONConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    var createdJSONRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: createdJSONConfiguration)) as! [String: Any]
    var createdJSONServers = createdJSONRoot["mcpServers"] as! [String: Any]
    createdJSONServers["later"] = ["command": "later"]
    createdJSONRoot["mcpServers"] = createdJSONServers
    createdJSONRoot["theme"] = "later"
    try JSONSerialization.data(withJSONObject: createdJSONRoot, options: [.prettyPrinted, .sortedKeys]).write(to: createdJSONConfiguration)
    let createdJSONRevoke = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )
    try require(createdJSONRevoke.cleanupFailures.isEmpty, "new JSON cleanup conflicted with unrelated additions")
    try require(createdJSONRevoke.cleanupWarnings.contains(where: { $0.configurationURL == createdJSONConfiguration && $0.message.localizedCaseInsensitiveContains("retained") }), "new JSON cleanup did not report its retained file")
    let createdJSONRestored = try JSONSerialization.jsonObject(with: Data(contentsOf: createdJSONConfiguration)) as! [String: Any]
    let createdJSONRestoredServers = createdJSONRestored["mcpServers"] as! [String: Any]
    try require(createdJSONRestored["theme"] as? String == "later" && createdJSONRestoredServers["later"] != nil, "new JSON cleanup discarded unrelated additions")
    try require(createdJSONRestoredServers["evee"] == nil, "new JSON cleanup retained the Evee-owned entry")

    let createdTOMLConfiguration = createdEditDirectory.appendingPathComponent("new.toml")
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Created TOML", configurationURL: createdTOMLConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    var createdTOMLCurrent = try String(contentsOf: createdTOMLConfiguration)
    createdTOMLCurrent += "\n[features]\nlater = true\n"
    try Data(createdTOMLCurrent.utf8).write(to: createdTOMLConfiguration)
    let createdTOMLRevoke = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )
    try require(createdTOMLRevoke.cleanupFailures.isEmpty, "new TOML cleanup conflicted with unrelated additions")
    try require(createdTOMLRevoke.cleanupWarnings.contains(where: { $0.configurationURL == createdTOMLConfiguration && $0.message.localizedCaseInsensitiveContains("retained") }), "new TOML cleanup did not report its retained file")
    let createdTOMLRestored = try String(contentsOf: createdTOMLConfiguration)
    try require(createdTOMLRestored.contains("[features]") && createdTOMLRestored.contains("later = true"), "new TOML cleanup discarded unrelated additions")
    try require(!createdTOMLRestored.contains("mcp_servers.evee"), "new TOML cleanup retained the Evee-owned table")

    for (suffix, pathExtension) in [("json", "json"), ("toml", "toml")] {
        let formerUnlinkConfiguration = createdEditDirectory.appendingPathComponent("former-unlink-\(suffix).\(pathExtension)")
        let formerUnlinkDetached = createdEditDirectory.appendingPathComponent("former-unlink-\(suffix)-detached.\(pathExtension)")
        let formerUnlinkReplacement = createdEditDirectory.appendingPathComponent("former-unlink-\(suffix)-replacement.\(pathExtension)")
        let replacementSentinel = Data((pathExtension == "json" ? "{\"replacement\":\"\(suffix)\"}" : "replacement = \"\(suffix)\"\n").utf8)
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Former unlink \(suffix)", configurationURL: formerUnlinkConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in }
        )
        try replacementSentinel.write(to: formerUnlinkReplacement)
        let formerUnlinkOutcome = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: accessSettings,
            saveSettings: { _ in },
            testing: MCPRegistrationTesting(checkpoint: { checkpoint, url in
                if checkpoint == .beforeRetainedFileRewrite, url == formerUnlinkConfiguration {
                    guard link(formerUnlinkConfiguration.path, formerUnlinkDetached.path) == 0,
                          rename(formerUnlinkReplacement.path, formerUnlinkConfiguration.path) == 0 else {
                        throw CoreCheckError.assertionFailed("could not inject \(suffix) former-unlink replacement")
                    }
                }
            })
        )
        let replacementCurrent = try Data(contentsOf: formerUnlinkConfiguration)
        try require(replacementCurrent == replacementSentinel, "\(suffix) former-unlink cleanup removed or changed the replacement")
        try require(formerUnlinkOutcome.cleanupFailures.contains(where: { $0.configurationURL == formerUnlinkConfiguration }), "\(suffix) former-unlink replacement did not retain a binding conflict")
        try FileManager.default.removeItem(at: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot))
        try FileManager.default.removeItem(at: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot))
    }

    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Owned conflict", configurationURL: concurrentEditConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    var conflictRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: concurrentEditConfiguration)) as! [String: Any]
    var conflictServers = conflictRoot["mcpServers"] as! [String: Any]
    conflictServers["evee"] = ["command": "changed-by-user", "args": []]
    conflictRoot["mcpServers"] = conflictServers
    try JSONSerialization.data(withJSONObject: conflictRoot, options: [.prettyPrinted, .sortedKeys]).write(to: concurrentEditConfiguration)
    let conflictRevoke = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in }
    )
    try require(conflictRevoke.cleanupFailures.count == 1 && conflictRevoke.cleanupFailures[0].message.localizedCaseInsensitiveContains("conflict"), "changed owned entry did not report a conflict")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "owned-entry conflict discarded the manifest")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "owned-entry conflict discarded the recovery journal")
    let conflictedCurrent = try String(contentsOf: concurrentEditConfiguration)
    try require(conflictedCurrent.contains("changed-by-user"), "owned-entry conflict was overwritten silently")
    conflictRoot["mcpServers"] = concurrentRestoredServers.merging(["evee": ["command": executable.path, "args": []]]) { _, replacement in replacement }
    try JSONSerialization.data(withJSONObject: conflictRoot, options: [.prettyPrinted, .sortedKeys]).write(to: concurrentEditConfiguration)
    let resolvedConflict = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: {
            var value = accessSettings
            value.mcpEnabled = false
            return value
        }(),
        saveSettings: { _ in }
    )
    try require(resolvedConflict.cleanupFailures.isEmpty, "resolved owned-entry conflict did not finish cleanup")

    let swapDirectory = home.appendingPathComponent(".swap", isDirectory: true)
    let safeSwapTarget = swapDirectory.appendingPathComponent("inside.json")
    let swapLink = swapDirectory.appendingPathComponent("client.json")
    let outsideSwapTarget = root.appendingPathComponent("outside-swap.json")
    let outsideSwapSentinel = Data("{\"outside\":\"sentinel\"}".utf8)
    try FileManager.default.createDirectory(at: swapDirectory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: safeSwapTarget)
    try outsideSwapSentinel.write(to: outsideSwapTarget)
    try FileManager.default.createSymbolicLink(atPath: swapLink.path, withDestinationPath: "inside.json")
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Swap", configurationURL: swapLink)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in },
            testing: MCPRegistrationTesting(checkpoint: { checkpoint, _ in
                if checkpoint == .beforeTargetMutation {
                    try FileManager.default.removeItem(at: swapLink)
                    try FileManager.default.createSymbolicLink(atPath: swapLink.path, withDestinationPath: outsideSwapTarget.path)
                }
            })
        )
        throw CoreCheckError.assertionFailed("target swap between validation and mutation was accepted")
    } catch MCPOwnedRegistrationError.unsafeConfiguration {
        // Expected.
    }
    let outsideSwapRestored = try Data(contentsOf: outsideSwapTarget)
    try require(outsideSwapRestored == outsideSwapSentinel, "descriptor race wrote through a swapped path outside the approved root")

    let parentSwapRoot = home.appendingPathComponent(".parent-swap", isDirectory: true)
    let parentSwapActive = parentSwapRoot.appendingPathComponent("active", isDirectory: true)
    let parentSwapHeld = parentSwapRoot.appendingPathComponent("held", isDirectory: true)
    let parentSwapConfiguration = parentSwapActive.appendingPathComponent("mcp.json")
    let outsideSwapDirectory = root.appendingPathComponent("outside-parent", isDirectory: true)
    let outsideParentSentinel = outsideSwapDirectory.appendingPathComponent("mcp.json")
    try FileManager.default.createDirectory(at: parentSwapActive, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideSwapDirectory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: parentSwapConfiguration)
    try outsideSwapSentinel.write(to: outsideParentSentinel)
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Parent swap", configurationURL: parentSwapConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in },
            testing: MCPRegistrationTesting(checkpoint: { checkpoint, _ in
                if checkpoint == .beforeTargetMutation {
                    try FileManager.default.moveItem(at: parentSwapActive, to: parentSwapHeld)
                    try FileManager.default.createSymbolicLink(atPath: parentSwapActive.path, withDestinationPath: outsideSwapDirectory.path)
                }
            })
        )
        throw CoreCheckError.assertionFailed("intermediate parent swap between validation and mutation was accepted")
    } catch MCPOwnedRegistrationError.unsafeConfiguration {
        // Expected.
    }
    let outsideParentRestored = try Data(contentsOf: outsideParentSentinel)
    try require(outsideParentRestored == outsideSwapSentinel, "descriptor traversal wrote through a swapped intermediate parent")

    let regularSwapDirectory = home.appendingPathComponent(".regular-swap", isDirectory: true)
    try FileManager.default.createDirectory(at: regularSwapDirectory, withIntermediateDirectories: true)
    let prewriteConfiguration = regularSwapDirectory.appendingPathComponent("prewrite.json")
    let prewriteReplacement = regularSwapDirectory.appendingPathComponent("prewrite-replacement.json")
    let prewriteOriginal = Data("{\"keep\":\"original\"}".utf8)
    let prewriteSentinel = Data("{\"replacement\":\"prewrite\"}".utf8)
    try prewriteOriginal.write(to: prewriteConfiguration)
    try prewriteSentinel.write(to: prewriteReplacement)
    let prewriteSavedSettings = LockedValues<Bool>()
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Prewrite replacement", configurationURL: prewriteConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { prewriteSavedSettings.append($0.mcpEnabled) },
            testing: MCPRegistrationTesting(checkpoint: { checkpoint, _ in
                if checkpoint == .beforeTargetWrite {
                    guard rename(prewriteReplacement.path, prewriteConfiguration.path) == 0 else {
                        throw CoreCheckError.assertionFailed("could not inject prewrite regular-file replacement")
                    }
                }
            })
        )
        throw CoreCheckError.assertionFailed("prewrite regular-file replacement was accepted")
    } catch let error as CoreCheckError {
        throw error
    } catch {
        // Expected descriptor/name binding conflict.
    }
    let prewriteCurrent = try Data(contentsOf: prewriteConfiguration)
    try require(prewriteCurrent == prewriteSentinel, "prewrite binding rejection modified the replacement sentinel")
    try require(!prewriteSavedSettings.values.contains(true), "prewrite binding conflict committed enabled settings")
    try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "prewrite binding conflict committed an ownership manifest")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "prewrite binding conflict discarded recovery state")
    try FileManager.default.removeItem(at: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot))

    let postwriteConfiguration = regularSwapDirectory.appendingPathComponent("postwrite.json")
    let postwriteReplacement = regularSwapDirectory.appendingPathComponent("postwrite-replacement.json")
    let postwriteDetached = regularSwapDirectory.appendingPathComponent("postwrite-detached.json")
    let postwriteOriginal = Data("{\"keep\":\"postwrite-original\"}".utf8)
    let postwriteSentinel = Data("{\"replacement\":\"postwrite\"}".utf8)
    try postwriteOriginal.write(to: postwriteConfiguration)
    try postwriteSentinel.write(to: postwriteReplacement)
    let postwriteSavedSettings = LockedValues<Bool>()
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Postwrite replacement", configurationURL: postwriteConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { postwriteSavedSettings.append($0.mcpEnabled) },
            testing: MCPRegistrationTesting(checkpoint: { checkpoint, _ in
                if checkpoint == .afterTargetWriteBeforeBindingCheck {
                    guard link(postwriteConfiguration.path, postwriteDetached.path) == 0,
                          rename(postwriteReplacement.path, postwriteConfiguration.path) == 0 else {
                        throw CoreCheckError.assertionFailed("could not inject postwrite regular-file replacement")
                    }
                }
            })
        )
        throw CoreCheckError.assertionFailed("postwrite regular-file replacement was accepted")
    } catch let error as CoreCheckError {
        throw error
    } catch {
        // Expected descriptor/name binding conflict.
    }
    let postwriteCurrent = try Data(contentsOf: postwriteConfiguration)
    let postwriteHeldCurrent = try Data(contentsOf: postwriteDetached)
    try require(postwriteCurrent == postwriteSentinel, "postwrite binding rejection modified the replacement sentinel")
    try require(postwriteHeldCurrent == postwriteOriginal, "postwrite binding rejection did not restore the held original inode")
    try require(!postwriteSavedSettings.values.contains(true), "postwrite binding conflict committed enabled settings")
    try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "postwrite binding conflict committed an ownership manifest")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "postwrite binding conflict discarded recovery state")
    try FileManager.default.removeItem(at: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot))

    for crashCheckpoint in [
        MCPRegistrationCheckpoint.afterMutationIntent,
        .duringExistingTargetWrite,
        .afterTargetWriteBeforeBindingCheck,
    ] {
        let intentConfiguration = home.appendingPathComponent(".intent-\(crashCheckpoint.rawValue)/mcp.json")
        try FileManager.default.createDirectory(at: intentConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
        let intentBefore = Data("{\"keep\":\"\(crashCheckpoint.rawValue)\"}".utf8)
        try intentBefore.write(to: intentConfiguration)
        do {
            _ = try await MCPOwnedRegistration.enable(
                clients: [MCPClientConfiguration(name: "Intent crash", configurationURL: intentConfiguration)],
                executableURL: executable,
                allowedRootURLs: [home],
                storageRootURL: registrationRoot,
                settings: EveeSettings(),
                saveSettings: { _ in },
                testing: MCPRegistrationTesting(crashAt: crashCheckpoint)
            )
            throw CoreCheckError.assertionFailed("injected \(crashCheckpoint.rawValue) crash completed enable")
        } catch MCPRegistrationInjectedCrash.checkpoint(crashCheckpoint) {
            // Expected.
        }
        try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "\(crashCheckpoint.rawValue) crash discarded mutation intent")
        if crashCheckpoint == .duringExistingTargetWrite {
            let partial = try Data(contentsOf: intentConfiguration)
            try require(partial != intentBefore, "partial-write checkpoint ran before mutating the target")
        }
        let intentRecovery = try await MCPOwnedRegistration.recover(
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in }
        )
        try require(intentRecovery.cleanupFailures.isEmpty, "\(crashCheckpoint.rawValue) recovery failed")
        let intentRestored = try Data(contentsOf: intentConfiguration)
        try require(intentRestored == intentBefore, "\(crashCheckpoint.rawValue) recovery did not restore the exact before-image")
        try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "\(crashCheckpoint.rawValue) recovery retained its journal")
    }

    let partialTOMLConfiguration = home.appendingPathComponent(".intent-partial-toml/config.toml")
    try FileManager.default.createDirectory(at: partialTOMLConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partialTOMLBefore = Data("model = \"before\"\n\n[features]\nkeep = true\n".utf8)
    try partialTOMLBefore.write(to: partialTOMLConfiguration)
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Partial TOML", configurationURL: partialTOMLConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in },
            testing: MCPRegistrationTesting(crashAt: .duringExistingTargetWrite)
        )
        throw CoreCheckError.assertionFailed("injected partial TOML crash completed enable")
    } catch MCPRegistrationInjectedCrash.checkpoint(.duringExistingTargetWrite) {
        // Expected.
    }
    let partialTOMLRecovery = try await MCPOwnedRegistration.recover(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    try require(partialTOMLRecovery.cleanupFailures.isEmpty, "partial TOML recovery reported a conflict")
    let partialTOMLRestored = try Data(contentsOf: partialTOMLConfiguration)
    try require(partialTOMLRestored == partialTOMLBefore, "partial TOML recovery accepted a parseable truncated prefix")

    let absentIntentDirectory = home.appendingPathComponent(".absent-intent", isDirectory: true)
    let absentIntentConfiguration = absentIntentDirectory.appendingPathComponent("mcp.json")
    try FileManager.default.createDirectory(at: absentIntentDirectory, withIntermediateDirectories: true)
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Absent intent", configurationURL: absentIntentConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in },
            testing: MCPRegistrationTesting(crashAt: .afterAbsentTargetCreation)
        )
        throw CoreCheckError.assertionFailed("injected absent-create crash completed enable")
    } catch MCPRegistrationInjectedCrash.checkpoint(.afterAbsentTargetCreation) {
        // Expected.
    }
    try require(FileManager.default.fileExists(atPath: absentIntentConfiguration.path), "absent-create checkpoint ran before target creation")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "absent-create crash discarded mutation intent")
    let absentIntentRecovery = try await MCPOwnedRegistration.recover(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    try require(absentIntentRecovery.cleanupFailures.isEmpty, "absent-create recovery failed")
    try require(absentIntentRecovery.cleanupWarnings.contains(where: { $0.configurationURL == absentIntentConfiguration }), "absent-create recovery did not report the retained file")
    try require(FileManager.default.fileExists(atPath: absentIntentConfiguration.path), "absent-create recovery removed the transaction-created file by name")
    let absentIntentRetained = try JSONSerialization.jsonObject(with: Data(contentsOf: absentIntentConfiguration)) as! [String: Any]
    let absentIntentServers = absentIntentRetained["mcpServers"] as! [String: Any]
    try require(absentIntentServers["evee"] == nil, "absent-create recovery retained the Evee entry")

    let revokeCrashDirectory = home.appendingPathComponent(".revoke-crash", isDirectory: true)
    try FileManager.default.createDirectory(at: revokeCrashDirectory, withIntermediateDirectories: true)
    for crashCheckpoint in [MCPRegistrationCheckpoint.afterRevokeJournal, .afterDisabledSettingsPersistence] {
        let revokeCrashConfiguration = revokeCrashDirectory.appendingPathComponent("\(crashCheckpoint.rawValue).json")
        let revokeCrashBefore = Data("{\"keep\":\"\(crashCheckpoint.rawValue)\"}".utf8)
        try revokeCrashBefore.write(to: revokeCrashConfiguration)
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Revoke crash", configurationURL: revokeCrashConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in }
        )
        let revokeCrashSaves = LockedValues<Bool>()
        do {
            _ = try await MCPOwnedRegistration.revoke(
                allowedRootURLs: [home],
                storageRootURL: registrationRoot,
                settings: accessSettings,
                saveSettings: { revokeCrashSaves.append($0.mcpEnabled) },
                testing: MCPRegistrationTesting(crashAt: crashCheckpoint)
            )
            throw CoreCheckError.assertionFailed("injected \(crashCheckpoint.rawValue) crash completed revoke")
        } catch MCPRegistrationInjectedCrash.checkpoint(crashCheckpoint) {
            // Expected.
        }
        try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "\(crashCheckpoint.rawValue) revoke crash discarded its fail-closed journal")
        if crashCheckpoint == .afterRevokeJournal {
            try require(!revokeCrashSaves.values.contains(false), "revoke persisted disabled before its journal was durable")
        } else {
            try require(revokeCrashSaves.values.contains(false), "post-disable crash ran before disabled authorization persistence")
        }
        let revokeCrashRecovery = try await MCPOwnedRegistration.recover(
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: accessSettings,
            saveSettings: { revokeCrashSaves.append($0.mcpEnabled) }
        )
        try require(revokeCrashRecovery.cleanupFailures.isEmpty, "\(crashCheckpoint.rawValue) revoke recovery failed")
        let revokeCrashRestored = try Data(contentsOf: revokeCrashConfiguration)
        try require(revokeCrashRestored == revokeCrashBefore, "\(crashCheckpoint.rawValue) revoke recovery did not restore the exact before-image")
        try require(revokeCrashSaves.values.contains(false), "\(crashCheckpoint.rawValue) recovery did not persist fail-closed authorization")
    }

    let mkdirIntentRoot = home.appendingPathComponent(".mkdir-intent", isDirectory: true)
    let mkdirIntentConfiguration = mkdirIntentRoot.appendingPathComponent("child/mcp.json")
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Directory intent", configurationURL: mkdirIntentConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in },
            testing: MCPRegistrationTesting(crashAt: .afterDirectoryCreationBeforeIdentity)
        )
        throw CoreCheckError.assertionFailed("injected directory-creation crash completed enable")
    } catch MCPRegistrationInjectedCrash.checkpoint(.afterDirectoryCreationBeforeIdentity) {
        // Expected.
    }
    try require(FileManager.default.fileExists(atPath: mkdirIntentRoot.path), "directory crash checkpoint ran before mkdirat")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "directory crash discarded its durable intent")
    let mkdirIntentRecovery = try await MCPOwnedRegistration.recover(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    try require(mkdirIntentRecovery.cleanupFailures.isEmpty, "unbound directory intent became a destructive cleanup failure")
    try require(mkdirIntentRecovery.cleanupWarnings.contains(where: {
        $0.configurationURL == mkdirIntentRoot && $0.message.localizedCaseInsensitiveContains("manual")
    }), "unbound directory residue was silently finalized")
    try require(FileManager.default.fileExists(atPath: mkdirIntentRoot.path), "recovery removed an unbound directory by name")
    try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "warning-only directory recovery retained a fail-closed journal")

    for crashCheckpoint in [MCPRegistrationCheckpoint.afterFirstClientMutation, .beforeManifestWrite] {
        let crashConfiguration = home.appendingPathComponent(".crash-\(crashCheckpoint.rawValue)/mcp.json")
        try FileManager.default.createDirectory(at: crashConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
        let crashBefore = Data("{\"keep\":\"before\"}".utf8)
        try crashBefore.write(to: crashConfiguration)
        do {
            _ = try await MCPOwnedRegistration.enable(
                clients: [MCPClientConfiguration(name: "Crash", configurationURL: crashConfiguration)],
                executableURL: executable,
                allowedRootURLs: [home],
                storageRootURL: registrationRoot,
                settings: EveeSettings(),
                saveSettings: { _ in },
                testing: MCPRegistrationTesting(crashAt: crashCheckpoint)
            )
            throw CoreCheckError.assertionFailed("injected \(crashCheckpoint.rawValue) crash completed enable")
        } catch MCPRegistrationInjectedCrash.checkpoint(crashCheckpoint) {
            // Expected.
        }
        try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "injected crash did not retain its durable journal")
        if crashCheckpoint == .afterFirstClientMutation {
            let recovery = try await MCPOwnedRegistration.recover(
                allowedRootURLs: [home],
                storageRootURL: registrationRoot,
                settings: EveeSettings(),
                saveSettings: { _ in }
            )
            try require(recovery.cleanupFailures.isEmpty, "journal recovery failed after \(crashCheckpoint.rawValue)")
        } else {
            _ = try await MCPOwnedRegistration.enable(
                clients: [MCPClientConfiguration(name: "Recovered enable", configurationURL: crashConfiguration)],
                executableURL: executable,
                allowedRootURLs: [home],
                storageRootURL: registrationRoot,
                settings: EveeSettings(),
                saveSettings: { _ in }
            )
            var recoveryEnabled = EveeSettings()
            recoveryEnabled.mcpEnabled = true
            let recoveredRevoke = try await MCPOwnedRegistration.revoke(
                allowedRootURLs: [home],
                storageRootURL: registrationRoot,
                settings: recoveryEnabled,
                saveSettings: { _ in }
            )
            try require(recoveredRevoke.cleanupFailures.isEmpty, "next enable did not recover the unfinished journal")
        }
        let crashRestored = try Data(contentsOf: crashConfiguration)
        try require(crashRestored == crashBefore, "journal recovery did not restore \(crashCheckpoint.rawValue)")
        try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot).path), "successful recovery retained its journal")
    }

    let createdIdentityConfiguration = home.appendingPathComponent(".created-identity/child/mcp.json")
    let createdIdentityDirectory = createdIdentityConfiguration.deletingLastPathComponent()
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Created identity", configurationURL: createdIdentityConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    let identityOutcome = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { _ in },
        testing: MCPRegistrationTesting(checkpoint: { checkpoint, url in
            if checkpoint == .beforeDirectoryCleanup, url == createdIdentityDirectory {
                try FileManager.default.removeItem(at: createdIdentityDirectory)
                try FileManager.default.createDirectory(at: createdIdentityDirectory, withIntermediateDirectories: true)
            }
        })
    )
    try require(identityOutcome.cleanupFailures.contains(where: { $0.message.localizedCaseInsensitiveContains("identity") }), "replacement directory did not report an identity conflict")
    try require(FileManager.default.fileExists(atPath: createdIdentityDirectory.path), "cleanup removed a replacement empty directory")
    try FileManager.default.removeItem(at: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot))
    try? FileManager.default.removeItem(at: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot))
    try FileManager.default.removeItem(at: home.appendingPathComponent(".created-identity", isDirectory: true))

    let serializedConfiguration = home.appendingPathComponent(".serialized/mcp.json")
    try FileManager.default.createDirectory(at: serializedConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    let serializedBefore = Data("{\"serial\":\"before\"}".utf8)
    try serializedBefore.write(to: serializedConfiguration)
    let enableHasLease = DispatchSemaphore(value: 0)
    let releaseEnable = DispatchSemaphore(value: 0)
    let revokeSaved = DispatchSemaphore(value: 0)
    let serializedEnable = Task {
        try await MCPOwnedRegistration.enable(
            clients: [MCPClientConfiguration(name: "Serialized", configurationURL: serializedConfiguration)],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: EveeSettings(),
            saveSettings: { _ in },
            testing: MCPRegistrationTesting(checkpoint: { checkpoint, _ in
                if checkpoint == .transactionLeaseAcquired {
                    enableHasLease.signal()
                    releaseEnable.wait()
                }
            })
        )
    }
    try require(enableHasLease.wait(timeout: .now() + 5) == .success, "enable did not acquire the complete transaction lease")
    let serializedRevoke = Task {
        var serializedEnabled = EveeSettings()
        serializedEnabled.mcpEnabled = true
        let outcome = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [home],
            storageRootURL: registrationRoot,
            settings: serializedEnabled,
            saveSettings: { settings in
                if !settings.mcpEnabled { revokeSaved.signal() }
            }
        )
        return outcome
    }
    try await Task.sleep(for: .milliseconds(150))
    try require(revokeSaved.wait(timeout: .now()) == .timedOut, "revoke entered while enable still owned the transaction lease")
    releaseEnable.signal()
    _ = try await serializedEnable.value
    let serializedOutcome = try await serializedRevoke.value
    try require(serializedOutcome.cleanupFailures.isEmpty, "serialized revoke failed after waiting for enable")
    let serializedRestored = try Data(contentsOf: serializedConfiguration)
    try require(serializedRestored == serializedBefore, "concurrent revoke did not restore the manifest produced by the completed enable")
    try require(!FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "serialized enable/revoke left a newer manifest behind")

    let partialGood = metadataDirectory.appendingPathComponent("partial-good.json")
    let partialTarget = metadataDirectory.appendingPathComponent("partial-target.json")
    let partialAlternate = metadataDirectory.appendingPathComponent("partial-alternate.json")
    let partialLink = metadataDirectory.appendingPathComponent("partial-link.json")
    let partialGoodOriginal = Data("{\"keep\":\"good\"}".utf8)
    let partialTargetOriginal = Data("{\"keep\":\"linked\"}".utf8)
    try partialGoodOriginal.write(to: partialGood)
    try partialTargetOriginal.write(to: partialTarget)
    try Data("{\"keep\":\"alternate\"}".utf8).write(to: partialAlternate)
    try FileManager.default.createSymbolicLink(atPath: partialLink.path, withDestinationPath: "partial-target.json")
    _ = try await MCPOwnedRegistration.enable(
        clients: [
            MCPClientConfiguration(name: "Partial good", configurationURL: partialGood),
            MCPClientConfiguration(name: "Partial linked", configurationURL: partialLink),
        ],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: EveeSettings(),
        saveSettings: { _ in }
    )
    try FileManager.default.removeItem(at: partialLink)
    try FileManager.default.createSymbolicLink(atPath: partialLink.path, withDestinationPath: "partial-alternate.json")
    let partialOutcome = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: accessSettings,
        saveSettings: { settings in
            try require(!settings.mcpEnabled, "partial cleanup ran before fail-closed persistence")
        }
    )
    try require(partialOutcome.removals.count == 1 && partialOutcome.cleanupFailures.count == 1, "partial cleanup did not accurately separate restored and failed targets")
    let partialGoodRestored = try Data(contentsOf: partialGood)
    try require(partialGoodRestored == partialGoodOriginal, "partial revoke did not restore its safe target")
    try require(FileManager.default.fileExists(atPath: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot).path), "partial cleanup discarded the remaining ownership snapshot")
    try FileManager.default.removeItem(at: partialLink)
    try FileManager.default.createSymbolicLink(atPath: partialLink.path, withDestinationPath: "partial-target.json")
    var alreadyDisabled = accessSettings
    alreadyDisabled.mcpEnabled = false
    let completedPartialCleanup = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: registrationRoot,
        settings: alreadyDisabled,
        saveSettings: { _ in }
    )
    try require(completedPartialCleanup.cleanupFailures.count == 1, "changed symlink identity was silently accepted on retry")
    try partialTargetOriginal.write(to: partialTarget)
    try FileManager.default.removeItem(at: MCPOwnedRegistration.manifestURL(storageRootURL: registrationRoot))
    try FileManager.default.removeItem(at: MCPOwnedRegistration.journalURL(storageRootURL: registrationRoot))

    let firstTransactionalConfiguration = root.appendingPathComponent("transaction/first.json")
    let secondTransactionalConfiguration = root.appendingPathComponent("transaction/second.json")
    try FileManager.default.createDirectory(at: firstTransactionalConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstTransactionalConfiguration.deletingLastPathComponent().path)
    let originalFirstConfiguration = Data("{\"keep\":true,\"mcpServers\":{\"other\":{\"command\":\"other\"}}}".utf8)
    let originalSecondConfiguration = Data("[]".utf8)
    try originalFirstConfiguration.write(to: firstTransactionalConfiguration)
    try originalSecondConfiguration.write(to: secondTransactionalConfiguration)
    do {
        _ = try MCPRegistration.writeConfigurations(
            for: [
                MCPClientConfiguration(name: "First", configurationURL: firstTransactionalConfiguration),
                MCPClientConfiguration(name: "Second", configurationURL: secondTransactionalConfiguration),
            ],
            executableURL: executable
        )
        throw CoreCheckError.assertionFailed("invalid later client configuration did not fail registration")
    } catch MCPRegistrationError.invalidConfiguration {
        // Expected.
    }
    let restoredFirstConfiguration = try Data(contentsOf: firstTransactionalConfiguration)
    let restoredSecondConfiguration = try Data(contentsOf: secondTransactionalConfiguration)
    try require(restoredFirstConfiguration == originalFirstConfiguration, "failed registration did not restore an earlier client exactly")
    try require(restoredSecondConfiguration == originalSecondConfiguration, "failed registration changed the rejecting client")
    let transactionDirectoryPermissions = try FileManager.default.attributesOfItem(atPath: firstTransactionalConfiguration.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    try require(transactionDirectoryPermissions?.intValue == 0o755, "registration changed permissions on an existing client directory")

    let codexClients = MCPRegistration.detectedClients(fileManager: .default, homeURL: home, applicationSupportURL: support)
    try require(codexClients.map(\.name) == ["Codex"], "Codex configuration was not detected exactly")
    _ = try MCPRegistration.writeConfiguration(at: codexConfiguration, executableURL: executable)
    let registeredCodex = try String(contentsOf: codexConfiguration)
    try require(registeredCodex.contains("[mcp_servers.evee]"), "Codex Evee table was not registered")
    let codexRemoval = try MCPRegistration.removeConfiguration(at: codexConfiguration)
    try require(codexRemoval.removedRegistration, "Codex Evee table was not removed")
    let restoredCodex = try String(contentsOf: codexConfiguration)
    try require(restoredCodex == originalCodex, "Codex round trip changed unrelated configuration")

    let packagedHelper = Bundle.main.executableURL!
        .deletingLastPathComponent()
        .appendingPathComponent("evee-mcp")
    try require(FileManager.default.isExecutableFile(atPath: packagedHelper.path), "build evee-mcp before running mcp-revocation")
    let libraryRoot = support.appendingPathComponent("Evee", isDirectory: true)
    let library = LibraryStore(rootURL: libraryRoot)
    var enabled = EveeSettings()
    enabled.mcpEnabled = true
    try await library.save(enabled)
    try await library.upsert(WorkspaceRecord(kind: .memo, title: "Synthetic private workspace", text: "revocation sentinel"))

    let corruptManifestConfiguration = home.appendingPathComponent(".corrupt-manifest/client.json")
    try FileManager.default.createDirectory(at: corruptManifestConfiguration.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"keep\":\"corrupt-manifest\"}".utf8).write(to: corruptManifestConfiguration)
    _ = try await MCPOwnedRegistration.enable(
        clients: [MCPClientConfiguration(name: "Corrupt manifest", configurationURL: corruptManifestConfiguration)],
        executableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: libraryRoot,
        settings: enabled,
        saveSettings: { settings in try await library.save(settings) }
    )
    let corruptManifestURL = MCPOwnedRegistration.manifestURL(storageRootURL: libraryRoot)
    let corruptJournalURL = MCPOwnedRegistration.journalURL(storageRootURL: libraryRoot)
    try Data("{\"version\":".utf8).write(to: corruptManifestURL)
    let corruptOutcome = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: libraryRoot,
        settings: enabled,
        saveSettings: { settings in try await library.save(settings) }
    )
    try require(corruptOutcome.authorizationDisabled, "corrupt manifest cleanup returned without persisted-disabled authorization")
    try require(corruptOutcome.cleanupFailures.contains(where: { $0.configurationURL == corruptManifestURL }), "corrupt manifest cleanup did not report retained manual action")
    let corruptPersistedSettings = try await library.loadSettings()
    try require(!corruptPersistedSettings.mcpEnabled, "corrupt manifest revoke did not persist disabled authorization")
    try require(FileManager.default.fileExists(atPath: corruptJournalURL.path), "corrupt manifest revoke did not retain its fail-closed barrier")
    try require(FileManager.default.fileExists(atPath: corruptManifestURL.path), "corrupt manifest revoke discarded the unreadable ownership record")

    let corruptHelper = Process()
    let corruptInput = Pipe()
    let corruptOutput = Pipe()
    let corruptErrors = Pipe()
    corruptHelper.executableURL = packagedHelper
    corruptHelper.standardInput = corruptInput
    corruptHelper.standardOutput = corruptOutput
    corruptHelper.standardError = corruptErrors
    var corruptEnvironment = ProcessInfo.processInfo.environment
    corruptEnvironment["CFFIXED_USER_HOME"] = home.path
    corruptHelper.environment = corruptEnvironment
    try corruptHelper.run()
    try writeMCPRequest([
        "jsonrpc": "2.0",
        "id": 49,
        "method": "tools/call",
        "params": ["name": "search", "arguments": ["query": "revocation"]],
    ], to: corruptInput.fileHandleForWriting)
    let corruptDenied = try readMCPResponse(from: corruptOutput.fileHandleForReading)
    let corruptDeniedError = corruptDenied["error"] as? [String: Any]
    try require(corruptDeniedError?["code"] as? Int == -32001, "helper read through a corrupt-manifest revoke barrier")
    let corruptDeniedText = String(decoding: try JSONSerialization.data(withJSONObject: corruptDenied), as: UTF8.self)
    try require(!corruptDeniedText.contains("revocation sentinel"), "corrupt-manifest helper denial exposed workspace data")
    try corruptInput.fileHandleForWriting.close()
    corruptHelper.waitUntilExit()
    try require(corruptHelper.terminationStatus == 0, "corrupt-manifest helper failed: \(String(decoding: corruptErrors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

    try FileManager.default.removeItem(at: corruptJournalURL)
    try FileManager.default.removeItem(at: corruptManifestURL)
    try FileManager.default.removeItem(at: corruptManifestConfiguration)
    try await library.save(enabled)
    try Data("{\"version\":".utf8).write(to: corruptManifestURL)
    do {
        _ = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [home],
            storageRootURL: libraryRoot,
            settings: enabled,
            saveSettings: { _ in throw SyntheticMCPPersistenceError.rejected }
        )
        throw CoreCheckError.assertionFailed("corrupt-manifest disable save failure returned a cleanup outcome")
    } catch SyntheticMCPPersistenceError.rejected {
        // Expected.
    }
    let corruptSaveFailureSettings = try await library.loadSettings()
    try require(corruptSaveFailureSettings.mcpEnabled, "corrupt-manifest save failure changed persisted authorization")
    try require(!FileManager.default.fileExists(atPath: corruptJournalURL.path), "corrupt-manifest save failure retained its untouched barrier")
    try require(FileManager.default.fileExists(atPath: corruptManifestURL.path), "corrupt-manifest save failure removed the ownership record")
    try FileManager.default.removeItem(at: corruptManifestURL)

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = packagedHelper
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["CFFIXED_USER_HOME"] = home.path
    process.environment = environment
    try process.run()
    try writeMCPRequest(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]], to: input.fileHandleForWriting)
    let initialized = try readMCPResponse(from: output.fileHandleForReading)
    try require(initialized["error"] == nil, "enabled helper rejected initialize")

    let invalidCalls: [(Int, String, [String: Any])] = [
        (2, "search", ["query": "revocation", "kind": "unknown"]),
        (3, "recent_activity", ["since": "not-a-date"]),
        (4, "recent_activity", ["limit": 0]),
        (5, "get_memo", ["id": "not-a-uuid"]),
    ]
    for (identifier, name, arguments) in invalidCalls {
        try writeMCPRequest([
            "jsonrpc": "2.0",
            "id": identifier,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ], to: input.fileHandleForWriting)
        let response = try readMCPResponse(from: output.fileHandleForReading)
        let invalidError = response["error"] as? [String: Any]
        try require(invalidError?["code"] as? Int == -32602, "malformed \(name) arguments did not return invalid parameters")
        let responseText = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        try require(!responseText.contains("revocation sentinel"), "malformed \(name) arguments broadened into workspace data")
    }

    let unfinishedJournal = MCPOwnedRegistration.journalURL(storageRootURL: libraryRoot)
    try Data("{}".utf8).write(to: unfinishedJournal)
    try writeMCPRequest([
        "jsonrpc": "2.0",
        "id": 50,
        "method": "tools/call",
        "params": ["name": "search", "arguments": ["query": "revocation"]],
    ], to: input.fileHandleForWriting)
    let unfinishedDenied = try readMCPResponse(from: output.fileHandleForReading)
    let unfinishedError = unfinishedDenied["error"] as? [String: Any]
    try require(unfinishedError?["code"] as? Int == -32001, "helper accepted a workspace read while an unfinished transaction journal existed")
    let unfinishedText = String(decoding: try JSONSerialization.data(withJSONObject: unfinishedDenied), as: UTF8.self)
    try require(!unfinishedText.contains("revocation sentinel"), "unfinished transaction response exposed workspace data")
    try FileManager.default.removeItem(at: unfinishedJournal)

    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "evee-mcp failed: \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

    let leaseAcquired = root.appendingPathComponent("lease-acquired")
    let releaseLease = root.appendingPathComponent("release-lease")
    let revokeReturned = root.appendingPathComponent("revoke-returned")
    let raceProcess = Process()
    let raceInput = Pipe()
    let raceOutput = Pipe()
    let raceErrors = Pipe()
    raceProcess.executableURL = packagedHelper
    raceProcess.standardInput = raceInput
    raceProcess.standardOutput = raceOutput
    raceProcess.standardError = raceErrors
    environment["EVEE_MCP_TEST_LEASE_ACQUIRED_PATH"] = leaseAcquired.path
    environment["EVEE_MCP_TEST_LEASE_RELEASE_PATH"] = releaseLease.path
    raceProcess.environment = environment
    try raceProcess.run()
    try writeMCPRequest([
        "jsonrpc": "2.0",
        "id": 6,
        "method": "tools/call",
        "params": ["name": "search", "arguments": ["query": "revocation"]],
    ], to: raceInput.fileHandleForWriting)
    let leaseDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: leaseAcquired.path), Date() < leaseDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try require(FileManager.default.fileExists(atPath: leaseAcquired.path), "helper did not acquire its workspace read lease")
    let revokeTask = Task {
        let outcome = try await MCPOwnedRegistration.revoke(
            allowedRootURLs: [home],
            storageRootURL: libraryRoot,
            settings: enabled,
            saveSettings: { settings in try await library.save(settings) }
        )
        try Data().write(to: revokeReturned)
        return outcome
    }
    try await Task.sleep(for: .milliseconds(150))
    try require(!FileManager.default.fileExists(atPath: revokeReturned.path), "revoke returned while an earlier workspace read lease was suspended")
    try Data().write(to: releaseLease)
    let preRevokeRead = try readMCPResponse(from: raceOutput.fileHandleForReading)
    let preRevokeText = String(decoding: try JSONSerialization.data(withJSONObject: preRevokeRead), as: UTF8.self)
    try require(preRevokeText.contains("revocation sentinel"), "the read that began before revoke acquired exclusivity did not complete")
    let raceRevocation = try await revokeTask.value
    try require(raceRevocation.cleanupFailures.isEmpty, "authorization-only revoke reported cleanup failures")
    try require(FileManager.default.fileExists(atPath: revokeReturned.path), "revoke did not return after the earlier read released its lease")

    try writeMCPRequest([
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/call",
        "params": ["name": "search", "arguments": ["query": "revocation"]],
    ], to: raceInput.fileHandleForWriting)
    let revoked = try readMCPResponse(from: raceOutput.fileHandleForReading)
    let error = revoked["error"] as? [String: Any]
    try require(error?["code"] as? Int == -32001, "revoked helper did not return the access-disabled error")
    try require((error?["message"] as? String)?.localizedCaseInsensitiveContains("enable local helper access in Evee") == true, "revoked helper error did not explain how to enable access")
    let revokedResponse = String(decoding: try JSONSerialization.data(withJSONObject: revoked), as: UTF8.self)
    try require(!revokedResponse.contains("revocation sentinel"), "revoked helper exposed workspace data")
    try raceInput.fileHandleForWriting.close()
    raceProcess.waitUntilExit()
    try require(raceProcess.terminationStatus == 0, "evee-mcp race process failed: \(String(decoding: raceErrors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")

    let disabledProcess = Process()
    let disabledInput = Pipe()
    let disabledOutput = Pipe()
    disabledProcess.executableURL = packagedHelper
    disabledProcess.standardInput = disabledInput
    disabledProcess.standardOutput = disabledOutput
    disabledProcess.standardError = Pipe()
    disabledProcess.environment = environment
    try disabledProcess.run()
    try writeMCPRequest(["jsonrpc": "2.0", "id": 8, "method": "initialize", "params": [:]], to: disabledInput.fileHandleForWriting)
    try disabledInput.fileHandleForWriting.close()
    let disabledInitialize = try readMCPResponse(from: disabledOutput.fileHandleForReading)
    disabledProcess.waitUntilExit()
    let disabledError = disabledInitialize["error"] as? [String: Any]
    try require(disabledError?["code"] as? Int == -32001, "disabled helper accepted initialize")

    print("mcp-revocation: passed")
}

private func checkMCPLegacyRegistrations() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-mcp-legacy-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let storage = support.appendingPathComponent("Evee", isDirectory: true)
    let executable = root.appendingPathComponent("Evee.app/Contents/Helpers/evee-mcp")
    let cursorURL = home.appendingPathComponent(".cursor/mcp.json")
    let codexURL = home.appendingPathComponent(".codex/config.toml")
    let windsurfURL = home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
    let claudeURL = support.appendingPathComponent("Claude/claude_desktop_config.json")
    defer { try? FileManager.default.removeItem(at: root) }

    for directory in [
        executable.deletingLastPathComponent(), cursorURL.deletingLastPathComponent(),
        codexURL.deletingLastPathComponent(), windsurfURL.deletingLastPathComponent(),
        claudeURL.deletingLastPathComponent(), storage,
    ] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let cursorOriginal = Data("{\"theme\":\"dark\",\"mcpServers\":{\"evee\":{\"command\":\"\(executable.path)\",\"args\":[]},\"other\":{\"command\":\"other\"}}}".utf8)
    let codexOriginal = "model = \"synthetic\"\n\n[mcp_servers.evee]\ncommand = \"\(executable.path)\"\nargs = []\n\n[mcp_servers.other]\ncommand = \"other\"\n"
    let ambiguousOriginal = Data("{\"mcpServers\":{\"evee\":{\"command\":\"\(executable.path)\",\"args\":[\"--manual\"]},\"other\":{\"command\":\"other\"}}}".utf8)
    let unrelatedOriginal = Data("{\"mcpServers\":{\"other\":{\"command\":\"other\"}},\"theme\":\"paper\"}".utf8)
    try cursorOriginal.write(to: cursorURL)
    try Data(codexOriginal.utf8).write(to: codexURL)
    try ambiguousOriginal.write(to: windsurfURL)
    try unrelatedOriginal.write(to: claudeURL)

    func inspections() throws -> [String: MCPRegistrationDisposition] {
        let values = try MCPOwnedRegistration.inspectSupportedClients(
            fileManager: .default,
            homeURL: home,
            applicationSupportURL: support,
            storageRootURL: storage,
            expectedExecutableURL: executable,
            allowedRootURLs: [home]
        )
        return Dictionary(uniqueKeysWithValues: values.map { ($0.client.name, $0.disposition) })
    }

    let initial = try inspections()
    try require(initial["Cursor"] == .recognizedLegacy, "exact JSON Evee unit was not recognized as legacy")
    try require(initial["Codex"] == .recognizedLegacy, "exact TOML Evee unit was not recognized as legacy")
    try require(initial["Windsurf"] == .ambiguous, "manual JSON Evee unit was not classified as ambiguous")
    try require(initial["Claude Desktop"] == .unregistered, "unrelated JSON configuration was not classified as unregistered")

    let cursor = MCPClientConfiguration(name: "Cursor", configurationURL: cursorURL)
    let codex = MCPClientConfiguration(name: "Codex", configurationURL: codexURL)
    let claude = MCPClientConfiguration(name: "Claude Desktop", configurationURL: claudeURL)
    var blockedEnableSaves: [Bool] = []
    do {
        _ = try await MCPOwnedRegistration.enable(
            clients: [claude],
            executableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: storage,
            settings: EveeSettings(),
            saveSettings: { settings in blockedEnableSaves.append(settings.mcpEnabled) },
            homeURL: home,
            applicationSupportURL: support
        )
        throw CoreCheckError.assertionFailed("enable ignored an unselected legacy registration")
    } catch MCPOwnedRegistrationError.legacyRegistrationSelectionRequired {
        // Expected: helper authorization cannot bypass unresolved registrations.
    }
    try require(blockedEnableSaves.isEmpty, "blocked enable persisted authorization")
    let claudeAfterBlockedEnable = try Data(contentsOf: claudeURL)
    try require(claudeAfterBlockedEnable == unrelatedOriginal, "blocked enable changed the selected client")

    var partialAdoptionSaves: [Bool] = []
    do {
        _ = try await MCPOwnedRegistration.adoptRecognizedLegacy(
            clients: [cursor],
            expectedExecutableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: storage,
            settings: EveeSettings(),
            saveSettings: { settings in partialAdoptionSaves.append(settings.mcpEnabled) },
            homeURL: home,
            applicationSupportURL: support
        )
        throw CoreCheckError.assertionFailed("partial legacy adoption enabled the helper")
    } catch MCPOwnedRegistrationError.legacyRegistrationSelectionRequired {
        // Expected: every recognized registration must be selected explicitly.
    }
    try require(partialAdoptionSaves.isEmpty, "partial legacy adoption persisted authorization")
    let cursorAfterPartialAdoption = try Data(contentsOf: cursorURL)
    let codexAfterPartialAdoption = String(decoding: try Data(contentsOf: codexURL), as: UTF8.self)
    let ambiguousAfterPartialAdoption = try Data(contentsOf: windsurfURL)
    try require(cursorAfterPartialAdoption == cursorOriginal, "partial legacy adoption changed the selected client")
    try require(codexAfterPartialAdoption == codexOriginal, "partial legacy adoption changed the untouched client")
    try require(ambiguousAfterPartialAdoption == ambiguousOriginal, "partial legacy adoption changed an ambiguous client")

    // The ambiguous entry is deliberately left untouched; remove this synthetic
    // client file so the two selected recognized registrations can be adopted.
    try FileManager.default.removeItem(at: windsurfURL)

    let adopted = try await MCPOwnedRegistration.adoptRecognizedLegacy(
        clients: [cursor, codex],
        expectedExecutableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: storage,
        settings: EveeSettings(),
        saveSettings: { settings in
            try require(settings.mcpEnabled, "legacy adoption did not enable authorization transactionally")
        },
        homeURL: home,
        applicationSupportURL: support
    )
    try require(adopted.map(\.configurationURL) == [cursorURL, codexURL], "batch legacy adoption did not adopt every selected client")
    let adoptedInspections = try inspections()
    let codexAfterAdopt = try Data(contentsOf: codexURL)
    try require(adoptedInspections["Cursor"] == .ownedCurrent, "adopted JSON unit was not classified as owned/current")
    try require(adoptedInspections["Codex"] == .ownedCurrent, "adopted TOML unit was not classified as owned/current")
    try require(codexAfterAdopt == Data(codexOriginal.utf8), "batch adoption changed the selected TOML client")

    var enabled = EveeSettings()
    enabled.mcpEnabled = true
    let revoked = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: storage,
        settings: enabled,
        saveSettings: { settings in try require(!settings.mcpEnabled, "adopted revoke did not disable authorization first") }
    )
    try require(revoked.cleanupFailures.isEmpty, "adopted JSON revoke failed")
    let revokedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorURL)) as! [String: Any]
    let revokedServers = revokedJSON["mcpServers"] as! [String: Any]
    try require(revokedServers["evee"] == nil, "revoke restored the pre-hardening JSON Evee unit")
    try require(revokedServers["other"] != nil && revokedJSON["theme"] as? String == "dark", "adopted JSON revoke changed unrelated configuration")

    try cursorOriginal.write(to: cursorURL)
    try Data(codexOriginal.utf8).write(to: codexURL)
    let removed = try await MCPOwnedRegistration.removeRecognizedLegacy(
        clients: [cursor],
        expectedExecutableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: storage,
        settings: EveeSettings(),
        saveSettings: { settings in try require(!settings.mcpEnabled, "legacy removal did not confirm disabled authorization before mutation") }
    )
    try require(removed.cleanupFailures.isEmpty && removed.removals.map(\.configurationURL) == [cursorURL], "selected JSON legacy unit was not removed")
    let removedCursor = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorURL)) as! [String: Any]
    let removedCursorServers = removedCursor["mcpServers"] as! [String: Any]
    try require(removedCursorServers["evee"] == nil, "JSON legacy removal left the Evee unit")
    try require(removedCursorServers["other"] != nil && removedCursor["theme"] as? String == "dark", "JSON legacy removal changed unrelated configuration")

    let adoptedAfterRemoval = try await MCPOwnedRegistration.adoptRecognizedLegacy(
        clients: [codex],
        expectedExecutableURL: executable,
        allowedRootURLs: [home],
        storageRootURL: storage,
        settings: EveeSettings(),
        saveSettings: { settings in try require(settings.mcpEnabled, "adopting the remaining recognized client did not enable authorization") },
        homeURL: home,
        applicationSupportURL: support
    )
    try require(adoptedAfterRemoval.map(\.configurationURL) == [codexURL], "remaining recognized client was not adopted")
    let afterRemovalAdoptionCodex = String(decoding: try Data(contentsOf: codexURL), as: UTF8.self)
    try require(afterRemovalAdoptionCodex == codexOriginal, "remaining TOML adoption changed configuration contents")
    _ = try await MCPOwnedRegistration.revoke(
        allowedRootURLs: [home],
        storageRootURL: storage,
        settings: enabled,
        saveSettings: { settings in try require(!settings.mcpEnabled, "post-adoption revoke did not disable authorization") }
    )
    let saveFailureOriginal = Data("{\"mcpServers\":{\"evee\":{\"command\":\"\(executable.path)\",\"args\":[]},\"other\":{\"command\":\"other\"}}}".utf8)
    try saveFailureOriginal.write(to: claudeURL)
    do {
        _ = try await MCPOwnedRegistration.adoptRecognizedLegacy(
            clients: [claude],
            expectedExecutableURL: executable,
            allowedRootURLs: [home],
            storageRootURL: storage,
            settings: EveeSettings(),
            saveSettings: { settings in
                if settings.mcpEnabled { throw SyntheticMCPPersistenceError.rejected }
            },
            homeURL: home,
            applicationSupportURL: support
        )
        throw CoreCheckError.assertionFailed("legacy adoption ignored authorization save failure")
    } catch SyntheticMCPPersistenceError.rejected {
        // Expected: fail-closed reversal removes the adopted unit rather than
        // restoring a pre-hardening Evee entry.
    }
    let failedAdoptionJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as! [String: Any]
    let failedAdoptionServers = failedAdoptionJSON["mcpServers"] as! [String: Any]
    try require(failedAdoptionServers["evee"] == nil, "adoption save failure restored a pre-hardening Evee unit")
    try require(failedAdoptionServers["other"] != nil, "adoption save failure changed unrelated JSON configuration")

    print("mcp-legacy: passed")
}

private func checkRecoveryTracks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-recovery-track-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(rootURL: root)
    let input = root.appendingPathComponent("Input", isDirectory: true)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let microphone = input.appendingPathComponent("microphone.wav")
    let system = input.appendingPathComponent("system.wav")
    try coreCheckSilentWAV().write(to: microphone)
    try Data("invalid system audio".utf8).write(to: system)
    let capture = try await store.beginRecoveryCapture(kind: .meeting)
    _ = try await store.addRecoveryTrack(captureID: capture.id, kind: .meeting, role: .microphone, sourceURL: microphone)
    _ = try await store.addRecoveryTrack(captureID: capture.id, kind: .meeting, role: .system, sourceURL: system)

    let assessments = try await store.assessRecoveryTracks(captureID: capture.id)
    try require(assessments.first(where: { $0.role == .microphone })?.isValid == true, "valid microphone was rejected")
    try require(assessments.first(where: { $0.role == .system })?.isValid == false, "invalid system track was accepted")

    let proposed = WorkspaceRecord(kind: .meeting, title: "Recovered", text: "Transcript")
    do {
        _ = try await store.commitRecoveredRecord(
            proposed,
            recoveryID: capture.id,
            trackSelection: .roles([.system]),
            keepAudio: true
        )
        throw CoreCheckError.assertionFailed("explicit invalid role selection committed")
    } catch LibraryStoreError.invalidRecoveryTrack(.system, _) {
        // Expected: the valid microphone original remains recoverable.
    }
    do {
        _ = try await store.commitRecoveredRecord(
            proposed,
            recoveryID: capture.id,
            trackSelection: .roles([]),
            keepAudio: true
        )
        throw CoreCheckError.assertionFailed("empty recovery selection committed")
    } catch LibraryStoreError.emptyRecoverySelection {
        // Expected.
    }
    let saved = try await store.commitRecoveredRecord(
        proposed,
        recoveryID: capture.id,
        trackSelection: .roles([.microphone]),
        keepAudio: true
    )
    try require(saved.audioTracks.map(\.role) == [.microphone], "explicit role selection retained the wrong tracks")
    let savedRecords = try await store.loadRecords()
    let remainingRecoveries = try await store.recoverableCaptures()
    try require(savedRecords.map(\.id) == [saved.id], "recovery created a missing or duplicate canonical record")
    try require(remainingRecoveries.isEmpty, "committed recovery originals were not removed")

    let systemOnlyRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-system-only-track-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: systemOnlyRoot) }
    let systemOnlyStore = LibraryStore(rootURL: systemOnlyRoot)
    let systemOnlyInput = systemOnlyRoot.appendingPathComponent("system.wav")
    try FileManager.default.createDirectory(at: systemOnlyRoot, withIntermediateDirectories: true)
    try coreCheckSilentWAV().write(to: systemOnlyInput)
    let systemOnlyCapture = try await systemOnlyStore.beginRecoveryCapture(kind: .meeting)
    _ = try await systemOnlyStore.addRecoveryTrack(
        captureID: systemOnlyCapture.id,
        kind: .meeting,
        role: .system,
        sourceURL: systemOnlyInput
    )
    let systemOnlyAssessments = try await systemOnlyStore.assessRecoveryTracks(captureID: systemOnlyCapture.id)
    try require(systemOnlyAssessments.map(\.role) == [.system] && systemOnlyAssessments.allSatisfy { $0.isValid }, "system-only recovery was not valid")
    let systemOnlyRecord = try await systemOnlyStore.commitRecoveredRecord(
        WorkspaceRecord(kind: .meeting, title: "System only", text: "Recovered"),
        recoveryID: systemOnlyCapture.id,
        trackSelection: .allValid,
        keepAudio: true
    )
    try require(systemOnlyRecord.audioTracks.map(\.role) == [.system], "system-only recovery retained the wrong role")

    let atomicRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-atomic-recovery-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: atomicRoot) }
    let seedStore = LibraryStore(rootURL: atomicRoot)
    let recordID = UUID()
    let oldDirectory = atomicRoot.appendingPathComponent("Audio/Records/\(recordID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    let oldAudio = oldDirectory.appendingPathComponent("existing.wav")
    try coreCheckSilentWAV().write(to: oldAudio)
    let existing = WorkspaceRecord(
        id: recordID,
        kind: .meeting,
        title: "Existing",
        text: "Canonical",
        audioTracks: [WorkspaceAudioTrack(role: .microphone, relativePath: "Audio/Records/\(recordID.uuidString)/existing.wav")]
    )
    try await seedStore.upsert(existing)
    let persistedExisting = try await seedStore.record(id: recordID)
    let atomicInput = atomicRoot.appendingPathComponent("Input", isDirectory: true)
    try FileManager.default.createDirectory(at: atomicInput, withIntermediateDirectories: true)
    let atomicMicrophone = atomicInput.appendingPathComponent("microphone.wav")
    let atomicSystem = atomicInput.appendingPathComponent("system.wav")
    try coreCheckSilentWAV().write(to: atomicMicrophone)
    try coreCheckSilentWAV().write(to: atomicSystem)
    let atomicCapture = try await seedStore.beginRecoveryCapture(kind: .meeting)
    _ = try await seedStore.addRecoveryTrack(captureID: atomicCapture.id, kind: .meeting, role: .microphone, sourceURL: atomicMicrophone)
    let withBoth = try await seedStore.addRecoveryTrack(captureID: atomicCapture.id, kind: .meeting, role: .system, sourceURL: atomicSystem)
    var originalURLs: [URL] = []
    for track in withBoth.tracks {
        originalURLs.append(try await seedStore.safeURL(forRelativePath: track.relativePath))
    }
    let replacement = WorkspaceRecord(id: recordID, kind: .meeting, title: "Recovered", text: "New")
    let directorySyncFailingStore = LibraryStore(rootURL: atomicRoot, failNextWritesAt: [.recordAudioDirectorySync])
    do {
        _ = try await directorySyncFailingStore.commitRecoveredRecord(
            replacement,
            recoveryID: atomicCapture.id,
            trackSelection: .allValid,
            keepAudio: true
        )
        throw CoreCheckError.assertionFailed("record audio directory sync failure unexpectedly committed recovery")
    } catch CoreCheckError.assertionFailed(let message) {
        throw CoreCheckError.assertionFailed(message)
    } catch {
        // Expected synthetic pre-metadata durability failure.
    }
    let afterDirectoryFailure = try await directorySyncFailingStore.record(id: recordID)
    let filesAfterDirectoryFailure = try FileManager.default.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil)
    try require(afterDirectoryFailure == persistedExisting, "directory sync failure changed canonical metadata")
    try require(filesAfterDirectoryFailure.map(\.lastPathComponent) == ["existing.wav"], "directory sync failure left copied audio")
    try require(originalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "directory sync failure removed recovery originals")

    let failingStore = LibraryStore(rootURL: atomicRoot, failNextWritesAt: [.recordMetadataBeforeReplacement])
    do {
        _ = try await failingStore.commitRecoveredRecord(
            replacement,
            recoveryID: atomicCapture.id,
            trackSelection: .allValid,
            keepAudio: true
        )
        throw CoreCheckError.assertionFailed("metadata failure unexpectedly committed recovery")
    } catch CoreCheckError.assertionFailed(let message) {
        throw CoreCheckError.assertionFailed(message)
    } catch {
        // Expected synthetic metadata write failure.
    }
    let unchanged = try await failingStore.record(id: recordID)
    let filesAfterFailure = try FileManager.default.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil)
    try require(unchanged == persistedExisting, "metadata failure changed the canonical record")
    try require(filesAfterFailure.map(\.lastPathComponent) == ["existing.wav"], "metadata failure left new owned copies")
    try require(originalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "metadata failure removed recovery originals")
    let retried = try await failingStore.commitRecoveredRecord(
        replacement,
        recoveryID: atomicCapture.id,
        trackSelection: .allValid,
        keepAudio: true
    )
    let filesAfterRetry = try FileManager.default.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil)
    let recordsAfterRetry = try await failingStore.loadRecords()
    try require(retried.audioTracks.count == 2 && filesAfterRetry.count == 2, "retry left duplicate or missing canonical audio")
    try require(recordsAfterRetry.filter { $0.id == recordID }.count == 1, "retry duplicated canonical metadata")
    try require(!FileManager.default.fileExists(atPath: oldAudio.path), "retry retained superseded canonical audio")

    let installedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-installed-durability-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: installedRoot) }
    let installedSeedStore = LibraryStore(rootURL: installedRoot)
    try FileManager.default.createDirectory(at: installedRoot, withIntermediateDirectories: true)
    let installedInput = installedRoot.appendingPathComponent("input.wav")
    try coreCheckSilentWAV().write(to: installedInput)
    let installedCapture = try await installedSeedStore.beginRecoveryCapture(kind: .memo)
    let installedManifest = try await installedSeedStore.addRecoveryTrack(
        captureID: installedCapture.id,
        kind: .memo,
        role: .microphone,
        sourceURL: installedInput
    )
    var installedOriginalURLs: [URL] = []
    for track in installedManifest.tracks {
        installedOriginalURLs.append(try await installedSeedStore.safeURL(forRelativePath: track.relativePath))
    }
    let installedRecord = WorkspaceRecord(kind: .memo, title: "Installed", text: "Durability uncertain")
    let postReplacementStore = LibraryStore(rootURL: installedRoot, failNextWritesAt: [.recordMetadataAfterReplacement])
    do {
        _ = try await postReplacementStore.commitRecoveredRecord(
            installedRecord,
            recoveryID: installedCapture.id,
            trackSelection: .allValid,
            keepAudio: true
        )
        throw CoreCheckError.assertionFailed("post-replacement failure was not surfaced")
    } catch LibraryStoreError.metadataInstalledButDurabilityUncertain {
        // Expected: metadata is installed, so copied audio must remain.
    }
    guard let installed = try await postReplacementStore.record(id: installedRecord.id) else {
        throw CoreCheckError.assertionFailed("post-replacement failure lost installed metadata")
    }
    try require(installed.audioTracks.count == 1, "post-replacement failure installed incomplete track metadata")
    for track in installed.audioTracks {
        let url = try await postReplacementStore.safeURL(forRelativePath: track.relativePath)
        try require(FileManager.default.fileExists(atPath: url.path), "post-replacement failure deleted metadata-owned audio")
    }
    try require(installedOriginalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "post-replacement failure removed recovery originals")

    let discardRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-discard-recovery-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: discardRoot) }
    let discardStore = LibraryStore(rootURL: discardRoot)
    let discardInput = discardRoot.appendingPathComponent("microphone.wav")
    try FileManager.default.createDirectory(at: discardRoot, withIntermediateDirectories: true)
    try coreCheckSilentWAV().write(to: discardInput)
    let discardCapture = try await discardStore.beginRecoveryCapture(kind: .memo)
    _ = try await discardStore.addRecoveryTrack(captureID: discardCapture.id, kind: .memo, role: .microphone, sourceURL: discardInput)
    try await discardStore.discardRecoveryCapture(id: discardCapture.id)
    let discardedRecoveries = try await discardStore.recoverableCaptures()
    try require(discardedRecoveries.isEmpty, "explicit discard left recovery artifacts")
    print("recovery-tracks: passed")
}

private func checkCorruptLibraryRecovery() async throws {
    let filenames = ["records.json", "settings.json", "meeting-draft.json"]
    for filename in filenames {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-corrupt-library-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        try await store.prepare()
        let source = root.appendingPathComponent(filename)
        let bytes = Data("{".utf8)
        try bytes.write(to: source)
        let preserved: URL?
        switch filename {
        case "records.json":
            let result = try await store.loadRecordsRecoveringCorruption()
            try require(result.value.isEmpty, "corrupt records did not return an empty library")
            preserved = result.preservedCorruptURL
        case "settings.json":
            let result = try await store.loadSettingsRecoveringCorruption()
            try require(result.value == EveeSettings(), "corrupt settings did not return privacy-safe defaults")
            preserved = result.preservedCorruptURL
        default:
            let result = try await store.loadMeetingDraftRecoveringCorruption()
            try require(result.value == nil, "corrupt meeting draft did not return nil")
            preserved = result.preservedCorruptURL
        }
        guard let preserved else { throw CoreCheckError.assertionFailed("\(filename) was not preserved") }
        try require(!FileManager.default.fileExists(atPath: source.path), "\(filename) still blocked startup after preservation")
        let preservedBytes = try Data(contentsOf: preserved)
        try require(preservedBytes == bytes, "\(filename) preserved different bytes")
        let permissions = try FileManager.default.attributesOfItem(atPath: preserved.path)[.posixPermissions] as? NSNumber
        try require((permissions?.intValue ?? 0) & 0o777 == 0o600, "\(filename) preserved with non-private permissions")
    }

    let failureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-corrupt-preservation-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: failureRoot) }
    let failureStore = LibraryStore(rootURL: failureRoot)
    try await failureStore.prepare()
    let failureSource = failureRoot.appendingPathComponent("records.json")
    let failureBytes = Data("{".utf8)
    try failureBytes.write(to: failureSource)
    try Data("not a directory".utf8).write(to: failureRoot.appendingPathComponent("Corrupt"))
    do {
        _ = try await failureStore.loadRecordsRecoveringCorruption()
        throw CoreCheckError.assertionFailed("preservation failure returned a fallback")
    } catch CoreCheckError.assertionFailed(let message) {
        throw CoreCheckError.assertionFailed(message)
    } catch {
        // Expected: canonical source must remain authoritative.
    }
    let remainingFailureBytes = try Data(contentsOf: failureSource)
    try require(remainingFailureBytes == failureBytes, "preservation failure changed the canonical source")

    for filename in ["records.json", "settings.json"] {
        let futureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-future-schema-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: futureRoot) }
        let futureStore = LibraryStore(rootURL: futureRoot)
        try await futureStore.prepare()
        let futureSource = futureRoot.appendingPathComponent(filename)
        let futureBytes = Data("{\"schemaVersion\":999,\"payload\":{\"changed\":true},\"records\":\"not-an-array\",\"settings\":false}".utf8)
        try futureBytes.write(to: futureSource)
        do {
            if filename == "records.json" {
                _ = try await futureStore.loadRecordsRecoveringCorruption()
            } else {
                _ = try await futureStore.loadSettingsRecoveringCorruption()
            }
            throw CoreCheckError.assertionFailed("future \(filename) schema was treated as corruption")
        } catch LibraryStoreError.unsupportedSchema(found: 999, supported: LibraryStore.currentSchemaVersion) {
            // Expected hard error independent of the future payload shape.
        }
        let remainingFutureBytes = try Data(contentsOf: futureSource)
        try require(remainingFutureBytes == futureBytes, "future \(filename) source was moved or changed")
        try require(!FileManager.default.fileExists(atPath: futureRoot.appendingPathComponent("Corrupt").path), "future \(filename) created a corrupt copy")
    }

    let quarantineRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("evee-records-quarantine-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: quarantineRoot) }
    let firstStore = LibraryStore(rootURL: quarantineRoot)
    try await firstStore.prepare()
    let orphanID = UUID()
    let orphanDirectory = quarantineRoot.appendingPathComponent("Audio/Records/\(orphanID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
    let orphanAudio = orphanDirectory.appendingPathComponent("unknown.wav")
    try coreCheckSilentWAV().write(to: orphanAudio)
    try Data("{".utf8).write(to: quarantineRoot.appendingPathComponent("records.json"))
    let firstLoad = try await firstStore.loadRecordsRecoveringCorruption()
    guard let firstPreserved = firstLoad.preservedCorruptURL else {
        throw CoreCheckError.assertionFailed("corrupt records did not create a durable quarantine")
    }
    guard let marker = try await firstStore.recordsQuarantine() else {
        throw CoreCheckError.assertionFailed("corrupt records did not persist a quarantine marker")
    }
    try require(marker.preservedCorruptRelativePath == "Corrupt/\(firstPreserved.lastPathComponent)", "quarantine marker did not reference the preserved copy")
    let markerPermissions = try FileManager.default.attributesOfItem(
        atPath: quarantineRoot.appendingPathComponent("records-quarantine.json").path
    )[.posixPermissions] as? NSNumber
    try require((markerPermissions?.intValue ?? 0) & 0o777 == 0o600, "quarantine marker was not private")

    let relaunchedStore = LibraryStore(rootURL: quarantineRoot)
    let relaunchedLoad = try await relaunchedStore.loadRecordsRecoveringCorruption()
    try require(relaunchedLoad.preservedCorruptURL == firstPreserved, "quarantine warning did not survive relaunch")
    let protectedID = UUID()
    let protectedDirectory = quarantineRoot.appendingPathComponent("Audio/Records/\(protectedID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
    let protectedAudio = protectedDirectory.appendingPathComponent("known.wav")
    try coreCheckSilentWAV().write(to: protectedAudio)
    let protectedRecord = WorkspaceRecord(
        id: protectedID,
        kind: .memo,
        title: "Later",
        text: "Saved",
        audioTracks: [WorkspaceAudioTrack(role: .microphone, relativePath: "Audio/Records/\(protectedID.uuidString)/known.wav")]
    )
    try await relaunchedStore.save([protectedRecord])
    try await relaunchedStore.reconcileAudioStorage()
    try require(FileManager.default.fileExists(atPath: orphanAudio.path), "ordinary save/reconciliation deleted quarantined record audio")
    try await relaunchedStore.delete(id: protectedID)
    try require(FileManager.default.fileExists(atPath: protectedAudio.path), "record delete bypassed quarantine audio protection")

    let recoveryInput = quarantineRoot.appendingPathComponent("recovery-input.wav")
    try coreCheckSilentWAV().write(to: recoveryInput)
    let recovery = try await relaunchedStore.beginRecoveryCapture(kind: .memo)
    let recoveryManifest = try await relaunchedStore.addRecoveryTrack(captureID: recovery.id, kind: .memo, role: .microphone, sourceURL: recoveryInput)
    var recoveryOriginals: [URL] = []
    for track in recoveryManifest.tracks {
        recoveryOriginals.append(try await relaunchedStore.safeURL(forRelativePath: track.relativePath))
    }
    _ = try await relaunchedStore.commitRecoveredRecord(
        WorkspaceRecord(kind: .memo, title: "Recovered", text: "Retained"),
        recoveryID: recovery.id,
        trackSelection: .allValid,
        keepAudio: true
    )
    try require(FileManager.default.fileExists(atPath: orphanAudio.path), "new retained recovery reconciled quarantined audio")
    try require(recoveryOriginals.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "retained recovery cleanup bypassed quarantine protection")
    try await relaunchedStore.resetRecordsQuarantine()
    let resetMarker = try await relaunchedStore.recordsQuarantine()
    try require(resetMarker == nil, "explicit reset left the quarantine marker")
    try require(FileManager.default.fileExists(atPath: orphanAudio.path), "explicit reset deleted audio in the same action")

    let crashCases: [(LibraryStoreWritePoint, Bool)] = [
        (.recordsQuarantineAfterArming, true),
        (.recordsQuarantineAfterPreserving, false),
    ]
    for (checkpoint, canonicalRemainsAfterFault) in crashCases {
        let crashRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-quarantine-crash-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: crashRoot) }
        let seedStore = LibraryStore(rootURL: crashRoot)
        try await seedStore.prepare()
        let crashOrphanID = UUID()
        let crashOrphanDirectory = crashRoot.appendingPathComponent("Audio/Records/\(crashOrphanID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: crashOrphanDirectory, withIntermediateDirectories: true)
        let crashOrphanAudio = crashOrphanDirectory.appendingPathComponent("unknown.wav")
        try coreCheckSilentWAV().write(to: crashOrphanAudio)
        let crashCanonical = crashRoot.appendingPathComponent("records.json")
        try Data("{".utf8).write(to: crashCanonical)
        let faultingStore = LibraryStore(rootURL: crashRoot, failNextWritesAt: [checkpoint])
        do {
            _ = try await faultingStore.loadRecordsRecoveringCorruption()
            throw CoreCheckError.assertionFailed("quarantine fault checkpoint did not interrupt preservation")
        } catch CoreCheckError.assertionFailed(let message) {
            throw CoreCheckError.assertionFailed(message)
        } catch {
            // Expected synthetic crash boundary.
        }
        guard let armed = try await faultingStore.recordsQuarantine() else {
            throw CoreCheckError.assertionFailed("fault checkpoint left no armed quarantine marker")
        }
        try require(armed.phase == .pending, "fault checkpoint completed or cleared its quarantine marker")
        try require(
            FileManager.default.fileExists(atPath: crashCanonical.path) == canonicalRemainsAfterFault,
            "fault checkpoint left canonical records in the wrong state"
        )

        let resumedStore = LibraryStore(rootURL: crashRoot)
        let resumed = try await resumedStore.loadRecordsRecoveringCorruption()
        try await resumedStore.reconcileAudioStorage()
        try require(FileManager.default.fileExists(atPath: crashOrphanAudio.path), "second bootstrap deleted audio under a pending quarantine")
        guard let resumedMarker = try await resumedStore.recordsQuarantine() else {
            throw CoreCheckError.assertionFailed("second bootstrap silently removed quarantine")
        }
        if canonicalRemainsAfterFault {
            try require(resumedMarker.phase == .complete, "pending marker with canonical source did not finish preservation")
            try require(resumed.preservedCorruptURL != nil, "finished pending preservation did not surface its copy")
            try require(resumed.manualRecoveryWarning == nil, "finished pending preservation still required manual recovery")
        } else {
            try require(resumedMarker.phase == .pending, "missing canonical source silently completed quarantine")
            try require(resumed.preservedCorruptURL == nil, "missing canonical source claimed a completed preserved copy")
            try require(resumed.manualRecoveryWarning != nil, "missing canonical source did not surface manual recovery")
        }
    }
    print("corrupt-library-recovery: passed")
}

private func coreCheckSilentWAV() -> Data {
    let sampleRate: UInt32 = 8_000
    let sampleCount: UInt32 = 800
    let dataSize = sampleCount * 2
    var data = Data()
    func append(_ text: String) { data.append(contentsOf: text.utf8) }
    func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    append("RIFF"); append(UInt32(36) + dataSize); append("WAVE")
    append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
    append("data"); append(dataSize); data.append(Data(count: Int(dataSize)))
    return data
}

private func checkAccessibilityEvents() throws {
    var reducer = AccessibilityAnnouncementReducer()

    try require(reducer.receive(.wakeListeningStarted) == "Wake phrase listening started.", "wake start was not announced")
    try require(reducer.receive(.wakeListeningStarted) == nil, "repeated wake start was announced")
    try require(reducer.receive(.wakeListeningStopped) == "Wake phrase listening stopped.", "wake stop was not announced")
    try require(reducer.receive(.wakeListeningFailed("Synthetic wake failure")) == "Wake phrase listening failed. Synthetic wake failure", "wake failure was not announced")

    try require(reducer.receive(.captureStarted) == "Recording started.", "capture start was not announced")
    try require(reducer.receive(.captureStarted) == nil, "audio-level publication repeated capture start")
    try require(reducer.receive(.captureStopped) == "Recording stopped. Transcribing locally.", "capture stop was not announced")
    try require(reducer.receive(.captureCancelled) == "Recording discarded.", "capture cancellation was not announced")
    try require(reducer.receive(.captureFailed("Synthetic capture failure")) == "Capture failed. Synthetic capture failure", "capture failure was not announced")
    try require(reducer.receive(.captureRecovered) == "Interrupted capture recovered.", "capture recovery was not announced")

    try require(reducer.receive(.modelDownloadStarted) == "Local model download started.", "model download start was not announced")
    try require(reducer.receive(.modelDownloadProgress(0.09)) == nil, "sub-milestone progress was announced")
    try require(reducer.receive(.modelDownloadProgress(0.10)) == "Local model download 10 percent.", "10-percent milestone was not announced")
    try require(reducer.receive(.modelDownloadProgress(0.19)) == nil, "repeated 10-percent bucket was announced")
    try require(reducer.receive(.modelDownloadProgress(0.31)) == "Local model download 30 percent.", "crossed milestone was not announced")
    try require(reducer.receive(.modelDownloadProgress(0.20)) == nil, "regressing progress was announced")
    try require(reducer.receive(.modelDownloadCancelled) == "Local model download cancelled.", "model cancellation was not announced")
    try require(reducer.receive(.modelDownloadStarted) == "Local model download started.", "a new download was deduplicated against an earlier operation")
    try require(reducer.receive(.modelDownloadProgress(0.10)) == "Local model download 10 percent.", "a new download did not reset milestone tracking")
    try require(reducer.receive(.modelDownloadFailed("Synthetic download failure")) == "Local model download failed. Synthetic download failure", "model failure was not announced")
    try require(reducer.receive(.modelReady) == "Local model is ready.", "model readiness was not announced")

    try require(reducer.receive(.microphoneSilence) == "No microphone signal has been detected. Check the selected input and mute switch.", "microphone silence was not announced")
    try require(reducer.receive(.channelFailed(.system, "Synthetic unrelated warning")) == "System audio warning. Synthetic unrelated warning", "unrelated warning was not announced")
    try require(reducer.receive(.microphoneSilence) == nil, "one silence incident was announced more than once")
    try require(reducer.receive(.microphoneSignalRestored) == nil, "microphone recovery emitted an announcement")
    try require(reducer.receive(.microphoneSilence) == "No microphone signal has been detected. Check the selected input and mute switch.", "a later silence incident was suppressed")
    var simpleSilenceReducer = AccessibilityAnnouncementReducer()
    _ = simpleSilenceReducer.receive(.microphoneSilence)
    _ = simpleSilenceReducer.receive(.microphoneSignalRestored)
    try require(simpleSilenceReducer.receive(.microphoneSilence) != nil, "silence-clear-silence did not begin a new incident")
    try require(reducer.receive(.channelFailed(.system, "Synthetic channel failure")) == "System audio warning. Synthetic channel failure", "channel failure was not announced")
    try require(reducer.receive(.webhookRevoked) == "Meeting webhook access revoked.", "webhook revocation was not announced")
    try require(reducer.receive(.helperRevoked) == "Local helper access revoked.", "helper revocation was not announced")

    print("accessibility-events: passed")
}

private func checkSystemVoiceStatus() throws {
    let ready = SystemVoiceStatus.make(capture: .idle, hotMic: .disabled, warnings: [])
    try require(ready.phase == .ready && !ready.isMicrophoneOpen, "idle status was not ready with a closed microphone")
    try require(ready.availableActions.isEmpty, "idle status exposed capture actions")

    let wakeStarting = SystemVoiceStatus.make(capture: .idle, hotMic: .starting, warnings: [])
    try require(wakeStarting.phase == .wakeStarting && !wakeStarting.isMicrophoneOpen, "wake startup status was inaccurate")
    let listening = SystemVoiceStatus.make(capture: .idle, hotMic: .active, warnings: [])
    try require(listening.phase == .wakeListening, "active hot mic was not presented as wake listening")
    try require(listening.isMicrophoneOpen, "active hot mic did not expose its open microphone")
    try require(listening.menuTitle.contains("listening"), "menu title hid wake listening")
    let wakeStopping = SystemVoiceStatus.make(capture: .idle, hotMic: .stopping, warnings: [])
    try require(wakeStopping.phase == .wakeStopping && wakeStopping.isMicrophoneOpen, "wake cleanup did not remain visibly open")
    let wakeFailed = SystemVoiceStatus.make(capture: .idle, hotMic: .failed(message: "Synthetic wake failure"), warnings: [])
    try require(wakeFailed.phase == .failed && wakeFailed.hudDetail.contains("Synthetic wake failure"), "wake failure was hidden")

    let starting = SystemVoiceStatus.make(capture: .starting(kind: .dictation), hotMic: .disabled, warnings: [])
    try require(starting.phase == .captureStarting && starting.availableActions == [.discard], "capture startup did not expose discard")
    let startingWithOpenCaptureMicrophone = SystemVoiceStatus.make(
        capture: .starting(kind: .meeting),
        hotMic: .disabled,
        captureMicrophone: .open,
        warnings: []
    )
    try require(startingWithOpenCaptureMicrophone.isMicrophoneOpen, "capture startup hid the microphone while system audio was starting")
    try require(startingWithOpenCaptureMicrophone.hudTitle.contains("Microphone open"), "capture startup HUD did not expose the open microphone")
    let startingDuringWakeCleanup = SystemVoiceStatus.make(capture: .starting(kind: .dictation), hotMic: .stopping, warnings: [])
    try require(startingDuringWakeCleanup.isMicrophoneOpen, "capture startup hid a wake microphone that was still closing")

    let microphoneWarning = CaptureHealthWarning(channel: .microphone, reason: .silence)
    let systemWarning = CaptureHealthWarning(channel: .system, reason: .unavailable)
    let recording = SystemVoiceStatus.make(
        capture: .recording(startedAt: .now, level: 0),
        hotMic: .disabled,
        warnings: [microphoneWarning, systemWarning]
    )
    try require(recording.phase == .recording && recording.isMicrophoneOpen, "hands-free capture did not expose recording microphone state")
    try require(recording.hudWarning != nil, "capture health warnings were absent from the HUD")
    try require(recording.menuTitle.contains("warning"), "capture health warnings were absent from the menu")
    try require(recording.availableActions == [.stopAndTranscribe, .discard], "recording did not expose stop and discard")
    let recordingWhileStopAwaits = SystemVoiceStatus.make(
        capture: .recording(startedAt: .now, level: 0),
        hotMic: .disabled,
        captureMicrophone: .stopping,
        warnings: []
    )
    try require(recordingWhileStopAwaits.isMicrophoneOpen, "an awaited recorder stop was presented as already closed")

    let processing = SystemVoiceStatus.make(capture: .transcribing, hotMic: .disabled, warnings: [])
    try require(processing.phase == .processing && !processing.isMicrophoneOpen, "transcription status was inaccurate")
    let stoppingCapture = SystemVoiceStatus.make(
        capture: .transcribing,
        hotMic: .disabled,
        captureMicrophone: .open,
        warnings: []
    )
    try require(stoppingCapture.phase == .processing && stoppingCapture.availableActions.isEmpty, "capture teardown exposed recording actions")
    try require(stoppingCapture.isMicrophoneOpen && stoppingCapture.hudTitle.contains("Stopping capture"), "capture teardown did not expose its open microphone and stopping status")
    let delivering = SystemVoiceStatus.make(capture: .delivering, hotMic: .disabled, warnings: [])
    try require(delivering.phase == .delivering && !delivering.isMicrophoneOpen, "delivery status was inaccurate")
    let failed = SystemVoiceStatus.make(capture: .failed("Synthetic capture failure"), hotMic: .active, warnings: [])
    try require(failed.phase == .failed && !failed.isMicrophoneOpen, "capture failure did not override stale wake state")
    try require(failed.hudDetail.contains("Synthetic capture failure"), "capture failure detail was hidden")
    let failedWithOpenMicrophone = SystemVoiceStatus.make(
        capture: .failed("Synthetic stop failure"),
        hotMic: .disabled,
        captureMicrophone: .open,
        warnings: []
    )
    try require(failedWithOpenMicrophone.isMicrophoneOpen, "capture failure hid a recorder that did not stop")
    try require(failedWithOpenMicrophone.hudTitle.contains("Microphone open"), "capture failure did not visibly warn that the microphone remained open")
    let protected = SystemVoiceStatus.make(capture: .checkpointed("Synthetic recovery checkpoint"), hotMic: .disabled, warnings: [])
    try require(protected.phase == .protected && !protected.isMicrophoneOpen, "recovery checkpoint was presented as a live or failed capture")
    try require(protected.menuTitle == "Capture protected", "recovery checkpoint lost its protected status")

    print("system-voice-status: passed")
}

private func checkPrivacyPresentation() throws {
    let protected = PrivacyPresentation(enabled: true)
    try require(!protected.constructsWorkspaceContent, "privacy mode constructed workspace content")
    try require(!protected.constructsSettingsContent, "privacy mode constructed settings content")
    try require(protected.constructsMenuContent, "privacy mode removed its menu escape hatch")
    try require(
        protected.accessibilityLabel == "Privacy mode is on. Sensitive Evee content is hidden.",
        "privacy mode accessibility state was inaccurate"
    )
    try require(protected.windowProtectionCopy.contains("best-effort"), "window protection copy overstated its guarantee")

    let ordinary = PrivacyPresentation(enabled: false)
    try require(ordinary.constructsWorkspaceContent, "ordinary mode hid workspace content")
    try require(ordinary.constructsSettingsContent, "ordinary mode hid settings content")
    try require(ordinary.constructsMenuContent, "ordinary mode hid menu content")

    print("privacy-presentation: passed")
}

private func checkSearchProjection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("evee-search-projection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryStore(rootURL: root)
    let record = WorkspaceRecord(
        kind: .meeting,
        title: "Search projection",
        text: "ordinary finished text",
        rawText: "RetainedQuasar",
        segments: [.init(start: 0, end: 1, speaker: "Facilitator", text: "SegmentNebula")],
        context: .init(windowTitle: "Project Atlas")
    )
    try await store.upsert(record)

    for term in ["RetainedQuasar", "Facilitator", "SegmentNebula", "Project Atlas"] {
        let results = try await store.searchResults(term, kind: .meeting)
        try require(results.first?.record.id == record.id, "search projection omitted \(term)")
        try require(results.first?.snippet.localizedCaseInsensitiveContains(term) == true, "search snippet omitted \(term)")
    }

    let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("evee-search-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: recoveryRoot) }
    let durable = WorkspaceRecord(kind: .memo, title: "Durable", text: "RecoverableNebula")
    do {
        let initialStore = LibraryStore(rootURL: recoveryRoot)
        try await initialStore.upsert(durable)
        _ = try await initialStore.searchResults("RecoverableNebula")
    }
    let indexURL = recoveryRoot.appendingPathComponent("workspace-index.sqlite3")
    try Data("not a sqlite database".utf8).write(to: indexURL, options: .atomic)
    for suffix in ["-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: indexURL.path + suffix)
    }
    let recovered = try await LibraryStore(rootURL: recoveryRoot).searchResults("RecoverableNebula")
    try require(recovered.first?.record.id == durable.id, "SQLite failure did not rebuild search from canonical records")

    print("search-projection: passed")
}

private func checkAtomicExport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("evee-atomic-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.m4a")
    let destination = root.appendingPathComponent("destination.m4a")
    let bytes = Data((0..<8192).map { UInt8($0 % 251) })
    try bytes.write(to: source)
    try Data("existing destination".utf8).write(to: destination)

    try await AtomicFileExporter().export(source: source, to: destination)

    let exportedBytes = try Data(contentsOf: destination)
    try require(exportedBytes == bytes, "atomic export did not install identical source bytes")
    let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".evee-export-") }
    try require(leftovers.isEmpty, "atomic export left a sibling staging file")

    try Data("existing destination".utf8).write(to: destination, options: .atomic)
    do {
        try await AtomicFileExporter(operations: SyntheticFailingExportOperations()).export(source: source, to: destination)
        throw CoreCheckError.assertionFailed("injected export verification failure was accepted")
    } catch SyntheticExportFailure.verification {}
    let preservedBytes = try Data(contentsOf: destination)
    try require(preservedBytes == Data("existing destination".utf8), "failed export destroyed the existing destination")
    let failureLeftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".evee-export-") }
    try require(failureLeftovers.isEmpty, "failed export left a sibling staging file")
    print("atomic-export: passed")
}

private func checkMeetingSuggestion() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let native = MeetingApplicationSnapshot(
        bundleIdentifier: "test.meeting",
        applicationName: "Synthetic Meeting App",
        isBrowser: false,
        permittedWindowTitle: nil,
        observedAt: now
    )
    try require(!EveeSettings().meetingSuggestionsEnabled, "meeting suggestions were not off by default")
    try require(MeetingSuggestionPolicy(settings: .suggestionsDisabled).evaluate(native) == nil, "disabled suggestions observed a meeting")

    let nativeSettings = MeetingSuggestionSettings(
        enabled: true,
        nativeBundleIdentifiers: ["test.meeting"],
        browserBundleIdentifiers: [],
        browserTitleTerms: [],
        dismissedUntilByBundleIdentifier: [:]
    )
    let nativePolicy = MeetingSuggestionPolicy(settings: nativeSettings)
    let pending = nativePolicy.nextSuggestion(current: nil, event: .observed(native))
    try require(pending?.applicationName == "Synthetic Meeting App", "native allowlist did not suggest a meeting")
    try require(
        nativePolicy.nextSuggestion(current: pending, event: .ownApplicationActivated) == pending,
        "activating Evee cleared the actionable meeting suggestion"
    )
    let externalNonmatch = MeetingApplicationSnapshot(
        bundleIdentifier: "test.editor",
        applicationName: "Synthetic Editor",
        isBrowser: false,
        permittedWindowTitle: nil,
        observedAt: now
    )
    try require(
        nativePolicy.nextSuggestion(current: pending, event: .observed(externalNonmatch)) == nil,
        "an unrelated external application did not clear the meeting suggestion"
    )
    try require(
        nativePolicy.nextSuggestion(current: pending, event: .dismissed) == nil,
        "dismissing a meeting suggestion did not clear it"
    )
    let ownIdentity = MeetingApplicationIdentity(processIdentifier: 42, bundleIdentifier: "test.evee")
    try require(
        ownIdentity.matches(processIdentifier: 42, bundleIdentifier: "unexpected.bundle"),
        "own application process identity was not recognized"
    )
    try require(
        ownIdentity.matches(processIdentifier: 99, bundleIdentifier: "test.evee"),
        "own application bundle fallback was not recognized"
    )
    try require(
        !ownIdentity.matches(processIdentifier: 99, bundleIdentifier: "test.editor"),
        "external application was mistaken for Evee"
    )

    let browserSettings = MeetingSuggestionSettings(
        enabled: true,
        nativeBundleIdentifiers: [],
        browserBundleIdentifiers: ["test.browser"],
        browserTitleTerms: ["meeting"],
        dismissedUntilByBundleIdentifier: ["test.browser": now.addingTimeInterval(60)]
    )
    let browserWithoutPermission = MeetingApplicationSnapshot(bundleIdentifier: "test.browser", applicationName: "Browser", isBrowser: true, permittedWindowTitle: nil, observedAt: now)
    try require(MeetingSuggestionPolicy(settings: browserSettings).evaluate(browserWithoutPermission) == nil, "browser suggestion read an unpermitted title")
    let dismissed = MeetingApplicationSnapshot(bundleIdentifier: "test.browser", applicationName: "Browser", isBrowser: true, permittedWindowTitle: "Project meeting", observedAt: now)
    try require(MeetingSuggestionPolicy(settings: browserSettings).evaluate(dismissed) == nil, "dismissal cooldown was ignored")
    let expired = MeetingApplicationSnapshot(bundleIdentifier: "test.browser", applicationName: "Browser", isBrowser: true, permittedWindowTitle: "Project meeting", observedAt: now.addingTimeInterval(61))
    try require(MeetingSuggestionPolicy(settings: browserSettings).evaluate(expired) != nil, "expired cooldown suppressed a permitted browser suggestion")

    do {
        _ = try SelectionTransformPipeline().transform(selectedText: "Original", instruction: "Rewrite this persuasively")
        throw CoreCheckError.assertionFailed("unrestricted transform was accepted")
    } catch SelectionTransformError.unsupportedInstruction {}
    try require(
        SelectionTransformPipeline.supportedCommandSummary == "Concise, clean up, uppercase, lowercase, title case, bullets, numbered list, and replace … with … (case-insensitive, all matches)",
        "transform scope copy drifted from supported deterministic commands"
    )
    let replaced = try SelectionTransformPipeline().transform(
        selectedText: "Alice met ALICE",
        instruction: "replace Alice with Bob"
    )
    try require(replaced == "Bob met Bob", "documented replacement semantics did not replace all matches case-insensitively")
    print("meeting-suggestion: passed")
}

private func checkResourceSeal() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("evee-resource-seal-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    func write(_ relativePath: String, _ text: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func seal(_ entries: [(String, String)]) throws {
        let text = entries.map { "\($0.0)  \($0.1)" }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: root.appendingPathComponent(".evee-resource-seal.sha256"))
    }
    let safeDigest = "8b3369944dd2a3fab39e32d1aeb1f763946a458ae3e6368a46432adc8f3a0860"
    try write("Model.bundle/config.json", "safe")
    try seal([(safeDigest, "Model.bundle/config.json")])
    try ResourceSealVerifier.verify(resourcesURL: root)

    try write("Model.bundle/config.json", "changed")
    try requireThrows("seal accepted changed bytes") { try ResourceSealVerifier.verify(resourcesURL: root) }
    try write("Model.bundle/config.json", "safe")
    try seal([])
    try requireThrows("seal accepted unsealed file") { try ResourceSealVerifier.verify(resourcesURL: root) }
    try seal([(safeDigest, "../outside")])
    try requireThrows("seal accepted traversal") { try ResourceSealVerifier.verify(resourcesURL: root) }
    try seal([(safeDigest, "/absolute")])
    try requireThrows("seal accepted absolute path") { try ResourceSealVerifier.verify(resourcesURL: root) }
    try seal([("NOT-A-DIGEST", "Model.bundle/config.json")])
    try requireThrows("seal accepted malformed digest") { try ResourceSealVerifier.verify(resourcesURL: root) }
    try seal([(safeDigest, "Model.bundle/config.json"), (safeDigest, "Model.bundle/config.json")])
    try requireThrows("seal accepted duplicate entry") { try ResourceSealVerifier.verify(resourcesURL: root) }
    try fileManager.removeItem(at: root.appendingPathComponent("Model.bundle/config.json"))
    try seal([(safeDigest, "Model.bundle/config.json")])
    try requireThrows("seal accepted missing file") { try ResourceSealVerifier.verify(resourcesURL: root) }
    try write("Model.bundle/config.json", "safe")
    try seal([(safeDigest, "Model.bundle/config.json")])
    try fileManager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("Model.bundle/config.json"))
    try requireThrows("seal accepted symbolic link") { try ResourceSealVerifier.verify(resourcesURL: root) }
    print("resource-seal: passed")
}

let arguments = CommandLine.arguments.dropFirst()
if arguments == ["--filter", "accessibility-events"] {
    try checkAccessibilityEvents()
} else if arguments == ["--filter", "system-voice-status"] {
    try checkSystemVoiceStatus()
} else if arguments == ["--filter", "action-contrast"] {
    try checkActionContrast()
} else if arguments == ["--filter", "visual-presentation"] {
    try checkVisualPresentation()
} else if arguments == ["--filter", "onboarding-presentation"] {
    try checkOnboardingPresentation()
} else if arguments == ["--filter", "onboarding-action-accessibility"] {
    try checkOnboardingActionAccessibility()
} else if arguments == ["--filter", "shortcut-defaults"] {
    try checkShortcutDefaults()
} else if arguments == ["--filter", "menu-window-recovery"] {
    try checkMenuWindowRecovery()
} else if arguments == ["--filter", "accessibility-copy"] {
    try checkAccessibilityCopy()
} else if arguments == ["--filter", "context-policy"] {
    checkContextPolicy()
} else if arguments == ["--filter", "public-record"] {
    try checkPublicRecord()
} else if arguments == ["--filter", "meeting-relabel"] {
    try await checkMeetingRelabel()
} else if arguments == ["--filter", "api-revoke"] {
    try await checkAPIRevocation()
} else if arguments == ["--filter", "api-rotate"] {
    try await checkAPIRotation()
} else if arguments == ["--filter", "api-limits"] {
    try await checkAPILimits()
} else if arguments == ["--filter", "api-start-races"] {
    try await checkAPIStartRaces()
} else if arguments == ["--filter", "api-revoke-persistence"] {
    try await checkAPIRevocationPersistence()
} else if arguments == ["--filter", "api-public-errors"] {
    try await checkAPIPublicErrors()
} else if arguments == ["--filter", "mcp-public-output"] {
    try await checkMCPPublicOutput()
} else if arguments == ["--filter", "mcp-revocation"] {
    try await checkMCPRevocation()
} else if arguments == ["--filter", "mcp-legacy"] {
    try await checkMCPLegacyRegistrations()
} else if arguments == ["--filter", "webhook-generation"] {
    try await checkWebhookGeneration()
} else if arguments == ["--filter", "webhook-signature"] {
    try checkWebhookSignature()
} else if arguments == ["--filter", "webhook-payload"] {
    try checkWebhookPayload()
} else if arguments == ["--filter", "webhook-legacy"] {
    try await checkWebhookLegacyRows()
} else if arguments == ["--filter", "termination-checkpoint"] {
    try await checkTerminationCheckpoint()
} else if arguments == ["--filter", "lifecycle-state"] {
    try checkLifecycleState()
} else if arguments == ["--filter", "model-download"] {
    try checkModelDownloadLifecycle()
} else if arguments == ["--filter", "model-readiness"] {
    try await checkModelReadiness()
} else if arguments == ["--filter", "microphone-meter"] {
    try await checkMicrophoneMeter()
} else if arguments == ["--filter", "quit-track-independence"] {
    try checkQuitTrackIndependence()
} else if arguments == ["--filter", "model-availability"] {
    try checkModelAvailability()
} else if arguments == ["--filter", "hot-mic-race"] {
    try checkHotMicRace()
} else if arguments == ["--filter", "bounded-mailbox"] {
    try await checkBoundedMailbox()
} else if arguments == ["--filter", "audio-pipeline"] {
    try await checkAudioPipeline()
} else if arguments == ["--filter", "audio-relay"] {
    try await checkAudioRelay()
} else if arguments == ["--filter", "webhook-transactions"] {
    try await checkWebhookTransactions()
} else if arguments == ["--filter", "recovery-tracks"] {
    try await checkRecoveryTracks()
} else if arguments == ["--filter", "corrupt-library-recovery"] {
    try await checkCorruptLibraryRecovery()
} else if arguments == ["--filter", "privacy-presentation"] {
    try checkPrivacyPresentation()
} else if arguments == ["--filter", "search-projection"] {
    try await checkSearchProjection()
} else if arguments == ["--filter", "atomic-export"] {
    try await checkAtomicExport()
} else if arguments == ["--filter", "meeting-suggestion"] {
    try checkMeetingSuggestion()
} else if arguments == ["--filter", "resource-seal"] {
    try checkResourceSeal()
} else {
    fputs("usage: evee-core-checks --filter <accessibility-events|system-voice-status|action-contrast|visual-presentation|onboarding-presentation|onboarding-action-accessibility|shortcut-defaults|menu-window-recovery|accessibility-copy|context-policy|public-record|meeting-relabel|api-revoke|api-rotate|api-limits|api-start-races|api-revoke-persistence|api-public-errors|mcp-public-output|mcp-revocation|mcp-legacy|webhook-generation|webhook-signature|webhook-payload|webhook-legacy|webhook-transactions|termination-checkpoint|lifecycle-state|model-download|model-readiness|microphone-meter|quit-track-independence|model-availability|hot-mic-race|bounded-mailbox|audio-pipeline|audio-relay|recovery-tracks|corrupt-library-recovery|privacy-presentation|search-projection|atomic-export|meeting-suggestion|resource-seal>\n", stderr)
    exit(EXIT_FAILURE)
}
