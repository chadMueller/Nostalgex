import XCTest

/// ABOUT > LINKS lists Discord, the website, the web tuner, Roku and GitHub, each with its
/// address on screen, and the RATE tile and the rating banner each say where the stars are.
final class SettingsAboutLinksTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func press(_ button: XCUIRemote.Button, _ settle: TimeInterval = 0.7) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
    }

    private func focusedLabel() -> String {
        let f = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? f.label : "<none>"
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func openRail(_ id: String) {
        let rail = app.buttons[id]
        XCTAssertTrue(rail.waitForExistence(timeout: 30), "Settings never opened")
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<8 where !rail.hasFocus { press(.down, 0.6) }
        XCTAssertTrue(rail.hasFocus, "rail \(id) never took focus")
        press(.right, 1.0)
    }

    func testAboutListsEveryLinkWithItsAddress() {
        app = isolatedApp(arguments: ["-uiTestForceSettingsPage"])
        app.launch()
        openRail("settingsRail_about")
        let expected = [
            ("DISCORD", "discord.gg/FgnZcr5bDT"),
            ("WEBSITE", "nostalgex.app"),
            ("WEB TUNER", "nostalgex.app/web-tuner"),
            ("ROKU", "my.roku.com/account/add/NOSTALGEX"),
            ("GITHUB", "github.com/chadMueller/Nostalgex"),
        ]
        // Walk the remote down the list: each row takes focus in turn, so the pane has scrolled to it and
        // its address is on screen, down to the last one.
        for (title, address) in expected {
            for _ in 0..<2 where !focusedLabel().contains(address) { press(.down) }
            XCTAssertTrue(focusedLabel().contains(address), "\(title): focus is on \(focusedLabel())")
            XCTAssertTrue(app.staticTexts[address].isHittable, "\(title): \(address) is not on screen")
        }
        shot("about-links-bottom")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'android'")).firstMatch.exists)
    }

    func testRateTileSaysWhereTheStarsAre() {
        app = isolatedApp(arguments: ["-uiTestForceSettingsPage"])
        app.launch()
        openRail("settingsRail_support")
        shot("support-rate")
        // The tile only draws when tips are available; the plain row carries the same words.
        let words = "Opens the App Store page. Scroll down to the stars to rate."
        let hint = app.staticTexts["supportTileHint"]
        let row = app.staticTexts[words]
        XCTAssertTrue(hint.exists || row.exists, "RATE shows no instruction")
        if hint.exists { XCTAssertEqual(hint.label, words) }
    }

    /// The banner is forced (`-NostalgexForceRatingNudge`) and appears on the way back from full
    /// screen to the guide. Its second line is the instruction, and RATE is the focused button.
    func testBannerSaysWhereTheStarsAre() {
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 3)
        app = isolatedApp(arguments: ["-uiTestResetCredentials", "-uiTestManyChannels", "-NostalgexForceRatingNudge"])
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 2)
        press(.select, 2.5)
        press(.select, 3.0)
        press(.menu, 2.0)
        let hint = app.staticTexts["ratingNudgeHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "the banner never showed its instruction")
        shot("rating-banner")
        XCTAssertEqual(hint.label, "Opens the App Store page. Scroll down to the stars to rate.")
        XCTAssertTrue(app.buttons["ratingNudgeRate"].exists)
    }
}
