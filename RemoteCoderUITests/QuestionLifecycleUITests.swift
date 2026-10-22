import XCTest

/// Opt-in, fixture-backed app/gateway checks. Seed the three RCQ_ASK_UI_* threads
/// with the local question-model fixture; never point this test at production.
final class QuestionLifecycleUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testAnswerAndDismissRemainResolvedAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        try requireLab(app)

        let answeredRow = openConversation("RCQ_ASK_UI_ANSWER", app: app)
        let bar = app.buttons["pending-question-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 25))
        bar.tap()
        let close = app.buttons["question-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "The off-page question must open as a sheet")
        close.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Close must not dismiss the question itself")
        bar.tap()
        XCTAssertTrue(app.buttons["question-option-0-1"].waitForExistence(timeout: 10))
        app.buttons["question-option-0-1"].tap()
        capture(app, name: "Answer editor before send")
        let send = app.buttons["question-send"]
        reveal(send, app: app)
        send.tap()
        waitAbsent(close, "Accepted answer must close only its own sheet")
        waitAbsent(bar, "Accepted answer must stop requesting attention")
        capture(app, name: "Answer admitted and attention cleared")

        app.terminate()
        app.launch()
        try requireLab(app)
        selectConversation(answeredRow, app: app)
        waitAbsent(bar, "Relaunch must not reconstruct the old question as pending")
        capture(app, name: "Answered question after relaunch")

        let dismissedRow = openConversation("RCQ_ASK_UI_DISMISS", app: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 25))
        bar.tap()
        let dismiss = app.buttons["question-dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 15))
        reveal(dismiss, app: app)
        dismiss.tap()
        waitAbsent(close, "Durable dismissal must update the open sheet")
        waitAbsent(bar, "Durable dismissal must remove its attention banner")
        app.terminate()
        app.launch()
        try requireLab(app)
        selectConversation(dismissedRow, app: app)
        waitAbsent(bar, "Dismissal must persist across app relaunch")
        capture(app, name: "Dismissed question after relaunch")
    }

    @MainActor
    private func requireLab(_ app: XCUIApplication) throws {
        let host = app.buttons["active-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 45))
        let value = host.value as? String ?? ""
        try XCTSkipUnless(value.contains("rcq."), "Requires the isolated question lab configuration")
    }

    @MainActor
    private func openConversation(_ prefix: String, app: XCUIApplication) -> String {
        app.buttons["open-conversations"].tap()
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "conversation-row-", prefix)
        let row = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25), "Seed \(prefix) in the isolated gateway before running this test")
        let identity = row.identifier
        selectVisibleConversation(identity, app: app)
        return identity
    }

    @MainActor
    private func selectConversation(_ identity: String, app: XCUIApplication) {
        app.buttons["open-conversations"].tap()
        selectVisibleConversation(identity, app: app)
    }

    @MainActor
    private func selectVisibleConversation(_ identity: String, app: XCUIApplication) {
        let row = app.buttons[identity]
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        // Completion refresh may reorder the drawer between a coordinate lookup
        // and its tap. Verify the selected identity, not merely that it closed.
        for attempt in 0..<3 {
            reveal(row, app: app)
            row.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: row)
            if XCTWaiter.wait(for: [selected], timeout: 5) == .completed { return }
            if attempt < 2 { app.buttons["open-conversations"].tap() }
        }
        XCTFail("The drawer did not select the requested conversation identity: \(identity)")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func waitAbsent(_ element: XCUIElement, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 25), .completed, message)
    }

}
