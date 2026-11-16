import XCTest
@testable import Nostalgex

/// A Jellyfin or Emby item keeps its real runtime in seconds next to the floored minutes, because the schedule gives a
/// programme its real length as its slot (#315). These read saved server answers through the services' own parse.
final class EpisodeRuntimeLoaderTests: XCTestCase {

    /// An Items answer for an episode, 42 min 3.0 s (25,230,000,000 ticks of 100 ns), as Jellyfin 10.9 sends it.
    private let episodeJSON = """
    {"Id":"3a1f0c2e9d5b4c7e8f60a1b2c3d4e5f6","Name":"The Long Weekend","SeriesName":"Late Shift Diner","Type":"Episode",
     "ParentIndexNumber":2,"IndexNumber":5,"RunTimeTicks":25230000000,"Overview":"Sample.","DateCreated":"2024-03-02T10:00:00Z",
     "MediaSources":[{"Id":"3a1f0c2e9d5b4c7e8f60a1b2c3d4e5f6","Container":"mkv","RunTimeTicks":25230000000}]}
    """

    private let showJSON = """
    {"Id":"9f8e7d6c5b4a39281706f5e4d3c2b1a0","Name":"Late Shift Diner","Type":"Series","Genres":["Drama"],"ProductionYear":1986}
    """

    private let noRuntimeJSON = """
    {"Id":"aaaa0000bbbb1111cccc2222dddd3333","Name":"No Runtime","SeriesName":"Late Shift Diner","Type":"Episode","IndexNumber":9}
    """

    /// A film with two files (disc 1 and disc 2) the server stacks: the slot is both.
    private let stackedMovieJSON = """
    {"Id":"11112222333344445555666677778888","Name":"Two Discs","Type":"Movie","RunTimeTicks":36000000000,
     "MediaSources":[{"Id":"d1","Name":"Two Discs - part1","Path":"/m/Two Discs - part1.mkv","RunTimeTicks":36000000000},
                     {"Id":"d2","Name":"Two Discs - part2","Path":"/m/Two Discs - part2.mkv","RunTimeTicks":30030000000}]}
    """

    private func decode(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    func testJellyfinEpisodeKeepsItsRealRuntime() throws {
        let service = JellyfinAPIService(serverURL: "", accessToken: "", userId: "")
        let item = try XCTUnwrap(service.parseEpisodeItem(try decode(episodeJSON), show: try decode(showJSON)))
        XCTAssertEqual(item.duration, 42, "floored minutes, as before")
        XCTAssertEqual(try XCTUnwrap(item.exactDurationSeconds), 2523.0, accuracy: 0.0001)
        XCTAssertEqual(item.slotSeconds, 2523, "the slot is the runtime: 42:03, not 42:00")
        XCTAssertEqual(item.title, "Late Shift Diner")
        XCTAssertEqual(item.seTag, "S02E05")
    }

    func testEmbyEpisodeKeepsItsRealRuntime() throws {
        let service = EmbyAPIService(serverURL: "", accessToken: "", userId: "")
        let item = try XCTUnwrap(service.parseEpisodeItem(try decode(episodeJSON), show: try decode(showJSON)))
        XCTAssertEqual(item.duration, 42)
        XCTAssertEqual(try XCTUnwrap(item.exactDurationSeconds), 2523.0, accuracy: 0.0001)
        XCTAssertEqual(item.slotSeconds, 2523)
        XCTAssertEqual(item.seTag, "S02E05")
    }

    func testAnEpisodeWithNoRuntimeIsSkippedOnBothServers() throws {
        let jellyfin = JellyfinAPIService(serverURL: "", accessToken: "", userId: "")
        let emby = EmbyAPIService(serverURL: "", accessToken: "", userId: "")
        XCTAssertNil(jellyfin.parseEpisodeItem(try decode(noRuntimeJSON), show: try decode(showJSON)))
        XCTAssertNil(emby.parseEpisodeItem(try decode(noRuntimeJSON), show: try decode(showJSON)))
    }

    /// The film loaders: the runtime in seconds, and for a stack the whole stack.
    func testMoviesKeepTheirRuntimeAndAStackKeepsTheWholeStack() throws {
        let stacked = try decode(stackedMovieJSON)
        let j = try XCTUnwrap(JellyfinAPIService(serverURL: "", accessToken: "", userId: "").parseMovieItem(stacked, isMusicSection: false))
        let e = try XCTUnwrap(EmbyAPIService(serverURL: "", accessToken: "", userId: "").parseMovieItem(stacked, isMusicSection: false))
        for item in [j, e] {
            XCTAssertEqual(item.duration, 110, "3600 s + 3003 s = 6603 s = 110 min 3 s")
            XCTAssertEqual(try XCTUnwrap(item.exactDurationSeconds), 6603.0, accuracy: 0.0001)
            XCTAssertEqual(item.slotSeconds, 6603)
        }
    }
}
