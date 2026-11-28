import XCTest

/// The weather channel's simulator walk (I-016): CH 299 in a demo guide, its four screens full screen, the
/// card with no location, and the WEATHER rows in Settings. Screenshots are kept as attachments. Needs the
/// relay: `-weatherBase` points at a stand-in on the Mac (see the dev log); with no relay the screens show
/// FORECAST UNAVAILABLE RIGHT NOW and the test still walks.
final class WeatherChannelWalkTests: XCTestCase {
    private var app: XCUIApplication!

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

    private func focusedLabel() -> String {
        let f = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? f.label : "<nothing>"
    }

    private var base: String { ProcessInfo.processInfo.environment["WEATHER_BASE"] ?? "https://www.nostalgex.app" }

    private func launch(place: String?) {
        var args = ["-uiTestResetCredentials", "-uiTestWeatherInDemo", "-uiTestMuteAudio", "-weatherBase", base]
        if let place { args += ["-uiTestWeatherPlace", place] }
        app = isolatedApp(arguments: args)
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        XCTAssertTrue(app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 2)
    }

    /// Down the guide to CH 299 and tune it.
    private func tuneWeather() {
        for _ in 0..<12 where !focusedLabel().contains("LOCAL WEATHER") { press(.down, 0.6) }
        XCTAssertTrue(focusedLabel().contains("LOCAL WEATHER"), "CH 299 is not in the guide: \(focusedLabel())")
        press(.select, 3)
    }

    /// Seconds until the loop (65 s on the wall clock) is `offset` seconds into its run.
    private func wait(untilLoopAt offset: Double) {
        let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 65)
        var d = offset - t
        if d < 0 { d += 65 }
        Thread.sleep(forTimeInterval: d)
    }

    func testTheWeatherChannelWalk() {
        continueAfterFailure = true
        XCUIRemote.shared.press(.menu)
        launch(place: "Toronto|CA|ON|43.65|-79.38|America/Toronto")
        tuneWeather()
        shot("guide-with-weather")
        XCTAssertTrue(app.descendants(matching: .any)["weatherChannel"].waitForExistence(timeout: 5), "the weather picture is not in the guide")
        // Full screen.
        press(.playPause, 2)
        wait(untilLoopAt: 7); shot("weather-current")
        wait(untilLoopAt: 22); shot("weather-today")
        wait(untilLoopAt: 37); shot("weather-week")
        wait(untilLoopAt: 58); shot("weather-radar")
        press(.menu, 2)

        // The settings are walked in testLocationSearch and testBarCreditsAndSettingsRow.
    }

    /// LOCATION: type a postcode, pick the match, the row says it.
    func testLocationSearch() {
        continueAfterFailure = false
        XCUIRemote.shared.press(.menu)
        launch(place: nil)
        for _ in 0..<6 where !focusedLabel().contains("SETTINGS") { press(.up, 0.5) }
        press(.select, 3)
        for _ in 0..<4 where !focusedLabel().contains("CHANNELS") { press(.down, 0.8) }
        press(.select, 2)
        for _ in 0..<8 where !focusedLabel().contains("LOCAL WEATHER") { press(.down, 0.6) }
        press(.select, 2)
        press(.select, 2)   // LOCATION
        let field = app.textFields["weatherLocationField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the location sheet has no field")
        press(.select, 2)   // the keyboard
        field.typeText("90210")
        Thread.sleep(forTimeInterval: 2)
        shot("location-keyboard")
        press(.menu, 2)
        XCTAssertTrue(app.buttons["weatherResult-0"].waitForExistence(timeout: 8), "no place matched 90210")
        shot("location-results")
        for _ in 0..<4 where !(app.buttons["weatherResult-0"].hasFocus) { press(.down, 0.6) }
        press(.select, 2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'BEVERLY HILLS'")).firstMatch.waitForExistence(timeout: 5),
                      "the LOCATION row does not show the picked place")
        shot("location-picked")
    }

    /// Chad's 2026-11-16 changes: CH 299 is one bar in the guide, the credits are a small stack at the bottom left,
    /// and the settings are a LOCAL WEATHER row under CHANNELS & BUNDLES with its own page.
    func testBarCreditsAndSettingsRow() {
        continueAfterFailure = true
        XCUIRemote.shared.press(.menu)
        launch(place: "Toronto|CA|ON|43.65|-79.38|America/Toronto")
        tuneWeather()
        Thread.sleep(forTimeInterval: 8)
        press(.right, 1); press(.right, 1)
        shot("guide-bar")
        XCTAssertTrue(focusedLabel().contains("LOCAL WEATHER"), "the cursor left the bar: \(focusedLabel())")
        press(.left, 1); press(.left, 1)
        press(.playPause, 2)
        wait(untilLoopAt: 58); shot("weather-radar-credits")
        press(.menu, 2)
        for _ in 0..<14 where !focusedLabel().contains("SETTINGS") { press(.up, 0.5) }
        press(.select, 3)
        for _ in 0..<4 where !focusedLabel().contains("CHANNELS") { press(.down, 0.8) }
        press(.select, 2)
        for _ in 0..<8 where !focusedLabel().contains("LOCAL WEATHER") { press(.down, 0.6) }
        XCTAssertTrue(focusedLabel().contains("LOCAL WEATHER"), "no LOCAL WEATHER row: \(focusedLabel())")
        shot("channels-weather-row")
        press(.select, 2)
        XCTAssertTrue(focusedLabel().contains("LOCATION"), "the page did not open on LOCATION: \(focusedLabel())")
        shot("weather-subpage")
        press(.menu, 2)
        XCTAssertTrue(focusedLabel().contains("LOCAL WEATHER"), "Menu did not return to the row: \(focusedLabel())")
    }

    func testNoLocationCard() {
        continueAfterFailure = true
        XCUIRemote.shared.press(.menu)
        launch(place: nil)
        tuneWeather()
        press(.playPause, 3)
        shot("weather-no-location")
    }
}
