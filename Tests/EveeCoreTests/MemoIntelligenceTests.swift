import XCTest
@testable import EveeCore

final class MemoIntelligenceTests: XCTestCase {
    func testMemoOverviewProducesBoundedTitleHighlightsAndActions() {
        let result = MemoIntelligencePipeline().generate(from: "Launch planning for Tuesday. Remember to send the brief. The budget is approved. A fourth detail.")
        XCTAssertEqual(result.title, "Launch planning for Tuesday")
        XCTAssertEqual(result.highlights.count, 3)
        XCTAssertEqual(result.actionItems, ["Remember to send the brief."])
    }

    func testMemoActionsExcludeQuestions() {
        let result = MemoIntelligencePipeline().generate(from: "Do we need to call Sam? We need to call Sam tomorrow.")
        XCTAssertEqual(result.actionItems, ["We need to call Sam tomorrow."])
    }

    func testLegacyRecordDecodesWithoutMemoOverview() throws {
        let record = WorkspaceRecord(kind: .memo, title: "Legacy", text: "Memo")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "memoIntelligence")
        let restored = try JSONDecoder().decode(WorkspaceRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.memoIntelligence)
    }
}
