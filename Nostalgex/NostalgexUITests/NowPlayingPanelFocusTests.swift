import XCTest

/// Drives the in-player Now Playing panel with the real tvOS focus engine.
///
/// The panel's focus has broken twice (f8dbf2d, 9a15a83) with the same symptom both
/// times: focus lands on the first row and directional presses do nothing after that.
/// No unit test can see it — the failure lives in how SwiftUI hands directional presses
/// to the focus engine — so this presses the remote and asserts every row is reachable.
final class NowPlayingPanelFocusTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchIntoPanel() -> XCUIApplication {
        let app = isolatedApp(arguments: ["-uiTestResetCredentials"])
        app.launch()

        // The connect screen stamps one accessibility identifier on every element, so
        // match the demo button by label.
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")

        // tvOS has no tap: walk focus down to the demo button, then select.
        for _ in 0..<10 where !demo.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(demo.hasFocus, "could not focus the demo mode button")
        XCUIRemote.shared.press(.select)

        // Play/Pause on the tuner enters fullscreen; DOWN opens the top panel.
        XCTAssertTrue(waitForTuner(app), "demo mode never reached the tuner")
        XCUIRemote.shared.press(.playPause)
        Thread.sleep(forTimeInterval: 5)
        XCUIRemote.shared.press(.down)

        XCTAssertTrue(
            app.buttons.matching(labelContains("RETRO MODE")).firstMatch.waitForExistence(timeout: 15),
            "Now Playing panel never opened"
        )
        return app
    }

    private func waitForTuner(_ app: XCUIApplication) -> Bool {
        app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30)
    }

    private func labelContains(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS[c] %@", text)
    }

    /// Label of whatever button currently holds focus, or nil if focus is nowhere —
    /// which is itself the failure mode these tests exist to catch.
    private func focusedLabel(_ app: XCUIApplication) -> String? {
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else { return nil }
        return focused.label
    }

    /// Presses `direction` up to `steps` times, collecting the focused label after each
    /// press. Stops early once focus stops moving (the end of a column).
    @discardableResult
    private func walk(
        _ app: XCUIApplication,
        _ direction: XCUIRemote.Button,
        steps: Int
    ) -> [String] {
        var seen: [String] = []
        if let start = focusedLabel(app) { seen.append(start) }
        for _ in 0..<steps {
            XCUIRemote.shared.press(direction)
            guard let label = focusedLabel(app) else {
                XCTFail("focus was lost after pressing \(direction)")
                return seen
            }
            if label == seen.last { break }
            seen.append(label)
        }
        return seen
    }

    // MARK: - Tests

    func testPanelFocus_reachesEveryRowInBothColumns() {
        let app = launchIntoPanel()

        // Focus opens on CC, at the top of the program column.
        XCTAssertEqual(focusedLabel(app)?.contains("CC"), true, "panel did not open focused on CC")

        // Demo streams expose one audio track, so the audio rows are correctly absent
        // here; the subtitle rows are the program column's conditional pair under test.
        let programColumn = walk(app, .down, steps: 12).joined(separator: " | ")
        for expected in ["SUBTITLE LANGUAGE", "AUTO SUBTITLES"] {
            XCTAssertTrue(
                programColumn.localizedCaseInsensitiveContains(expected),
                "down never reached \(expected). Visited: \(programColumn)"
            )
        }

        // Cross into the device column and walk it top to bottom.
        XCUIRemote.shared.press(.right)
        XCTAssertNotNil(focusedLabel(app), "focus was lost crossing to the device column")
        walk(app, .up, steps: 12)

        let deviceColumn = walk(app, .down, steps: 12).joined(separator: " | ")
        for expected in ["RETRO MODE", "STREAM QUALITY", "OFF", "15 MIN", "30 MIN", "1 HR"] {
            XCTAssertTrue(
                deviceColumn.localizedCaseInsensitiveContains(expected),
                "down never reached \(expected). Visited: \(deviceColumn)"
            )
        }

        // And back again — the two columns are one focus section, not two islands.
        XCUIRemote.shared.press(.left)
        XCTAssertNotNil(focusedLabel(app), "focus was lost crossing back to the program column")
    }

    func testPanelFocus_expandingAndClosingAPickerKeepsFocus() {
        let app = launchIntoPanel()

        let quality = app.buttons.matching(labelContains("STREAM QUALITY")).firstMatch
        XCTAssertTrue(quality.exists)

        // Walk to STREAM QUALITY without assuming a fixed row count.
        for step in 0..<14 {
            if quality.hasFocus { break }
            XCUIRemote.shared.press(step == 0 ? .right : .down)
        }
        XCTAssertTrue(quality.hasFocus, "never reached the STREAM QUALITY row")
        XCUIRemote.shared.press(.select)

        // The expanded list replaces the columns; focus must land on the active option.
        XCTAssertTrue(
            app.buttons.matching(labelContains("MAXIMUM")).firstMatch.waitForExistence(timeout: 10),
            "stream quality picker did not expand"
        )
        XCTAssertNotNil(focusedLabel(app), "focus was lost when the picker expanded")

        let options = walk(app, .down, steps: 8).joined(separator: " | ")
        for expected in ["MAXIMUM", "HIGH", "MEDIUM", "LOW"] {
            XCTAssertTrue(
                options.localizedCaseInsensitiveContains(expected),
                "picker did not expose \(expected). Visited: \(options)"
            )
        }

        // Back collapses the picker and hands focus back to the row that owns it,
        // rather than dropping the whole panel.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            app.buttons.matching(labelContains("RETRO MODE")).firstMatch.waitForExistence(timeout: 10),
            "Back closed the panel instead of the picker"
        )
        let landed = focusedLabel(app) ?? "<nothing focused>"
        XCTAssertTrue(
            landed.localizedCaseInsensitiveContains("STREAM QUALITY"),
            "focus did not return to the STREAM QUALITY row, landed on: \(landed)"
        )
    }

    func testPlaybackInformationIsBelowSleepTimerAndBackRestoresItsFocus() {
        let app = launchIntoPanel()
        let retro = app.buttons.matching(labelContains("RETRO MODE")).firstMatch
        let quality = app.buttons.matching(labelContains("STREAM QUALITY")).firstMatch
        let sleep = app.buttons.matching(labelContains("1 HR")).firstMatch
        let information = app.buttons.matching(labelContains("PLAYBACK INFORMATION")).firstMatch
        XCTAssertTrue(information.waitForExistence(timeout: 10))
        XCTAssertLessThan(retro.frame.minY, quality.frame.minY)
        XCTAssertLessThan(quality.frame.minY, sleep.frame.minY)
        XCTAssertLessThan(sleep.frame.maxY, information.frame.minY)

        XCUIRemote.shared.press(.right)
        walk(app, .up, steps: 15)
        let labels = walk(app, .down, steps: 15)
        let visited = labels.joined(separator: " | ")
        for expected in ["RETRO MODE", "STREAM QUALITY", "15 MIN", "30 MIN", "1 HR", "PLAYBACK INFORMATION"] {
            XCTAssertTrue(visited.localizedCaseInsensitiveContains(expected), "device controls skipped \(expected): \(visited)")
        }
        XCTAssertTrue(focusedLabel(app)?.contains("PLAYBACK INFORMATION") == true)
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "Playback information below sleep timer"
        controls.lifetime = .keepAlways
        add(controls)

        XCUIRemote.shared.press(.select)
        let back = app.buttons["Back to playback controls"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        let backFocus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [backFocus], timeout: 3), .completed)
        XCTAssertTrue(app.descendants(matching: .any).matching(labelContains("BACKEND")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(labelContains("DELIVERED CODECS")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(labelContains("STREAM BITRATE")).firstMatch.exists)
        let details = XCTAttachment(screenshot: app.screenshot())
        details.name = "Playback information contents"
        details.lifetime = .keepAlways
        add(details)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(retro.waitForExistence(timeout: 10), "Back dismissed the panel")
        let ownerFocus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: information)
        XCTAssertEqual(XCTWaiter.wait(for: [ownerFocus], timeout: 3), .completed)
    }
}
