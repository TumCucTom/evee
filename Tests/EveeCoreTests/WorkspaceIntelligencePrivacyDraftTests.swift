import EveeCore
import XCTest

final class WorkspaceIntelligencePrivacyDraftTests: XCTestCase {
    func testLateAndRepeatedLoadsCannotOverwriteUnsavedEditorDraft() {
        var draft = WorkspaceIntelligencePrivacyDraft()
        XCTAssertTrue(draft.beginInitialLoad())

        var edited = draft.preferences
        edited.isEnabled = true
        edited.includeWindowTitles = true
        draft.update(edited)

        draft.receiveLoaded(WorkspaceIntelligencePreferences(retentionDays: 30))
        XCTAssertEqual(draft.preferences, edited)
        XCTAssertTrue(draft.isDirty)
        XCTAssertFalse(draft.beginInitialLoad())

        draft.receiveLoaded(WorkspaceIntelligencePreferences(retentionDays: 90))
        XCTAssertEqual(draft.preferences, edited)
    }

    func testCleanInitialLoadAndSaveLifecycle() {
        var draft = WorkspaceIntelligencePrivacyDraft()
        XCTAssertTrue(draft.beginInitialLoad())
        let stored = WorkspaceIntelligencePreferences(isEnabled: true, retentionDays: 30)
        draft.receiveLoaded(stored)
        XCTAssertEqual(draft.preferences, stored)
        XCTAssertFalse(draft.isDirty)

        var edited = stored
        edited.journalEnabled = true
        draft.update(edited)
        XCTAssertTrue(draft.isDirty)
        draft.markSaved()
        XCTAssertFalse(draft.isDirty)
    }
}
