import XCTest

/// The OPEN ON LAST CHANNEL row (I-017) is on PLAYBACK & PICTURE, on by default, and a press
/// switches it. Put back the way it was at the end so nothing is left on the simulator.
final class SettingsOpenOnLastChannelTests: XCTestCase {
    private var app: XCUIApplication!

    private func focused() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.7) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    func testTheRowIsThereOnByDefaultAndSwitches() {
        continueAfterFailure = false
        app = XCUIApplication()
        // A fresh storage root: the shipped default is what is read, not a press an earlier run left on
        // this simulator. Nothing here reaches the app's real stores.
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = "i017-settings-row-\(Int(Date().timeIntervalSince1970))"
        app.launchArguments = ["-uiTestForceSettingsPage"]
        app.launch()
        let playback = app.buttons["settingsRail_playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 30), "Settings never opened")
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<4 where !playback.hasFocus { press(.down, 0.6) }
        press(.right, 1.0)
        for _ in 0..<14 where focused().label != "OPEN ON LAST CHANNEL" { press(.down) }
        let row = focused()
        XCTAssertEqual(row.label, "OPEN ON LAST CHANNEL", "the row is not on PLAYBACK & PICTURE")
        XCTAssertEqual(row.value as? String, "On", "on until someone turns it off")
        let on = app.screenshot()
        let a = XCTAttachment(screenshot: on); a.name = "open-on-last-channel-on"; a.lifetime = .keepAlways; add(a)

        press(.select, 1.0)
        XCTAssertEqual(focused().value as? String, "Off")
        let off = app.screenshot()
        let b = XCTAttachment(screenshot: off); b.name = "open-on-last-channel-off"; b.lifetime = .keepAlways; add(b)

        press(.select, 1.0)
        XCTAssertEqual(focused().value as? String, "On", "left as it was found")
    }
}
