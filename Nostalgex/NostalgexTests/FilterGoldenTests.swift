import XCTest
@testable import Nostalgex

/// Shared golden vectors for the channel pool filter.
///
/// `scripts/filter-golden.json` is read by this test AND by the web tuner's node test
/// (`npm run test:filter-golden`, scripts/nostalgex-filter-golden-smoke.mjs). Each case
/// is one item run against the shipped channel rules, exclusive rules and membership
/// manifest; both engines must put it on the same channels. The rules come from the
/// bundled `channels.json` and `channels-memberships.json`, which also proves the build
/// phase copied the current files into the app.
final class FilterGoldenTests: XCTestCase {

    private struct Golden: Decodable {
        let cases: [Case]
    }

    private struct Enrichment: Decodable {
        let keywords: [String]?
        let productionCompanies: [String]?
        let networks: [String]?
        let tmdbGenres: [String]?
        /// OMDb rating a plain ratingMin gate falls back to when rating and
        /// userRating both miss the bar (the Emby CommunityRating-is-always-null fix).
        let imdbRating: Double?
    }

    private struct Item: Decodable {
        let title: String
        let artist: String?
        let episodeTitle: String?
        let summary: String?
        let originallyAvailableAt: String?
        let year: Int?
        let type: String?
        let librarySource: String?
        let genres: [String]?
        let contentRating: String?
        let duration: Int?
        let rating: Double?
        let studio: String?
        let tmdbID: String?
        let enrichment: Enrichment?
        /// plex | jellyfin | emby; absent means plex.
        let backend: String?
        let doviProfile: Int?
    }

    private struct Case: Decodable {
        let name: String
        let item: Item
        let `in`: [Int]?
        let out: [Int]?
    }

    /// Repo root, found from this source file: NostalgexTests -> Nostalgex -> root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func bundled(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: name, withExtension: "json"),
                                "\(name).json is not in the app bundle")
        return try Data(contentsOf: url)
    }

    private func plexItem(_ g: Item) -> PlexMediaItem {
        let type: MediaType = g.type == "episode" ? .episode : .movie
        let source = g.librarySource.flatMap { LibrarySource(rawValue: $0) } ?? (type == .episode ? .tv : .movie)
        return PlexMediaItem(
            id: "golden", title: g.title, artist: g.artist, episodeTitle: g.episodeTitle,
            seTag: nil, summary: g.summary ?? "", year: g.year, originallyAvailableAt: g.originallyAvailableAt,
            contentRating: g.contentRating, duration: g.duration ?? 100, ratingKey: "golden",
            partKey: nil, container: nil, videoCodec: nil, audioCodec: nil, videoProfile: nil,
            bitrate: nil, genres: g.genres ?? [], rating: g.rating ?? 0, userRating: 0, type: type,
            thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: g.studio, tmdbID: g.tmdbID,
            imdbID: nil, librarySource: source, doviProfile: g.doviProfile
        )
    }

    /// What `makeFilterCache` builds for this item in the app: artist first, then title,
    /// lowercased, trailing " (YYYY)" stripped, and the channel eligibility for its backend.
    @MainActor
    private func cache(_ g: Item) -> AppState.FilterCache {
        let item = plexItem(g)
        let haystack = [g.artist, g.title].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " ").lowercased()
        let enrichment = g.enrichment.map {
            MediaEnrichment(
                tmdbID: g.tmdbID ?? "0", imdbID: nil, mediaType: item.type == .episode ? "tv" : "movie",
                keywords: ($0.keywords ?? []).map { $0.lowercased() }, networks: $0.networks ?? [],
                productionCompanies: $0.productionCompanies ?? [], tmdbGenres: $0.tmdbGenres ?? [],
                imdbRating: $0.imdbRating, imdbVotes: nil, rottenTomatoesScore: nil, metacriticScore: nil,
                awards: nil, fetchedAt: Date()
            )
        }
        return AppState.FilterCache(
            item: item,
            titleLower: AppState.stripTrailingYearSuffix(haystack),
            episodeTitleLower: (g.episodeTitle ?? "").lowercased(),
            genresLowerSet: Set((g.genres ?? []).map { $0.lowercased() }),
            enrichment: enrichment,
            itemStudioLower: (g.studio ?? "").lowercased(),
            leftOffChannels: ChannelEligibility.isLeftOffChannels(
                item, backend: g.backend.flatMap(MediaBackendKind.init(rawValue:)) ?? .plex)
        )
    }

    @MainActor
    func testEveryGoldenCaseLandsOnTheSameChannelsAsTheWebFilter() throws {
        let golden = try JSONDecoder().decode(
            Golden.self,
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent("scripts/filter-golden.json")))
        let config = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: bundled("channels")))
        let memberships = try JSONDecoder().decode(ChannelMemberships.self, from: bundled("channels-memberships"))
        let channels = Dictionary(uniqueKeysWithValues: config.channels.map { ($0.id, $0) })
        XCTAssertFalse(golden.cases.isEmpty)

        for c in golden.cases {
            let cached = [cache(c.item)]
            func passes(_ id: Int) -> Bool? {
                guard let ch = channels[id] else { return nil }
                return !AppState.filterItems(
                    cached, rules: ch.rules, forChannelID: ch.id, category: ch.category,
                    memberships: memberships, exclusiveRules: config.exclusiveRules
                ).isEmpty
            }
            for id in c.in ?? [] {
                let hit = passes(id)
                XCTAssertNotNil(hit, "\(c.name): channel id \(id) is not in channels.json")
                XCTAssertEqual(hit, true, "\(c.name): not on \(id) \(channels[id]?.name ?? "?")")
            }
            for id in c.out ?? [] {
                let hit = passes(id)
                XCTAssertNotNil(hit, "\(c.name): channel id \(id) is not in channels.json")
                XCTAssertEqual(hit, false, "\(c.name): on \(id) \(channels[id]?.name ?? "?")")
            }
        }
    }
}
