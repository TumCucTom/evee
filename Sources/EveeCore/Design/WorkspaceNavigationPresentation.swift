public enum WorkspaceNavigationPresentation {
    public enum MoveDirection: Equatable, Sendable {
        case previous
        case next
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let route: WorkspaceRouteKind
        public let title: String
        public let symbolName: String

        public var id: String { title }

        public init(route: WorkspaceRouteKind, title: String, symbolName: String) {
            self.route = route
            self.title = title
            self.symbolName = symbolName
        }
    }

    public struct Status: Equatable, Sendable {
        public let phase: SystemVoicePhase
        public let title: String
        public let detail: String
        public let symbolName: String
        public let isMicrophoneOpen: Bool
        public let warningTitle: String?

        public var hasWarning: Bool { warningTitle != nil }

        public init(
            phase: SystemVoicePhase,
            title: String,
            detail: String,
            symbolName: String,
            isMicrophoneOpen: Bool,
            warningTitle: String?
        ) {
            self.phase = phase
            self.title = title
            self.detail = detail
            self.symbolName = symbolName
            self.isMicrophoneOpen = isMicrophoneOpen
            self.warningTitle = warningTitle
        }
    }

    public static let items: [Item] = [
        Item(route: .library, title: "Workspace", symbolName: "rectangle.stack"),
        Item(route: .meetings, title: "Meetings", symbolName: "person.2.wave.2"),
        Item(route: .memos, title: "Memos", symbolName: "waveform"),
        Item(route: .dictionary, title: "Dictionary", symbolName: "text.book.closed"),
        Item(route: .settings, title: "Settings", symbolName: "slider.horizontal.3")
    ]

    public static func move(from route: WorkspaceRouteKind, direction: MoveDirection) -> WorkspaceRouteKind {
        guard let currentIndex = items.firstIndex(where: { $0.route == route }) else { return route }
        let offset = direction == .previous ? -1 : 1
        let destinationIndex = min(items.count - 1, max(0, currentIndex + offset))
        return items[destinationIndex].route
    }

    public static func status(for status: SystemVoiceStatus) -> Status {
        let presentation = switch status.phase {
        case .ready:
            ("Ready", "circle", status.hudDetail)
        case .wakeStarting:
            ("Preparing to listen", "mic.badge.plus", status.hudDetail)
        case .wakeListening:
            ("Listening", "ear", status.hudDetail)
        case .wakeStopping:
            ("Stopping listening", "mic.slash", status.hudDetail)
        case .captureStarting:
            ("Starting recording", "record.circle", status.hudDetail)
        case .recording:
            ("Recording", "record.circle.fill", status.hudDetail)
        case .processing:
            ("Processing", "waveform.badge.magnifyingglass", status.hudDetail)
        case .delivering:
            ("Delivering", "paperplane", status.hudDetail)
        case .protected:
            ("Protected", "shield.checkered", status.hudDetail)
        case .failed:
            ("Needs attention", "exclamationmark.triangle.fill", status.hudDetail)
        }

        return Status(
            phase: status.phase,
            title: presentation.0,
            detail: presentation.2,
            symbolName: presentation.1,
            isMicrophoneOpen: status.isMicrophoneOpen,
            warningTitle: status.warnings.isEmpty ? nil : "Audio warning"
        )
    }
}
