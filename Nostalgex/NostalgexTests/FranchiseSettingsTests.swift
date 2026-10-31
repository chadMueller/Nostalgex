import XCTest
@testable import Nostalgex

/// Phase 2 of the franchise bundle: the Settings wiring around `FranchiseChannelBuilder`.
/// Drives `AppState` directly with an injected enrichment lookup (no network, no server)
/// and checks the four things the UI relies on: a found franchise's switch persists,
/// ADD ALL / REMOVE ALL rebuild the lineup, the retired NOTABLE STARS state migrates,
/// and a server collection that IS a franchise is folded out of both lists.
@MainActor
final class FranchiseSettingsTests: XCTestCase {

    private let franchisesKey = AppState.enabledFranchisesKey
    private let bundlesKey = "nostalgex_enabled_bundles"
    private let collectionsKey = "nostalgex_enabled_collections"
    private var savedBundles: [String]?
    private var savedCollections: [String]?

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        savedBundles = d.stringArray(forKey: bundlesKey)
        savedCollections = d.stringArray(forKey: collectionsKey)
        d.removeObject(forKey: franchisesKey)
        d.removeObject(forKey: AppState.disabledFranchisesKey)
    }

    override func tearDown() {
        let d = UserDefaults.standard
        d.removeObject(forKey: franchisesKey)
        d.removeObject(forKey: AppState.disabledFranchisesKey)
        if let savedBundles { d.set(savedBundles, forKey: bundlesKey) } else { d.removeObject(forKey: bundlesKey) }
        if let savedCollections { d.set(savedCollections, forKey: collectionsKey) } else { d.removeObject(forKey: collectionsKey) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func movie(_ id: String, _ title: String) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2000, originallyAvailableAt: nil, contentRating: nil,
            duration: 120, ratingKey: id, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: id, imdbID: nil, librarySource: .movie
        )
    }

    private func episode(_ id: String, show: String) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: show, artist: nil, episodeTitle: "Pilot", seTag: "S01E01",
            summary: "", year: 2020, originallyAvailableAt: nil, contentRating: nil,
            duration: 45, ratingKey: id, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .episode, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: id, imdbID: nil, librarySource: .tv
        )
    }

    private func enrichment(franchiseID: Int?, franchiseName: String?) -> MediaEnrichment {
        MediaEnrichment(
            tmdbID: UUID().uuidString, imdbID: nil, mediaType: "movie",
            keywords: [], networks: [], productionCompanies: [], tmdbGenres: [],
            imdbRating: nil, imdbVotes: nil, rottenTomatoesScore: nil, metacriticScore: nil,
            awards: nil, franchiseID: franchiseID, franchiseName: franchiseName, fetchedAt: Date()
        )
    }

    private func lookup(_ table: [String: (Int, String)]) -> (PlexMediaItem) -> MediaEnrichment? {
        var map: [String: MediaEnrichment] = [:]
        for (id, pair) in table { map[id] = enrichment(franchiseID: pair.0, franchiseName: pair.1) }
        return { map[$0.id] }
    }

    private let wick = ["w1": "John Wick", "w2": "John Wick: Chapter 2", "w3": "John Wick: Chapter 3 - Parabellum"]
    private let hunger = ["h1": "The Hunger Games", "h2": "The Hunger Games: Catching Fire", "h3": "The Hunger Games: Mockingjay - Part 1"]
    private let spyKids = ["s1": "Spy Kids", "s2": "Spy Kids 2", "s3": "Spy Kids 3"]
    private let starWars = ["sw1": "Star Wars: Episode IV - A New Hope", "sw2": "Star Wars: Episode V - The Empire Strikes Back", "sw3": "Star Wars: Episode VI - Return of the Jedi"]
    private let hanks = ["t1": "Big", "t2": "Cast Away", "t3": "Forrest Gump"]

    private func films(_ table: [String: String]) -> [PlexMediaItem] {
        table.keys.sorted().map { movie($0, table[$0]!) }
    }

    /// The enrichment table for every fixture film: real TMDB collection ids where the
    /// dictionary has them, an invented one for Spy Kids, none for the actor set.
    private var fixtureLookup: (PlexMediaItem) -> MediaEnrichment? {
        var table: [String: (Int, String)] = [:]
        for id in wick.keys { table[id] = (404609, "John Wick Collection") }
        for id in hunger.keys { table[id] = (131635, "The Hunger Games Collection") }
        for id in spyKids.keys { table[id] = (99999, "Spy Kids Collection") }
        for id in starWars.keys { table[id] = (10, "Star Wars Collection") }
        return lookup(table)
    }

    /// An AppState with the stock FRANCHISES package on and (optionally) CH100 built.
    private func makeState(stockStarWars: Bool = false) -> AppState {
        let state = AppState()
        state.bundles = [
            ChannelBundle(id: AppState.franchisesBundleID, name: "FRANCHISES", description: nil,
                          channelIDs: [100, 101, 102, 103, 104, 105, 106], activeMonths: nil, enabled: true)
        ]
        state.enabledBundleIDs = [AppState.franchisesBundleID]
        state.discoveredCollections = []
        if stockStarWars {
            var ch = Channel(id: 100, number: 100, name: "STAR WARS", color: .blue, category: "franchise",
                             rules: ChannelRules(titleContains: ["Star Wars"]), timeRestrictions: nil, minItems: 3)
            ch.itemPool = films(starWars)
            state.allChannels = [ch]
        } else {
            state.allChannels = []
        }
        return state
    }

    private func collection(_ id: String, _ title: String, _ items: [PlexMediaItem],
                            category: CollectionCategory, enabled: Bool = true) -> DiscoveredCollection {
        DiscoveredCollection(id: id, title: title, movieCount: items.count, items: items,
                             enabled: enabled, matchedChannel: nil, contentOverlap: nil, category: category)
    }

    // MARK: - Persistence round-trip

    func testFoundFranchiseDefaultsOffAndItsSwitchPersistsAcrossRelaunch() {
        let state = makeState()
        state.allItems = films(wick)
        state.rebuildFoundFranchises(enrichmentFor: fixtureLookup)

        guard let found = state.listedFoundFranchises.first else {
            return XCTFail("John Wick should be found from three films")
        }
        XCTAssertEqual(found.id, "dict:JOHN WICK")
        XCTAssertEqual(found.countLabel, "3 movies")
        XCTAssertFalse(found.enabled, "found franchises default OFF")
        XCTAssertFalse(state.channels.contains { $0.name == "JOHN WICK" })

        state.toggleFranchise(found)

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: franchisesKey), ["dict:JOHN WICK"])
        XCTAssertTrue(state.channels.contains { $0.name == "JOHN WICK" && $0.rules == nil },
                      "toggling on puts the channel in the guide immediately")

        // A fresh AppState (relaunch) reads the key back and the rebuilt list honours it.
        let relaunched = makeState()
        XCTAssertTrue(relaunched.enabledFranchiseIDs.contains("dict:JOHN WICK"))
        relaunched.allItems = films(wick)
        relaunched.rebuildFoundFranchises(enrichmentFor: fixtureLookup)
        XCTAssertEqual(relaunched.listedFoundFranchises.first?.enabled, true)
        relaunched.materializeDynamicChannels()
        relaunched.applyBundleFilter()
        XCTAssertTrue(relaunched.channels.contains { $0.name == "JOHN WICK" })

        // Off again: key empties, channel leaves.
        state.toggleFranchise(state.listedFoundFranchises[0])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: franchisesKey), [])
        XCTAssertFalse(state.channels.contains { $0.name == "JOHN WICK" })
    }

    func testEnabledIDsPersistAsAPlainStringArray() {
        // A later iCloud sync carries this key as-is, so it must stay a flat [String].
        let state = makeState()
        state.allItems = films(wick) + films(hunger)
        state.rebuildFoundFranchises(enrichmentFor: fixtureLookup)
        state.setAllFoundFranchises(enabled: true)
        let stored = UserDefaults.standard.object(forKey: franchisesKey) as? [String]
        XCTAssertEqual(stored, ["dict:JOHN WICK", "dict:THE HUNGER GAMES"])
    }

    // MARK: - ADD ALL / REMOVE ALL

    func testAddAllThenRemoveAllRebuildTheLineup() {
        let state = makeState()
        state.allItems = films(wick) + films(hunger) + films(spyKids)
        state.rebuildFoundFranchises(enrichmentFor: fixtureLookup)
        XCTAssertEqual(state.listedFoundFranchises.map(\.name), ["JOHN WICK", "SPY KIDS", "THE HUNGER GAMES"])
        XCTAssertTrue(state.listedFoundFranchises.allSatisfy { !$0.enabled })

        state.setAllFoundFranchises(enabled: true)

        XCTAssertTrue(state.listedFoundFranchises.allSatisfy(\.enabled))
        let dynamic = state.channels.filter { $0.rules == nil }
        XCTAssertEqual(dynamic.map(\.name), ["JOHN WICK", "SPY KIDS", "THE HUNGER GAMES"])
        // Collection numbering convention: display numbers from the FRANCHISES range.
        XCTAssertEqual(dynamic.map(\.number), [310, 311, 312])
        XCTAssertEqual(dynamic.map(\.id), [1_000_000, 1_000_001, 1_000_002])
        XCTAssertEqual(Set(UserDefaults.standard.stringArray(forKey: franchisesKey) ?? []),
                       ["dict:JOHN WICK", "dict:THE HUNGER GAMES", "tmdb:99999"])

        // The found channels ride on the package switch.
        state.enabledBundleIDs.remove(AppState.franchisesBundleID)
        state.applyBundleFilter()
        XCTAssertTrue(state.channels.isEmpty, "package off hides every found franchise channel")
        state.enabledBundleIDs.insert(AppState.franchisesBundleID)
        state.applyBundleFilter()
        XCTAssertEqual(state.channels.count, 3)

        state.setAllFoundFranchises(enabled: false)

        XCTAssertTrue(state.listedFoundFranchises.allSatisfy { !$0.enabled })
        XCTAssertTrue(state.channels.filter { $0.rules == nil }.isEmpty)
        XCTAssertTrue(state.allChannels.filter { ChannelIDSpace.isDynamic($0.id) }.isEmpty)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: franchisesKey), [])
    }

    // MARK: - NOTABLE STARS retired

    func testRetiredActorsBundleIDMigratesToCustom() {
        let state = makeState()
        state.enabledBundleIDs = ["nostalgex", AppState.retiredActorsBundleID]

        state.migrateCollectionBundleIDs()

        XCTAssertFalse(state.enabledBundleIDs.contains(AppState.retiredActorsBundleID))
        XCTAssertTrue(state.enabledBundleIDs.contains(CollectionCategory.custom.bundleID))
        XCTAssertTrue(state.enabledBundleIDs.contains("nostalgex"))
        XCTAssertEqual(Set(UserDefaults.standard.stringArray(forKey: bundlesKey) ?? []),
                       ["nostalgex", CollectionCategory.custom.bundleID])
    }

    func testSnapshotRowFromTheActorsCategoryResolvesToCustomAndStillMaterialises() {
        // A snapshot written by an older build still carries "actors" rows.
        let row = StoredDiscoveredCollection(
            id: "c-hanks", title: "TOM HANKS", movieCount: 3,
            itemRatingKeys: ["t1", "t2", "t3"], enabled: true, matchedChannel: nil,
            categoryRaw: "actors"
        )
        let lookupByID = Dictionary(uniqueKeysWithValues: films(hanks).map { ($0.id, $0) })
        let resolved = row.resolve(itemLookup: lookupByID)
        XCTAssertEqual(resolved.category, .custom)
        XCTAssertEqual(resolved.items.count, 3)
        XCTAssertNil(resolved.foldedIntoFranchise)

        let state = makeState()
        state.enabledBundleIDs = [CollectionCategory.custom.bundleID]
        state.discoveredCollections = [resolved]
        state.materializeDynamicChannels()
        state.applyBundleFilter()
        let channel = state.channels.first { $0.name == "TOM HANKS" }
        XCTAssertNotNil(channel, "the collection is not lost, it moves to OTHER COLLECTIONS")
        XCTAssertEqual(channel?.category, CollectionCategory.custom.rawValue)
        XCTAssertEqual(channel?.number, CollectionCategory.custom.displayNumberBase)
        XCTAssertFalse(CollectionCategory.allCases.map(\.rawValue).contains("actors"))
    }

    func testClassifierNeverReturnsARetiredCategory() {
        for category in CollectionCategory.allCases {
            XCTAssertNotEqual(category.displayName, "NOTABLE STARS")
        }
        XCTAssertEqual(CollectionCategory.custom.displayName, "OTHER COLLECTIONS")
    }

    // MARK: - Fold

    func testCollectionThatIsAFranchiseIsHiddenFromBothLists() {
        let state = makeState(stockStarWars: true)
        state.allItems = films(starWars) + films(wick) + films(hanks)
        state.discoveredCollections = [
            collection("c-sw", "STAR WARS COLLECTION", films(starWars), category: .franchises),
            collection("c-wick", "JOHN WICK COLLECTION", films(wick), category: .franchises),
            collection("c-hanks", "TOM HANKS", films(hanks), category: .custom)
        ]

        state.rebuildFoundFranchises(enrichmentFor: fixtureLookup)

        // STAR WARS folds into the classic: not listed with a switch, shown as covered.
        XCTAssertEqual(state.listedFoundFranchises.map(\.name), ["JOHN WICK"])
        XCTAssertEqual(state.coveredFoundFranchises.map(\.name), ["STAR WARS"])
        XCTAssertEqual(state.coveredFoundFranchises.first?.coveredByChannelID, 100)

        // Both franchise collections fold; the actor set does not.
        let byID = Dictionary(uniqueKeysWithValues: state.discoveredCollections.map { ($0.id, $0) })
        XCTAssertEqual(byID["c-sw"]?.foldedIntoFranchise, "CH 100 STAR WARS")
        XCTAssertEqual(byID["c-wick"]?.foldedIntoFranchise, "JOHN WICK")
        XCTAssertNil(byID["c-hanks"]?.foldedIntoFranchise)
        XCTAssertEqual(state.visibleDiscoveredCollections.map(\.id), ["c-hanks"])

        // Even though both folded collections were switched on, neither becomes a channel.
        state.materializeDynamicChannels()
        state.applyBundleFilter()
        let dynamicNames = state.allChannels.filter { $0.rules == nil }.map(\.name)
        XCTAssertEqual(dynamicNames, ["TOM HANKS"])
        XCTAssertFalse(state.enabledBundleIDs.contains(CollectionCategory.franchises.bundleID),
                       "a category whose only collections folded does not get a bundle")

        // Turning the found franchise on yields exactly one JOHN WICK channel.
        state.toggleFranchise(state.listedFoundFranchises[0])
        XCTAssertEqual(state.allChannels.filter { $0.name == "JOHN WICK" }.count, 1)
        XCTAssertEqual(state.allChannels.filter { $0.name == "STAR WARS" }.count, 1, "only the classic")
    }

    func testFoldSurvivesTheSnapshotRoundTrip() {
        let items = films(wick)
        let folded = DiscoveredCollection(
            id: "c-wick", title: "JOHN WICK COLLECTION", movieCount: 3, items: items, enabled: true,
            matchedChannel: nil, contentOverlap: nil, category: .franchises, foldedIntoFranchise: "JOHN WICK"
        )
        let stored = StoredDiscoveredCollection.from(folded)
        XCTAssertEqual(stored.foldedIntoFranchise, "JOHN WICK")
        let lookupByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(stored.resolve(itemLookup: lookupByID).foldedIntoFranchise, "JOHN WICK")

        let franchise = FoundFranchise(id: "dict:JOHN WICK", name: "JOHN WICK", movies: items, tvItems: [],
                                       coveredByChannelID: nil, fromDictionary: true, enabled: true)
        let row = StoredFoundFranchise.from(franchise)
        let back = row.resolve(itemLookup: lookupByID, enabledIDs: ["dict:JOHN WICK"])
        XCTAssertEqual(back, franchise)
        XCTAssertFalse(row.resolve(itemLookup: lookupByID, enabledIDs: []).enabled)
    }

    func testTVJoinShowsInTheCountLabel() {
        let state = makeState()
        state.allItems = films(wick) + [episode("e1", show: "The Continental: From the World of John Wick"),
                                        episode("e2", show: "The Continental: From the World of John Wick")]
        state.rebuildFoundFranchises(enrichmentFor: fixtureLookup)
        XCTAssertEqual(state.listedFoundFranchises.first?.countLabel, "3 movies, 1 show")
        state.toggleFranchise(state.listedFoundFranchises[0])
        XCTAssertEqual(state.channels.first { $0.name == "JOHN WICK" }?.itemPool.count, 5)
    }

    // MARK: - Stock pools take what the builder placed on them

    /// CH100 with its real channels.json rule (`type: movie`), built through the same
    /// path the library load uses.
    private func starWarsConfigChannel() -> Channel {
        Channel(id: 100, number: 100, name: "STAR WARS", color: .blue, category: "franchise",
                rules: ChannelRules(type: .movie, titleContains: ["Star Wars"]),
                timeRestrictions: nil, minItems: 3)
    }

    private func marvelConfigChannel() -> Channel {
        Channel(id: 101, number: 101, name: "MARVEL", color: .red, category: "franchise",
                rules: ChannelRules(type: .movie, studios: ["Marvel Studios"]),
                timeRestrictions: nil, minItems: 3)
    }

    private func marvelFilm(_ id: String, _ title: String) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2012, originallyAvailableAt: nil, contentRating: nil,
            duration: 120, ratingKey: id, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: "Marvel Studios", tmdbID: id, imdbID: nil, librarySource: .movie
        )
    }

    private let mandalorian = ["m1", "m2"]

    /// Builds CH100 (and CH101 when asked) from their rules over `items`, then runs the
    /// franchise rebuild the way the library load does.
    private func buildStockLineup(_ state: AppState, items: [PlexMediaItem], marvel: Bool = false) async {
        state.allItems = items
        var config = [starWarsConfigChannel()]
        if marvel { config.append(marvelConfigChannel()) }
        state.allChannels = await state.rebuildStaticChannelPools(
            configChannels: config, items: items, onlyChannelIDs: Set(config.map(\.id))
        )
        state.rebuildFoundFranchises(enrichmentFor: fixtureLookup)
    }

    private func pool(_ state: AppState, _ channelID: Int) -> [String] {
        state.allChannels.first { $0.id == channelID }?.itemPool.map(\.id) ?? []
    }

    func testStarWarsPoolMixesTheFilmsAndTheMandalorian() async {
        let state = makeState()
        let items = films(starWars) + mandalorian.map { episode($0, show: "The Mandalorian") }

        // The rule alone: three films, no show.
        let ruleOnly = await state.rebuildStaticChannelPools(
            configChannels: [starWarsConfigChannel()], items: items, onlyChannelIDs: [100]
        )
        XCTAssertEqual(ruleOnly.first?.itemPool.map(\.id).sorted(), ["sw1", "sw2", "sw3"])

        await buildStockLineup(state, items: items)
        XCTAssertEqual(pool(state, 100).sorted(), ["m1", "m2", "sw1", "sw2", "sw3"])
        XCTAssertEqual(state.coveredFoundFranchises.first?.coveredLabel, "3 movies, 1 show on CH 100")

        // A second rebuild with no pool rebuild in between adds nothing twice.
        state.rebuildFoundFranchises(enrichmentFor: fixtureLookup)
        XCTAssertEqual(pool(state, 100).count, 5)

        // And the guide sees it.
        state.applyBundleFilter()
        XCTAssertEqual(state.channels.first { $0.id == 100 }?.itemPool.count, 5)
    }

    func testMarvelFilmsStayStudioRuledAndItsShowsJoinCH101() async {
        let state = makeState()
        let marvelFilms = [marvelFilm("mv1", "The Avengers"), marvelFilm("mv2", "Iron Man"),
                           marvelFilm("mv3", "Thor")]
        // A non-Marvel-studio film titled like a listed show must not join: films
        // never match MARVEL's title list.
        let items = films(starWars) + marvelFilms + [movie("echoFilm", "Echo")]
            + [episode("loki1", show: "Loki"), episode("loki2", show: "Loki"),
               episode("wi1", show: "What If...?"), episode("echo1", show: "Echo"),
               episode("ep1", show: "Echo Park")]
        await buildStockLineup(state, items: items, marvel: true)

        XCTAssertEqual(pool(state, 101).sorted(), ["echo1", "loki1", "loki2", "mv1", "mv2", "mv3", "wi1"])
        let marvel = state.foundFranchises.first { $0.coveredByChannelID == 101 }
        XCTAssertEqual(marvel?.name, "MARVEL")
        XCTAssertEqual(marvel?.movies.count, 0, "films stay with CH101's studio rule")
        XCTAssertEqual(marvel?.coveredLabel, "3 shows on CH 101")
        XCTAssertFalse(state.listedFoundFranchises.contains { $0.name == "MARVEL" },
                       "a stock fold has no switch of its own")

        // And the guide airs them.
        state.applyBundleFilter()
        XCTAssertEqual(state.channels.first { $0.id == 101 }?.itemPool.count, 7)
    }

    func testBundleOffMeansNoUnion() async {
        let state = makeState()
        state.enabledBundleIDs = []
        let items = films(starWars) + mandalorian.map { episode($0, show: "The Mandalorian") }
        await buildStockLineup(state, items: items)

        XCTAssertEqual(pool(state, 100).sorted(), ["sw1", "sw2", "sw3"])
    }

    func testItemLockedToAnotherChannelIsNotTaken() async {
        let state = makeState()
        // An exclusive rule owns The Mandalorian for CH130; a manifest lock owns one
        // Andor episode for CH60. The other Andor episode is free.
        state.exclusiveRules = [
            ExclusiveRule(channelIDs: [130], genres: [], titleContains: [],
                          editorialTitles: ["The Mandalorian"], manifestExclusive: false)
        ]
        state.channelMemberships = ChannelMemberships(
            version: 1, generated: "test",
            items: ["tv:a2": .init(channels: [60], source: nil, name: nil, mediaType: nil, exclusive: 60)]
        )
        let items = films(starWars)
            + mandalorian.map { episode($0, show: "The Mandalorian") }
            + [episode("a1", show: "Andor"), episode("a2", show: "Andor")]
        await buildStockLineup(state, items: items)

        XCTAssertEqual(pool(state, 100).sorted(), ["a1", "sw1", "sw2", "sw3"])
    }

    // MARK: - One franchise list: stock classics and found franchises together

    /// FRANCHISES on, CH100 and CH101 built from their rules, plus found franchises.
    private func listState() async -> AppState {
        let state = makeState()
        let marvelFilms = [marvelFilm("mv1", "The Avengers"), marvelFilm("mv2", "Iron Man"),
                           marvelFilm("mv3", "Thor")]
        let items = films(starWars) + marvelFilms + films(wick) + films(hunger)
            + [episode("loki1", show: "Loki"), episode("loki2", show: "Loki")]
        await buildStockLineup(state, items: items, marvel: true)
        state.materializeDynamicChannels()
        state.applyBundleFilter()
        return state
    }

    func testListIsAlphabeticalStockAndFoundTogetherWithChannelNumbers() async {
        let state = await listState()
        let rows = state.franchiseListRows
        // Every stock classic in the package is listed, built or not, plus the found ones.
        XCTAssertEqual(rows.map(\.name), [
            "HARRY POTTER", "JASON BOURNE", "JOHN WICK", "JURASSIC PARK", "LORD OF THE RINGS",
            "MARVEL", "MISSION IMPOSSIBLE", "STAR WARS", "THE HUNGER GAMES"
        ])
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        XCTAssertEqual(byName["STAR WARS"]?.channelNumber, 100)
        XCTAssertEqual(byName["STAR WARS"]?.enabled, true, "stock classics default on")
        XCTAssertEqual(byName["STAR WARS"]?.countLabel, "3 movies")
        XCTAssertEqual(byName["JOHN WICK"]?.channelNumber, nil)
        XCTAssertEqual(byName["JOHN WICK"]?.enabled, false, "found franchises still default off")
        XCTAssertEqual(byName["HARRY POTTER"]?.countLabel, "None in your library yet")
    }

    func testMarvelIsListedWithItsFilmsAndMCUShows() async {
        let state = await listState()
        let marvel = state.franchiseListRows.first { $0.name == "MARVEL" }
        XCTAssertEqual(marvel?.id, "dict:MARVEL")
        XCTAssertEqual(marvel?.stockChannelID, 101)
        XCTAssertEqual(marvel?.countLabel, "3 movies, 1 show")
    }

    func testSwitchingAStockClassicOffTakesItsChannelOutAndPersists() async {
        let state = await listState()
        XCTAssertTrue(state.channels.contains { $0.id == 100 })
        let starWarsRow = state.franchiseListRows.first { $0.name == "STAR WARS" }!

        state.toggleFranchiseRow(starWarsRow)

        XCTAssertFalse(state.channels.contains { $0.id == 100 }, "CH100 leaves the guide")
        XCTAssertTrue(state.channels.contains { $0.id == 101 }, "the other classics stay")
        XCTAssertTrue(state.allChannels.contains { $0.id == 100 }, "built, just not shown")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AppState.disabledFranchisesKey), ["dict:STAR WARS"])
        XCTAssertEqual(state.franchiseListRows.first { $0.name == "STAR WARS" }?.enabled, false)

        // Relaunch: the choice is read back and the bundle filter honours it.
        let relaunched = makeState(stockStarWars: true)
        relaunched.applyBundleFilter()
        XCTAssertFalse(relaunched.channels.contains { $0.id == 100 })

        // Back on.
        state.toggleFranchiseRow(state.franchiseListRows.first { $0.name == "STAR WARS" }!)
        XCTAssertTrue(state.channels.contains { $0.id == 100 })
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AppState.disabledFranchisesKey), [])
    }

    func testAddAllAndRemoveAllCoverTheWholeList() async {
        let state = await listState()

        state.setAllFranchises(enabled: false)
        XCTAssertTrue(state.franchiseListRows.allSatisfy { !$0.enabled })
        XCTAssertFalse(state.channels.contains { $0.id == 100 || $0.id == 101 })
        XCTAssertTrue(state.channels.filter { $0.rules == nil }.isEmpty)

        state.setAllFranchises(enabled: true)
        XCTAssertTrue(state.franchiseListRows.allSatisfy(\.enabled))
        XCTAssertTrue(state.channels.contains { $0.id == 100 })
        XCTAssertTrue(state.channels.contains { $0.id == 101 })
        XCTAssertEqual(Set(state.channels.filter { $0.rules == nil }.map(\.name)), ["JOHN WICK", "THE HUNGER GAMES"])
    }

    func testAStockChoiceFromAnotherAppleTVChangesTheGuide() async {
        let state = await listState()
        state.applyEnabledFranchiseIDs([], disabled: ["dict:MARVEL"])
        XCTAssertFalse(state.channels.contains { $0.id == 101 })
        state.applyEnabledFranchiseIDs([], disabled: [])
        XCTAssertTrue(state.channels.contains { $0.id == 101 })
    }

    func testMCUSpiderManFilmsCountOnSpiderManNotAlsoOnMarvel() async {
        let state = makeState()
        let mcu = [marvelFilm("sm1", "Spider-Man: Homecoming"), marvelFilm("sm2", "Spider-Man: Far From Home"),
                   marvelFilm("sm3", "Spider-Man: No Way Home")]
        let others = [marvelFilm("mv1", "The Avengers"), marvelFilm("mv2", "Iron Man")]
        let raimi = [movie("r1", "Spider-Man (2002)")]
        let items = films(starWars) + mcu + others + raimi
        state.allItems = items
        state.allChannels = await state.rebuildStaticChannelPools(
            configChannels: [starWarsConfigChannel(), marvelConfigChannel()], items: items, onlyChannelIDs: [100, 101]
        )
        var table: [String: (Int, String)] = [:]
        for id in ["sm1", "sm2", "sm3"] { table[id] = (531241, "Spider-Man (MCU) Collection") }
        table["r1"] = (556, "Spider-Man Collection")
        state.rebuildFoundFranchises(enrichmentFor: lookup(table))

        XCTAssertEqual(pool(state, 101).count, 5, "CH101's studio rule still airs all five")
        let rows = Dictionary(uniqueKeysWithValues: state.franchiseListRows.map { ($0.name, $0) })
        XCTAssertEqual(rows["SPIDER-MAN"]?.countLabel, "4 movies")
        XCTAssertEqual(rows["MARVEL"]?.countLabel, "2 movies", "the MCU Spider-Man films are counted once")
    }

    func testMergedFoundFranchiseIsOneRow() {
        let state = makeState()
        let pie = ["p1": "American Pie", "p2": "American Pie 2"]
        let spin = ["q1": "American Pie Presents: Band Camp", "q2": "American Pie Presents: The Naked Mile"]
        state.allItems = films(pie) + films(spin)
        var table: [String: (Int, String)] = [:]
        for id in pie.keys { table[id] = (2806, "American Pie Collection") }
        for id in spin.keys { table[id] = (298820, "American Pie (Spin-off) Collection") }
        state.rebuildFoundFranchises(enrichmentFor: lookup(table))
        let found = state.franchiseListRows.filter { !$0.isStock }
        XCTAssertEqual(found.map(\.name), ["AMERICAN PIE"])
        XCTAssertEqual(found.first?.id, "tmdb:2806")
        XCTAssertEqual(found.first?.countLabel, "4 movies")
    }
}
