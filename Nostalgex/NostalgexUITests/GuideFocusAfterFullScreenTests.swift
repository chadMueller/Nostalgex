import XCTest

/// I-041: change channel in full screen, go back to the guide, and the guide has to be on the
/// channel that is now playing. It came back on the row the viewer had left from, because tvOS
/// restores the last focused row after the full screen cover closes.
///
/// Demo mode, with the app's storage isolated (`NOSTALGEX_HARNESS_ROOT`) so a run on a real Apple
/// TV never touches the sign-in or the library that TV holds.
final class GuideFocusAfterFullScreenTests: XCTestCase {
    private var app: XCUIApplication!

    private func focused() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.8) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The channel the guide's selection is on, read from what the viewer sees: the info panel's
    /// header follows the focused row ("CH 06 - DEMO FILLER 6").
    private func panelChannelNumber() -> String? {
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'CH '")).firstMatch
        guard header.exists else { return nil }
        return String(header.label.prefix(5))
    }

    /// What the debug probe in the guide recorded since the guide last came back or first appeared
    /// (`GuideJumpProbe`, readable with `-uiTestGuideJumpProbe`): `origin=... live=<id> shown=[...] raw=[...]`.
    /// `shown` is the row the guide drew highlighted, in order, which is what the viewer sees.
    private func probeSummary() -> String {
        let element = app.otherElements["guideJumpProbe"]
        return element.exists ? (element.value as? String ?? "") : "<no probe>"
    }

    private func probeList(_ key: String, in summary: String) -> [String] {
        guard let range = summary.range(of: "\(key)=[") else { return [] }
        let rest = summary[range.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return [] }
        // Each entry is "id@milliseconds": the row, and when the guide drew or focused it.
        return rest[..<end].split(separator: ",").map { String($0.split(separator: "@")[0]) }
    }

    /// The scroll offsets the probe saw since the guide came back: the first is where the list was, any
    /// further entry is the list moving in front of the viewer.
    private func probeScroll(in summary: String) -> [String] { probeList("scroll", in: summary) }

    private func probeLive(in summary: String) -> String? {
        guard let range = summary.range(of: "live=") else { return nil }
        return String(summary[range.upperBound...].prefix { $0 != " " })
    }

    /// The guide must have drawn the live channel highlighted from its first frame, and never another row
    /// before it: the viewer must not see the highlight move.
    private func assertNeverShownAnotherRow(_ summary: String, live expected: String, _ context: String) {
        let live = probeLive(in: summary)
        XCTAssertEqual(live, expected, "\(context): the probe read the wrong live channel: \(summary)")
        let rows = probeList("shown", in: summary).filter { $0 != "none" }
        XCTAssertEqual(rows, [expected], "\(context): the guide drew \(rows) highlighted, not only the live channel \(expected). \(summary)")
    }

    private func settled(on prefix: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if panelChannelNumber() == prefix { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return panelChannelNumber() == prefix
    }

    func testChannelChangedInFullScreenThenBackLandsOnTheLiveChannel() {
        continueAfterFailure = false
        // An Apple TV in standby refuses a foreground launch; a remote press wakes it. Harmless
        // on a simulator.
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 4)
        app = XCUIApplication()
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = "i041-guide-focus"
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestManyChannels", "-uiTestGuideJumpProbe"]
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 2)

        // Tune channel 4 from the guide, then go full screen.
        for _ in 0..<8 where !(focused().exists && focused().label.hasPrefix("Channel 4,")) { press(.down, 0.6) }
        XCTAssertTrue(focused().label.hasPrefix("Channel 4,"), "could not reach channel 4: \(focused().label)")
        press(.select, 2.5)
        press(.select, 3.0)

        // Two channels up in full screen: the playing channel is now 6.
        press(.right, 2.0)
        press(.right, 2.0)
        shot("fullscreen-on-channel-6")

        // Back to the guide: the selection has to be the live channel, 6, not the 4 the viewer left from.
        // The first frames of the guide coming back, as fast as the harness can take them.
        XCUIRemote.shared.press(.menu)
        shot("guide-returning-frame-1")
        shot("guide-returning-frame-2")
        Thread.sleep(forTimeInterval: 1.0)
        let landed = settled(on: "CH 06", within: 6)
        shot("guide-after-return")
        XCTAssertTrue(landed, "the guide came back on \(panelChannelNumber() ?? "no channel"), not the live channel 6")
        // What the viewer saw on the way: the old row (channel 4) must never have been drawn highlighted.
        let summary = probeSummary()
        print("GUIDE-JUMP full-screen return: \(summary)")
        XCTAssertTrue(summary.hasPrefix("origin=fullScreenClosed"), summary)
        assertNeverShownAnotherRow(summary, live: "9006", "back from full screen")
    }

    /// The same handout problem when the guide first appears: with the playing channel not the first
    /// (what OPEN ON LAST CHANNEL does, and a seasonal invite above channel 1 does to the first row),
    /// tvOS handed focus to the first row, not the channel that is playing.
    func testGuideOpensOnThePlayingChannelWhenItIsNotTheFirst() {
        guideOpensOnTheLiveChannel(startingOn: "4", withInvite: false, root: "i041-first-focus")
    }

    /// A seasonal invite sits above channel 1 while its package is in season; first focus went to it
    /// instead of the channel that is playing.
    func testGuideOpensOnThePlayingChannelWithASeasonalInviteAboveChannelOne() {
        guideOpensOnTheLiveChannel(startingOn: "1", withInvite: true, root: "i041-first-focus-invite")
    }

    private func guideOpensOnTheLiveChannel(startingOn channel: String, withInvite: Bool, root: String) {
        continueAfterFailure = false
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 4)
        app = XCUIApplication()
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = root
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestManyChannels", "-uiTestStartOnChannel", channel,
                               "-uiTestGuideJumpProbe"]
            + (withInvite ? ["-uiTestSeasonalInvite"] : [])
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 3)
        shot("guide-first-seconds-\(withInvite ? "invite" : "plain")")
        XCTAssertTrue(focused().exists && focused().label.hasPrefix("Channel \(channel),"),
                      "the guide opened on \(focused().exists ? focused().label : "nothing"), not the playing channel \(channel)")
        // And it never drew the first row, or the invite, highlighted on the way.
        let summary = probeSummary()
        print("GUIDE-JUMP first appearance (channel \(channel), invite \(withInvite)): \(summary)")
        assertNeverShownAnotherRow(summary, live: "900\(channel)", "first appearance")
    }

    // MARK: The old row far from the live one

    /// tvOS scrolls a list to show the row it focuses. When the row it hands focus to is far from the live
    /// channel (here 19 rows, a whole screen and more), that scroll must not be seen: the list has to stay
    /// where the guide put it, on the live channel, and not slide to the old row and back.
    ///
    /// Channel down from channel 1 wraps to channel 20, so one press in full screen is a 19 row jump.
    func testTheListDoesNotScrollToTheOldRowWhenTheLiveChannelIsFarAbove() {
        farJump(root: "i041-far-jump-down", tuneRow: 0, press: .left, expectLive: "9020", expectOld: "9001", listIsScrolled: true)
    }

    /// The other way round: tuned on channel 20 (the bottom), one press up in full screen wraps to channel 1.
    func testTheListDoesNotScrollToTheOldRowWhenTheLiveChannelIsFarBelow() {
        farJump(root: "i041-far-jump-up", tuneRow: 19, press: .right, expectLive: "9001", expectOld: "9020", listIsScrolled: false)
    }

    /// `listIsScrolled`: whether the live row is one the list has to be scrolled down to reach (channel 20), so
    /// the offset it rests at is not zero; at the top (channel 1) it rests at zero.
    private func farJump(root: String, tuneRow: Int, press change: XCUIRemote.Button, expectLive: String, expectOld: String,
                         listIsScrolled: Bool) {
        continueAfterFailure = false
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 4)
        app = XCUIApplication()
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = root
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestManyChannels", "-uiTestGuideJumpProbe"]
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 2)

        // Tune the row the test starts from (the first is already playing), then full screen.
        for _ in 0..<tuneRow { press(.down, 0.3) }
        if tuneRow > 0 { press(.select, 2.5) }
        press(.select, 3.0)
        // One channel change in full screen: the wrap makes it 19 rows.
        press(change, 2.5)
        shot("far-fullscreen")

        // Back to the guide.
        XCUIRemote.shared.press(.menu)
        shot("far-returning-frame-1")
        shot("far-returning-frame-2")
        Thread.sleep(forTimeInterval: 3)
        shot("far-guide-after-return")

        let summary = probeSummary()
        print("GUIDE-JUMP far jump (old \(expectOld), live \(expectLive)): \(summary)")
        XCTAssertTrue(summary.hasPrefix("origin=fullScreenClosed"), summary)
        assertNeverShownAnotherRow(summary, live: expectLive, "far jump, back from full screen")
        // The row tvOS handed focus to was the far one, so the jump really was far.
        XCTAssertTrue(probeList("raw", in: summary).contains(expectOld),
                      "tvOS never handed focus to the old row \(expectOld), so this was not the far case: \(summary)")
        // And the list did not move in front of the viewer. The probe lists the offset the list had when the
        // guide came back, then every change: exactly one entry is a list that stayed put, none is an observer
        // that never reported (which would make the check vacuous), more than one is a scroll.
        let offsets = probeScroll(in: summary)
        XCTAssertEqual(offsets.count, 1, "expected the one offset the list rested at, saw \(offsets). \(summary)")
        if let rest = offsets.first.flatMap({ Double($0) }) {
            if listIsScrolled {
                XCTAssertGreaterThan(rest, 0, "the live row is far down, so the list rests scrolled: \(summary)")
            } else {
                XCTAssertEqual(rest, 0, accuracy: 0.5, "the live row is at the top, so the list rests at zero: \(summary)")
            }
        }
        let liveNumber = (Int(expectLive) ?? 0) - 9000
        XCTAssertTrue(focused().exists && focused().label.hasPrefix("Channel \(liveNumber),"),
                      "focus ended on \(focused().exists ? focused().label : "nothing"), not the live channel")
    }
}
