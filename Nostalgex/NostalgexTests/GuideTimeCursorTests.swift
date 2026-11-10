import XCTest
@testable import Nostalgex

/// I-089: the info panel follows the guide's window through time. Pure; the focus engine and the panel on screen are
/// covered by `GuideInfoPanelTimeTests` (UI).
final class GuideTimeCursorTests: XCTestCase {
    private let windowStart = Date(timeIntervalSince1970: 1_800_000_000)   // a half hour boundary
    private var now: Date { windowStart.addingTimeInterval(600) }           // ten minutes into the window

    private func item(_ title: String) -> PlexMediaItem {
        PlexMediaItem(
            id: title, title: title, artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: 1990, originallyAvailableAt: nil,
            contentRating: nil, duration: 30, ratingKey: title, partKey: nil, container: nil, videoCodec: nil, audioCodec: nil,
            videoProfile: nil, bitrate: nil, genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie
        )
    }

    private func entry(_ title: String, from minutes: Int, to end: Int) -> ScheduleEntry {
        ScheduleEntry(id: title, item: item(title), startTime: windowStart.addingTimeInterval(Double(minutes) * 60),
                      endTime: windowStart.addingTimeInterval(Double(end) * 60), isNowPlaying: minutes <= 10 && 10 < end)
    }

    func testAtTheStartOfTheWindowThePanelShowsWhatIsOn() {
        XCTAssertNil(GuideTimeCursor.previewTime(slotOffset: 0, windowStart: windowStart, now: now))
    }

    func testEachStepLaterMovesTheCursorThirtyMinutes() {
        XCTAssertEqual(GuideTimeCursor.previewTime(slotOffset: 1, windowStart: windowStart, now: now), windowStart.addingTimeInterval(1800))
        XCTAssertEqual(GuideTimeCursor.previewTime(slotOffset: 3, windowStart: windowStart, now: now), windowStart.addingTimeInterval(5400))
    }

    func testACursorThatIsNotLaterThanNowShowsWhatIsOn() {
        let late = windowStart.addingTimeInterval(4000)
        XCTAssertNil(GuideTimeCursor.previewTime(slotOffset: 1, windowStart: windowStart, now: late))
    }

    func testTheProgrammeAtTheCursorIsTheOneThatCoversIt() {
        let entries = [entry("A", from: 0, to: 45), entry("B", from: 45, to: 90), entry("C", from: 90, to: 120)]
        XCTAssertEqual(GuideTimeCursor.entry(in: entries, at: windowStart.addingTimeInterval(30 * 60))?.item.title, "A")
        XCTAssertEqual(GuideTimeCursor.entry(in: entries, at: windowStart.addingTimeInterval(45 * 60))?.item.title, "B", "a start is that programme's")
        XCTAssertEqual(GuideTimeCursor.entry(in: entries, at: windowStart.addingTimeInterval(90 * 60))?.item.title, "C")
        XCTAssertNil(GuideTimeCursor.entry(in: entries, at: windowStart.addingTimeInterval(120 * 60)), "past the last")
        XCTAssertNil(GuideTimeCursor.entry(in: [], at: windowStart))
    }

    func testAGapHasNoProgramme() {
        let entries = [entry("A", from: 0, to: 20), entry("B", from: 50, to: 90)]
        XCTAssertNil(GuideTimeCursor.entry(in: entries, at: windowStart.addingTimeInterval(30 * 60)))
    }

    func testUpNextIsTheProgrammeAfterThePreviewedOne() {
        let entries = [entry("C", from: 90, to: 120), entry("A", from: 0, to: 45), entry("B", from: 45, to: 90)]
        XCTAssertEqual(GuideTimeCursor.entry(after: entries[2], in: entries)?.item.title, "C")
        XCTAssertNil(GuideTimeCursor.entry(after: entries[0], in: entries))
    }
}
