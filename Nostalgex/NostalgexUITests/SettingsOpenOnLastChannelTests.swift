import XCTest

/// The OPEN ON LAST CHANNEL row (I-017) is on PLAYBACK & PICTURE, off by default, and a press
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

    func testTheRowIsThereOffByDefaultAndSwitches() {
        continueAfterFailure = false
        app = XCUIApplication()
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
        XCTAssertEqual(row.value as? String, "Off", "off until someone turns it on")
        let off = app.screenshot()
        let a = XCTAttachment(screenshot: off); a.name = "open-on-last-channel-off"; a.lifetime = .keepAlways; add(a)

        press(.select, 1.0)
        XCTAssertEqual(focused().value as? String, "On")
        let on = app.screenshot()
        let b = XCTAttachment(screenshot: on); b.name = "open-on-last-channel-on"; b.lifetime = .keepAlways; add(b)

        press(.select, 1.0)
        XCTAssertEqual(focused().value as? String, "Off", "left as it was found")
    }
}
