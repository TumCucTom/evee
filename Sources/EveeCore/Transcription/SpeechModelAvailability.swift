import Foundation

public struct SpeechModelAvailability: Sendable {
    public static var current: Self {
        Self(operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }

    public let operatingSystemVersion: OperatingSystemVersion

    public init(operatingSystemVersion: OperatingSystemVersion) {
        self.operatingSystemVersion = operatingSystemVersion
    }

    public func isSupported(_ model: SpeechModel) -> Bool {
        switch model {
        case .parakeet:
            true
        case .qwen3:
            operatingSystemVersion.majorVersion >= 15
        }
    }

    public func unavailableReason(for model: SpeechModel) -> String? {
        guard !isSupported(model) else { return nil }
        switch model {
        case .parakeet:
            return nil
        case .qwen3:
            return "Qwen3 ASR requires macOS 15 or newer. Parakeet v3 remains available on this Mac."
        }
    }

    public func safeSelection(for model: SpeechModel) -> SpeechModel {
        if isSupported(model) { return model }
        return SpeechModel.allCases.first(where: isSupported) ?? .parakeet
    }

    public func validate(_ model: SpeechModel) throws {
        guard isSupported(model) else { throw TranscriptionError.unsupportedOperatingSystem }
    }
}
