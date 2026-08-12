import XCTest
@testable import EveeCore

final class WritingEnhancementsTests: XCTestCase {
    func testSmartLinksUseWholePhraseAndValidWebSchemes() {
        let result = WritingEnhancementPipeline().applySmartLinks(
            "Open the project brief and project briefly",
            links: [
                SmartLink(phrase: "project brief", destination: "https://example.test/brief"),
                SmartLink(phrase: "project", destination: "file:///private/data")
            ]
        )
        XCTAssertEqual(result, "Open the https://example.test/brief and project briefly")
    }

    func testAutomaticEmailModeUsesApplicationContext() {
        let context = WorkspaceContext(bundleIdentifier: "com.apple.mail", recipient: "Sam")
        let result = WritingEnhancementPipeline().enhance(
            "The report is ready.",
            smartLinks: [],
            emailMode: .automatic,
            emailSignOff: "Alex",
            context: context
        )
        XCTAssertEqual(result, "Hi Sam,\n\nThe report is ready.\n\nBest,\nAlex")
    }

    func testAutomaticEmailModeDoesNotAlterUnrelatedApps() {
        let context = WorkspaceContext(bundleIdentifier: "com.example.editor")
        let result = WritingEnhancementPipeline().enhance(
            "The report is ready.",
            smartLinks: [],
            emailMode: .automatic,
            emailSignOff: "Alex",
            context: context
        )
        XCTAssertEqual(result, "The report is ready.")
    }

    func testCorrectionLearnerAcceptsOneUnambiguousSubstitution() {
        let candidate = CorrectionLearner().candidate(
            from: "Please send this to Johnny today.",
            edited: "Please send this to Jonny today."
        )
        XCTAssertEqual(candidate?.spoken, "Johnny")
        XCTAssertEqual(candidate?.replacement, "Jonny")
    }

    func testCorrectionLearnerDeclinesStructuralEdits() {
        XCTAssertNil(CorrectionLearner().candidate(
            from: "Please send this today.",
            edited: "Could you please send this tomorrow?"
        ))
    }

    func testSettingsDecodeNewFieldsFromOlderPayload() throws {
        let settings = try JSONDecoder().decode(EveeSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.emailFormattingMode, .automatic)
        XCTAssertFalse(settings.captureVisibleContext)
        XCTAssertFalse(settings.learnCorrections)
        XCTAssertTrue(settings.smartLinks.isEmpty)
        XCTAssertFalse(settings.hotMicEnabled)
        XCTAssertEqual(settings.wakePhrase, "hey evee")
    }

    func testWakePhrasePreferenceRoundTrips() throws {
        var settings = EveeSettings()
        settings.hotMicEnabled = true
        settings.wakePhrase = "hello evee"
        let restored = try JSONDecoder().decode(EveeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.hotMicEnabled)
        XCTAssertEqual(restored.wakePhrase, "hello evee")
    }
}
