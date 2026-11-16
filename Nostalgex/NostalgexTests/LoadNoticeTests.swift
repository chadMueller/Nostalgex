import XCTest
@testable import Nostalgex

/// The loading pattern's words, line for line with Android's `LoadNotice.kt` (the reference for every platform).
final class LoadNoticeTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(GuideLoadKind.changing.title, "CHANNEL GUIDE IS CHANGING")
        XCTAssertEqual(GuideLoadKind.loading.title, "LOADING YOUR LIBRARY")
        XCTAssertEqual(LoadNotice.readySeconds, 4)
    }

    func testReadLineSaysOfOnlyWithATotal() {
        XCTAssertEqual(LoadNotice.readLine(read: 4210), "READ 4,210 TITLES")
        XCTAssertEqual(LoadNotice.readLine(read: 1), "READ 1 TITLE")
        XCTAssertEqual(LoadNotice.readLine(read: 40, total: 4210), "READ 40 OF 4,210 TITLES")
        XCTAssertEqual(LoadNotice.readLine(read: 50, total: 40), "READ 50 TITLES", "a total under the count is not shown")
    }

    func testLibraryLine() {
        XCTAssertEqual(LoadNotice.libraryLine("Movies", done: 40, total: 40), "MOVIES: 40 OF 40")
        XCTAssertEqual(LoadNotice.libraryLine("TV shows", done: 1200, total: 1450), "TV SHOWS: 1,200 OF 1,450")
        XCTAssertEqual(LoadNotice.libraryLine("Movies"), "MOVIES", "no total from the server, no OF")
        XCTAssertEqual(LoadNotice.libraryLine("Den · Movies", done: nil, total: 40), "DEN · MOVIES")
    }

    func testHeaderLines() {
        XCTAssertEqual(LoadNotice.updatingLine(read: 4210), "UPDATING LIBRARY: 4,210 TITLES READ")
        XCTAssertEqual(LoadNotice.updatingLine(read: 0), "UPDATING LIBRARY")
        XCTAssertEqual(LoadNotice.updatingLine(read: nil), "UPDATING LIBRARY")
        XCTAssertEqual(LoadNotice.readyLine(4210), "GUIDE READY: 4,210 TITLES")
        XCTAssertEqual(LoadNotice.readyLine(1), "GUIDE READY: 1 TITLE")
    }
}
