import XCTest
@testable import Nostalgex

/// TMDB numbers films and shows separately, and the shared table keeps a row for each (its
/// key is the number plus the type). A read by number can answer with two rows. These pin
/// that a library item finds the row of its own type, and that a show is not taken as
/// cached because a film with its number is.
@MainActor
final class EnrichmentKeyTests: XCTestCase {

    private func item(_ id: String, type: MediaType, tmdbID: String?) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: "Title \(id)", artist: nil, episodeTitle: type == .episode ? "Episode" : nil,
            seTag: type == .episode ? "S01E01" : nil,
            summary: "", year: 1999, originallyAvailableAt: nil, contentRating: "PG",
            duration: 100, ratingKey: id, partKey: "src\(id)", container: "mkv",
            videoCodec: "h264", audioCodec: "aac", videoProfile: "High", bitrate: 8_000,
            genres: ["Drama"], rating: 0, userRating: 0, type: type, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: tmdbID, imdbID: nil,
            librarySource: type == .episode ? .tv : .movie
        )
    }

    private func row(_ tmdbID: String, type: String, keywords: [String]) -> MediaEnrichment {
        MediaEnrichment(
            tmdbID: tmdbID, imdbID: nil, mediaType: type,
            keywords: keywords, networks: [], productionCompanies: [], tmdbGenres: [],
            imdbRating: nil, imdbVotes: nil, rottenTomatoesScore: nil, metacriticScore: nil, awards: nil,
            fetchedAt: Date()
        )
    }

    func testAFilmAndAShowWithOneNumberEachFindTheirOwnRow() {
        let service = EnrichmentService()
        service.seedCache([
            row("603", type: "movie", keywords: ["the film"]),
            row("603", type: "tv", keywords: ["the show"]),
        ])
        XCTAssertEqual(service.cache.count, 2, "one number, two rows")
        XCTAssertEqual(service.enrichment(for: item("f", type: .movie, tmdbID: "603"))?.keywords, ["the film"])
        XCTAssertEqual(service.enrichment(for: item("e", type: .episode, tmdbID: "603"))?.keywords, ["the show"])
        XCTAssertNil(service.enrichment(for: item("n", type: .movie, tmdbID: nil)))
    }

    func testTheOrderRowsArriveInDoesNotMatter() {
        let service = EnrichmentService()
        service.seedCache([row("603", type: "tv", keywords: ["the show"])])
        service.seedCache([row("603", type: "movie", keywords: ["the film"])])
        XCTAssertEqual(service.enrichment(for: item("e", type: .episode, tmdbID: "603"))?.keywords, ["the show"])
        XCTAssertEqual(service.enrichment(for: item("f", type: .movie, tmdbID: "603"))?.keywords, ["the film"])
    }

    func testOnlyTheFilmCachedLeavesTheShowWithNoRow() {
        let service = EnrichmentService()
        service.seedCache([row("603", type: "movie", keywords: ["the film"])])
        XCTAssertNil(service.enrichment(for: item("e", type: .episode, tmdbID: "603")),
                     "a show must not read the film's keywords")
    }

    func testAShowIsStillFetchedWhenTheTableOnlyHasTheFilmWithItsNumber() {
        let work = [
            OMDBWorkItem(tmdbID: "603", imdbID: nil, mediaType: "movie", genres: []),
            OMDBWorkItem(tmdbID: "603", imdbID: nil, mediaType: "tv", genres: []),
            OMDBWorkItem(tmdbID: "9", imdbID: nil, mediaType: "tv", genres: []),
        ]
        let onlyFilm = EnrichmentService.needingFetch(work: work, cached: [row("603", type: "movie", keywords: [])])
        XCTAssertEqual(onlyFilm.map(\.key).sorted(), ["tv:603", "tv:9"])

        let both = EnrichmentService.needingFetch(work: work, cached: [
            row("603", type: "movie", keywords: []), row("603", type: "tv", keywords: []),
        ])
        XCTAssertEqual(both.map(\.key), ["tv:9"])
    }

    func testTheKeyIsTheTypeAndTheNumber() {
        XCTAssertEqual(row("603", type: "movie", keywords: []).cacheKey, "movie:603")
        XCTAssertEqual(row("603", type: "tv", keywords: []).cacheKey, "tv:603")
        XCTAssertEqual(item("f", type: .movie, tmdbID: "603").enrichmentKey, "movie:603")
        XCTAssertEqual(item("e", type: .episode, tmdbID: "603").enrichmentKey, "tv:603")
        XCTAssertNil(item("n", type: .episode, tmdbID: nil).enrichmentKey)
    }
}
