import XCTest

/// EPISODE ORDER (I-103), one walk on the simulator in demo mode: the row in CHANNELS & BUNDLES reads CLASSIC RERUNS,
/// a press makes it SHUFFLE, the guide's rows are read again, and what is playing carries on. Prints what the guide
/// showed before and after (`EPISODE-ORDER-WALK`), and keeps screenshots as attachments (and as files when
/// `NX_WALK_SHOTS` names a folder).
final class EpisodeOrderWalkTests: XCTestCase {
    private var app: XCUIApplication!

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.8) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    private func focused() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func focusedLabel() -> String { focused().exists ? focused().label : "<none>" }

    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["NX_WALK_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// The row's value is its own text on screen (and its accessibility value), not part of its label.
    private func rowReads(_ value: String) -> Bool {
        app.staticTexts[value].exists || (focused().value as? String) == value
    }

    /// Every label on screen, in order: the guide's rows and the now-playing line among them.
    private func labels() -> [String] {
        app.descendants(matching: .any).allElementsBoundByIndex.prefix(400).map(\.label).filter { !$0.isEmpty }
    }

    func testPressingTheRowChangesTheGuideAndPlaybackCarriesOn() {
        continueAfterFailure = true
        XCUIRemote.shared.press(.menu)
        app = isolatedApp(arguments: ["-uiTestResetCredentials", "-uiTestMuteAudio"])
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        let settings = app.buttons["tunerSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 4)
        let before = labels()
        shot("1-guide-before")
        print("EPISODE-ORDER-WALK before: \(before.joined(separator: " | "))")

        for _ in 0..<8 where !settings.hasFocus { press(.up, 0.4) }
        for _ in 0..<8 where !settings.hasFocus { press(.right, 0.4) }
        press(.select, 2)
        let rail = app.buttons["settingsRail_channels"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "Settings never opened")
        for _ in 0..<5 where !rail.hasFocus { press(.down) }
        press(.right, 1)
        for _ in 0..<8 where !focusedLabel().uppercased().contains("EPISODE ORDER") { press(.down, 0.6) }
        XCTAssertTrue(focusedLabel().uppercased().contains("EPISODE ORDER"), focusedLabel())
        XCTAssertTrue(rowReads("CLASSIC RERUNS"), "the row does not read CLASSIC RERUNS")
        print("EPISODE-ORDER-WALK row before: \(focusedLabel())")
        shot("2-row-classic")
        press(.select, 1.5)
        print("EPISODE-ORDER-WALK row after: \(focusedLabel())")
        XCTAssertTrue(rowReads("SHUFFLE"), "the row does not read SHUFFLE after a press")
        shot("3-row-shuffle")

        // Back to the guide.
        for _ in 0..<4 where !settings.exists { press(.menu, 1.2) }
        for _ in 0..<3 where !app.buttons["tunerSettingsButton"].waitForExistence(timeout: 2) { press(.menu, 1.2) }
        Thread.sleep(forTimeInterval: 3)
        let after = labels()
        shot("4-guide-after")
        print("EPISODE-ORDER-WALK after: \(after.joined(separator: " | "))")
        print("EPISODE-ORDER-WALK changed: \(before != after)")
        // Demo mode's episode channel is the one the order changes; what is playing (a film here) carries on.
        XCTAssertNotEqual(before.filter { $0.contains("Demo Episode") }, after.filter { $0.contains("Demo Episode") },
                          "the guide's episode row did not change")
        XCTAssertEqual(before.first { $0.hasPrefix("CH ") }, after.first { $0.hasPrefix("CH ") })
        XCTAssertEqual(before.dropFirst().first, after.dropFirst().first, "what is playing changed")

        // Leave the simulator's setting as it was found.
        for _ in 0..<8 where !settings.hasFocus { press(.up, 0.4) }
        for _ in 0..<8 where !settings.hasFocus { press(.right, 0.4) }
        press(.select, 2)
        for _ in 0..<5 where !rail.hasFocus { press(.down) }
        press(.right, 1)
        for _ in 0..<8 where !focusedLabel().uppercased().contains("EPISODE ORDER") { press(.down, 0.6) }
        if rowReads("SHUFFLE") { press(.select, 1.5) }
        XCTAssertTrue(rowReads("CLASSIC RERUNS"), "the row was not put back to CLASSIC RERUNS")
    }
}
