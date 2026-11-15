import XCTest
@testable import Nostalgex

/// Posters on Jellyfin and Emby, the same chain as Plex (#312, Chad 2026-11-15): an episode's season, then its series,
/// then its own Primary image; a film's own.
final class MediaBrowserPosterTests: XCTestCase {
    /// An Items answer for an episode as Emby 4.10 and Jellyfin 10.9 send it, with the season and series ids.
    private let episodeJSON = """
    {"Id":"ep1","Name":"Pilot","SeriesName":"Late Shift Diner","SeriesId":"series9","SeasonId":"season3","Type":"Episode",
     "ParentIndexNumber":1,"IndexNumber":1,"RunTimeTicks":25230000000,"ImageTags":{"Primary":"abc"}}
    """

    private func item(type: MediaType, id: String, show: String? = nil, season: String? = nil) -> PlexMediaItem {
        var i = PlexMediaItem(
            id: id, title: "T", artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: 2000,
            originallyAvailableAt: nil, contentRating: nil, duration: 42, ratingKey: id, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil, genres: [], rating: 0, userRating: 0,
            type: type, thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: type == .episode ? .tv : .movie)
        i.showKey = show
        i.parentRatingKey = season
        return i
    }

    func testTheSeasonIdIsRead() throws {
        let ep = try JSONDecoder().decode(JellyfinItem.self, from: Data(episodeJSON.utf8))
        XCTAssertEqual(ep.SeasonId, "season3")
    }

    func testAnEpisodeTriesItsSeasonThenItsSeriesThenItself() {
        let urls = JellyfinAPIService.posterURLs(serverURL: "http://192.0.2.79:8096",
                                                 for: item(type: .episode, id: "ep1", show: "series9", season: "season3"), width: 300)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "http://192.0.2.79:8096/Items/season3/Images/Primary?maxWidth=300",
            "http://192.0.2.79:8096/Items/series9/Images/Primary?maxWidth=300",
            "http://192.0.2.79:8096/Items/ep1/Images/Primary?maxWidth=300",
        ])
    }

    /// An episode read before the season was kept goes series then itself; a film is its own poster.
    func testWithoutASeasonAndForAFilm() {
        let old = JellyfinAPIService.posterURLs(serverURL: "http://s", for: item(type: .episode, id: "ep1", show: "series9"), width: 300)
        XCTAssertEqual(old.map(\.path), ["/Items/series9/Images/Primary", "/Items/ep1/Images/Primary"])
        let film = JellyfinAPIService.posterURLs(serverURL: "http://s", for: item(type: .movie, id: "m1"), width: 300)
        XCTAssertEqual(film.map(\.path), ["/Items/m1/Images/Primary"])
    }

    func testEmbyUsesTheSameChain() {
        let emby = EmbyAPIService(serverURL: "http://192.0.2.79:8096", accessToken: "", userId: "")
        XCTAssertEqual(emby.posterURLs(for: item(type: .episode, id: "ep1", show: "series9", season: "season3")).count, 3)
    }
}

/// OPEN IN JELLYFIN: Swiftfin's item link (jellyfin/Swiftfin Shared/Services/DeepLink.swift).
@MainActor
final class OpenInJellyfinLinkTests: XCTestCase {
    func testTheLinkSwiftfinReads() {
        let url = AppState.jellyfinItemLink(serverID: "4d1c2b9e0f6a4f3e8b7c6d5e4f3a2b1c", userID: "a1b2c3d4e5f60718293a4b5c6d7e8f90", itemID: "f00dfeed00112233445566778899aabb")
        XCTAssertEqual(url?.absoluteString, "jellyfin://4d1c2b9e0f6a4f3e8b7c6d5e4f3a2b1c/a1b2c3d4e5f60718293a4b5c6d7e8f90/item/f00dfeed00112233445566778899aabb")
        // Swiftfin's own pattern, copied from DeepLink.swift.
        let pattern = #"^(?:swiftfin|jellyfin):\/\/[A-Za-z0-9-]+\/[A-Za-z0-9-]+\/(?:item|library)\/[A-Za-z0-9-]+\/?$"#
        XCTAssertNotNil(url?.absoluteString.range(of: pattern, options: .regularExpression))
    }

    func testNoLinkWhenAnIdIsMissingOrOdd() {
        XCTAssertNil(AppState.jellyfinItemLink(serverID: "", userID: "u", itemID: "i"))
        XCTAssertNil(AppState.jellyfinItemLink(serverID: "s", userID: "u/../x", itemID: "i"))
        XCTAssertNil(AppState.jellyfinItemLink(serverID: "s", userID: "u", itemID: "é1"))
    }
}
