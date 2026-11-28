import XCTest

/// The loading pattern in Settings, one walk on the simulator: a switch is running (`-uiTestGuideLoadFixture changing`),
/// the viewer goes to Settings, and SERVERS & ACCOUNTS and CHANNELS & BUNDLES show the status line; PLAYBACK & PICTURE
/// does not. Screenshots are kept as attachments.
final class SettingsLoadStatusWalkTests: XCTestCase {
    private var app: XCUIApplication!

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.8) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func focusedLabel() -> String {
        let f = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? f.label : "<nothing>"
    }

    func testSettingsShowsTheLoadingPattern() {
        continueAfterFailure = true
        XCUIRemote.shared.press(.menu)
        app = isolatedApp(arguments: ["-uiTestResetCredentials", "-uiTestMuteAudio", "-uiTestGuideLoadFixture", "changing"])
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        XCTAssertTrue(app.otherElements["guideLoadBlock"].waitForExistence(timeout: 5) || app.staticTexts["CHANNEL GUIDE IS CHANGING"].exists,
                      "the guide's block is not up")
        for _ in 0..<6 where !focusedLabel().contains("SETTINGS") { press(.up, 0.5) }
        press(.select, 3)

        // PLAYBACK & PICTURE is not a page with a status line.
        press(.down, 1)
        XCTAssertFalse(app.descendants(matching: .any)["settingsLoadStatus"].exists, "the status shows on PLAYBACK & PICTURE")

        // CHANNELS & BUNDLES.
        for _ in 0..<4 where !focusedLabel().contains("CHANNELS") { press(.down, 0.8) }
        XCTAssertTrue(app.descendants(matching: .any)["settingsLoadStatus"].waitForExistence(timeout: 5), "no status on CHANNELS & BUNDLES")
        let label = app.descendants(matching: .any)["settingsLoadStatus"].label
        XCTAssertTrue(label.contains("BUILDING CHANNELS"), label)
        XCTAssertTrue(label.contains("READ 4,210 TITLES"), label)
        XCTAssertTrue(label.contains("TV SHOWS: 1,200 OF 1,450"), label)
        shot("settings-channels-status")

        // SERVERS & ACCOUNTS.
        press(.down, 1)
        XCTAssertTrue(app.descendants(matching: .any)["settingsLoadStatus"].exists, "no status on SERVERS & ACCOUNTS")
        shot("settings-servers-status")
    }
}
