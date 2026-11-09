import XCTest

/// Real production controls on a fresh simulator, without live credentials. No prompts,
/// commands or calls are sent. Tactile perception remains a physical-device test.
final class HapticInteractionUITests: XCTestCase {
    @MainActor
    func testFolderHoldCancellationPreservesNormalTap() throws {
        let app = launchDraft()
        let header = app.buttons["active-host"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.press(forDuration: 1)
        capture(app, name: "Folder press-and-hold preview")
        XCTAssertTrue(header.isHittable)
        header.tap()
        XCTAssertTrue(app.navigationBars["Working Directory"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUsagePeekOpensItsExistingDetails() throws {
        let app = launchDraft()
        app.buttons["open-conversations"].tap()
        let usage = app.buttons["usage-codex"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.press(forDuration: 1)
        let show = app.buttons["Show usage"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        capture(app, name: "Usage press-and-hold preview")
        show.tap()
        XCTAssertTrue(app.buttons["Codex account"].waitForExistence(timeout: 5))
        XCTAssertFalse(show.exists)
    }

}
