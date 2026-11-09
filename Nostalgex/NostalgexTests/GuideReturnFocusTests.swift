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

    /// The seasonal invite and the wrap rows are not channels; a handout to one of them moves too.
    func testFocusHandedToTheInviteRowMovesToTheLiveChannel() {
        XCTAssertEqual(GuideReturnFocus.target(handedTo: -900, liveChannelID: 9006), 9006)
    }
}
