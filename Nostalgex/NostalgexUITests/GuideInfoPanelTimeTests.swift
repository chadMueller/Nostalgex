import XCTest

/// I-089: in the guide, Right moves the window later in time with focus staying on the row, and the top-left
/// info panel shows the focused channel's programme at that time (with when it is on, in place of the progress
/// bar), not only what is on now. Left back to the start shows what is on now again.
final class GuideInfoPanelTimeTests: XCTestCase {
    private var app: XCUIApplication!

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.9) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    /// The focused element's label. Focus can read as nowhere for a moment while the window animates, so look
    /// again for up to two seconds before saying so.
    private func focusedLabel() -> String {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let f = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if f.exists { return f.label }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return "<nothing>"
    }

    private var time: XCUIElement { app.staticTexts["infoPanelTime"] }

    func testTheInfoPanelFollowsTheWindowThroughTime() {
        continueAfterFailure = false
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 4)
        app = isolatedApp(arguments: ["-uiTestResetCredentials", "-uiTestManyChannels"])
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 3)

        // At the start of the window the panel shows what is on now: no "when it is on" line.
        XCTAssertTrue(focusedLabel().hasPrefix("Channel 1,"), focusedLabel())
        XCTAssertFalse(time.exists, "the panel previews a later programme at the start of the window")

        // Right, a step at a time: focus stays on the row, and within three hours the programme changes and the
        // panel shows it with its time range.
        var seen: String?
        for step in 1...6 where seen == nil {
            press(.right, 1.0)
            // The panel stays on this row's channel while the window moves: Right is a step through time, not a row.
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'CH 01'")).firstMatch.exists,
                          "the panel left channel 1 at step \(step)")
            if time.exists { seen = time.label }
        }
        let range = try? XCTUnwrap(seen, "after six steps right the panel still shows what is on now")
        XCTAssertTrue(range?.contains(" - ") ?? false, "time range: \(range ?? "-")")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "panel-later-programme"; shot.lifetime = .keepAlways; add(shot)

        // The panel also follows a change of row while the window is moved.
        press(.down, 1.0)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'CH 02'")).firstMatch.waitForExistence(timeout: 3),
                      "the panel is not on channel 2")

        // Left all the way back: the live programme again.
        for _ in 0..<8 where time.exists { press(.left, 0.8) }
        XCTAssertFalse(time.exists, "the panel still previews a later programme at the start of the window")
    }
}
