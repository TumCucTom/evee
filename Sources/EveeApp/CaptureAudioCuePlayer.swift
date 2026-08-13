import AppKit
import EveeCore

@MainActor
enum CaptureAudioCuePlayer {
    private enum Phase: Equatable {
        case idle, starting, recording, processing, failed
    }

    static func playTransition(from previous: CaptureState, to current: CaptureState) {
        let oldPhase = phase(previous)
        let newPhase = phase(current)
        guard oldPhase != newPhase else { return }

        let soundName: NSSound.Name?
        switch newPhase {
        case .recording:
            soundName = NSSound.Name("Tink")
        case .processing:
            soundName = oldPhase == .recording ? NSSound.Name("Pop") : nil
        case .idle:
            soundName = oldPhase == .processing ? NSSound.Name("Glass") : nil
        case .failed:
            soundName = NSSound.Name("Basso")
        case .starting:
            soundName = nil
        }

        guard let soundName else { return }
        if let sound = NSSound(named: soundName) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private static func phase(_ state: CaptureState) -> Phase {
        switch state {
        case .idle: .idle
        case .starting: .starting
        case .recording: .recording
        case .transcribing, .delivering: .processing
        case .checkpointed: .idle
        case .failed: .failed
        }
    }
}
