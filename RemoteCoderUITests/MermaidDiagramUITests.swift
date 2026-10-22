import XCTest

final class MermaidDiagramUITests: XCTestCase {
    @MainActor
    func testInlineSourceCopyExpandZoomAndAppearance() throws {
        let app = launch()
        let expand = app.buttons["mermaid-expand"].firstMatch
        waitForEnabled(expand)
        captureScreen(name: "Mermaid - light inline")
        app.buttons["mermaid-source-toggle"].firstMatch.tap()
        XCTAssertTrue(app.scrollViews["mermaid-source"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["mermaid-copy"].firstMatch.tap()
        XCTAssertEqual(app.buttons["mermaid-copy"].firstMatch.label, "Mermaid source copied")
        app.buttons["mermaid-source-toggle"].firstMatch.tap()
        expand.tap()
        XCTAssertTrue(app.buttons["mermaid-close"].waitForExistence(timeout: 10))
        let vector = app.webViews.firstMatch
        XCTAssertTrue(vector.waitForExistence(timeout: 15))
        XCTAssertTrue(app.progressIndicators["mermaid-viewer-loading"].waitForNonExistence(timeout: 15))
        captureScreen(name: "Mermaid - vector fit")
        vector.pinch(withScale: 2, velocity: 1)
        captureScreen(name: "Mermaid - vector zoom")
        app.buttons["mermaid-fit"].tap()
        app.buttons["mermaid-viewer-source"].tap()
        XCTAssertTrue(app.scrollViews["mermaid-source"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["mermaid-close"].tap()
        app.switches["Dark"].tap()
        waitForEnabled(expand)
        captureScreen(name: "Mermaid - dark inline")
        app.switches["Large text"].tap()
        waitForEnabled(expand)
        XCTAssertTrue(app.buttons["mermaid-source-toggle"].firstMatch.isHittable)
        captureScreen(name: "Mermaid - accessibility text")
    }

    @MainActor
    func testStreamingAndInvalidSyntaxRemainUsable() throws {
        let app = launch()
        select("Streaming", app: app)
        XCTAssertTrue(app.staticTexts["Diagram is being written…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mermaid-expand"].firstMatch.isEnabled)
        app.buttons["Finish diagram"].tap()
        waitForEnabled(app.buttons["mermaid-expand"].firstMatch)
        select("Invalid", app: app)
        XCTAssertTrue(app.staticTexts["Couldn't render this diagram"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.scrollViews["mermaid-source"].firstMatch.exists)
        XCTAssertTrue(app.buttons["mermaid-copy"].firstMatch.isEnabled)
        XCTAssertFalse(app.buttons["mermaid-expand"].firstMatch.isEnabled)
        captureScreen(name: "Mermaid - recoverable invalid source")
        select("Flowchart", app: app)
        waitForEnabled(app.buttons["mermaid-expand"].firstMatch)
    }

    @MainActor
    func testWideDiagramAndRotation() throws {
        let app = launch()
        select("Wide sequence", app: app)
        waitForEnabled(app.buttons["mermaid-expand"].firstMatch)
        captureScreen(name: "Mermaid - wide inline")
        app.buttons["mermaid-expand"].firstMatch.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let frame = app.webViews.firstMatch.frame
                return frame.width > frame.height && app.frame.width > app.frame.height
            }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        app.buttons["mermaid-fit"].tap()
        XCTAssertTrue(app.progressIndicators["mermaid-viewer-loading"].waitForNonExistence(timeout: 15))
        captureScreen(name: "Mermaid - landscape vector")
        app.buttons["mermaid-close"].tap()
    }

    @MainActor private func select(_ value: String, app: XCUIApplication) {
        app.buttons["mermaid-example"].tap()
        app.buttons[value].firstMatch.tap()
    }

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-mermaid-preview-fixture", "-taskCompletionNotificationsEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Mermaid Preview"].waitForExistence(timeout: 30))
        return app
    }

}
