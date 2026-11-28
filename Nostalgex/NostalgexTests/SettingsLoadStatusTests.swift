import XCTest
@testable import Nostalgex

/// The loading pattern inside Settings: the same step names and lines as the guide block and every other platform.
final class SettingsLoadStatusTests: XCTestCase {
    private func status(inPlace: Bool = true, refresh: Bool = false, phase: LibraryLoadPhase = .scanningLibrary, read: Int = 0,
                        detail: String = "", ready: Int? = nil) -> SettingsLoadStatus? {
        SettingsLoadStatus.current(inPlaceLoad: inPlace, backgroundRefresh: refresh, phase: phase, titlesRead: read, scanDetail: detail, readyTitles: ready)
    }

    func testNothingGoingOnShowsNothing() {
        XCTAssertNil(status(inPlace: false))
    }

    func testReadingTheLibraryShowsBuildingChannelsTheCountAndTheLibrary() {
        let s = status(read: 4210, detail: LoadNotice.libraryLine("TV shows", done: 1200, total: 1450))
        XCTAssertEqual(s?.title, "BUILDING CHANNELS")
        XCTAssertEqual(s?.readLine, "READ 4,210 TITLES")
        XCTAssertEqual(s?.detailLine, "TV SHOWS: 1,200 OF 1,450")
        XCTAssertEqual(s?.isReady, false)
    }

    func testNoCountUntilSomethingHasBeenRead() {
        XCTAssertNil(status(phase: .scanningLibrary, read: 0)?.readLine)
        XCTAssertEqual(status(phase: .scanningLibrary, read: 1)?.readLine, "READ 1 TITLE")
        // Past the scan the count stays, even at zero (the read is finished).
        XCTAssertEqual(status(phase: .buildingChannels, read: 0)?.readLine, "READ 0 TITLES")
    }

    func testTheStepAfterTheScanNamesItself() {
        XCTAssertEqual(status(phase: .discoveringCollections, read: 10)?.detailLine, "COLLECTIONS")
        XCTAssertEqual(status(phase: .enrichingMetadata, read: 10)?.detailLine, "METADATA")
        XCTAssertEqual(status(phase: .buildingChannels, read: 10)?.detailLine, "CHANNELS")
        XCTAssertNil(status(phase: .preparing, read: 0)?.detailLine, "the quiet first step says no more than its title")
        XCTAssertEqual(status(phase: .buildingChannels, read: 10)?.title, "BUILDING CHANNELS")
    }

    func testTheLastStepIsBuildingSchedule() {
        let s = status(phase: .finishing, read: 4210)
        XCTAssertEqual(s?.title, "BUILDING SCHEDULE")
        XCTAssertEqual(s?.readLine, "READ 4,210 TITLES")
        XCTAssertNil(s?.detailLine)
    }

    func testGuideReadyShowsTheTitleCountWhenTheLoadIsOver() {
        let s = status(inPlace: false, ready: 4210)
        XCTAssertEqual(s?.title, "GUIDE READY: 4,210 TITLES")
        XCTAssertEqual(s?.isReady, true)
        XCTAssertEqual(status(inPlace: false, ready: 1)?.title, "GUIDE READY: 1 TITLE")
        XCTAssertEqual(LoadNotice.readySeconds, 4)
    }

    func testALoadWinsOverTheReadyLine() {
        XCTAssertEqual(status(inPlace: true, ready: 4210)?.title, "BUILDING CHANNELS")
    }

    func testARefreshBehindTheGuideSaysUpdatingLibrary() {
        XCTAssertEqual(status(inPlace: false, refresh: true, read: 4210)?.title, "UPDATING LIBRARY: 4,210 TITLES READ")
        XCTAssertEqual(status(inPlace: false, refresh: true, read: 0)?.title, "UPDATING LIBRARY")
    }

    /// The guide's block and Settings read the step the same way.
    func testTheGuideBlockAndSettingsShareTheDetailLine() {
        XCTAssertEqual(LoadNotice.detailLine(phase: .scanningLibrary, scanDetail: "MOVIES: 3 OF 9"), "MOVIES: 3 OF 9")
        XCTAssertEqual(LoadNotice.detailLine(phase: .preparing, scanDetail: "x"), "")
        XCTAssertEqual(LoadNotice.detailLine(phase: .buildingChannels, scanDetail: "x"), "CHANNELS")
    }
}
