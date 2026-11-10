import XCTest

/// SUPPORT NOSTALGEX is RATE as a full-width row with the three tips (POPCORN, TV DINNER, PIZZA NIGHT)
/// in a row of three below it. The remote walks it the way it reads: Down from RATE reaches a tip, Right
/// and Left move along the tips (stopping at the ends), Up from any tip reaches RATE.
final class SettingsSupportGridTests: XCTestCase {
    private var app: XCUIApplication!

    private func press(_ b: XCUIRemote.Button, _ settle: TimeInterval = 0.9) {
        XCUIRemote.shared.press(b)
        Thread.sleep(forTimeInterval: settle)
    }

    private func focusedLabel() -> String {
        let f = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? f.label : "<none>"
    }

    private let tips = ["POPCORN", "TV DINNER", "PIZZA NIGHT"]

    func testRateRowThenThreeTipsAndTheRemoteWalksThem() throws {
        continueAfterFailure = false
        app = isolatedApp(arguments: ["-uiTestForceSettingsPage"])
        app.launch()
        let rail = app.buttons["settingsRail_support"]
        XCTAssertTrue(rail.waitForExistence(timeout: 30), "Settings never opened")
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<8 where !rail.hasFocus { press(.down, 0.6) }
        press(.right, 1.2)
        // The tip tiles only draw when tips are available, which a simulator without the store has not got.
        try XCTSkipUnless(app.buttons[tips[0]].exists, "tips are not available here, so there is no grid to walk")

        XCTAssertEqual(focusedLabel(), "RATE NOSTALGEX", "the pane opens on RATE")
        // RATE is the wide row: the tips sit below it, all three, left to right.
        let rate = app.buttons["RATE NOSTALGEX"].frame
        let frames = tips.map { app.buttons[$0].frame }
        XCTAssertGreaterThan(rate.width, frames[0].width * 2.5, "RATE is a full-width row, not a tile")
        for f in frames { XCTAssertGreaterThan(f.minY, rate.maxY - 1, "the tips are below RATE") }
        XCTAssertLessThan(frames[0].minX, frames[1].minX)
        XCTAssertLessThan(frames[1].minX, frames[2].minX)
        XCTAssertEqual(frames[0].minY, frames[2].minY, accuracy: 2, "the three tips are one row")

        // Down from RATE reaches a tip.
        press(.down)
        let first = focusedLabel()
        XCTAssertTrue(tips.contains(first), "Down from RATE landed on \(first)")
        // Along the row and back.
        let index = tips.firstIndex(of: first)!
        if index < 2 {
            press(.right)
            XCTAssertEqual(focusedLabel(), tips[index + 1])
            press(.left)
            XCTAssertEqual(focusedLabel(), first)
        } else {
            press(.left)
            XCTAssertEqual(focusedLabel(), tips[1])
            press(.right)
            XCTAssertEqual(focusedLabel(), first)
        }
        // Up from a tip reaches RATE, from every tip.
        for tip in tips {
            for _ in 0..<3 where focusedLabel() != tip {
                press(focusedLabel() == "RATE NOSTALGEX" ? .down : (tips.firstIndex(of: focusedLabel())! < tips.firstIndex(of: tip)! ? .right : .left))
            }
            XCTAssertEqual(focusedLabel(), tip)
            press(.up)
            XCTAssertEqual(focusedLabel(), "RATE NOSTALGEX", "Up from \(tip)")
            press(.down)
        }
    }
}
