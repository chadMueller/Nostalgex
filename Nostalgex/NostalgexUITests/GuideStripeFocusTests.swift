import XCTest

/// The guide's package stripe (the coloured band down the left edge, with the package name written up it) and
/// the way into it: Left from the rows focuses it, Up and Down jump to the previous and next package (the
/// guide scrolls so that package's first channel is at the top), Right returns to the rows, Select opens the
/// package list, and Left again does too. It is never where first focus goes.
///
/// Demo mode with `-uiTestGuideStripes`: twenty demo channels in four demo packages (RETRO ACTION 1 to 6,
/// LATE NIGHT 7 to 12, TINY 13, THE REST OF THE DEMO 14 to 20). Storage is isolated (`isolatedApp`).
final class GuideStripeFocusTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func focused() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func focusText() -> String {
        if stripeIsFocused { return "stripe | \(stripeLabel)" }
        let f = focused()
        return f.exists ? "\(f.identifier.isEmpty ? "-" : f.identifier) | \(f.label)" : "<nothing>"
    }

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.9) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launchGuide() {
        XCUIRemote.shared.press(.menu)   // wakes an Apple TV in standby; harmless on a simulator
        Thread.sleep(forTimeInterval: 4)
        app = isolatedApp(arguments: ["-uiTestResetCredentials", "-uiTestManyChannels", "-uiTestGuideStripes", "-uiTestGuideJumpProbe"])
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 3)
    }

    /// What the guide itself recorded (`GuideJumpProbe`, `-uiTestGuideJumpProbe`): the focus the guide has had
    /// since it appeared. The stripe is a focus target the accessibility tree does not report as focused, so
    /// the test reads the guide's own record of where focus is: the last entry of `raw`, -903 for the stripe.
    private func probeRaw() -> [String] {
        let element = app.otherElements["guideJumpProbe"]
        guard element.exists, let value = element.value as? String, let range = value.range(of: "raw=[") else { return [] }
        let rest = value[range.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return [] }
        return rest[..<end].split(separator: ",").map { String($0.split(separator: "@")[0]) }
    }

    private var stripeIsFocused: Bool { probeRaw().last == "-903" }

    /// The stripe's own label: "Package <name>".
    private var stripeLabel: String { app.buttons["guideStripe"].exists ? app.buttons["guideStripe"].label : "<no stripe>" }

    /// Top of the list on the screen, and of channel `n`'s row.
    private var listTop: CGFloat { app.scrollViews.firstMatch.frame.minY }

    private func rowTop(_ n: Int) -> CGFloat? {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Channel \(n),")).firstMatch
        return row.exists ? row.frame.minY : nil
    }

    private func log(_ step: String) { print("STRIPE \(step): \(focusText())") }

    func testLeftFocusesTheStripeUpDownJumpPackagesAndRightReturns() {
        launchGuide()

        // First focus is a row, the playing channel: the stripe is not a focus target yet.
        log("start")
        XCTAssertTrue(focused().label.hasPrefix("Channel 1,"), "first focus: \(focusText())")
        XCTAssertFalse(stripeIsFocused)
        shot("1-start")

        // Left from the rows (the time window is at its start): the stripe, on the package of the row.
        press(.left)
        log("left")
        XCTAssertTrue(stripeIsFocused, "Left did not reach the stripe: \(focusText())")
        XCTAssertEqual(stripeLabel, "Package RETRO ACTION")
        shot("2-stripe-on-first-package")

        // Down: the next package; its first channel is at the top of the list, and focus stays on the stripe.
        for (name, firstChannel) in [("LATE NIGHT", 7), ("TINY", 13), ("THE REST OF THE DEMO", 14)] {
            press(.down, 1.3)
            log("down to \(name)")
            XCTAssertTrue(stripeIsFocused, "focus left the stripe going down to \(name): \(focusText())")
            XCTAssertEqual(stripeLabel, "Package \(name)")
            let top = rowTop(firstChannel)
            XCTAssertNotNil(top, "channel \(firstChannel) is not on screen after the jump to \(name)")
            if let top { XCTAssertEqual(top, listTop, accuracy: 6, "\(name): its first channel (\(firstChannel)) is not at the top of the list") }
            shot("3-\(name)")
        }

        // Past the last package nothing moves.
        press(.down, 1.0)
        XCTAssertTrue(stripeIsFocused)
        XCTAssertEqual(stripeLabel, "Package THE REST OF THE DEMO", "no wrap past the last package")

        // Up goes back, package by package.
        press(.up, 1.3)
        XCTAssertEqual(stripeLabel, "Package TINY")
        press(.up, 1.3)
        XCTAssertEqual(stripeLabel, "Package LATE NIGHT")
        XCTAssertTrue(stripeIsFocused)
        if let top = rowTop(7) { XCTAssertEqual(top, listTop, accuracy: 6, "LATE NIGHT back at the top") }

        // Right: back to the rows, on the first channel of the package the stripe is on, fully on screen.
        press(.right, 1.2)
        log("right")
        XCTAssertFalse(stripeIsFocused, "Right did not leave the stripe: \(focusText())")
        XCTAssertTrue(focused().label.hasPrefix("Channel 7,"), "back on \(focusText()), not channel 7")
        let list = app.scrollViews.firstMatch.frame
        if let top = rowTop(7) {
            XCTAssertGreaterThanOrEqual(top, list.minY - 1, "channel 7 is cut off at the top")
            XCTAssertLessThanOrEqual(top + 81, list.maxY + 1, "channel 7 is cut off at the bottom")
        }
        shot("4-back-on-the-rows")

        // Up from the top of the stripe's first package goes nowhere either.
        press(.left, 1.6)
        XCTAssertTrue(stripeIsFocused, "the second Left did not reach the stripe: \(focusText())")
        XCTAssertEqual(stripeLabel, "Package LATE NIGHT")
        press(.up, 1.3)
        press(.up, 1.3)
        XCTAssertEqual(stripeLabel, "Package RETRO ACTION", "no wrap before the first package")
        if let top = rowTop(1) { XCTAssertEqual(top, listTop, accuracy: 6, "the first package is at the very top") }
        // Right returns to the first channel of the package the stripe was moved to.
        press(.right, 1.2)
        XCTAssertTrue(focused().label.hasPrefix("Channel 1,"), focusText())
    }

    func testSelectOnTheStripeOpensThePackageList() {
        launchGuide()
        press(.left)
        XCTAssertTrue(stripeIsFocused, focusText())
        press(.select, 1.5)
        log("select")
        XCTAssertTrue(app.staticTexts["PACKAGES"].waitForExistence(timeout: 5), "the package list did not open")
        shot("5-package-list-from-select")
    }

    func testLeftAgainFromTheStripeOpensThePackageList() {
        launchGuide()
        press(.left)
        XCTAssertTrue(stripeIsFocused, focusText())
        press(.left, 1.5)
        log("left again")
        XCTAssertTrue(app.staticTexts["PACKAGES"].waitForExistence(timeout: 5), "the package list did not open")
        shot("6-package-list-from-left")
    }
}
