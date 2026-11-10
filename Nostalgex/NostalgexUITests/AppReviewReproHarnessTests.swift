import XCTest

final class AppReviewReproHarnessTests: XCTestCase {
    func testReproAppReviewFlow_LandsOnTuner() {
        let app = isolatedApp(arguments: ["-reproAppReviewFlow", "1"])
        app.launch()

        XCTAssertTrue(app.buttons["SETTINGS"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["CONNECT TO PLEX"].exists)
    }
}

