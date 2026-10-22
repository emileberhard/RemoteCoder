import XCTest

final class HTMLVisualDrawerUITests: XCTestCase {
    @MainActor
    func testSwipeStartingOnVisualOpensDrawer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-html-visual-fixture", "-taskCompletionNotificationsEnabled", "NO"]
        app.launch()
        let text = app.webViews.staticTexts["Selectable text inside visual 1."]
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        let content = app.buttons["close-conversations"]
        XCTAssertEqual(content.frame.minX, 0, accuracy: 1)

        let start = text.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 260, dy: 0)))
        let deadline = Date.now.addingTimeInterval(5)
        while content.frame.minX < 200, Date.now < deadline {
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        if content.frame.minX < 200 { captureScreen(name: "After swipe on visual") }
        XCTAssertGreaterThan(content.frame.minX, 200, "A swipe starting on a visual did not open the drawer")
    }
}
