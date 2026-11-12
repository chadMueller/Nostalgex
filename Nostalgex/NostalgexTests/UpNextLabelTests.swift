import XCTest
@testable import Nostalgex

/// The UP NEXT badge in the Now Playing panel counts minutes only (Chad, 2026-11-10).
final class UpNextLabelTests: XCTestCase {
    func testMinutesAreWholeAndRoundedDown() {
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 12 * 60), "UP NEXT IN 12 MIN")
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 12 * 60 + 59), "UP NEXT IN 12 MIN")
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 60), "UP NEXT IN 1 MIN")
    }

    func testAnHourOrMoreStaysInMinutes() {
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 84 * 60), "UP NEXT IN 84 MIN")
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 65 * 60), "UP NEXT IN 65 MIN")
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 120 * 60), "UP NEXT IN 120 MIN")
    }

    func testUnderAMinuteAndAlreadyStartedSayLessThanOne() {
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 59), "UP NEXT IN LESS THAN 1 MIN")
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: 0), "UP NEXT IN LESS THAN 1 MIN")
        XCTAssertEqual(UpNextLabel.text(secondsUntilStart: -30), "UP NEXT IN LESS THAN 1 MIN")
    }
}
