import XCTest

final class ComposerRetryUITests: XCTestCase {
    @MainActor
    func testComposerErrorRetryDoesNotFocusTheKeyboard() throws {
        let app = launchDraft()
        let retry = app.buttons["Retry settings sync"]
        try XCTSkipUnless(retry.waitForExistence(timeout: 15), "Requires a simulator without gateway credentials")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        retry.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "A dynamic recovery control must not be intercepted by empty-space focus.")
    }
}
