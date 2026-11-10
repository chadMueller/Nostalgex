import XCTest
@testable import Nostalgex

/// GUIDE TIMEOUT: 5 MIN unless a viewer chose otherwise, the row cycles OFF, 5 MIN, 15 MIN,
/// and the guide only hands over to fullscreen when it is in front, a channel is playing,
/// and the remote has been left alone for the whole timeout.
final class GuideTimeoutTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testNothingSavedIsFiveMinutes() {
        let defaults = UserDefaults(suiteName: "GuideTimeoutTests")!
        defaults.removePersistentDomain(forName: "GuideTimeoutTests")
        XCTAssertEqual(GuideTimeout.current(defaults: defaults), .fiveMinutes)
        XCTAssertEqual(GuideTimeout(stored: "nonsense"), .fiveMinutes)
        defaults.set("off", forKey: GuideTimeout.storageKey)
        XCTAssertEqual(GuideTimeout.current(defaults: defaults), .off)
        defaults.set("15m", forKey: GuideTimeout.storageKey)
        XCTAssertEqual(GuideTimeout.current(defaults: defaults), .fifteenMinutes)
    }

    func testRowCyclesThroughEveryChoice() {
        XCTAssertEqual(GuideTimeout.off.next, .fiveMinutes)
        XCTAssertEqual(GuideTimeout.fiveMinutes.next, .fifteenMinutes)
        XCTAssertEqual(GuideTimeout.fifteenMinutes.next, .off)
        XCTAssertEqual(GuideTimeout.allCases.map(\.label), ["OFF", "5 MIN", "15 MIN"])
    }

    func testIntervals() {
        XCTAssertNil(GuideTimeout.off.interval)
        XCTAssertEqual(GuideTimeout.fiveMinutes.interval, 300)
        XCTAssertEqual(GuideTimeout.fifteenMinutes.interval, 900)
    }

    func testFiresOnlyAfterTheWholeTimeout() {
        func fires(after seconds: TimeInterval) -> Bool {
            GuideTimeout.shouldGoFullscreen(interval: 300, lastActivity: start,
                                            now: start + seconds, guideIsFrontmost: true, isPlaying: true)
        }
        XCTAssertFalse(fires(after: 299))
        XCTAssertTrue(fires(after: 300))
        XCTAssertTrue(fires(after: 3600))
    }

    func testNeverFiresWhenOffOrNotOnTheGuideOrNothingPlays() {
        let later = start + 3600
        XCTAssertFalse(GuideTimeout.shouldGoFullscreen(interval: nil, lastActivity: start, now: later,
                                                       guideIsFrontmost: true, isPlaying: true))
        XCTAssertFalse(GuideTimeout.shouldGoFullscreen(interval: 300, lastActivity: start, now: later,
                                                       guideIsFrontmost: false, isPlaying: true))
        XCTAssertFalse(GuideTimeout.shouldGoFullscreen(interval: 300, lastActivity: start, now: later,
                                                       guideIsFrontmost: true, isPlaying: false))
    }
}
