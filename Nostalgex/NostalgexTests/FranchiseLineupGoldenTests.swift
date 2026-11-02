import XCTest
@testable import Nostalgex

/// Shared golden vectors for franchise channels and the FRANCHISES / OTHER COLLECTIONS split.
///
/// `scripts/franchise-lineup-golden.json` is read by this test, by the web tuner's node test
/// (`npm run test:franchise-lineup`, scripts/nostalgex-franchise-lineup-smoke.mjs) and by the
/// Roku tests (a byte copy under roku/tests/vectors). Each builds the same library with the
/// shared `franchises.json` and `channels.json`, applies the same franchise choices, and must
/// give the same collection categories, folds, Settings rows, runtime channels and numbers.
///
/// The expected answers come from THIS app. Run once with the regenerate switch to have
/// the Apple TV's own code write them, then read the diff:
///
///     TEST_RUNNER_NOSTALGEX_GOLDEN_DUMP=/path/to/dump.json xcodebuild test ... \
///       -only-testing:NostalgexTests/FranchiseLineupGoldenTests
///
/// and `scripts/merge-franchise-lineup-golden.mjs <dump>` puts them into the file. Without
/// the switch the test only compares.
@MainActor
final class FranchiseLineupGoldenTests: XCTestCase {

    // MARK: - Golden file shape

    private struct Golden: Decodable {
        let classifier: [ClassifierCase]
        let blocks: [BlockCase]
        let lineups: [Lineup]
    }

    private struct GEnrichment: Decodable {
        let franchiseID: Int?
        let franchiseName: String?

        // A franchise id may arrive as a string ("42"), as the web's lookup accepts one.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if let n = try? c.decodeIfPresent(Int.self, forKey: .franchiseID) {
                franchiseID = n
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .franchiseID) {
                franchiseID = Int(s)
            } else {
                franchiseID = nil
            }
            franchiseName = try c.decodeIfPresent(String.self, forKey: .franchiseName)
        }
        private enum Keys: String, CodingKey { case franchiseID, franchiseName }
    }

    private struct GItem: Decodable {
        let id: String
        let type: String
        let title: String
        let episodeTitle: String?
        let showKey: String?
        let tmdbID: String?
        let genres: [String]?
        let enrichment: GEnrichment?
    }

    private struct ClassifierCase: Decodable {
        let name: String
        let title: String
        let items: [GItem]
        let expected: String?
    }

    private struct BlockEntry: Decodable {
        let id: String
        let name: String
        let films: Int
    }

    private struct BlockCase: Decodable {
        let name: String
        let capacity: Int
        let entries: [BlockEntry]
        let kept: [String]?
        let skipped: Int?
    }

    private struct GOverlap: Decodable {
        let channelID: Int
        let overlapCount: Int
        let totalCount: Int
    }

    private struct GCollection: Decodable {
        let id: String
        let title: String
        let members: [String]
        let matchedChannel: String?
        let contentOverlap: GOverlap?
    }

    private struct GEntry: Decodable {
        let channels: [Int]
        let exclusive: Int?
    }

    private struct GManifest: Decodable {
        let items: [String: GEntry]
    }

    private struct GRule: Decodable {
        let channelIDs: [Int]
        let genres: [String]?
        let titleContains: [String]?
        let editorialTitles: [String]?
        let manifestExclusive: Bool?
        let type: String?
        let source: String?
    }

    /// What a lineup produces. Codable both ways: decoded from the golden file to compare,
    /// encoded to the dump when regenerating.
    private struct Outcome: Codable, Equatable {
        struct Found: Codable, Equatable {
            let id: String
            let name: String
            let covered: Int?
            let fromDictionary: Bool
            let enabled: Bool
            let movies: [String]
            let tvItems: [String]
        }
        struct Row: Codable, Equatable {
            let id: String
            let name: String
            let countLabel: String
            let stockChannelID: Int?
            let channelNumber: Int?
            let enabled: Bool
        }
        struct Coll: Codable, Equatable {
            let id: String
            let title: String
            let category: String
            let foldedInto: String?
        }
        struct Chan: Codable, Equatable {
            let number: Int
            let id: Int
            let name: String
            let kind: String
            let items: [String]
        }
        let found: [Found]
        let stockPools: [String: [String]]
        let switchedOffStock: [Int]
        let rows: [Row]
        let collections: [Coll]
        let channels: [Chan]
        let overCap: [String: Int]
        let guide: [Int]
    }

    private struct Lineup: Decodable {
        let name: String
        let about: String?
        let packageOn: Bool
        let enabledFranchiseIDs: [String]
        let disabledFranchiseIDs: [String]
        let enabledCollectionIDs: [String]
        let stock: [String: [String]]
        let items: [GItem]
        let collections: [GCollection]
        let manifest: GManifest?
        let exclusiveRules: [GRule]
        let expected: Outcome?
    }

    // MARK: - Fixtures

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func loadGolden() throws -> Golden {
        let url = Self.repoRoot.appendingPathComponent("scripts/franchise-lineup-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    private let bundlesKey = "nostalgex_enabled_bundles"
    private let collectionsKey = "nostalgex_enabled_collections"
    private var savedBundles: [String]?
    private var savedCollections: [String]?

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedBundles = d.stringArray(forKey: bundlesKey)
        savedCollections = d.stringArray(forKey: collectionsKey)
    }

    override func tearDown() {
        let d = UserDefaults.standard
        if let savedBundles { d.set(savedBundles, forKey: bundlesKey) } else { d.removeObject(forKey: bundlesKey) }
        if let savedCollections { d.set(savedCollections, forKey: collectionsKey) } else { d.removeObject(forKey: collectionsKey) }
        super.tearDown()
    }

    private func item(_ g: GItem) -> PlexMediaItem {
        let isEpisode = g.type == "episode"
        return PlexMediaItem(
            id: g.id, title: g.title, artist: nil, episodeTitle: isEpisode ? (g.episodeTitle ?? "Pilot") : nil,
            seTag: isEpisode ? "S01E01" : nil, summary: "", year: 2000, originallyAvailableAt: nil, contentRating: nil,
            duration: isEpisode ? 45 : 120, ratingKey: g.id, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: g.genres ?? [], rating: 0, userRating: 0, type: isEpisode ? .episode : .movie,
            thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: g.tmdbID ?? g.id, imdbID: nil,
            librarySource: isEpisode ? .tv : .movie, showKey: isEpisode ? g.showKey : nil
        )
    }

    private func lookup(_ items: [GItem]) -> (PlexMediaItem) -> MediaEnrichment? {
        var map: [String: MediaEnrichment] = [:]
        for g in items {
            guard let e = g.enrichment else { continue }
            map[g.id] = MediaEnrichment(
                tmdbID: g.id, imdbID: nil, mediaType: g.type == "episode" ? "tv" : "movie",
                keywords: [], networks: [], productionCompanies: [], tmdbGenres: [],
                imdbRating: nil, imdbVotes: nil, rottenTomatoesScore: nil, metacriticScore: nil,
                awards: nil, franchiseID: e.franchiseID, franchiseName: e.franchiseName, fetchedAt: Date()
            )
        }
        return { map[$0.id] }
    }

    private func config() throws -> ChannelConfigResult {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        return try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
    }

    // MARK: - Running one lineup

    private func run(_ s: Lineup, config: ChannelConfigResult) -> Outcome {
        let items = s.items.map(item)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let enrich = lookup(s.items)

        let state = AppState()
        let franchiseChannelIDs = [100, 101, 102, 103, 104, 105, 106]
        state.bundles = [
            ChannelBundle(id: AppState.franchisesBundleID, name: "FRANCHISES", description: nil,
                          channelIDs: franchiseChannelIDs, activeMonths: nil, enabled: s.packageOn)
        ]
        state.enabledBundleIDs = s.packageOn ? [AppState.franchisesBundleID] : []
        state.enabledFranchiseIDs = Set(s.enabledFranchiseIDs)
        state.disabledFranchiseIDs = Set(s.disabledFranchiseIDs)
        state.allItems = items

        var memberships = ChannelMemberships.empty
        if let m = s.manifest {
            memberships = ChannelMemberships(version: 0, generated: "", items: m.items.mapValues {
                ChannelMemberships.Entry(channels: $0.channels, source: nil, name: nil, mediaType: nil, exclusive: $0.exclusive)
            })
        }
        state.channelMemberships = memberships
        state.exclusiveRules = s.exclusiveRules.map {
            ExclusiveRule(channelIDs: $0.channelIDs, genres: $0.genres ?? [], titleContains: $0.titleContains ?? [],
                          editorialTitles: $0.editorialTitles ?? [], manifestExclusive: $0.manifestExclusive ?? false,
                          type: $0.type.flatMap { MediaType(rawValue: $0) },
                          source: $0.source.flatMap { LibrarySource(rawValue: $0) })
        }

        // The classics in the lineup: channels.json's own definitions (rules, numbers,
        // names) with the pool each lineup states.
        state.allChannels = config.channels.compactMap { channel in
            guard let ids = s.stock[String(channel.id)] else { return nil }
            var ch = channel
            ch.itemPool = ids.compactMap { byID[$0] }
            return ch
        }

        // What scanCollections makes of each server collection. The classifier is the app's
        // own; the name match and the manifest overlap are the scan's inputs, stated by the
        // lineup (the web side recomputes them and checks it gets the same).
        state.discoveredCollections = s.collections.map { c in
            let members = c.members.compactMap { byID[$0] }
            let category = CollectionClassifier.classify(title: c.title, items: members, enrichmentFor: enrich)
            return DiscoveredCollection(
                id: c.id, title: c.title.uppercased(),
                movieCount: members.filter { $0.type == .movie }.count,
                items: members, enabled: s.enabledCollectionIDs.contains(c.id),
                matchedChannel: c.matchedChannel,
                contentOverlap: c.contentOverlap.map {
                    ContentOverlap(channelID: $0.channelID, channelName: "CH \($0.channelID)",
                                   overlapCount: $0.overlapCount, totalCount: $0.totalCount)
                },
                category: category)
        }

        state.rebuildFoundFranchises(enrichmentFor: enrich)
        state.materializeDynamicChannels()
        state.applyBundleFilter()

        let dynamic = state.allChannels.filter { ChannelIDSpace.isDynamic($0.id) }.sorted { $0.number < $1.number }
        func kind(_ id: Int) -> String {
            if id >= DynamicChannelBlock.otherCollections.idBase { return "otherCollection" }
            if id >= DynamicChannelBlock.collectionFranchises.idBase { return "franchiseCollection" }
            return "found"
        }
        var stockPools: [String: [String]] = [:]
        for ch in state.allChannels where ch.rules != nil { stockPools[String(ch.id)] = ch.itemPool.map(\.id) }
        var overCap: [String: Int] = [:]
        for (block, n) in state.dynamicChannelsOverCap where n > 0 { overCap[block.rawValue] = n }

        return Outcome(
            found: state.foundFranchises.map {
                Outcome.Found(id: $0.id, name: $0.name, covered: $0.coveredByChannelID, fromDictionary: $0.fromDictionary,
                             enabled: $0.enabled, movies: $0.movies.map(\.id), tvItems: $0.tvItems.map(\.id))
            },
            stockPools: stockPools,
            switchedOffStock: state.switchedOffStockFranchiseChannelIDs.sorted(),
            rows: state.franchiseListRows.map {
                Outcome.Row(id: $0.id, name: $0.name, countLabel: $0.countLabel, stockChannelID: $0.stockChannelID,
                           channelNumber: $0.channelNumber, enabled: $0.enabled)
            },
            collections: state.discoveredCollections.map {
                Outcome.Coll(id: $0.id, title: $0.title, category: $0.category.rawValue, foldedInto: $0.foldedIntoFranchise)
            },
            channels: dynamic.map {
                Outcome.Chan(number: $0.number, id: $0.id, name: $0.name, kind: kind($0.id), items: $0.itemPool.map(\.id))
            },
            overCap: overCap,
            guide: state.channels.map(\.number).filter { (300...499).contains($0) }
        )
    }

    // MARK: - The checks

    private var dump: URL? {
        ProcessInfo.processInfo.environment["NOSTALGEX_GOLDEN_DUMP"].map { URL(fileURLWithPath: $0) }
    }

    private struct Dump: Encodable {
        var classifier: [String] = []
        var blocks: [BlockOut] = []
        var lineups: [Outcome] = []
        struct BlockOut: Encodable { let kept: [String]; let skipped: Int }
    }

    /// One test, so the dump is whole and the three sections are written together.
    func testGoldenVectors() throws {
        let golden = try loadGolden()
        var out = Dump()

        for c in golden.classifier {
            let items = c.items.map(item)
            let got = CollectionClassifier.classify(title: c.title, items: items, enrichmentFor: lookup(c.items)).rawValue
            out.classifier.append(got)
            if dump == nil { XCTAssertEqual(got, c.expected, "classifier: \(c.name)") }
        }

        for b in golden.blocks {
            let r = DynamicChannelBlock.keptInDisplayOrder(b.entries, capacity: b.capacity,
                name: \.name, stableID: \.id, films: \.films)
            out.blocks.append(.init(kept: r.kept.map(\.id), skipped: r.skipped))
            if dump == nil {
                XCTAssertEqual(r.kept.map(\.id), b.kept, "block: \(b.name)")
                XCTAssertEqual(r.skipped, b.skipped, "block skipped: \(b.name)")
            }
        }

        let config = try config()
        for s in golden.lineups {
            let got = run(s, config: config)
            out.lineups.append(got)
            if dump == nil {
                let expected = try XCTUnwrap(s.expected, "lineup \(s.name) has no expected answer")
                XCTAssertEqual(got.found, expected.found, "found: \(s.name)")
                XCTAssertEqual(got.stockPools, expected.stockPools, "stock pools: \(s.name)")
                XCTAssertEqual(got.switchedOffStock, expected.switchedOffStock, "switched off: \(s.name)")
                XCTAssertEqual(got.rows, expected.rows, "rows: \(s.name)")
                XCTAssertEqual(got.collections, expected.collections, "collections: \(s.name)")
                XCTAssertEqual(got.channels, expected.channels, "channels: \(s.name)")
                XCTAssertEqual(got.overCap, expected.overCap, "over cap: \(s.name)")
                XCTAssertEqual(got.guide, expected.guide, "guide: \(s.name)")
            }
        }

        if let url = dump {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(out).write(to: url)
            print("[Plex90] GOLDEN: wrote \(url.path)")
        }
    }
}
