import CoreGraphics
import XCTest

final class HTMLVisualAppearanceUITests: XCTestCase {
    @MainActor
    func testVisualsFollowSwitchToDarkAppearance() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-html-visual-fixture", "-html-visual-fixture-compact", "-taskCompletionNotificationsEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["HTML visuals"].waitForExistence(timeout: 30))
        waitForTheme(.light, visual: 1, app, "in light mode")

        app.switches["html-visual-dark"].tap()
        waitForTheme(.dark, visual: 1, app, "after switching to dark appearance")

        app.buttons["Jump to visual"].tap()
        app.buttons["Last"].tap()
        waitForTheme(.dark, visual: 36, app, "on a page created after the switch")
    }

    private enum Scheme { case light, dark }

    @MainActor private func waitForTheme(_ scheme: Scheme, visual index: Int, _ app: XCUIApplication, _ moment: String) {
        let labels = ["Compact visual \(index).", "Compact visual \(index)"]
        let text = app.webViews.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 30), "Visual \(index) never rendered its document \(moment)")
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            if rendersText(scheme, text) { return }
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        }
        captureScreen(name: "HTML visual theme - \(moment)")
        XCTFail("Visual \(index) did not render \(scheme)-theme text \(moment)")
    }

    @MainActor private func rendersText(_ scheme: Scheme, _ element: XCUIElement) -> Bool {
        guard let image = element.screenshot().image.cgImage else { return false }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let ink = stride(from: 0, to: pixels.count, by: 4).count {
            switch scheme {
            case .dark: min(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 200
            case .light: max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) < 60
            }
        }
        return ink > 0 && ink * 3 < width * height
    }
}
