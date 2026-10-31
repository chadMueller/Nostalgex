import XCTest

/// Drives CHANNELS & BUNDLES with the real focus engine (N-028): the short list, each
/// sub-page, and Menu stepping back one page at a time to the row that opened it, then
/// to the rail. Demo mode plus the franchise fixture, so every page has rows.
///
/// The accordions this replaced opened fine in a simulator and still lagged and jumped
/// on an Apple TV, because the page re-filtered the library on every focus move. So
/// besides where focus lands, this checks each press moves focus within a second.
final class SettingsChannelsDrilldownTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func focused() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func focusedLabel() -> String {
        let f = focused()
        return f.exists ? f.label : "<none>"
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func press(_ button: XCUIRemote.Button, _ settle: TimeInterval = 0.8) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
    }

    /// Presses and returns how long focus took to move, in seconds.
    @discardableResult
    private func timedMove(_ button: XCUIRemote.Button) -> TimeInterval {
        let before = focusedLabel()
        let start = Date()
        XCUIRemote.shared.press(button)
        while focusedLabel() == before && Date().timeIntervalSince(start) < 5 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let elapsed = Date().timeIntervalSince(start)
        print("CHANNELS-DRILLDOWN move \(button) \(Int(elapsed * 1000)) ms -> \(focusedLabel().prefix(40))")
        Thread.sleep(forTimeInterval: 0.4)
        return elapsed
    }

    private func rail(_ id: String) -> XCUIElement { app.buttons["settingsRail_\(id)"] }

    private func openChannelsTab() {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestFranchiseFixture"]
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        let settings = app.buttons["tunerSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<8 where !settings.hasFocus { press(.up, 0.4) }
        for _ in 0..<8 where !settings.hasFocus { press(.right, 0.4) }
        press(.select, 2)
        XCTAssertTrue(rail("support").waitForExistence(timeout: 10), "Settings never opened")
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<4 where !rail("channels").hasFocus { press(.down) }
        XCTAssertTrue(rail("channels").hasFocus, focusedLabel())
    }

    /// Opens the focused link row, checks focus landed inside the page, and returns
    /// with Menu, checking focus is back on the same link row.
    private func visit(_ linkTitle: String, shotName: String, expectFirst: String, inside: () -> Void = {}) {
        XCTAssertTrue(focusedLabel().hasPrefix(linkTitle), "expected \(linkTitle), focus on \(focusedLabel())")
        press(.select, 1.2)
        XCTAssertTrue(focusedLabel().uppercased().contains(expectFirst),
                      "\(linkTitle): first row should be \(expectFirst), focus on \(focusedLabel())")
        shot(shotName)
        inside()
        press(.menu, 1.2)
        XCTAssertTrue(focusedLabel().hasPrefix(linkTitle), "\(linkTitle): Menu did not return to its row: \(focusedLabel())")
    }

    func testDrilldownPagesAndBack() {
        openChannelsTab()
        press(.right, 1.2)

        // The list: three link rows and the WATERSHED switch, nothing else.
        let list = ["CHANNEL PACKAGES", "FRANCHISES", "MY COLLECTIONS", "WATERSHED"]
        XCTAssertTrue(focusedLabel().hasPrefix(list[0]), focusedLabel())
        shot("after-1-channels-list")
        for title in list.dropFirst() {
            press(.down, 0.6)
            XCTAssertTrue(focusedLabel().hasPrefix(title), "expected \(title), got \(focusedLabel())")
        }
        press(.down, 0.6)
        XCTAssertTrue(focusedLabel().hasPrefix("WATERSHED"), "list should end at WATERSHED: \(focusedLabel())")
        for _ in 0..<3 { press(.up, 0.6) }

        visit("CHANNEL PACKAGES", shotName: "after-2-packages", expectFirst: "DEMO") {
            // Down to the missing-channels link, into that page and back.
            for _ in 0..<6 where !focusedLabel().hasPrefix("WHY ARE SOME CHANNELS MISSING") { press(.down, 0.6) }
            XCTAssertTrue(focusedLabel().hasPrefix("WHY ARE SOME CHANNELS MISSING"), focusedLabel())
            press(.select, 1.5)
            let card = focused()
            XCTAssertTrue(card.identifier.hasPrefix("channelRequirementCard_"), "missing page: \(card.identifier) \(focusedLabel())")
            Thread.sleep(forTimeInterval: 1)
            shot("after-3-missing")
            var cards = Set<String>([card.identifier])
            for _ in 0..<4 {
                XCTAssertLessThan(timedMove(.down), 1.0, "a press inside MISSING CHANNELS took over a second")
                cards.insert(focused().identifier)
            }
            XCTAssertEqual(cards.count, 5, "every card should take focus: \(cards)")
            press(.menu, 1.2)
            XCTAssertTrue(focusedLabel().hasPrefix("WHY ARE SOME CHANNELS MISSING"),
                          "Menu from MISSING CHANNELS should land on its link: \(focusedLabel())")
            for _ in 0..<6 { press(.up, 0.4) }
        }

        press(.down, 0.6)
        visit("FRANCHISES", shotName: "after-4-franchises", expectFirst: "ADD ALL") {
            for _ in 0..<4 {
                XCTAssertLessThan(timedMove(.down), 1.0, "a press inside FRANCHISES took over a second")
            }
        }

        press(.down, 0.6)
        visit("MY COLLECTIONS", shotName: "after-5-collections", expectFirst: "SCAN MY COLLECTIONS") {
            press(.down, 0.6)
            XCTAssertTrue(focusedLabel().hasPrefix("TOM HANKS"), "collection row: \(focusedLabel())")
        }

        // Menu from the list goes to the rail; Menu there leaves Settings.
        press(.menu, 1.2)
        XCTAssertTrue(rail("channels").hasFocus, "Menu from the list should go to the rail: \(focusedLabel())")

        // A sub-page does not survive a trip to another tab.
        press(.right, 1.2)
        press(.select, 1.2)
        press(.left, 1.0)
        press(.up, 1.0)
        press(.down, 1.0)
        press(.right, 1.2)
        XCTAssertTrue(focusedLabel().hasPrefix("CHANNEL PACKAGES"), "tab change should reset to the list: \(focusedLabel())")
    }
}
