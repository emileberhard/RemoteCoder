import XCTest

@MainActor
extension XCTestCase {
    func launchDraft() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-taskCompletionNotificationsEnabled", "NO"]
        app.launch()
        let notification = app.alerts.firstMatch
        if notification.waitForExistence(timeout: 2),
           notification.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'notifications'")).count > 0 {
            let decline = notification.buttons["Don’t Allow"]
            if decline.exists { decline.tap() }
        }
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 45))
        newChat.tap()
        return app
    }

    func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func captureScreen(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func waitForEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed)
    }
}
