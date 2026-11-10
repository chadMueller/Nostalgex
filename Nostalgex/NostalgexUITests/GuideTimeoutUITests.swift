import XCTest

/// GUIDE TIMEOUT end to end in demo mode, with `-uiTestGuideTimeoutSeconds 20` standing in for
/// five minutes: a guide left alone goes fullscreen on the playing channel, and a guide the
/// viewer keeps pressing stays put.
///
/// Fullscreen is read from the Now Playing panel: DOWN in fullscreen opens it (RETRO MODE is
/// its first row), while DOWN on the guide only moves to the next channel row.
final class GuideTimeoutUITests: XCTestCase {
    private var app: XCUIApplication!

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.8) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    private func launchIntoDemo() {
        continueAfterFailure = false
        XCUIRemote.shared.press(.menu)   // wakes an Apple TV in standby; harmless on a simulator
        Thread.sleep(forTimeInterval: 4)
        app = XCUIApplication()
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = "guide-timeout-\(Int(Date().timeIntervalSince1970))"
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestGuideTimeoutSeconds", "20"]
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.6) }
        XCTAssertTrue(demo.hasFocus, "could not focus the demo mode button")
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
    }

    private var nowPlayingPanelRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "RETRO MODE")).firstMatch
    }

    func testAGuideLeftAloneGoesFullscreen() {
        launchIntoDemo()
        Thread.sleep(forTimeInterval: 30)
        press(.down, 2)
        XCTAssertTrue(nowPlayingPanelRow.waitForExistence(timeout: 10),
                      "the guide was still up 30 seconds into a 20-second timeout")
    }

    func testAGuideInUseStaysUp() {
        launchIntoDemo()
        // A press every 8 seconds for 40 seconds: never 20 seconds without one.
        for i in 0..<5 {
            Thread.sleep(forTimeInterval: 7)
            press(i.isMultiple(of: 2) ? .down : .up, 1)
        }
        XCTAssertFalse(nowPlayingPanelRow.exists, "the guide went fullscreen while the remote was in use")
        XCTAssertTrue(app.buttons["tunerSettingsButton"].isHittable, "the guide is no longer in front")
    }
}
