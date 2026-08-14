import Foundation

public struct CaptureOverlayPresentation: Equatable, Sendable {
    public let phase: SystemVoicePhase
    public let isMicrophoneOpen: Bool
    public let title: String
    public let detail: String
    public let hasWarning: Bool
    public let level: Double?

    public var isVisible: Bool { phase != .ready }

    public var accessibilityLabel: String {
        let microphoneState = isMicrophoneOpen ? "Microphone open." : "Microphone closed."
        return "\(title). \(microphoneState) \(detail)"
    }

    public static func make(snapshot: CaptureOverlaySnapshot) -> Self {
        let measuredLevel = snapshot.level.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        return Self(
            phase: snapshot.status.phase,
            isMicrophoneOpen: snapshot.status.isMicrophoneOpen,
            title: snapshot.status.hudTitle,
            detail: snapshot.status.hudDetail,
            hasWarning: !snapshot.status.warnings.isEmpty,
            level: measuredLevel
        )
    }

    public func hasSameSemantics(as other: Self) -> Bool {
        phase == other.phase
            && isMicrophoneOpen == other.isMicrophoneOpen
            && title == other.title
            && detail == other.detail
            && hasWarning == other.hasWarning
    }
}

public struct MenuBarVoicePresentation: Equatable, Sendable {
    public let closedAccessibilityLabel: String
    public let openAccessibilityLabel: String

    public static func make(status: SystemVoiceStatus) -> Self {
        let microphoneState = status.isMicrophoneOpen ? "Microphone open." : "Microphone closed."
        let warningState = status.warnings.isEmpty ? "" : " Audio warning present."
        let state = "\(status.menuTitle). \(microphoneState)\(warningState)"
        return Self(
            closedAccessibilityLabel: "Evee. \(state)",
            openAccessibilityLabel: "Evee status. \(state)"
        )
    }
}

@MainActor
public protocol CaptureOverlayRendering: AnyObject {
    func createOverlay()
    func apply(_ presentation: CaptureOverlayPresentation)
    func presentOverlay(reposition: Bool)
    func hideOverlay()
}

/// Applies semantic transitions immediately while bounding real meter-only
/// invalidations. It retains only the latest applied presentation.
@MainActor
public final class CaptureOverlayUpdateDriver {
    private let renderer: any CaptureOverlayRendering
    private let minimumMeterInterval: TimeInterval

    private var didCreateOverlay = false
    private var isVisible = false
    private var lastApplied: CaptureOverlayPresentation?
    private var lastMeterApplicationTime: TimeInterval?

    public init(
        renderer: any CaptureOverlayRendering,
        minimumMeterInterval: TimeInterval = 0.05
    ) {
        self.renderer = renderer
        self.minimumMeterInterval = max(1.0 / 60.0, minimumMeterInterval)
    }

    public func receive(_ snapshot: CaptureOverlaySnapshot, at time: TimeInterval) {
        let presentation = CaptureOverlayPresentation.make(snapshot: snapshot)
        guard presentation.isVisible else {
            if isVisible { renderer.hideOverlay() }
            isVisible = false
            lastApplied = nil
            lastMeterApplicationTime = nil
            return
        }

        if !didCreateOverlay {
            renderer.createOverlay()
            didCreateOverlay = true
        }

        let semanticChanged = lastApplied.map { !$0.hasSameSemantics(as: presentation) } ?? true
        let levelChanged = lastApplied?.level != presentation.level
        let meterIntervalElapsed = lastMeterApplicationTime.map {
            time - $0 >= minimumMeterInterval
        } ?? true

        if semanticChanged || (levelChanged && meterIntervalElapsed) {
            renderer.apply(presentation)
            lastApplied = presentation
            lastMeterApplicationTime = time
        }

        if !isVisible {
            renderer.presentOverlay(reposition: true)
            isVisible = true
        } else if semanticChanged {
            renderer.presentOverlay(reposition: true)
        }
    }
}
