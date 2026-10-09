import XCTest

/// Drives FIND SERVERS ON MY NETWORK on the Emby form against whatever is really on
/// the test machine's LAN. Needs a live Emby server, so it only runs when asked:
///
///   TEST_RUNNER_NOSTALGEX_LAN_DISCOVERY_UITEST=1 xcodebuild test ... -only-testing:NostalgexUITests/LANDiscoveryUITests
///
/// (xcodebuild forwards TEST_RUNNER_ prefixed variables to the test process.)
///
/// It pauses on the results list and again after the pick so a screenshot can be
/// taken from outside with `xcrun simctl io booted screenshot`.
final class LANDiscoveryUITests: XCTestCase {

    func testEmbyForm_findServers_listsTheRealServerAndFillsTheField() throws {
        guard ProcessInfo.processInfo.environment["NOSTALGEX_LAN_DISCOVERY_UITEST"] == "1" else {
            throw XCTSkip("Needs a real Emby on the LAN. Set NOSTALGEX_LAN_DISCOVERY_UITEST=1 to run.")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestForceSettings", "1"]
        app.launch()

        XCTAssertTrue(app.buttons["CONNECT TO PLEX"].waitForExistence(timeout: 15))
        moveFocus(to: app.buttons["EMBY"], pressing: .down)
        XCUIRemote.shared.press(.select)

        let find = app.buttons["FIND SERVERS ON MY NETWORK"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        moveFocus(to: find, pressing: .down)
        XCUIRemote.shared.press(.select)

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'http'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no server answered the broadcast")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No servers found'")).firstMatch.exists)
        let rowLabel = row.label
        print("[UITest] discovered row label: \(rowLabel)")
        sleep(6)  // screenshot window: results list showing

        moveFocus(to: row, pressing: .down)
        XCUIRemote.shared.press(.select)

        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH 'http'"), object: urlField)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, "URL field did not fill")
        let filled = urlField.value as? String ?? ""
        print("[UITest] URL field now: \(filled)")
        XCTAssertTrue(rowLabel.contains(filled), "field \(filled) is not the address from the row \(rowLabel)")
        XCTAssertFalse(row.exists, "list should clear after a pick")
        sleep(6)  // screenshot window: field filled
    }

    private func moveFocus(to element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int = 8) {
        var presses = 0
        while !element.hasFocus && presses < limit {
            XCUIRemote.shared.press(direction)
            usleep(500_000)
            presses += 1
        }
        XCTAssertTrue(element.hasFocus, "could not focus \(element.identifier) after \(presses) presses")
    }
}
