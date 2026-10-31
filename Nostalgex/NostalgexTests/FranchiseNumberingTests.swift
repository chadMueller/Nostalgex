import XCTest
@testable import Nostalgex

/// Display numbers for runtime channels, and the franchises that start switched on.
///
/// Found franchises used to number from 220 and custom collections from 260. A library
/// with 86 franchises under ADD ALL ran the franchise numbers through 305, so two rows
/// showed the same number and interleaved in the guide. Then found franchises and the
/// server's franchise collections shared 300-499 on one id base, collections numbered after
/// the found ones, so the FRANCHISES package moved them. Then each kind got a fixed block:
/// found franchises 300-449, franchise collections 450-499, other collections 500-699.
/// Since 1.0.29 each sits in its own hundred beside the channels.json blocks: found
/// franchises 310-399 (after the stock FRANCHISES package at 300-309), franchise
/// collections 400-449, other collections 450-499, and HIGH ROTATION alone from 500.
@MainActor
final class FranchiseNumberingTests: XCTestCase {

    private let enabledKey = AppState.enabledFranchisesKey
    private let disabledKey = AppState.disabledFranchisesKey
    private let collectionsKey = "nostalgex_enabled_collections"
    private let bundlesKey = "nostalgex_enabled_bundles"
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        for key in [enabledKey, disabledKey, collectionsKey, bundlesKey] {
            if let v = d.object(forKey: key) { saved[key] = v }
            d.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let d = UserDefaults.standard
        for key in [enabledKey, disabledKey, collectionsKey, bundlesKey] {
            if let v = saved[key] { d.set(v, forKey: key) } else { d.removeObject(forKey: key) }
        }
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

    private func films(_ prefix: String, _ count: Int = 3) -> [PlexMediaItem] {
        (1...count).map { movie("\(prefix)-\($0)", "\(prefix) \($0)") }
    }

    private func franchise(_ i: Int, enabled: Bool = true, films count: Int = 3,
                           coveredBy: Int? = nil) -> FoundFranchise {
        FoundFranchise(id: "tmdb:\(10_000 + i)", name: String(format: "FRANCHISE %03d", i),
                       movies: films("f\(i)", count), tvItems: [], coveredByChannelID: coveredBy,
                       fromDictionary: false, enabled: enabled)
    }

    private func collection(_ id: String, category: CollectionCategory, enabled: Bool = true,
                            films count: Int = 3) -> DiscoveredCollection {
        let items = films(id, count)
        return DiscoveredCollection(id: id, title: id.uppercased(), movieCount: items.count, items: items,
                                    enabled: enabled, matchedChannel: nil, contentOverlap: nil, category: category)
    }

    private func makeState() -> AppState {
        let state = AppState()
        state.bundles = [
            ChannelBundle(id: AppState.franchisesBundleID, name: "FRANCHISES", description: nil,
                          channelIDs: [100, 101, 102, 103, 104, 105, 106], activeMonths: nil, enabled: true)
        ]
        state.enabledBundleIDs = [AppState.franchisesBundleID]
        state.allChannels = []
        state.discoveredCollections = []
        return state
    }

    private func shippedStaticNumbers() throws -> Set<Int> {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let config = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        return Set(config.channels.map(\.number))
    }

    private func inBlock(_ state: AppState, _ block: DynamicChannelBlock) -> [Channel] {
        state.allChannels.filter { (block.idBase..<(block.idBase + ChannelIDSpace.categoryStride)).contains($0.id) }
            .sorted { $0.number < $1.number }
    }

    private func numbers(_ state: AppState, _ block: DynamicChannelBlock) -> [Int] {
        inBlock(state, block).map(\.number)
    }

    private func numbers(_ state: AppState, _ category: CollectionCategory) -> [Int] {
        numbers(state, category.block)
    }

    // MARK: - Ranges

    func testRangesSitClearOfEveryShippedNumber() throws {
        let staticNumbers = try shippedStaticNumbers()
        for block in DynamicChannelBlock.allCases {
            let inside = staticNumbers.filter { (block.displayNumberBase...block.displayNumberEnd).contains($0) }
            XCTAssertTrue(inside.isEmpty, "channels.json now reaches the \(block) range: \(inside.sorted())")
        }
        XCTAssertEqual(DynamicChannelBlock.foundFranchises.displayNumberBase, 310)
        XCTAssertEqual(DynamicChannelBlock.foundFranchises.displayNumberEnd, 399)
        XCTAssertEqual(DynamicChannelBlock.collectionFranchises.displayNumberBase, 400)
        XCTAssertEqual(DynamicChannelBlock.collectionFranchises.displayNumberEnd, 449)
        XCTAssertEqual(DynamicChannelBlock.otherCollections.displayNumberBase, 450)
        XCTAssertEqual(DynamicChannelBlock.otherCollections.displayNumberEnd, 499)
        XCTAssertEqual(DynamicChannelBlock.allCases.map(\.capacity), [90, 50, 50])
        let ordered = DynamicChannelBlock.allCases.sorted { $0.displayNumberBase < $1.displayNumberBase }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(a.displayNumberEnd, b.displayNumberBase, "\(a) and \(b) overlap")
        }
    }

    func testEachKindHasItsOwnFixedIDBase() {
        XCTAssertEqual(DynamicChannelBlock.foundFranchises.idBase, 1_000_000, "found franchises keep their ids")
        XCTAssertEqual(DynamicChannelBlock.collectionFranchises.idBase, 1_010_000)
        XCTAssertEqual(DynamicChannelBlock.otherCollections.idBase, 1_020_000, "what the web tuner uses")
        XCTAssertEqual(CollectionCategory.franchises.block, .collectionFranchises)
        XCTAssertEqual(CollectionCategory.custom.block, .otherCollections)
    }

    func testEightySixFranchisesNumber310Through395AndCollectionsKeepTheirOwnBlocks() throws {
        let state = makeState()
        state.foundFranchises = (0..<86).map { franchise($0) }
        state.discoveredCollections = [
            collection("saga-a", category: .franchises), collection("saga-b", category: .franchises),
            collection("hanks", category: .custom), collection("nolan", category: .custom),
            collection("off", category: .custom, enabled: false)
        ]

        state.materializeDynamicChannels()

        let found = state.allChannels.filter { state.foundFranchiseChannelIDs.contains($0.id) }.map(\.number)
        XCTAssertEqual(found, Array(310...395))
        XCTAssertEqual(numbers(state, .foundFranchises), Array(310...395))
        XCTAssertEqual(inBlock(state, .collectionFranchises).map(\.name), ["SAGA-A", "SAGA-B"])
        XCTAssertEqual(numbers(state, .collectionFranchises), [400, 401])
        XCTAssertEqual(inBlock(state, .collectionFranchises).map(\.id), [1_010_000, 1_010_001])
        XCTAssertEqual(numbers(state, .otherCollections), [450, 451])

        // No duplicate number anywhere: runtime numbers are unique and none lands on a
        // number channels.json uses.
        let dynamic = state.allChannels.filter { ChannelIDSpace.isDynamic($0.id) }.map(\.number)
        XCTAssertEqual(Set(dynamic).count, dynamic.count)
        XCTAssertTrue(Set(dynamic).isDisjoint(with: try shippedStaticNumbers()))
        XCTAssertEqual(state.dynamicChannelsOverCap, [:])

        // The guide order is by number, so each kind runs as one contiguous block.
        XCTAssertEqual(state.allChannels.map(\.number), state.allChannels.map(\.number).sorted())
    }

    // MARK: - Numbers that don't move with packages

    private func collectionChannels(_ state: AppState) -> [String: [Int]] {
        Dictionary(uniqueKeysWithValues: (inBlock(state, .collectionFranchises) + inBlock(state, .otherCollections))
            .map { ($0.name, [$0.id, $0.number]) })
    }

    func testFranchiseCollectionsDoNotMoveWhenFoundFranchisesChange() {
        let state = makeState()
        state.enabledBundleIDs.formUnion([CollectionCategory.franchises.bundleID, CollectionCategory.custom.bundleID])
        state.discoveredCollections = [
            collection("alien saga", category: .franchises), collection("mad max", category: .franchises),
            collection("hanks", category: .custom)
        ]
        // FRANCHISES package off: nothing found is built.
        state.foundFranchises = []
        state.materializeDynamicChannels()
        let baseline = collectionChannels(state)
        XCTAssertEqual(baseline["ALIEN SAGA"], [1_010_000, 400])
        XCTAssertEqual(baseline["MAD MAX"], [1_010_001, 401])
        XCTAssertEqual(baseline["HANKS"], [1_020_000, 450])

        // Package on, 64 found (Chad's library).
        state.foundFranchises = (0..<64).map { franchise($0) }
        state.materializeDynamicChannels()
        XCTAssertEqual(collectionChannels(state), baseline)

        // One found franchise switched off through the real toggle.
        state.toggleFranchise(state.foundFranchises[10])
        XCTAssertEqual(collectionChannels(state), baseline)
        XCTAssertEqual(numbers(state, .foundFranchises), Array(310...372))

        // Stock channels arrive (package on with its classics), covering some found ones.
        state.foundFranchises = (0..<64).map { franchise($0, coveredBy: $0 < 5 ? 100 + $0 : nil) }
        state.materializeDynamicChannels()
        XCTAssertEqual(collectionChannels(state), baseline)

        // A full found block still leaves them alone.
        state.foundFranchises = (0..<170).map { franchise($0) }
        state.materializeDynamicChannels()
        XCTAssertEqual(collectionChannels(state), baseline)
    }

    func testFoundFranchisesKeepTheirIDs() {
        let state = makeState()
        state.foundFranchises = (0..<3).map { franchise($0) }
        state.materializeDynamicChannels()
        XCTAssertEqual(inBlock(state, .foundFranchises).map(\.id), [1_000_000, 1_000_001, 1_000_002])
    }

    // MARK: - Full blocks

    func testFoundFranchiseRangeIsCappedAt399AndKeepsTheBiggest() {
        let state = makeState()
        // 100 on: 10 too many. The ten smallest (3 films) wait; numbering stays A to Z.
        state.foundFranchises = (0..<100).map { franchise($0, films: $0 % 10 == 0 ? 3 : 4) }
        state.discoveredCollections = [
            collection("saga-a", category: .franchises), collection("hanks", category: .custom)
        ]

        state.materializeDynamicChannels()

        let kept = inBlock(state, .foundFranchises)
        XCTAssertEqual(kept.count, 90)
        XCTAssertEqual(kept.first?.number, 310)
        XCTAssertEqual(kept.last?.number, 399)
        XCTAssertEqual(kept.map(\.name), kept.map(\.name).sorted(), "A to Z")
        XCTAssertFalse(kept.contains { $0.name == "FRANCHISE 000" || $0.name == "FRANCHISE 090" },
                       "the 3-film ones are the ones left out")
        XCTAssertEqual(state.dynamicChannelsOverCap[.foundFranchises], 10)
        XCTAssertNil(state.dynamicChannelsOverCap[.collectionFranchises])
        XCTAssertEqual(numbers(state, .collectionFranchises), [400], "franchise collections keep their numbers")
        XCTAssertEqual(numbers(state, .otherCollections), [450], "collections keep their own numbers")

        // Switching some off frees the range and the counter clears.
        for i in 0..<15 { state.foundFranchises[i].enabled = false }
        state.materializeDynamicChannels()
        XCTAssertEqual(state.dynamicChannelsOverCap, [:])
        XCTAssertEqual(numbers(state, .foundFranchises).last, 394)
    }

    func testFranchiseCollectionRangeIsCappedAt449AndKeepsTheBiggest() {
        let state = makeState()
        state.enabledBundleIDs.insert(CollectionCategory.franchises.bundleID)
        // 53 on; three have 3 films, the rest 5. Ties on films go by name, then id.
        state.discoveredCollections = (0..<53).map { i in
            collection(String(format: "saga-%02d", i), category: .franchises, films: [7, 20, 41].contains(i) ? 3 : 5)
        }

        state.materializeDynamicChannels()

        let kept = inBlock(state, .collectionFranchises)
        XCTAssertEqual(kept.count, 50)
        XCTAssertEqual(kept.map(\.number), Array(400...449))
        XCTAssertEqual(kept.map(\.id), Array(1_010_000...1_010_049))
        XCTAssertFalse(kept.contains { ["SAGA-07", "SAGA-20", "SAGA-41"].contains($0.name) })
        XCTAssertEqual(kept.map(\.name), kept.map(\.name).sorted())
        XCTAssertEqual(state.dynamicChannelsOverCap[.collectionFranchises], 3)
        XCTAssertEqual(numbers(state, .foundFranchises), [], "nothing spills into 310-399")
        XCTAssertEqual(numbers(state, .otherCollections), [], "or into 450")
    }

    func testOverflowOrderIsFilmsThenNameThenStableID() {
        struct Entry { let id: String; let name: String; let films: Int }
        let entries = [
            Entry(id: "b", name: "SAME", films: 4), Entry(id: "a", name: "SAME", films: 4),
            Entry(id: "z", name: "ZED", films: 9), Entry(id: "c", name: "ALPHA", films: 4),
            Entry(id: "d", name: "SMALL", films: 2)
        ]
        let result = DynamicChannelBlock.keptInDisplayOrder(entries, capacity: 3,
            name: \.name, stableID: \.id, films: \.films)
        // Kept: ZED (9 films), then the 4-film ties by name: ALPHA, SAME(a). SAME(b) and SMALL wait.
        XCTAssertEqual(result.kept.map(\.id), ["c", "a", "z"], "numbered A to Z, id breaking the name tie")
        XCTAssertEqual(result.skipped, 2)

        // Under capacity nothing is dropped and the order is A to Z.
        let all = DynamicChannelBlock.keptInDisplayOrder(entries, capacity: 10,
            name: \.name, stableID: \.id, films: \.films)
        XCTAssertEqual(all.kept.map(\.id), ["c", "a", "b", "d", "z"])
        XCTAssertEqual(all.skipped, 0)
        // Input order never matters.
        let reversed = DynamicChannelBlock.keptInDisplayOrder(Array(entries.reversed()), capacity: 3,
            name: \.name, stableID: \.id, films: \.films)
        XCTAssertEqual(reversed.kept.map(\.id), ["c", "a", "z"])
    }

    func testCollectionRangeIsCappedAt499() {
        let state = makeState()
        state.enabledBundleIDs.insert(CollectionCategory.custom.bundleID)
        state.discoveredCollections = (0..<53).map { collection(String(format: "set-%03d", $0), category: .custom) }

        state.materializeDynamicChannels()

        let custom = numbers(state, .custom)
        XCTAssertEqual(custom.count, 50)
        XCTAssertEqual(custom.first, 450)
        XCTAssertEqual(custom.last, 499)
        XCTAssertEqual(state.dynamicChannelsOverCap[.otherCollections], 3)
        // Unchanged rule, the one the web tuner mirrors: the first 50 A to Z.
        XCTAssertEqual(inBlock(state, .otherCollections).last?.name, "SET-049")
    }

    // MARK: - Saved choices survive the renumber

    func testSavedChoicesAreKeyedByIDSoTheyComeBackOnTheNewNumbers() {
        // What an older build left behind: ids, never numbers.
        UserDefaults.standard.set(["tmdb:10001", "tmdb:10003"], forKey: enabledKey)
        UserDefaults.standard.set(["hanks"], forKey: collectionsKey)

        let state = makeState()
        XCTAssertEqual(state.enabledFranchiseIDs, ["tmdb:10001", "tmdb:10003"])
        // A runtime row restored from an old snapshot still carries its old number.
        state.allChannels = [Channel(id: CollectionCategory.franchises.idBase, number: 221, name: "FRANCHISE 001",
                                     color: .blue, category: CollectionCategory.franchises.rawValue,
                                     rules: nil, timeRestrictions: nil, minItems: 3)]
        // Rebuilt lists resolve enabled state from the saved ids, the way the scan does.
        state.foundFranchises = (0..<4).map { i in
            franchise(i, enabled: FranchiseDictionary.isOn("tmdb:\(10_000 + i)",
                                                           enabledIDs: state.enabledFranchiseIDs,
                                                           disabledIDs: state.disabledFranchiseIDs))
        }
        state.discoveredCollections = [
            collection("hanks", category: .custom, enabled: state.enabledCollectionKeys.contains("hanks")),
            collection("nolan", category: .custom, enabled: state.enabledCollectionKeys.contains("nolan"))
        ]

        state.materializeDynamicChannels()

        let dynamic = state.allChannels.filter { ChannelIDSpace.isDynamic($0.id) }
        XCTAssertEqual(dynamic.map(\.name), ["FRANCHISE 001", "FRANCHISE 003", "HANKS"])
        XCTAssertEqual(dynamic.map(\.number), [310, 311, 450])
        XCTAssertFalse(state.allChannels.contains { $0.number == 221 }, "the stale row is gone")

        // The snapshot row path agrees.
        let row = StoredFoundFranchise.from(franchise(3))
        XCTAssertTrue(row.resolve(itemLookup: [:], enabledIDs: state.enabledFranchiseIDs).enabled)
    }

    // MARK: - Default-on franchises

    private func enrichment(_ fid: Int, _ name: String) -> MediaEnrichment {
        MediaEnrichment(
            tmdbID: UUID().uuidString, imdbID: nil, mediaType: "movie",
            keywords: [], networks: [], productionCompanies: [], tmdbGenres: [],
            imdbRating: nil, imdbVotes: nil, rottenTomatoesScore: nil, metacriticScore: nil,
            awards: nil, franchiseID: fid, franchiseName: name, fetchedAt: Date()
        )
    }

    private var trek: [PlexMediaItem] {
        [movie("st1", "Star Trek: The Motion Picture"), movie("st2", "Star Trek II: The Wrath of Khan"),
         movie("st3", "Star Trek III: The Search for Spock")]
    }
    private var fast: [PlexMediaItem] {
        [movie("ff1", "The Fast and the Furious"), movie("ff2", "2 Fast 2 Furious"), movie("ff3", "Fast Five")]
    }
    private var wick: [PlexMediaItem] {
        [movie("w1", "John Wick"), movie("w2", "John Wick: Chapter 2"),
         movie("w3", "John Wick: Chapter 3 - Parabellum")]
    }

    private var lookup: (PlexMediaItem) -> MediaEnrichment? {
        var map: [String: MediaEnrichment] = [:]
        for m in trek { map[m.id] = enrichment(151, "Star Trek: The Original Series Collection") }
        for m in fast { map[m.id] = enrichment(9485, "The Fast and the Furious Collection") }
        for m in wick { map[m.id] = enrichment(404609, "John Wick Collection") }
        return { map[$0.id] }
    }

    private func onNames(_ state: AppState) -> [String] {
        state.listedFoundFranchises.filter(\.enabled).map(\.name).sorted()
    }

    func testDictionaryMarksStarTrekAndFastAndFuriousDefaultOn() {
        XCTAssertEqual(FranchiseDictionary.defaultOnIDs, ["dict:STAR TREK", "dict:FAST & FURIOUS"])
    }

    func testStarTrekAndFastAndFuriousStartOnEverythingElseOff() {
        let state = makeState()
        state.allItems = trek + fast + wick
        state.rebuildFoundFranchises(enrichmentFor: lookup)
        state.materializeDynamicChannels()
        state.applyBundleFilter()

        XCTAssertEqual(onNames(state), ["FAST & FURIOUS", "STAR TREK"])
        XCTAssertEqual(state.listedFoundFranchises.first { $0.name == "JOHN WICK" }?.enabled, false)
        XCTAssertTrue(state.channels.contains { $0.name == "STAR TREK" })
        XCTAssertTrue(state.channels.contains { $0.name == "FAST & FURIOUS" })
        XCTAssertFalse(state.channels.contains { $0.name == "JOHN WICK" })
        // A default is not a choice: nothing is written until the viewer acts.
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: enabledKey))
    }

    func testStarTrekSwitchedOffStaysOffAcrossRelaunchAndRescan() {
        let state = makeState()
        state.allItems = trek + fast + wick
        state.rebuildFoundFranchises(enrichmentFor: lookup)
        let star = state.listedFoundFranchises.first { $0.name == "STAR TREK" }!

        state.toggleFranchise(star)

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: disabledKey), ["dict:STAR TREK"])
        XCTAssertFalse(state.channels.contains { $0.name == "STAR TREK" })

        // Rescan on the same TV.
        state.rebuildFoundFranchises(enrichmentFor: lookup)
        XCTAssertEqual(onNames(state), ["FAST & FURIOUS"])

        // Relaunch.
        let relaunched = makeState()
        relaunched.allItems = trek + fast + wick
        relaunched.rebuildFoundFranchises(enrichmentFor: lookup)
        XCTAssertEqual(onNames(relaunched), ["FAST & FURIOUS"])

        // Snapshot restore path agrees.
        let row = StoredFoundFranchise.from(star)
        XCTAssertFalse(row.resolve(itemLookup: [:], enabledIDs: relaunched.enabledFranchiseIDs,
                                   disabledIDs: relaunched.disabledFranchiseIDs).enabled)
        XCTAssertTrue(row.resolve(itemLookup: [:], enabledIDs: []).enabled, "default on with no choice recorded")

        // Back on: the off record clears.
        relaunched.toggleFranchise(relaunched.listedFoundFranchises.first { $0.name == "STAR TREK" }!)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: disabledKey), [])
        XCTAssertEqual(onNames(relaunched), ["FAST & FURIOUS", "STAR TREK"])
    }

    func testAddAllAndRemoveAllStillWorkWithDefaults() {
        let state = makeState()
        state.allItems = trek + fast + wick
        state.rebuildFoundFranchises(enrichmentFor: lookup)

        state.setAllFoundFranchises(enabled: false)
        XCTAssertEqual(onNames(state), [])
        XCTAssertTrue(state.channels.filter { $0.rules == nil }.isEmpty)

        let relaunched = makeState()
        relaunched.allItems = trek + fast + wick
        relaunched.rebuildFoundFranchises(enrichmentFor: lookup)
        XCTAssertEqual(onNames(relaunched), [], "REMOVE ALL holds the defaults off too")

        relaunched.setAllFoundFranchises(enabled: true)
        XCTAssertEqual(onNames(relaunched), ["FAST & FURIOUS", "JOHN WICK", "STAR TREK"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: disabledKey), [])
        XCTAssertEqual(relaunched.channels.filter { $0.rules == nil }.map(\.number), [310, 311, 312])
    }

    func testNoChannelWhenTheLibraryHasNoneOfThem() {
        let state = makeState()
        state.allItems = wick + [trek[0], fast[0]]   // one film each: under the three-film gate
        state.rebuildFoundFranchises(enrichmentFor: lookup)
        state.materializeDynamicChannels()
        state.applyBundleFilter()

        XCTAssertEqual(state.listedFoundFranchises.map(\.name), ["JOHN WICK"])
        XCTAssertFalse(state.channels.contains { $0.name == "STAR TREK" || $0.name == "FAST & FURIOUS" })
    }
}
