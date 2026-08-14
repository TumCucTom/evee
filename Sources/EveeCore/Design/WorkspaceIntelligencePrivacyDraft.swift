import Foundation

public struct WorkspaceIntelligencePrivacyDraft: Equatable, Sendable {
    public private(set) var preferences: WorkspaceIntelligencePreferences
    public private(set) var isDirty: Bool

    private var didBeginInitialLoad: Bool
    private var didReceiveInitialLoad: Bool

    public init(preferences: WorkspaceIntelligencePreferences = WorkspaceIntelligencePreferences()) {
        self.preferences = preferences
        self.isDirty = false
        self.didBeginInitialLoad = false
        self.didReceiveInitialLoad = false
    }

    public mutating func beginInitialLoad() -> Bool {
        guard !didBeginInitialLoad else { return false }
        didBeginInitialLoad = true
        return true
    }

    public mutating func receiveLoaded(_ loaded: WorkspaceIntelligencePreferences) {
        guard didBeginInitialLoad, !didReceiveInitialLoad else { return }
        didReceiveInitialLoad = true
        guard !isDirty else { return }
        preferences = loaded
    }

    public mutating func update(_ updated: WorkspaceIntelligencePreferences) {
        guard preferences != updated else { return }
        preferences = updated
        isDirty = true
    }

    @discardableResult
    public mutating func markSaved(ifMatching savedPreferences: WorkspaceIntelligencePreferences) -> Bool {
        guard preferences == savedPreferences else { return false }
        isDirty = false
        return true
    }
}
