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
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestManyChannels"]
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
        press(.menu, 1.0)
        let landed = settled(on: "CH 06", within: 6)
        shot("guide-after-return")
        XCTAssertTrue(landed, "the guide came back on \(panelChannelNumber() ?? "no channel"), not the live channel 6")
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
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestManyChannels", "-uiTestStartOnChannel", channel]
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
    }
}
