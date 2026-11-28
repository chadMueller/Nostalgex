import XCTest
@testable import Nostalgex

/// OMDb through the site relay. The App Store build ships without an OMDb key, so
/// OMDBService asks `api/tmdb.js?path=omdb/{imdbID}`; a build with a key keeps asking
/// OMDb directly. The free tier is 1,000 requests a day shared by every device, so only
/// titles that could land on an IMDb-gated channel are looked up, at most 50 per load,
/// and a daily-limit answer parks OMDb until the next UTC midnight.
final class OMDBRelayTests: XCTestCase {

    // MARK: - Request routing

    func testProxyRequestCarriesNoKey() throws {
        let service = OMDBService(apiKey: "")
        XCTAssertTrue(service.usesProxy)
        let request = try XCTUnwrap(service.request(imdbID: "tt0133093"))
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertEqual(url, "https://www.nostalgex.app/api/tmdb?path=omdb/tt0133093")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Nostalgex-Client"), "tvos")
        XCTAssertFalse(url.contains("apikey"))
        XCTAssertFalse(url.contains("omdbapi.com"))
    }

    func testDirectRequestWhenKeyIsPresent() throws {
        let service = OMDBService(apiKey: "k123")
        XCTAssertFalse(service.usesProxy)
        let request = try XCTUnwrap(service.request(imdbID: "tt0133093"))
        XCTAssertEqual(request.url?.absoluteString, "https://www.omdbapi.com/?i=tt0133093&apikey=k123&tomatoes=true")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Nostalgex-Client"))
    }

    func testKeyWinsOverProxy() throws {
        let service = OMDBService(apiKey: "k123", proxyURL: "https://example.test/api/tmdb")
        let request = try XCTUnwrap(service.request(imdbID: "tt0133093"))
        XCTAssertTrue(try XCTUnwrap(request.url?.absoluteString).hasPrefix("https://www.omdbapi.com/"))
    }

    func testOnlyRelayShapedIMDbIDsBuildARequest() {
        let service = OMDBService(apiKey: "")
        for bad in ["", "tt123456", "tt1234567890", "0133093", "TT0133093", "tt0133093&apikey=x", "nm0000206"] {
            XCTAssertNil(service.request(imdbID: bad), bad)
        }
        XCTAssertNotNil(service.request(imdbID: "tt123456789"))
    }

    func testConfiguredByEitherRoute() {
        XCTAssertTrue(OMDBService(apiKey: "").isConfigured)
        XCTAssertTrue(OMDBService(apiKey: "k", proxyURL: "").isConfigured)
        XCTAssertFalse(OMDBService(apiKey: "", proxyURL: "").isConfigured)
    }

    // MARK: - Parse

    func testParseRelayDocument() throws {
        let json = """
        {"Title":"The Matrix","imdbRating":"8.7","imdbVotes":"2,213,456","Metascore":"73",
         "Awards":"Won 4 Oscars. 42 wins & 52 nominations total",
         "Ratings":[{"Source":"Internet Movie Database","Value":"8.7/10"},{"Source":"Rotten Tomatoes","Value":"83%"}],
         "Response":"True"}
        """.data(using: .utf8)!
        let r = try OMDBService(apiKey: "").parseResponse(data: json, imdbID: "tt0133093")
        XCTAssertEqual(r.imdbRating, 8.7)
        XCTAssertEqual(r.imdbVotes, 2_213_456)
        XCTAssertEqual(r.rottenTomatoesScore, 83)
        XCTAssertEqual(r.metacriticScore, 73)
        XCTAssertEqual(r.awards, "Won 4 Oscars. 42 wins & 52 nominations total")
    }

    func testParseNotAvailableValuesAsNil() throws {
        let json = #"{"imdbRating":"N/A","imdbVotes":"N/A","Metascore":"N/A","Awards":"N/A","Response":"True"}"#.data(using: .utf8)!
        let r = try OMDBService(apiKey: "").parseResponse(data: json, imdbID: "tt0000001")
        XCTAssertNil(r.imdbRating)
        XCTAssertNil(r.imdbVotes)
        XCTAssertNil(r.metacriticScore)
        XCTAssertNil(r.awards)
    }

    func testParseLimitAndUnknownIDErrors() {
        let service = OMDBService(apiKey: "")
        let limit = #"{"Response":"False","Error":"Request limit reached!"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try service.parseResponse(data: limit, imdbID: "tt0133093")) { error in
            guard case OMDBService.OMDBError.rateLimited = error else { return XCTFail("\(error)") }
        }
        let unknown = #"{"Response":"False","Error":"Incorrect IMDb ID."}"#.data(using: .utf8)!
        XCTAssertThrowsError(try service.parseResponse(data: unknown, imdbID: "tt9999999")) { error in
            guard case OMDBService.OMDBError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    /// A TMDB movie document carries `imdb_id`; it fills in when the server had no IMDb guid.
    func testTMDBDocumentSuppliesIMDbID() throws {
        let doc = #"{"id":603,"imdb_id":"tt0133093","keywords":{"keywords":[]}}"#.data(using: .utf8)!
        let fromDoc = try TMDBService(apiKey: "").parseResponse(data: doc, tmdbID: "603", imdbID: nil, mediaType: "movie")
        XCTAssertEqual(fromDoc.imdbID, "tt0133093")
        let serverWins = try TMDBService(apiKey: "").parseResponse(data: doc, tmdbID: "603", imdbID: "tt7654321", mediaType: "movie")
        XCTAssertEqual(serverWins.imdbID, "tt7654321")
        let junk = #"{"id":1,"imdb_id":""}"#.data(using: .utf8)!
        XCTAssertNil(try TMDBService(apiKey: "").parseResponse(data: junk, tmdbID: "1", imdbID: nil, mediaType: "movie").imdbID)
    }

    // MARK: - Candidate filter

    private var foreignFilms: ChannelRules {
        var r = ChannelRules()
        r.type = .movie
        r.keywords = ["foreign language film", "French Cinema"]
        r.imdbRatingMin = 6.5
        r.imdbVotesMin = 5000
        return r
    }

    private var cultClassics: ChannelRules {
        var r = ChannelRules()
        r.type = .movie
        r.keywords = ["cult film"]
        r.imdbVotesMin = 30000
        return r
    }

    private var spyGames: ChannelRules {
        var r = ChannelRules()
        r.type = .movie
        r.keywords = ["spy"]
        return r
    }

    private func row(_ tmdbID: String, imdbID: String? = nil, type: String = "movie",
                     keywords: [String] = [], genres: [String] = [], rating: Double? = nil) -> MediaEnrichment {
        MediaEnrichment(
            tmdbID: tmdbID, imdbID: imdbID, mediaType: type,
            keywords: keywords, networks: [], productionCompanies: [], tmdbGenres: genres,
            imdbRating: rating, imdbVotes: nil, rottenTomatoesScore: nil, metacriticScore: nil, awards: nil,
            fetchedAt: Date()
        )
    }

    func testGatesComeOnlyFromOMDbRuledChannels() {
        let gates = OMDBGate.gates(from: [foreignFilms, cultClassics, spyGames])
        XCTAssertEqual(gates.count, 2)
        XCTAssertEqual(gates[0].mediaType, "movie")
        XCTAssertEqual(gates[0].keywords, ["foreign language film", "french cinema"])
        XCTAssertEqual(gates[1].keywords, ["cult film"])
    }

    func testShippedConfigGatesForeignFilmsAndCultClassics() throws {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let config = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        let gated = config.channels.filter { $0.rules.map(OMDBGate.needsOMDb) ?? false }.map(\.name)
        XCTAssertTrue(gated.contains("FOREIGN FILMS"), "\(gated)")
        XCTAssertTrue(gated.contains("CULT CLASSICS"), "\(gated)")
        let gates = OMDBGate.gates(from: config.channels.compactMap(\.rules))
        XCTAssertTrue(OMDBQuota.isCandidate(mediaType: "movie", keywords: ["Cult Film"], genres: [], gates: gates))
        XCTAssertFalse(OMDBQuota.isCandidate(mediaType: "movie", keywords: ["superhero"], genres: ["Action"], gates: gates))
    }

    func testCandidateNeedsMatchingTypeAndAKeywordOrGenre() {
        var withGenre = cultClassics
        withGenre.genres = GenreRules(include: ["Horror"])
        let gates = OMDBGate.gates(from: [foreignFilms, withGenre])
        XCTAssertTrue(OMDBQuota.isCandidate(mediaType: "movie", keywords: ["French cinema"], genres: [], gates: gates))
        XCTAssertTrue(OMDBQuota.isCandidate(mediaType: "movie", keywords: [], genres: ["Comedy Horror"], gates: gates))
        XCTAssertFalse(OMDBQuota.isCandidate(mediaType: "tv", keywords: ["french cinema"], genres: [], gates: gates))
        XCTAssertFalse(OMDBQuota.isCandidate(mediaType: "movie", keywords: ["heist"], genres: ["Drama"], gates: gates))
        XCTAssertFalse(OMDBQuota.isCandidate(mediaType: "movie", keywords: ["cult film"], genres: [], gates: []))
    }

    func testCandidatesSkipRatedRowsAndRowsWithoutAnIMDbID() {
        let gates = OMDBGate.gates(from: [cultClassics])
        let work = [
            OMDBWorkItem(tmdbID: "1", imdbID: "tt0000001", mediaType: "movie", genres: []),
            OMDBWorkItem(tmdbID: "2", imdbID: "tt0000002", mediaType: "movie", genres: []),
            OMDBWorkItem(tmdbID: "3", imdbID: nil, mediaType: "movie", genres: []),
            OMDBWorkItem(tmdbID: "4", imdbID: nil, mediaType: "movie", genres: []),
            OMDBWorkItem(tmdbID: "5", imdbID: "tt0000005", mediaType: "movie", genres: []),
            OMDBWorkItem(tmdbID: "6", imdbID: "tt0000006", mediaType: "movie", genres: []),
        ]
        let rows: [String: MediaEnrichment] = [
            "movie:1": row("1", keywords: ["cult film"]),                         // candidate
            "movie:2": row("2", keywords: ["cult film"], rating: 7.1),            // already rated
            "movie:3": row("3", keywords: ["cult film"]),                         // no IMDb id anywhere
            "movie:4": row("4", imdbID: "tt0000004", keywords: ["cult film"]),    // id from TMDB row
            "movie:5": row("5", keywords: ["romance"]),                           // no gate admits it
            // 6: no TMDB row at all
        ]
        let picked = EnrichmentService.omdbCandidates(work: work, enrichments: rows, gates: gates)
        XCTAssertEqual(picked.map(\.tmdbID).sorted(), ["1", "4"])
        XCTAssertEqual(picked.first { $0.tmdbID == "4" }?.imdbID, "tt0000004")
    }

    func testServerGenresCountForTheGate() {
        var horrorCult = cultClassics
        horrorCult.keywords = nil
        horrorCult.genres = GenreRules(include: ["horror"])
        let gates = OMDBGate.gates(from: [horrorCult])
        let work = [OMDBWorkItem(tmdbID: "9", imdbID: "tt0000009", mediaType: "movie", genres: ["Horror"])]
        let picked = EnrichmentService.omdbCandidates(work: work, enrichments: ["movie:9": row("9")], gates: gates)
        XCTAssertEqual(picked.map(\.tmdbID), ["9"])
    }

    // MARK: - Budget

    func testPickCapsAtFiftyWithoutRepeats() {
        let all = Array(0..<400)
        var rng = SplitMix64(seed: 7)
        let picked = OMDBQuota.pick(all, limit: OMDBQuota.perLoadLimit, using: &rng)
        XCTAssertEqual(OMDBQuota.perLoadLimit, 50)
        XCTAssertEqual(picked.count, 50)
        XCTAssertEqual(Set(picked).count, 50)
        XCTAssertNotEqual(picked, Array(0..<50), "random order, not the first fifty")
        XCTAssertEqual(OMDBQuota.pick([1, 2, 3]).sorted(), [1, 2, 3])
        XCTAssertEqual(OMDBQuota.pick([1, 2, 3], limit: 0), [])
    }

    func testNextUTCMidnight() throws {
        let f = ISO8601DateFormatter()
        let lateEvening = try XCTUnwrap(f.date(from: "2026-10-11T23:59:00Z"))
        XCTAssertEqual(OMDBQuota.nextUTCMidnight(after: lateEvening), f.date(from: "2026-10-12T00:00:00Z"))
        let exactlyMidnight = try XCTUnwrap(f.date(from: "2026-10-12T00:00:00Z"))
        XCTAssertEqual(OMDBQuota.nextUTCMidnight(after: exactlyMidnight), f.date(from: "2026-10-13T00:00:00Z"))
    }

    func testBackoffHoldsUntilUTCMidnight() throws {
        let suite = "OMDBRelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backoff = OMDBBackoff(defaults: defaults)
        let f = ISO8601DateFormatter()
        let hit = try XCTUnwrap(f.date(from: "2026-10-11T15:30:00Z"))

        XCTAssertFalse(backoff.isBlocked(now: hit))
        backoff.markRateLimited(now: hit)
        XCTAssertTrue(backoff.isBlocked(now: hit))
        XCTAssertTrue(backoff.isBlocked(now: try XCTUnwrap(f.date(from: "2026-10-11T23:59:59Z"))))
        XCTAssertFalse(backoff.isBlocked(now: try XCTUnwrap(f.date(from: "2026-10-12T00:00:00Z"))))
        // Survives a relaunch: a fresh value reads the same defaults.
        XCTAssertTrue(OMDBBackoff(defaults: defaults).isBlocked(now: hit))
    }
}

/// Deterministic generator so the shuffle assertion is stable.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
