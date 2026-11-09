import XCTest
import Vision

/// The RESCAN LIBRARY row in SERVERS & ACCOUNTS has to show every line it is given.
///
/// A report of a library coming up short asked for the "X OF Y ON CHANNELS" line under that
/// row to be read back, and the row showed two lines ending in an ellipsis: the library
/// summary alone wraps to two lines in the pane, and every row's subtitle was cut at two.
/// This holds a test library of 444 movies and 3,639 episodes from 55 shows
/// (`-uiTestRescanRowFixture`, with `-uiTestForceSettingsPage`), opens the page with the
/// real focus engine, and reads the screen back with text recognition, since the row's
/// accessibility label is its name and a frame alone cannot say whether the words are there.
final class SettingsRescanRowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The fixture writes a fake last-load time and a fake playback verdict into the
    /// simulator's defaults. One more launch with `clear` takes them out again.
    override func tearDown() {
        let cleaner = XCUIApplication()
        cleaner.launchArguments = ["-uiTestForceSettingsPage", "-uiTestRescanRowFixture", "clear"]
        cleaner.launch()
        _ = cleaner.buttons["settingsRail_servers"].waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        cleaner.terminate()
        super.tearDown()
    }

    private func focused() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func focusedLabel() -> String {
        let f = focused()
        return f.exists ? f.label : "<none>"
    }

    private func press(_ button: XCUIRemote.Button, _ settle: TimeInterval = 0.8) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
    }

    @discardableResult
    private func shot(_ name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let a = XCTAttachment(screenshot: screenshot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        return screenshot
    }

    /// Everything the screen shows as text, upper-cased, one string. Recognised from the
    /// pixels, so it is what a viewer sees and not what the view tree holds.
    private func screenText(_ screenshot: XCUIScreenshot) -> String {
        guard let cg = screenshot.image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").uppercased()
    }

    /// Opens SERVERS & ACCOUNTS and walks down to RESCAN LIBRARY.
    private func openRescanRow(fixture: String) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestForceSettingsPage", "-uiTestRescanRowFixture", fixture]
        app.launch()
        let servers = app.buttons["settingsRail_servers"]
        XCTAssertTrue(servers.waitForExistence(timeout: 30), "Settings never opened")
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<6 where !servers.hasFocus { press(.down, 0.6) }
        XCTAssertTrue(servers.hasFocus, "rail focus: \(focusedLabel())")
        press(.right, 1.0)
        for _ in 0..<8 where focusedLabel() != "Rescan library" { press(.down, 0.7) }
        XCTAssertEqual(focusedLabel(), "Rescan library")
        Thread.sleep(forTimeInterval: 1)
    }

    /// The long-summary case: the summary line wraps to two lines, so the coverage line is
    /// the third and the "Last updated" line the fourth. Both used to be cut.
    private func check(fixture: String, expecting needles: [String]) {
        openRescanRow(fixture: fixture)
        let screenshot = shot("rescan-\(fixture)-focused")
        let text = screenText(screenshot)
        print("RESCAN-ROW \(fixture) screen text:\n\(text)")

        func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let compact = squash(text)
        for needle in needles {
            XCTAssertTrue(compact.contains(squash(needle)),
                          "\(fixture): '\(needle)' is not on the screen. Read:\n\(text)")
        }

        // The row sits fully on screen, above SYNC WITH MY OTHER APPLE TVS, with nothing over it.
        let rescan = app.buttons["Rescan library"]
        let sync = app.buttons["SYNC WITH MY OTHER APPLE TVS"]
        XCTAssertTrue(sync.exists, "SYNC row is gone")
        print("RESCAN-ROW \(fixture) frames: rescan \(rescan.frame) sync \(sync.frame) screen \(app.frame)")
        XCTAssertGreaterThanOrEqual(rescan.frame.minY, 0, "RESCAN row starts above the screen")
        XCTAssertLessThanOrEqual(rescan.frame.maxY, sync.frame.minY, "RESCAN row runs into SYNC")
        XCTAssertLessThanOrEqual(sync.frame.maxY, app.frame.maxY + 1, "SYNC row falls off the screen")

        // Focus and scrolling still work with the taller row: down to SYNC and DISCONNECT, and back.
        press(.down, 1.0)
        XCTAssertEqual(focusedLabel(), "SYNC WITH MY OTHER APPLE TVS")
        shot("rescan-\(fixture)-sync-focused")
        press(.down, 1.0)
        XCTAssertTrue(focusedLabel().lowercased().hasPrefix("disconnect from"), focusedLabel())
        shot("rescan-\(fixture)-disconnect-focused")
        press(.up, 1.0)
        press(.up, 1.0)
        XCTAssertEqual(focusedLabel(), "Rescan library", "Up twice should come back to RESCAN")
        shot("rescan-\(fixture)-back-on-rescan")
    }

    func testPlainCoverageLineIsReadable() {
        check(fixture: "plain", expecting: [
            "4,083 TITLES",
            "100% MATCHED TO TMDB",
            "4,083 OF 4,083 ON CHANNELS",
            "LAST UPDATED",
        ])
    }

    func testSplitCoverageLineIsReadable() {
        check(fixture: "split", expecting: [
            "100% MATCHED TO TMDB",
            "4,001 OF 4,083 ON CHANNELS",
            "82 ON NO CHANNEL (31 MOVIES, 51 EPISODES)",
            "12 SKIPPED (NO RUNTIME)",
            "LAST UPDATED",
            "LAST PLAYBACK FAILURE",
        ])
    }
}
