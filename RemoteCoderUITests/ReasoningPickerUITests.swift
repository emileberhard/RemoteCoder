import XCTest

/// Sends physical touches to the real composer; an accessibility activation
/// would bypass the gesture arbitration that previously swallowed short taps.
/// Requires a configured gateway, but never sends a prompt or starts a call.
final class ReasoningPickerUITests: XCTestCase {
    @MainActor
    func testSecondTouchSelectionCloseOutsideTapAndReopen() throws {
        let app = try launchReasoningDraft()
        openPicker(in: app)
        app.buttons["close-reasoning-slider"].tap()
        assertClosed(in: app)

        openPicker(in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        assertClosed(in: app)

        openPicker(in: app)
        dragSlider(in: app, to: 0.94)
        XCTAssertNotEqual(trigger(in: app).value as? String, "Automatic")

        openPicker(in: app)
        dragSlider(in: app, to: 0.06)
        XCTAssertEqual(trigger(in: app).value as? String, "Automatic")
        openPicker(in: app)
        XCTAssertEqual(slider(in: app).value as? String, "Automatic")
    }

    @MainActor
    func testHoldReleaseCancellationAndNoTapReopen() throws {
        let app = try launchReasoningDraft()
        openPicker(in: app)
        let trackFrame = slider(in: app).frame
        dragSlider(in: app, to: 0.94)
        let original = try XCTUnwrap(trigger(in: app).value as? String)
        XCTAssertNotEqual(original, "Automatic")

        trigger(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4)
        assertClosed(in: app)
        XCTAssertEqual(trigger(in: app).value as? String, original)

        let origin = app.coordinate(withNormalizedOffset: .zero)
        let cancelled = origin.withOffset(CGVector(dx: trackFrame.minX + 32, dy: trackFrame.midY - 170))
        trigger(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: cancelled)
        assertClosed(in: app)
        XCTAssertEqual(trigger(in: app).value as? String, original)

        let automatic = origin.withOffset(CGVector(dx: trackFrame.minX + 32, dy: trackFrame.midY))
        trigger(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: automatic)
        assertClosed(in: app)
        XCTAssertEqual(trigger(in: app).value as? String, "Automatic")
    }

    @MainActor
    func testTapAndSecondTouchPreserveOpenKeyboard() throws {
        let app = try launchReasoningDraft()
        app.textFields["codex-composer-input"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        openPicker(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        dragSlider(in: app, to: 0.06)
        XCTAssertEqual(trigger(in: app).value as? String, "Automatic")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        openPicker(in: app)
        // The keyboard and connection status move the popup; a fixed screen
        // fraction can land on its title rather than the dismissing scrim.
        let track = slider(in: app).frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: track.minX / 2, dy: track.midY)).tap()
        assertClosed(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    @MainActor
    func testEmptyActionRowSpaceFocusesInput() throws {
        let app = try launchReasoningDraft()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let attachment = app.buttons["Add attachment"].frame
        let voice = app.buttons["Voice mode"].frame
        XCTAssertGreaterThan(voice.minX - attachment.maxX, 20)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (attachment.maxX + voice.minX) / 2, dy: attachment.midY))
            .tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "The empty space between action buttons must focus the composer.")
        XCTAssertFalse(slider(in: app).exists)

        let probe = "Composer focus probe"
        app.typeText(probe)
        XCTAssertEqual(app.textFields["codex-composer-input"].value as? String, probe)
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: probe.count))
        openPicker(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["close-reasoning-slider"].tap()
        assertClosed(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    @MainActor
    func testComposerPaddingAndSettingsGapFocusInput() throws {
        for area in ["leading", "trailing", "belowText", "bottomInset", "settingsGap"] {
            let app = try launchReasoningDraft()
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            let input = app.textFields["codex-composer-input"].frame
            let attachment = app.buttons["Add attachment"].frame
            let point: CGPoint
            switch area {
            case "leading":
                point = CGPoint(x: input.minX - 6, y: input.midY)
            case "trailing":
                point = CGPoint(x: input.maxX + 6, y: input.midY)
            case "belowText":
                point = CGPoint(x: input.midX, y: input.maxY + 5)
            case "bottomInset":
                point = CGPoint(x: input.midX, y: attachment.maxY + 4)
            default:
                let start = app.buttons["conversation-model-menu"].frame.maxX + 44
                let end = trigger(in: app).frame.minX
                XCTAssertGreaterThan(end - start, 4, "The fixture must have empty space after the status slot.")
                point = CGPoint(x: (start + end) / 2, y: trigger(in: app).frame.midY)
            }
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                          "Empty composer region did not focus input: \(area)")
            XCTAssertFalse(slider(in: app).exists)
        }
    }

    @MainActor
    func testComposerControlsDoNotFocusInput() throws {
        let app = try launchReasoningDraft()
        openPicker(in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Opening the picker must not focus the composer.")
        app.buttons["close-reasoning-slider"].tap()
        assertClosed(in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        let fast = app.switches["conversation-fast-mode-toggle"]
        let original = fast.value as? String
        fast.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        if fast.isEnabled {
            XCTAssertNotEqual(fast.value as? String, original)
            fast.tap()
            XCTAssertEqual(fast.value as? String, original)
        }

        app.buttons["conversation-model-menu"].tap()
        XCTAssertTrue(app.buttons["Claude Sonnet"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        app.buttons["Add attachment"].tap()
        XCTAssertTrue(app.buttons["Choose File"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    @MainActor
    private func launchReasoningDraft() throws -> XCUIApplication {
        let app = launchDraft()
        let control = trigger(in: app)
        if !control.waitForExistence(timeout: 10),
           app.descendants(matching: .any).matching(identifier: "conversation-model-unavailable").firstMatch.exists {
            throw XCTSkip("Requires a configured gateway model")
        }
        XCTAssertTrue(control.exists)
        return app
    }

    @MainActor
    private func openPicker(in app: XCUIApplication) {
        trigger(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(slider(in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    private func dragSlider(in app: XCUIApplication, to fraction: CGFloat) {
        let slider = slider(in: app)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)))
        assertClosed(in: app)
    }

    @MainActor
    private func assertClosed(in app: XCUIApplication) {
        XCTAssertTrue(slider(in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(trigger(in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    private func trigger(in app: XCUIApplication) -> XCUIElement {
        app.buttons["conversation-reasoning-control"]
    }

    @MainActor
    private func slider(in app: XCUIApplication) -> XCUIElement {
        app.sliders["conversation-reasoning-slider"]
    }
}
