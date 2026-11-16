import XCTest
@testable import Nostalgex

/// UP NEXT on both panels: the title first in the guide's yellow, then the minutes (Chad 2026-11-15).
final class UpNextLineTests: XCTestCase {
    func testTheTitleComesFirstThenTheMinutes() {
        XCTAssertEqual(UpNextLabel.line(title: "Varsity Blues", secondsUntilStart: 24 * 60 + 59), "Varsity Blues  UP NEXT IN 24 MIN")
        XCTAssertEqual(UpNextLabel.line(title: "Varsity Blues", secondsUntilStart: 59), "Varsity Blues  UP NEXT IN LESS THAN 1 MIN")
        XCTAssertEqual(UpNextLabel.line(title: "Heat", secondsUntilStart: 84 * 60), "Heat  UP NEXT IN 84 MIN", "minutes, never hours")
    }

    /// The yellow title holds 4.5:1 on both panels it sits on: the Now Playing panel and the guide info panel.
    func testTheTitleColourReadsOnBothPanels() {
        let infoPanel = [NXRGB(r: 0.04, g: 0.04, b: 0.10), NXRGB(r: 0.05, g: 0.05, b: 0.12)]
        for bg in [NXColor.panel] + infoPanel {
            XCTAssertGreaterThanOrEqual(NXRGB.contrast(UpNextLabel.titleColor, bg), 4.5)
        }
        XCTAssertEqual(NXRGB.contrast(UpNextLabel.titleColor, NXColor.panel), 14.96, accuracy: 0.05)
    }

    /// White programme titles still read on the cursor cell's fill (cyan at 30% over the darkest and the brightest
    /// row fills it can sit on).
    func testTitlesReadOnTheCursorCell() {
        for row in [NXColor.guide, NXColor.row, NXRGB(0x5A1022)] {
            let cell = GuideRowContrast.mix(NXColor.cyan, over: row, opacity: GuideCursorStyle.fillOpacity)
            XCTAssertGreaterThanOrEqual(NXRGB.contrast(NXColor.text, cell), 4.5)
        }
    }
}
