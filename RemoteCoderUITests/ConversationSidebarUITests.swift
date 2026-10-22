import XCTest

/// Drives the shipped app, not a model: open the merged drawer from its
/// accessible control and select conversations owned by two different
/// gateways. Model-level tests cannot cover this, because the drawer used to
/// be reachable only by an edge drag that no automation can perform.
///
/// Requires the target simulator to have more than one gateway configured with
/// cached conversations, which is the only state in which the merged drawer
/// differs from the old single-host one. Run it with `just ios-ui-test`.
final class ConversationSidebarUITests: XCTestCase {
    private static let rowPrefix = "conversation-row-"
    private static let timeout: TimeInterval = 90

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTheDrawerListsAndSelectsConversationsOnEveryConfiguredHost() throws {
        let app = XCUIApplication()
        app.launch()

        let hostLabel = Self.activeHost(in: app)
        try XCTSkipUnless(
            hostLabel.waitForExistence(timeout: Self.timeout),
            "Requires a simulator with several configured gateways; the chat says which one runs the next prompt."
        )
        let initialHost = hostLabel.label

        openDrawer(in: app)

        // The list is lazy, so only realized rows exist. Scroll until a second
        // host's rows appear, and remember one row per host while it is on screen.
        var topRowsByHost: [String: String] = [:]
        var scrolledRow: String?
        for scroll in 0..<15 {
            let visible = visibleRowIdentifiers(in: app)
            if scroll == 0 {
                XCTAssertFalse(visible.isEmpty, "The drawer must list the configured hosts' cached conversations.")
                for identifier in visible {
                    topRowsByHost[Self.hostID(of: identifier)] = topRowsByHost[Self.hostID(of: identifier)] ?? identifier
                }
            } else {
                scrolledRow = visible.first { topRowsByHost[Self.hostID(of: $0)] == nil }
            }
            if scrolledRow != nil || topRowsByHost.count > 1 { break }
            app.swipeUp()
        }

        let firstHostID = try XCTUnwrap(topRowsByHost.keys.sorted().first, "no rows were listed")
        let secondRow = try XCTUnwrap(
            scrolledRow ?? topRowsByHost.first { $0.key != firstHostID }?.value,
            "The drawer only listed host \(firstHostID); a merged sidebar must carry every configured gateway."
        )
        XCTAssertNotEqual(Self.hostID(of: secondRow), firstHostID)

        // The second host's row is on screen right now, so select it here.
        let secondHostLabel = try selectRow(secondRow, in: app)

        // Reopening starts at the top of the list again, where the first host
        // had rows, so the return trip crosses hosts in the other direction.
        openDrawer(in: app)
        let firstRow = try XCTUnwrap(
            visibleRowIdentifiers(in: app).first { Self.hostID(of: $0) == firstHostID },
            "The first host's rows disappeared after selecting a conversation on the other host."
        )
        let firstHostLabel = try selectRow(firstRow, in: app)

        XCTAssertNotEqual(
            firstHostLabel,
            secondHostLabel,
            "Selecting a row must switch to its owning host: both selections reported \(firstHostLabel)."
        )
        XCTAssertTrue(firstHostLabel.hasPrefix("Running on"))
        XCTAssertTrue(secondHostLabel.hasPrefix("Running on"))
        XCTAssertTrue(
            [firstHostLabel, secondHostLabel].contains(initialHost),
            "One of the two selections should have been the host that was already visible (\(initialHost))."
        )
    }

    // MARK: - Helpers

    @MainActor
    private func openDrawer(in app: XCUIApplication) {
        let control = app.buttons["open-conversations"]
        XCTAssertTrue(control.waitForExistence(timeout: Self.timeout), "the accessible drawer control must exist")
        control.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(Self.rowQuery).firstMatch.waitForExistence(timeout: Self.timeout),
            "the drawer must open and list conversations"
        )
    }

    /// Taps a row and returns the host the chat then reports running on.
    @MainActor
    private func selectRow(_ identifier: String, in app: XCUIApplication) throws -> String {
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout), "row \(identifier) is not on screen")
        row.tap()

        let hostLabel = Self.activeHost(in: app)
        XCTAssertTrue(hostLabel.waitForExistence(timeout: Self.timeout))
        // The drawer closes on selection, so the chat is visible again.
        XCTAssertTrue(
            app.buttons["open-conversations"].waitForExistence(timeout: Self.timeout),
            "selecting a row must return to the chat"
        )
        return hostLabel.label
    }

    @MainActor
    private func visibleRowIdentifiers(in app: XCUIApplication) -> [String] {
        var seen: Set<String> = []
        return app.descendants(matching: .any).matching(Self.rowQuery)
            .allElementsBoundByIndex
            .filter(\.exists)
            .map(\.identifier)
            .filter { seen.insert($0).inserted }
    }

    /// SwiftUI decides the element type of a combined header, so match on the
    /// identifier alone rather than guessing between static text and other.
    @MainActor
    private static func activeHost(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "active-host").firstMatch
    }

    private static var rowQuery: NSPredicate {
        NSPredicate(format: "identifier BEGINSWITH %@", rowPrefix)
    }

    /// `conversation-row-<host uuid>|<thread id>`.
    private static func hostID(of identifier: String) -> String {
        String(identifier.dropFirst(rowPrefix.count).prefix { $0 != "|" })
    }
}
