import XCTest

/// The FRANCHISES page with the FRANCHISES switch off. Since 1.0.29 that switch gates
/// every franchise channel, franchise collections included, so a collection must not be
/// switchable (or read ON) while it is off. Demo mode plus the franchise fixture, where
/// THREE FLAVOURS CORNETTO is the franchise collection that lists on the page.
final class FranchisesPageGateUITests: XCTestCase {
    private var app: XCUIApplication!
    private let cornetto = "THREE FLAVOURS CORNETTO"

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

    private func focusedValue() -> String {
        let f = focused()
        return f.exists ? (f.value as? String ?? "") : ""
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

    private func log(_ step: String) {
        print("FRANCHISES-GATE-UI \(step): focus=\(focusedLabel()) value=\(focusedValue())")
    }

    private func rail(_ id: String) -> XCUIElement { app.buttons["settingsRail_\(id)"] }

    private func openFranchisesPage() {
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
        press(.right, 1.2)
        press(.down, 0.6)
        XCTAssertTrue(focusedLabel().hasPrefix("FRANCHISES"), focusedLabel())
        press(.select, 1.2)
        XCTAssertTrue(focusedLabel().hasPrefix("FRANCHISES"), "page opens on the switch: \(focusedLabel())")
    }

    private func walkDownTo(_ prefix: String, presses: Int = 25) -> Bool {
        for _ in 0..<presses where !focusedLabel().hasPrefix(prefix) { press(.down, 0.5) }
        return focusedLabel().hasPrefix(prefix)
    }

    private func walkUpToMaster() {
        for _ in 0..<30 where !(focusedLabel() == "FRANCHISES") { press(.up, 0.4) }
        XCTAssertEqual(focusedLabel(), "FRANCHISES")
    }

    func testCollectionsGreyOutWhileFranchisesIsOff() {
        openFranchisesPage()
        XCTAssertEqual(focusedValue(), "On")

        // FRANCHISES on: switch CORNETTO on.
        XCTAssertTrue(walkDownTo(cornetto), "CORNETTO listed with FRANCHISES on: \(focusedLabel())")
        if focusedValue() != "On" { press(.select, 1.5) }
        log("master on, cornetto")
        XCTAssertEqual(focusedValue(), "On")
        shot("gate-1-master-on")

        // FRANCHISES off.
        walkUpToMaster()
        press(.select, 2)
        log("master off")
        XCTAssertEqual(focusedValue(), "Off")
        Thread.sleep(forTimeInterval: 1)
        shot("gate-2-master-off")

        // Nothing under the switch takes focus: the collections are listed but greyed out.
        var reached: [String] = []
        for _ in 0..<4 {
            press(.down, 0.6)
            log("master off, down")
            reached.append("\(focusedLabel())=\(focusedValue())")
        }
        print("FRANCHISES-GATE-UI master off, focus walk: \(reached)")
        XCTAssertFalse(reached.contains { $0.hasPrefix(cornetto) },
                       "a franchise collection took focus with FRANCHISES off: \(reached)")
        XCTAssertTrue(app.staticTexts[cornetto].exists, "CORNETTO stays listed while FRANCHISES is off")

        // FRANCHISES on again: CORNETTO is back exactly as it was set.
        walkUpToMaster()
        press(.select, 3)
        XCTAssertEqual(focusedValue(), "On")
        XCTAssertTrue(walkDownTo(cornetto), "CORNETTO back with FRANCHISES on: \(focusedLabel())")
        log("master on again, cornetto")
        XCTAssertEqual(focusedValue(), "On", "CORNETTO keeps its choice through FRANCHISES off and on")
        shot("gate-3-master-on-again")
    }
}
