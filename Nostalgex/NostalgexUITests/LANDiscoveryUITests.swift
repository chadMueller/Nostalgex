import XCTest

/// Opens the Emby screen, whose search starts on its own, against whatever is really on
/// the test machine's LAN. Needs a live Emby server, so it only runs when asked:
///
///   TEST_RUNNER_NOSTALGEX_LAN_DISCOVERY_UITEST=1 xcodebuild test ... -scheme NostalgexUITests -only-testing:NostalgexUITests/LANDiscoveryUITests
///
/// (xcodebuild forwards TEST_RUNNER_ prefixed variables to the test process.)
///
/// With one Emby answering, the app goes straight to that server's sign-in screen with no
/// pick; with several, it lists them and the first is picked here.
final class LANDiscoveryUITests: XCTestCase {

    func testEmbyScreen_findMyServer_opensTheRealServersSignIn() throws {
        guard ProcessInfo.processInfo.environment["NOSTALGEX_LAN_DISCOVERY_UITEST"] == "1" else {
            throw XCTSkip("Needs a real Emby on the LAN. Set NOSTALGEX_LAN_DISCOVERY_UITEST=1 to run.")
        }

        let app = isolatedApp(arguments: ["-uiTestForceSettings", "1"])
        app.launch()

        XCTAssertTrue(app.buttons["CONNECT TO PLEX"].waitForExistence(timeout: 15))
        moveFocus(to: app.buttons["EMBY"], pressing: .down)
        XCUIRemote.shared.press(.select)

        // The search starts as the screen opens; FIND MY SERVER is only the retry.

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'embyDiscoveredServer-'")).firstMatch
        let signInTo = app.staticTexts["SIGN IN TO"]
        let start = Date()
        while !signInTo.exists && !row.exists && Date().timeIntervalSince(start) < 15 { usleep(300_000) }
        if row.exists {
            moveFocus(to: row, pressing: .down)
            XCUIRemote.shared.press(.select)
        }
        XCTAssertTrue(signInTo.waitForExistence(timeout: 15), "no sign-in screen after discovery")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No server answered'")).firstMatch.exists)
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
