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

    // MARK: A playing channel with no row

    func testThePlayingChannelIsOnlyAnAnchorWhenTheGuideHasARowForIt() {
        let rows: Set<Int> = [1, 2, 3, 4]
        XCTAssertEqual(GuideReturnFocus.liveRowID(liveChannelID: 3, hasRow: rows.contains), 3)
        XCTAssertNil(GuideReturnFocus.liveRowID(liveChannelID: 9, hasRow: rows.contains), "no row to anchor to")
        XCTAssertNil(GuideReturnFocus.liveRowID(liveChannelID: nil, hasRow: rows.contains))
        // With no row for the playing channel the handout stands: focus stays where tvOS put it and the
        // info panel follows it. Measured on a simulator: anchoring to the missing row left the ring on
        // channel 1 with no info panel at all.
        let liveRow = GuideReturnFocus.liveRowID(liveChannelID: 9, hasRow: rows.contains)
        XCTAssertNil(GuideReturnFocus.target(handedTo: 1, liveChannelID: liveRow))
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

    // MARK: What is drawn highlighted while the guide comes back

    /// The viewer must never see the highlight on the row tvOS hands focus to first.
    func testWhileHoldingTheLiveRowIsHighlightedWhateverHasFocus() {
        for focused in [nil, 9004, 9001, -900] as [Int?] {
            XCTAssertEqual(GuideReturnFocus.highlighted(focused: focused, holdingLive: true, liveRow: 9006), 9006,
                           "focus on \(String(describing: focused)): the live row is what is drawn")
        }
    }

    func testWithoutAHoldTheHighlightFollowsFocus() {
        for focused in [nil, 9004, 9006, -900] as [Int?] {
            XCTAssertEqual(GuideReturnFocus.highlighted(focused: focused, holdingLive: false, liveRow: 9006), focused)
        }
    }

    /// No row for the playing channel (its package was switched off): nothing to hold the highlight on.
    func testAHoldWithNoLiveRowLeavesTheHighlightOnFocus() {
        XCTAssertEqual(GuideReturnFocus.highlighted(focused: 9004, holdingLive: true, liveRow: nil), 9004)
        XCTAssertNil(GuideReturnFocus.highlighted(focused: nil, holdingLive: true, liveRow: nil))
    }

    func testTheHoldSurvivesOnlyTheHandoutOfTheWrongRow() {
        XCTAssertTrue(GuideReturnFocus.holdSurvives(isHandout: true, handedTo: 9004, liveRow: 9006),
                      "the old row handed out: the correction follows, keep the highlight on the live row")
        XCTAssertTrue(GuideReturnFocus.holdSurvives(isHandout: true, handedTo: -900, liveRow: 9006), "the invite handed out")
        XCTAssertFalse(GuideReturnFocus.holdSurvives(isHandout: true, handedTo: 9006, liveRow: 9006),
                       "focus arrived on the live row itself: nothing to correct")
        XCTAssertFalse(GuideReturnFocus.holdSurvives(isHandout: true, handedTo: 9004, liveRow: nil), "no live row to hold")
        XCTAssertFalse(GuideReturnFocus.holdSurvives(isHandout: false, handedTo: 9004, liveRow: 9006),
                       "not a handout: the viewer moved focus, or the correction landed, and the highlight follows it")
    }

    func testAHoldNobodyEndsEndsByItsOwnTimer() {
        var hold = GuideReturnFocus.LiveHighlightHold()
        XCTAssertFalse(hold.isActive)
        let generation = hold.begin()
        XCTAssertTrue(hold.isActive)
        hold.expire(generation: generation)
        XCTAssertFalse(hold.isActive, "the hard limit: it can never stay on")
    }

    func testTheHoldEndsWhenFocusIsWhereItBelongsOrTheViewerMoves() {
        var hold = GuideReturnFocus.LiveHighlightHold()
        _ = hold.begin()
        hold.end()
        XCTAssertFalse(hold.isActive)
    }

    /// The timer of a hold that ended, or of an earlier close of full screen, cannot end a later hold.
    func testAnEarlierHoldsTimerCannotEndALaterHold() {
        var hold = GuideReturnFocus.LiveHighlightHold()
        let first = hold.begin()
        hold.end()
        let second = hold.begin()
        XCTAssertNotEqual(first, second)
        hold.expire(generation: first)
        XCTAssertTrue(hold.isActive, "the first hold's timer fired during the second hold")
        hold.expire(generation: second)
        XCTAssertFalse(hold.isActive)
    }

    /// A press between tvOS handing focus to the wrong row and the move to the live row must not act on the
    /// wrong one: the viewer is looking at the live row.
    func testWhileHoldingOnlyThePressOnTheHighlightedRowActs() {
        XCTAssertTrue(GuideReturnFocus.rowActs(row: 9006, highlighted: 9006, holding: true), "the row drawn highlighted")
        XCTAssertFalse(GuideReturnFocus.rowActs(row: 9004, highlighted: 9006, holding: true), "the old row, not drawn highlighted")
        XCTAssertFalse(GuideReturnFocus.rowActs(row: -900, highlighted: 9006, holding: true), "the invite handed out, not highlighted")
    }

    func testWithoutAHoldEveryPressActs() {
        for row in [9004, 9006, -900] {
            XCTAssertTrue(GuideReturnFocus.rowActs(row: row, highlighted: 9006, holding: false))
        }
    }

    /// No live row to hold the highlight on: nothing is held, so nothing is ignored.
    func testAHoldWithNoHighlightedRowIgnoresNothing() {
        XCTAssertTrue(GuideReturnFocus.rowActs(row: 9004, highlighted: nil, holding: true))
    }

    /// The cover takes about half a second to close and hands focus back at the end of it, so a hold
    /// shorter than that would let go of the live row just before the old one is handed out.
    func testTheHoldOutlastsTheCoverClosingAndIsNeverLongerThanTheHandoutWindow() {
        XCTAssertGreaterThan(GuideReturnFocus.holdTimeout, 1, "well over the ~0.5 s the cover takes to close")
        XCTAssertLessThanOrEqual(GuideReturnFocus.holdTimeout, 2, "no longer than the handout window")
    }

    func testOnceTheWrongRowIsHandedOutTheMoveHasOnlyAMomentToLand() {
        XCTAssertLessThanOrEqual(GuideReturnFocus.correctionTimeout, 0.3)
        XCTAssertGreaterThan(GuideReturnFocus.correctionTimeout, 0.1, "longer than the move takes on a slow TV")
    }
}
