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
        XCTAssertTrue(draft.markSaved(ifMatching: edited))
        XCTAssertFalse(draft.isDirty)
    }

    func testCompletingOlderSaveCannotMarkNewerDraftClean() {
        var draft = WorkspaceIntelligencePrivacyDraft()
        var firstEdit = draft.preferences
        firstEdit.isEnabled = true
        draft.update(firstEdit)
        let savedSnapshot = draft.preferences

        var newerEdit = firstEdit
        newerEdit.includeWindowTitles = true
        draft.update(newerEdit)

        XCTAssertFalse(draft.markSaved(ifMatching: savedSnapshot))
        XCTAssertEqual(draft.preferences, newerEdit)
        XCTAssertTrue(draft.isDirty)
    }
}
