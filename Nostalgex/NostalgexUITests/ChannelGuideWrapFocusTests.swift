import XCTest

/// Drives the channel guide with the real tvOS focus engine and checks the edge wrap:
/// Down on the last channel lands on the first, Up on the first lands on the last.
///
/// Tester report (1.0.22 b38, Apple TV 4K A2169, tvOS 26.6): "the loop from bottom to
/// top is still missing." The wrap lives in ChannelGuideView.onMoveCommand and depends on
/// event ordering between .onMoveCommand and the focus engine, so only a remote-driven
/// test can see it.
///
/// Two library shapes matter and they behave differently:
///   * five bundled demo channels — the whole list fits on screen, never scrolls
///   * `-uiTestManyChannels` — twenty channels, so the list is taller than the grid
///
/// Every tester has the second shape. The first is what the original wrap was verified
/// against, which is why the bug shipped.
final class ChannelGuideWrapFocusTests: XCTestCase {

    private let demoChannelCount = 5
    /// Must match DemoData.uiTestChannelCount.
    private let manyChannelCount = 20

    private func launchIntoGuide(manyChannels: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetCredentials"]
        if manyChannels { app.launchArguments.append("-uiTestManyChannels") }
        app.launch()

        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(demo.hasFocus, "could not focus the demo mode button")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["tunerSettingsButton"].waitForExistence(timeout: 30),
            "demo mode never reached the tuner"
        )
        // Let the guide's onAppear focus + scroll settle before pressing anything.
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    private func focusedLabel(_ app: XCUIApplication) -> String? {
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else { return nil }
        return focused.label
    }

    /// "Channel N, NAME[, live]" -> N
    private func channelNumber(in label: String?) -> Int? {
        guard let label, label.hasPrefix("Channel ") else { return nil }
        let rest = label.dropFirst("Channel ".count)
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    private func focusedChannel(_ app: XCUIApplication) -> Int? {
        channelNumber(in: focusedLabel(app))
    }

    /// Waits up to `timeout` for focus to land on `expected`; returns what it landed on.
    @discardableResult
    private func waitForFocusedChannel(
        _ app: XCUIApplication, _ expected: Int, timeout: TimeInterval = 3
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Int? = nil
        while Date() < deadline {
            last = focusedChannel(app)
            if last == expected { return last }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return last
    }

    /// Presses `direction` with a human-ish pause before it. The wrap decision requires
    /// the last real focus change to be stale, so an edge press fired immediately after
    /// arriving at the edge is, by design, not supposed to wrap.
    private func pressSettled(_ direction: XCUIRemote.Button, pause: TimeInterval = 0.6) {
        Thread.sleep(forTimeInterval: pause)
        XCUIRemote.shared.press(direction)
    }

    private func walkToChannel(_ app: XCUIApplication, _ target: Int) {
        var guardCount = 0
        while focusedChannel(app) != target {
            pressSettled(.down, pause: 0.3)
            guardCount += 1
            XCTAssertLessThan(guardCount, target + 4,
                "never reached channel \(target); focus on \(focusedLabel(app) ?? "<nothing>")")
            if guardCount >= target + 4 { return }
        }
    }

    // MARK: - Down wrap, list fits on screen

    func testGuide_downOnLastChannelWrapsToFirst() {
        let app = launchIntoGuide()
        XCTAssertEqual(focusedChannel(app), 1,
            "guide did not open focused on channel 1, focus on: \(focusedLabel(app) ?? "<nothing>")")

        walkToChannel(app, demoChannelCount)
        XCTAssertEqual(focusedChannel(app), demoChannelCount)

        // Human cadence: sitting on the bottom row, press Down once.
        pressSettled(.down)
        let landed = waitForFocusedChannel(app, 1)
        XCTAssertEqual(landed, 1,
            "Down on the last channel did not wrap to channel 1; focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    // MARK: - Down wrap, list scrolls (what every tester actually has)

    /// The case from Kelly's report. Twenty channels, so the bottom row is reached only
    /// after the grid has scrolled several times.
    func testGuide_downOnLastChannelWrapsToFirst_scrollingList() {
        let app = launchIntoGuide(manyChannels: true)
        XCTAssertEqual(focusedChannel(app), 1,
            "guide did not open focused on channel 1, focus on: \(focusedLabel(app) ?? "<nothing>")")

        walkToChannel(app, manyChannelCount)
        XCTAssertEqual(focusedChannel(app), manyChannelCount,
            "never reached the last channel; focus on: \(focusedLabel(app) ?? "<nothing>")")

        pressSettled(.down)
        let landed = waitForFocusedChannel(app, 1)
        XCTAssertEqual(landed, 1,
            "Down on the last channel of a SCROLLING guide did not wrap to channel 1; focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    // MARK: - Up wrap

    func testGuide_upOnFirstChannelWrapsToLast() {
        let app = launchIntoGuide()
        XCTAssertEqual(focusedChannel(app), 1)

        pressSettled(.up)
        let landed = waitForFocusedChannel(app, demoChannelCount)
        XCTAssertEqual(landed, demoChannelCount,
            "Up on the first channel did not wrap to channel \(demoChannelCount); focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    func testGuide_upOnFirstChannelWrapsToLast_scrollingList() {
        let app = launchIntoGuide(manyChannels: true)
        XCTAssertEqual(focusedChannel(app), 1)

        pressSettled(.up)
        let landed = waitForFocusedChannel(app, manyChannelCount)
        XCTAssertEqual(landed, manyChannelCount,
            "Up on the first channel of a SCROLLING guide did not wrap to channel \(manyChannelCount); focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    // MARK: - Arrival must not wrap

    /// A press that arrives at the edge and a second press after it. The first press must
    /// land on the edge row and stay there — an earlier fix made arrival itself wrap, and
    /// the bottom channel became impossible to select.
    func testGuide_arrivingAtBottomDoesNotWrapButNextPressDoes() {
        let app = launchIntoGuide()
        XCTAssertEqual(focusedChannel(app), 1)

        for _ in 0..<(demoChannelCount - 2) { pressSettled(.down, pause: 0.3) }
        XCTAssertEqual(focusedChannel(app), demoChannelCount - 1)

        // Arrival press: must land on the bottom row and stay there.
        pressSettled(.down, pause: 0.3)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(focusedChannel(app), demoChannelCount,
            "arriving at the bottom row wrapped (or missed); focus on: \(focusedLabel(app) ?? "<nothing>")")

        pressSettled(.down)
        XCTAssertEqual(waitForFocusedChannel(app, 1), 1,
            "second Down on the bottom row did not wrap; focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    /// Same contract on a scrolling list: arriving at the last row of a long guide must
    /// not wrap, because that press is how the bottom channel gets selected.
    func testGuide_arrivingAtBottomOfScrollingListDoesNotWrap() {
        let app = launchIntoGuide(manyChannels: true)
        XCTAssertEqual(focusedChannel(app), 1)

        walkToChannel(app, manyChannelCount - 1)
        XCTAssertEqual(focusedChannel(app), manyChannelCount - 1)

        pressSettled(.down, pause: 0.3)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(focusedChannel(app), manyChannelCount,
            "arriving at the last row of a scrolling guide wrapped (or missed); focus on: \(focusedLabel(app) ?? "<nothing>")")

        pressSettled(.down)
        XCTAssertEqual(waitForFocusedChannel(app, 1), 1,
            "second Down on the last row did not wrap; focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    // MARK: - Real remote cadence

    /// Nobody pauses 600 ms between presses. Walking a 20-channel guide with a held
    /// direction or a swipe produces move events far closer together than that, and the
    /// extra presses at the bottom land inside the same burst. This is the cadence the
    /// tester described, and the one the old timing-window wrap could not serve.
    func testGuide_rapidPressesAtBottomStillWrap() {
        let app = launchIntoGuide(manyChannels: true)
        XCTAssertEqual(focusedChannel(app), 1)

        // One uninterrupted burst: 19 presses to walk 1 -> 20, then one more. No
        // accessibility query anywhere inside it, so the cadence is the remote's and the
        // final press lands ~80 ms after focus reached the bottom row — well inside the
        // old 150 ms staleness window.
        for _ in 0..<manyChannelCount {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.08)
        }

        XCTAssertEqual(waitForFocusedChannel(app, 1), 1,
            "a held/swiped Down burst at the bottom never wrapped; focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    /// Same for Up out of channel 1 at remote cadence.
    func testGuide_rapidPressesAtTopStillWrap() {
        let app = launchIntoGuide(manyChannels: true)
        XCTAssertEqual(focusedChannel(app), 1)

        // Down to 2, back up to 1, and one more Up inside the same burst.
        for direction in [XCUIRemote.Button.down, .up, .up] {
            XCUIRemote.shared.press(direction)
            Thread.sleep(forTimeInterval: 0.08)
        }

        XCTAssertEqual(waitForFocusedChannel(app, manyChannelCount), manyChannelCount,
            "rapid Up presses at the top never wrapped; focus on: \(focusedLabel(app) ?? "<nothing>")")
    }

    /// Up from the top row must not wrap on the press that arrived there, or channel 1
    /// becomes unselectable from channel 2.
    func testGuide_arrivingAtTopDoesNotWrap() {
        let app = launchIntoGuide(manyChannels: true)
        XCTAssertEqual(focusedChannel(app), 1)

        pressSettled(.down, pause: 0.3)
        XCTAssertEqual(focusedChannel(app), 2)

        pressSettled(.up, pause: 0.3)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(focusedChannel(app), 1,
            "arriving at the top row wrapped; focus on: \(focusedLabel(app) ?? "<nothing>")")
    }
}
