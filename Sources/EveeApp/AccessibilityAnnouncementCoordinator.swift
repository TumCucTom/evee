import AppKit
import EveeCore

@MainActor
final class AccessibilityAnnouncementCoordinator {
    typealias AnnouncementPoster = @MainActor (String) -> Void

    private var reducer = AccessibilityAnnouncementReducer()
    private let postAnnouncement: AnnouncementPoster

    init(postAnnouncement: AnnouncementPoster? = nil) {
        self.postAnnouncement = postAnnouncement ?? AccessibilityAnnouncementCoordinator.postToApplication
    }

    func post(_ event: AccessibilityStatusEvent) {
        guard let message = reducer.receive(event) else { return }
        postAnnouncement(message)
    }

    private static func postToApplication(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
