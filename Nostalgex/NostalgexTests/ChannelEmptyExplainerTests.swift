import XCTest
@testable import Nostalgex

/// I-004: Settings explains why a channel never came on air, in plain language, next to
/// how many library items currently match its rules. Covers the two building blocks:
/// `ChannelRules.plainLanguageRequirements` (pure) and `AppState.currentMatchCount` /
/// `AppState.channelDefinition` (need a library and the real filter). Only static,
/// rule-based channels are in scope; dynamic and franchise channels have no `rules`.
@MainActor
final class ChannelEmptyExplainerTests: XCTestCase {

    // MARK: - Plain-language requirements (pure)

    func testEmptyRulesFallsBackToOneLine() {
        let lines = ChannelRules().plainLanguageRequirements
        XCTAssertEqual(lines, ["A specific, curated list of titles rather than a general rule"])
    }

    func testGenreYearRatingAndStudioReadAsPlainSentences() {
        var rules = ChannelRules()
        rules.genres = GenreRules(include: ["Horror", "Thriller"], exclude: ["Comedy"])
        rules.yearRange = YearRange(min: 1980, max: 1999)
        rules.contentRatings = ["R", "NC-17"]
        rules.studios = ["A24"]

        let lines = rules.plainLanguageRequirements
        XCTAssertTrue(lines.contains("Genre: Horror or Thriller"), "\(lines)")
        XCTAssertTrue(lines.contains("Not genre: Comedy"), "\(lines)")
        XCTAssertTrue(lines.contains("Released 1980 to 1999"), "\(lines)")
        XCTAssertTrue(lines.contains("Rated: R, NC-17"), "\(lines)")
        XCTAssertTrue(lines.contains("Studio: A24"), "\(lines)")
        XCTAssertFalse(lines.contains(where: { $0.contains("nil") }), "never leak a raw Optional")
    }

    func testOpenEndedYearRangeReadsEitherDirection() {
        var lower = ChannelRules()
        lower.yearRange = YearRange(min: 2000, max: nil)
        XCTAssertEqual(lower.plainLanguageRequirements, ["Released 2000 or later"])

        var upper = ChannelRules()
        upper.yearRange = YearRange(min: nil, max: 1989)
        XCTAssertEqual(upper.plainLanguageRequirements, ["Released before 1989"])
    }

    func testMusicVideoSourceAndKeywordsReadPlainly() {
        var rules = ChannelRules()
        rules.source = .musicVideo
        rules.keywords = ["christmas", "holiday", "snow", "santa", "winter"]

        let lines = rules.plainLanguageRequirements
        XCTAssertTrue(lines.contains("Music videos only"), "\(lines)")
        // Keyword lists are capped at 4 so the card never runs long.
        XCTAssertTrue(lines.contains("About: christmas, holiday, snow, santa"), "\(lines)")
    }

    func testWatchedFlagsReadPlainly() {
        var rewatched = ChannelRules()
        rewatched.rewatched = true
        XCTAssertEqual(rewatched.plainLanguageRequirements, ["Watched three times or more"])

        var unwatched = ChannelRules()
        unwatched.unwatchedOnly = true
        XCTAssertEqual(unwatched.plainLanguageRequirements, ["Unwatched titles only"])
    }

    // MARK: - currentMatchCount (needs a library)

    private func film(_ id: String, genres: [String]) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: "Film \(id)", artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 1995, originallyAvailableAt: nil, contentRating: "PG",
            duration: 100, ratingKey: id, partKey: "src\(id)", container: "mkv",
            videoCodec: "h264", audioCodec: "aac", videoProfile: nil, bitrate: 10_000,
            genres: genres, rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie
        )
    }

    private func horrorChannel(id: Int = 900, minItems: Int = 50) -> Channel {
        var rules = ChannelRules()
        rules.genres = GenreRules(include: ["Horror"])
        return Channel(
            id: id, number: id, name: "TEST HORROR", color: .red, category: nil,
            rules: rules, timeRestrictions: nil, minItems: minItems
        )
    }

    func testCurrentMatchCountReflectsTheLibraryRegardlessOfMinItems() {
        let state = AppState()
        state.allItems = [
            film("h1", genres: ["Horror"]),
            film("h2", genres: ["Horror", "Thriller"]),
            film("c1", genres: ["Comedy"]),
        ]
        // minItems is deliberately far above what the library holds: currentMatchCount
        // must still report the real count, not zero and not the gate.
        let channel = horrorChannel(minItems: 50)
        XCTAssertEqual(state.currentMatchCount(for: channel), 2)
    }

    func testCurrentMatchCountIsZeroWhenNothingMatches() {
        let state = AppState()
        state.allItems = [film("c1", genres: ["Comedy"]), film("c2", genres: ["Drama"])]
        XCTAssertEqual(state.currentMatchCount(for: horrorChannel()), 0)
    }

    /// A dynamic/collection channel has no `rules`; the explainer never calls
    /// `currentMatchCount` for one, but if it did, this must not crash and must fall back
    /// to the stored pool rather than claim a count it cannot compute.
    func testCurrentMatchCountFallsBackToStoredPoolWhenRulesAreNil() {
        let state = AppState()
        var dynamic = Channel(
            id: 901, number: 901, name: "USER COLLECTION", color: .blue, category: "franchises",
            rules: nil, timeRestrictions: nil, minItems: 0
        )
        dynamic.itemPool = [film("x1", genres: [])]
        XCTAssertEqual(state.currentMatchCount(for: dynamic), 1)
    }

    // MARK: - channelDefinition fallback

    func testChannelDefinitionFallsBackToConfigForADroppedChannel() {
        let state = AppState()
        let dropped = horrorChannel(id: 902, minItems: 999)
        // Not in allChannels (as if it failed the minItems gate and was dropped), but
        // still in the full config, the same fallback channelName(for:) already uses.
        state.allChannels = []
        state.channelConfigChannels = [dropped]
        let resolved = state.channelDefinition(for: 902)
        XCTAssertEqual(resolved?.id, 902)
        XCTAssertEqual(resolved?.minItems, 999)
        XCTAssertNotNil(resolved?.rules)
    }

    func testChannelDefinitionReturnsNilForAnUnknownID() {
        let state = AppState()
        XCTAssertNil(state.channelDefinition(for: 123_456))
    }

    // MARK: - bundleChannelAvailability carries the id through

    func testBundleChannelAvailabilityCarriesIDAlongsideNameAndContent() {
        let state = AppState()
        let live = horrorChannel(id: 903)
        state.allChannels = [live]
        state.channelConfigChannels = [live, horrorChannel(id: 904)]
        let bundle = ChannelBundle(
            id: "test-bundle", name: "TEST BUNDLE", description: nil,
            channelIDs: [903, 904], activeMonths: nil
        )
        let availability = state.bundleChannelAvailability(for: bundle)
        XCTAssertEqual(availability.map(\.id), [903, 904])
        XCTAssertEqual(availability.first(where: { $0.id == 903 })?.hasContent, true)
        XCTAssertEqual(availability.first(where: { $0.id == 904 })?.hasContent, false)
    }
}
