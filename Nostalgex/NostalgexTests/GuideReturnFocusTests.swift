import XCTest
@testable import Nostalgex

/// I-041: back from full screen, focus lands on the live channel even when the channel was
/// changed in full screen. The decision is pure; the real focus engine is covered by
/// `GuideFocusAfterFullScreenTests` (UI).
final class GuideReturnFocusTests: XCTestCase {
    func testFocusHandedToTheRowTheViewerLeftFromMovesToTheLiveChannel() {
        XCTAssertEqual(GuideReturnFocus.target(handedTo: 9004, liveChannelID: 9006), 9006)
    }

    func testFocusHandedToTheLiveChannelStaysThere() {
        XCTAssertNil(GuideReturnFocus.target(handedTo: 9006, liveChannelID: 9006))
    }

    func testNothingPlayingLeavesFocusWhereTvOSPutIt() {
        XCTAssertNil(GuideReturnFocus.target(handedTo: 9004, liveChannelID: nil))
        XCTAssertNil(GuideReturnFocus.target(handedTo: nil, liveChannelID: 9006))
    }

    // MARK: The window

    func testAnEarlierTimerCannotCloseALaterWindow() {
        var window = GuideReturnFocus.HandoutWindow()
        let first = window.open()          // full screen closes
        let second = window.open()         // it closes again before the first timer ran out
        window.expire(generation: first)   // the first timer fires
        XCTAssertTrue(window.isOpen, "the stale timer left the newer window open")
        window.expire(generation: second)
        XCTAssertFalse(window.isOpen, "its own timer closes it")
    }

    func testAStaleTimerCannotCloseAWindowOpenedAfterTheHandout() {
        var window = GuideReturnFocus.HandoutWindow()
        let first = window.open()
        window.close()                     // the handout came
        XCTAssertFalse(window.isOpen)
        _ = window.open()                  // the next close of full screen
        window.expire(generation: first)   // the old timer fires
        XCTAssertTrue(window.isOpen)
    }

    func testAWindowNobodyClosesIsClosedByItsOwnTimer() {
        var window = GuideReturnFocus.HandoutWindow()
        let generation = window.open()
        XCTAssertTrue(window.isOpen)
        window.expire(generation: generation)
        XCTAssertFalse(window.isOpen)
    }

    /// The seasonal invite and the wrap rows are not channels; a handout to one of them moves too.
    func testFocusHandedToTheInviteRowMovesToTheLiveChannel() {
        XCTAssertEqual(GuideReturnFocus.target(handedTo: -900, liveChannelID: 9006), 9006)
    }
}
