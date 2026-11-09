import XCTest

/// CHANNEL PACKAGES (discussion #217): the focused package row grows to list its channel names
/// under the description, and shrinks back when focus leaves. Only the focused row opens, so the
/// page is no longer than before while a viewer scrolls past.
///
/// The risk is how tvOS scrolls when the focused row changes height: the Settings scroll
/// view centres the row it was told about, and the row above it shrinks in the same moment. So this
/// walks the whole list with the real focus engine, down and then up, through a long package
/// (NOSTALGEX, 22 channels), the first and the last package and packages that are on with
/// channels short of content (amber), and checks after every press that the focused row is
/// grown, wholly on screen, and not pushed off centre.
///
/// Demo mode with `-uiTestPackageList`: the shipped packages from channels.json, some on with
/// channels the sample library cannot fill. Storage is isolated, so nothing the Apple TV holds is touched.
final class SettingsPackageChannelsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func focused() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func focusedLabel() -> String {
        let f = focused()
        return f.exists ? f.label : "<none>"
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func press(_ button: XCUIRemote.Button, _ settle: TimeInterval = 0.9) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
    }

    private func rail(_ id: String) -> XCUIElement { app.buttons["settingsRail_\(id)"] }

    private func openPackages() {
        XCUIRemote.shared.press(.menu)   // wakes an Apple TV in standby; harmless on a simulator
        Thread.sleep(forTimeInterval: 4)
        app = XCUIApplication()
        app.launchEnvironment["NOSTALGEX_HARNESS_ROOT"] = "i084-package-channels-\(Int(Date().timeIntervalSince1970))"
        app.launchArguments = ["-uiTestResetCredentials", "-uiTestFranchiseFixture", "-uiTestPackageList"]
        app.launch()
        let demo = app.buttons["demo mode"]
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "connect screen never appeared")
        for _ in 0..<10 where !demo.hasFocus { press(.down, 0.4) }
        press(.select, 4)
        let settings = app.buttons["tunerSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "tuner never appeared")
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<8 where !settings.hasFocus { press(.up, 0.4) }
        for _ in 0..<8 where !settings.hasFocus { press(.right, 0.4) }
        press(.select, 2)
        XCTAssertTrue(rail("support").waitForExistence(timeout: 10), "Settings never opened")
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<4 where !rail("channels").hasFocus { press(.down) }
        XCTAssertTrue(rail("channels").hasFocus, focusedLabel())
        press(.right, 1.2)
        XCTAssertTrue(focusedLabel().hasPrefix("CHANNEL PACKAGES"), focusedLabel())
        press(.select, 1.5)
    }

    /// The package row whose title starts with `title`, wherever it is on screen now.
    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func isPackageRow(_ label: String) -> Bool {
        label != "<none>" && !label.hasPrefix("WHY ARE SOME CHANNELS MISSING")
    }

    /// One focused package row as measured on the screen.
    private struct Seen {
        let label: String
        let frame: CGRect
        /// The row's vertical middle as a fraction of the window height.
        let centre: CGFloat
    }

    /// Where the focused row sits, checked against the window. `centre` is its vertical middle
    /// as a fraction of the window height; the Settings pane centres a focused row in what is
    /// left under the pinned header, so a row that scrolled properly sits a little under half.
    private func look(_ step: String) -> Seen {
        let f = focused()
        XCTAssertTrue(f.exists, "\(step): nothing has focus")
        let window = app.frame
        let frame = f.frame
        let centre = (frame.midY - window.minY) / window.height
        let names = app.descendants(matching: .any)["packageChannelNames"].exists
        let legend = app.descendants(matching: .any)["packageChannelNamesLegend"].exists
        XCTAssertTrue(names, "\(step): the focused row lists its channels")
        // The amber legend is on exactly the rows that carry the amber count: the count names what it counts.
        XCTAssertEqual(legend, f.label.contains("more content"), "\(step): amber names and the amber count go together: \(f.label)")
        print("PACKAGE-CHANNELS \(step): \(f.label.prefix(34)) y=\(Int(frame.minY))..\(Int(frame.maxY)) h=\(Int(frame.height)) centre=\(String(format: "%.2f", centre)) names=\(names) legend=\(legend) value=\(f.value as? String ?? "-")")
        shot(step)
        XCTAssertGreaterThanOrEqual(frame.minY, window.minY, "\(step): the focused row is cut off at the top")
        XCTAssertLessThanOrEqual(frame.maxY, window.maxY, "\(step): the focused row is cut off at the bottom")
        return Seen(label: f.label, frame: frame, centre: centre)
    }

    func testTheFocusedPackageRowGrowsAndShrinksAndStaysOnScreen() {
        openPackages()
        Thread.sleep(forTimeInterval: 1)

        // 1. Down the whole list, first package to the last, then the WHY ARE SOME CHANNELS MISSING? link.
        var grown: [String: CGFloat] = [:]       // row title -> its height while focused
        var centres: [String: CGFloat] = [:]     // row title -> where it came to rest going down
        var plain: [String: CGFloat] = [:]       // row title -> its own height once focus had left it
        var order: [String] = []
        var previous: (title: String, frame: CGRect)?
        for index in 0..<24 {
            let label = focusedLabel()
            if !isPackageRow(label) { break }
            let title = label.components(separatedBy: ". ").first ?? label
            let seen = look("down-\(index + 1)-\(title)")
            grown[title] = seen.frame.height
            centres[title] = seen.centre
            order.append(title)
            // The row left behind has shrunk back to its plain height, whatever it held.
            if let previous {
                let behind = row(previous.title)
                XCTAssertTrue(behind.exists && !behind.hasFocus, "\(previous.title) should still be on screen, unfocused")
                plain[previous.title] = behind.frame.height
            }
            previous = (title, seen.frame)
            press(.down)
        }
        XCTAssertGreaterThanOrEqual(order.count, 10, "the list walked: \(order)")
        XCTAssertTrue(focusedLabel().hasPrefix("WHY ARE SOME CHANNELS MISSING"), "the list ends at the missing-channels link: \(focusedLabel())")
        shot("down-end-why-link")
        if let last = previous {
            let behind = row(last.title)
            XCTAssertTrue(behind.exists && !behind.hasFocus, "\(last.title) should still be on screen, unfocused")
            plain[last.title] = behind.frame.height
        }

        // 2. Every package row grew while focused and shrank back when focus left it: the same row,
        //    measured focused and then unfocused, is taller focused by more than a line of text.
        XCTAssertEqual(Set(plain.keys), Set(order), "every row was measured both ways: \(plain)")
        for title in order {
            XCTAssertGreaterThan(grown[title] ?? 0, (plain[title] ?? .infinity) + 20,
                                 "\(title) did not grow while focused / shrink when focus left it: \(grown[title] ?? 0) focused, \(plain[title] ?? 0) not")
        }
        print("PACKAGE-CHANNELS plain heights: \(plain.mapValues { Int($0) })")
        // The long package grew the most: 22 names take more lines than the short ones.
        let longest = order.compactMap { grown[$0] }.max() ?? 0
        XCTAssertEqual(grown["NOSTALGEX"] ?? 0, longest, accuracy: 1, "the 22 channel package is the tallest row: \(grown)")

        // 2b. Rows in the middle of the list come to rest at the same height on the screen whatever
        //     their own height and whatever the row above grew or shrank by: the pane centres them.
        let middle = order.dropFirst(2).dropLast(2).compactMap { centres[$0] }
        XCTAssertGreaterThan(middle.count, 5)
        XCTAssertLessThan((middle.max() ?? 0) - (middle.min() ?? 0), 0.03, "middle rows rest off centre by different amounts: \(centres)")

        // 3. Back up, the same walk, so scrolling up through the grown rows is checked too.
        for index in 0..<24 {
            press(.up)
            let label = focusedLabel()
            if !isPackageRow(label) { break }
            let title = label.components(separatedBy: ". ").first ?? label
            let seen = look("up-\(index + 1)-\(title)")
            // The same row comes to rest in the same place going up as it did going down.
            XCTAssertEqual(seen.centre, centres[title] ?? -1, accuracy: 0.03, "\(title) rests somewhere else going up than going down")
            if title == order.first { break }
        }
        XCTAssertTrue(focusedLabel().hasPrefix(order.first ?? "?"), "back on the first package: \(focusedLabel())")

        // 4. Nothing was pressed to open a row: switching a package is Select, and none was pressed.
        //    The pane is where it began: the first row is on screen, whole.
        let first = row(order.first ?? "?")
        XCTAssertTrue(first.exists)
        XCTAssertGreaterThanOrEqual(first.frame.minY, app.frame.minY)
    }

    /// Pressing Select on a package switches it, and its list stays open under the pressed row: the
    /// row stays focused, stays grown and stays wholly on screen while the package builds and after,
    /// then switches back, leaving the isolated storage as it found it.
    func testSwitchingAPackageKeepsItsListOpenAndOnScreen() {
        openPackages()
        Thread.sleep(forTimeInterval: 1)
        press(.down)   // NOSTALGEX
        press(.down)   // KIDZ ZONE, off
        var seen = look("toggle-0-before")
        XCTAssertTrue(seen.label.hasPrefix("KIDZ ZONE"), seen.label)
        XCTAssertEqual(focused().value as? String, "Off")
        let offHeight = seen.frame.height
        // Its plain height, measured with focus one row down, and back.
        press(.down)
        let plainHeight = row("KIDZ ZONE").frame.height
        XCTAssertGreaterThan(offHeight, plainHeight + 20, "KIDZ ZONE grows while focused: \(offHeight) vs \(plainHeight)")
        press(.up)
        XCTAssertTrue(focusedLabel().hasPrefix("KIDZ ZONE"), focusedLabel())

        press(.select, 1.0)
        for second in 1...3 {
            Thread.sleep(forTimeInterval: 2)
            seen = look("toggle-1-on-after-\(second * 2)s")
            XCTAssertTrue(seen.label.hasPrefix("KIDZ ZONE"), "focus stayed on the pressed row: \(seen.label)")
            XCTAssertEqual(focused().value as? String, "On")
            XCTAssertGreaterThan(seen.frame.height, plainHeight + 20, "the pressed row kept its list while it built")
        }
        print("PACKAGE-CHANNELS toggle: KIDZ ZONE off h=\(Int(offHeight)) on h=\(Int(seen.frame.height))")

        press(.select, 1.5)
        seen = look("toggle-2-off-again")
        XCTAssertTrue(seen.label.hasPrefix("KIDZ ZONE"), seen.label)
        XCTAssertEqual(focused().value as? String, "Off", "switched back")
        XCTAssertEqual(seen.frame.height, offHeight, accuracy: 2, "the same row it was before it was switched")
    }
}
