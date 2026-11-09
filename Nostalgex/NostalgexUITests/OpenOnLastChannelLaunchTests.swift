import XCTest

/// OPEN ON LAST CHANNEL (I-017) end to end, in demo mode with the app's storage isolated
/// (`NOSTALGEX_HARNESS_ROOT`) and `-uiTestLaunchMemoryInDemo`, so it runs on an Apple TV that is
/// signed out and touches nothing it holds: leave the switch as it is (On), tune a channel,
/// relaunch, and the app starts on that channel; turn it off, relaunch, and it starts on channel 1
/// as it always did. The switch is on by default, so the first half presses nothing: it reads the
/// row, finds it On, and tunes.
final class OpenOnLastChannelLaunchTests: XCTestCase {
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

    /// Launches (or relaunches) into demo mode and waits for the guide.
    private func launchIntoDemo() {
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 3)
    }

    /// The channel the guide marks as playing ("Channel 5, DEMO LATE NIGHT, live").
    private func liveChannelLabel() -> String {
        let live = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', live'")).firstMatch
        return live.exists ? live.label : "<none>"
    }

    /// Guide to SETTINGS, PLAYBACK & PICTURE, the OPEN ON LAST CHANNEL row, a press only if it is not
    /// already at `wanted`, and back out. Returns what the row read before any press.
    @discardableResult
    private func setOpenOnLastChannel(to wanted: Bool) -> String? {
        let settings = app.buttons["tunerSettingsButton"]
        for _ in 0..<10 where !settings.hasFocus { press(.up, 0.4) }
        for _ in 0..<8 where !settings.hasFocus { press(.right, 0.4) }
        press(.select, 2)
        let playback = app.buttons["settingsRail_playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 10), "Settings never opened")
        for _ in 0..<4 where !playback.hasFocus { press(.down, 0.6) }
        press(.right, 1.0)
        for _ in 0..<14 where focused().label != "OPEN ON LAST CHANNEL" { press(.down) }
        XCTAssertEqual(focused().label, "OPEN ON LAST CHANNEL")
        let found = focused().value as? String
        if (found == "On") != wanted { press(.select, 1.0) }
        XCTAssertEqual(focused().value as? String, wanted ? "On" : "Off")
        press(.menu, 1.0)   // rail
        press(.menu, 2.0)   // out of Settings
        return found
    }

    func testTheLaunchOpensOnTheLastChannelOnlyWhileTheSwitchIsOn() {
        continueAfterFailure = false
        XCUIRemote.shared.press(.menu)   // wakes an Apple TV in standby; harmless on a simulator
        Thread.sleep(forTimeInterval: 4)
        app = XCUIApplication()
        // A fresh root every run: the setting and the saved channel persist in it, and a run that stops
        // half way must not hand its state to the next.
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = "i017-open-on-last-channel-\(Int(Date().timeIntervalSince1970))"
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestLaunchMemoryInDemo", "-uiTestManyChannels"]

        // 1. Nothing remembered yet (a viewer's first launch after an update): channel 1.
        launchIntoDemo()
        XCTAssertTrue(liveChannelLabel().hasPrefix("Channel 1,"), "fresh launch: \(liveChannelLabel())")

        // 2. The switch is On as shipped: read it without pressing it, then tune channel 5 from the guide.
        let shipped = setOpenOnLastChannel(to: true)
        XCTAssertEqual(shipped, "On", "on by default: the helper only presses a row that is not already On")
        for _ in 0..<8 where !(focused().exists && focused().label.hasPrefix("Channel 5,")) { press(.down, 0.6) }
        XCTAssertTrue(focused().label.hasPrefix("Channel 5,"), "could not reach channel 5: \(focused().label)")
        press(.select, 3)
        XCTAssertTrue(liveChannelLabel().hasPrefix("Channel 5,"), "tuned: \(liveChannelLabel())")
        Thread.sleep(forTimeInterval: 2)

        // 3. Relaunch: it opens on channel 5, with the switch never pressed.
        app.terminate()
        launchIntoDemo()
        shot("relaunch-switch-on")
        XCTAssertTrue(liveChannelLabel().hasPrefix("Channel 5,"), "switch on by default, relaunched: \(liveChannelLabel())")

        // 4. Switch it off and relaunch: channel 1, exactly as before.
        setOpenOnLastChannel(to: false)
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        launchIntoDemo()
        shot("relaunch-switch-off")
        XCTAssertTrue(liveChannelLabel().hasPrefix("Channel 1,"), "switch off, relaunched: \(liveChannelLabel())")
    }

    /// Demo mode (what App Review sees) has no use for the setting, so PLAYBACK & PICTURE does not show it.
    func testTheRowIsNotShownInDemoMode() {
        continueAfterFailure = false
        XCUIRemote.shared.press(.menu)   // wakes an Apple TV in standby; harmless on a simulator
        Thread.sleep(forTimeInterval: 4)
        app = XCUIApplication()
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = "i017-demo-row-\(Int(Date().timeIntervalSince1970))"
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestManyChannels"]   // no -uiTestLaunchMemoryInDemo
        launchIntoDemo()

        let settings = app.buttons["tunerSettingsButton"]
        for _ in 0..<10 where !settings.hasFocus { press(.up, 0.4) }
        for _ in 0..<8 where !settings.hasFocus { press(.right, 0.4) }
        press(.select, 2)
        let playback = app.buttons["settingsRail_playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 10), "Settings never opened")
        for _ in 0..<4 where !playback.hasFocus { press(.down, 0.6) }
        press(.right, 1.0)
        var labels: [String] = []
        for _ in 0..<12 {
            labels.append(focused().exists ? focused().label : "<none>")
            press(.down, 0.5)
        }
        shot("demo-playback-rows")
        XCTAssertTrue(labels.contains("AUDIO LANGUAGE"), "walked the page: \(labels)")
        XCTAssertFalse(labels.contains("OPEN ON LAST CHANNEL"), "the row shows in demo mode: \(labels)")
    }
}
