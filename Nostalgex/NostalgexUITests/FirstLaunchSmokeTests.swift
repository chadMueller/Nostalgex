import XCTest

final class FirstLaunchSmokeTests: XCTestCase {
    func testFirstLaunch_ShowsConnectToPlex() {
        // Force SettingsView so credentials never affect this smoke test.
        let app = isolatedApp(arguments: ["-uiTestForceSettings", "1"])
        app.launch()

        XCTAssertTrue(app.buttons["CONNECT TO PLEX"].waitForExistence(timeout: 15))
    }

    func testConnectFlow_InstantAuth_ShowsTunerAndDoesNotReturnToConnect() throws {
        throw XCTSkip("This flow is covered by deterministic unit tests; UI test is flaky on tvOS sim.")
    }
}

