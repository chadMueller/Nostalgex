import XCTest
@testable import Nostalgex

/// Server collections that hold shows. A collection of shows used to be skipped because
/// the scan matched children against films only; it now expands each show to the episodes
/// the library load already holds and airs them like a TV channel. The child shapes are
/// the ones measured on real servers (see CollectionMemberIndex).
@MainActor
final class CollectionShowsTests: XCTestCase {

    // MARK: - Fixtures

    private func film(_ key: String, _ title: String, server: String? = nil) -> PlexMediaItem {
        PlexMediaItem(
            id: PlexAPIService.compositeID(serverID: server ?? "", ratingKey: key), title: title,
            artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: 2000,
            originallyAvailableAt: nil, contentRating: "PG-13", duration: 100, ratingKey: key,
            partKey: nil, container: "mp4", videoCodec: "h264", audioCodec: "aac", videoProfile: nil,
            bitrate: 4000, genres: ["Drama"], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie,
            serverID: server)
    }

    /// `showKey: nil` is an episode restored from a snapshot written before the field.
    private func episode(_ key: String, show: String, showKey: String?, season: Int, number: Int,
                         server: String? = nil, minutes: Int = 22) -> PlexMediaItem {
        var item = PlexMediaItem(
            id: PlexAPIService.compositeID(serverID: server ?? "", ratingKey: key), title: show,
            artist: nil, episodeTitle: "\(show) \(season)x\(number)",
            seTag: String(format: "S%02dE%02d", season, number), summary: "", year: 2001,
            originallyAvailableAt: nil, contentRating: "TV-PG", duration: minutes, ratingKey: key,
            partKey: nil, container: "mp4", videoCodec: "h264", audioCodec: "aac", videoProfile: nil,
            bitrate: 2000, genres: ["Reality"], rating: 0, userRating: 0, type: .episode, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .tv,
            serverID: server)
        item.showKey = showKey
        return item
    }

    /// `count` episodes of one show, keys "<showKey>-e<n>", over seasons of 4.
    private func episodes(of show: String, showKey: String, count: Int, stampShowKey: Bool = true) -> [PlexMediaItem] {
        (0..<count).map { i in
            episode("\(showKey)-e\(i + 1)", show: show, showKey: stampShowKey ? showKey : nil,
                    season: i / 4 + 1, number: i % 4 + 1)
        }
    }

    // MARK: - CollectionMemberIndex

    /// Plex and Jellyfin: the collection lists the shows; each expands to its episodes.
    func testShowKeysExpandToEveryEpisode() {
        let alpha = episodes(of: "Alpha Island", showKey: "s1", count: 4)
        let bravo = episodes(of: "Bravo Kitchen", showKey: "s2", count: 5)
        let index = CollectionMemberIndex(items: alpha + bravo + [film("m1", "Delta Run")])
        let members = index.resolve(["s1", "s2"])
        XCTAssertEqual(members.map(\.id), (alpha + bravo).map(\.id))
        XCTAssertEqual(members.collectionMovieCount, 0)
        XCTAssertEqual(members.collectionShowCount, 2)
    }

    /// Emby 4.10 answers the same BoxSet query with the episodes themselves. They match by
    /// key, even on items restored from an old snapshot that carry no show key.
    func testEpisodeChildrenMatchByKeyWithoutShowKey() {
        let alpha = episodes(of: "Alpha Island", showKey: "s1", count: 4, stampShowKey: false)
        let index = CollectionMemberIndex(items: alpha)
        let members = index.resolve(alpha.map(\.ratingKey))
        XCTAssertEqual(members.map(\.id), alpha.map(\.id))
        XCTAssertEqual(members.collectionShowCount, 1, "falls back to the show title")
    }

    /// A Jellyfin BoxSet holding films and a series.
    func testMixedCollectionHoldsFilmsAndEpisodes() {
        let films = [film("m1", "Delta Run"), film("m2", "Echo Point")]
        let lima = episodes(of: "Hotel Lima", showKey: "s4", count: 2)
        let index = CollectionMemberIndex(items: films + lima)
        let members = index.resolve(["m1", "m2", "s4"])
        XCTAssertEqual(members.map(\.id), (films + lima).map(\.id))
        XCTAssertEqual(DiscoveredCollection.memberSummary(
            movies: members.collectionMovieCount, shows: members.collectionShowCount,
            episodes: members.count - members.collectionMovieCount), "2 movies · 1 show")
    }

    /// Duplicate children, a show listed next to one of its own episodes, and unknown keys.
    func testEachItemOnceAndUnknownKeysIgnored() {
        let alpha = episodes(of: "Alpha Island", showKey: "s1", count: 3)
        let index = CollectionMemberIndex(items: alpha + [film("m1", "Delta Run")])
        let members = index.resolve(["m1", "m1", "s1", alpha[0].ratingKey, "nope", "s9"])
        XCTAssertEqual(members.map(\.id), ["m1"] + alpha.map(\.id))
    }

    /// Films only: the same items, the same "N movies" text and the same floor as before.
    func testFilmsOnlyCollectionUnchanged() {
        let films = [film("m1", "Big"), film("m2", "Cast Away"), film("m3", "Forrest Gump")]
        let members = CollectionMemberIndex(items: films).resolve(["m1", "m2", "m3"])
        XCTAssertEqual(members.map(\.id), films.map(\.id))
        let collection = DiscoveredCollection(id: "c", title: "TOM HANKS", movieCount: 3, items: members, enabled: true)
        XCTAssertEqual(collection.memberSummary, "3 movies")
        XCTAssertEqual(collection.showCount, 0)
        XCTAssertEqual(CollectionMemberIndex.minimumItems, 3)
    }

    func testTitleRepresentativesWeighAShowOnce() {
        let films = [film("m1", "Delta Run")]
        let alpha = episodes(of: "Alpha Island", showKey: "s1", count: 30)
        let reps = (films + alpha).collectionTitleRepresentatives
        XCTAssertEqual(reps.map(\.id), ["m1", alpha[0].id])
    }

    func testMemberSummaryWording() {
        XCTAssertEqual(DiscoveredCollection.memberSummary(movies: 12, shows: 0, episodes: 0), "12 movies")
        XCTAssertEqual(DiscoveredCollection.memberSummary(movies: 0, shows: 3, episodes: 47), "3 shows · 47 episodes")
        XCTAssertEqual(DiscoveredCollection.memberSummary(movies: 0, shows: 1, episodes: 1), "1 show · 1 episode")
        XCTAssertEqual(DiscoveredCollection.memberSummary(movies: 1, shows: 2, episodes: 9), "1 movie · 2 shows")
    }

    // MARK: - Classification

    /// Every episode carries its show's title, so 30 episodes of one show read as "30
    /// titles sharing a word". A collection of shows is the viewer's own set, whatever
    /// its name says.
    func testShowCollectionsAreNeverFranchises() {
        let survivor = episodes(of: "Survivor", showKey: "s1", count: 30)
        XCTAssertEqual(CollectionClassifier.classify(title: "Reality TV", items: survivor), .custom)
        let trek = episodes(of: "Star Trek: The Next Generation", showKey: "s2", count: 8)
            + episodes(of: "Star Trek: Voyager", showKey: "s3", count: 8)
        XCTAssertEqual(CollectionClassifier.classify(title: "Star Trek Saga", items: trek), .custom)
    }

    /// A mix is classified on its films alone, exactly as the films-only scan did.
    func testMixedCollectionClassifiesOnItsFilms() {
        let wick = [film("m1", "John Wick"), film("m2", "John Wick: Chapter 2"), film("m3", "Parabellum")]
        let show = episodes(of: "The Continental", showKey: "s1", count: 3)
        XCTAssertEqual(CollectionClassifier.classify(title: "John Wick", items: wick + show), .franchises)
        let hanks = [film("m4", "Big"), film("m5", "Cast Away")]
        let band = episodes(of: "Band of Brothers", showKey: "s2", count: 10)
        XCTAssertEqual(CollectionClassifier.classify(title: "Tom Hanks", items: hanks + band), .custom)
    }

    // MARK: - Franchise fold

    /// A fold hides the collection, so it must never take shows the franchise does not air.
    func testShowCollectionDoesNotFoldIntoAFilmsOnlyFranchise() {
        let films = [film("m1", "Star Wars"), film("m2", "The Empire Strikes Back"), film("m3", "Return of the Jedi")]
        let mando = episodes(of: "The Mandalorian", showKey: "s1", count: 4)
        let filmsOnlyTarget = FranchiseCollectionFold.Target(label: "STAR WARS", itemIDs: Set(films.map(\.id)))

        let mixed = DiscoveredCollection(id: "mixed", title: "STAR WARS", movieCount: 3, items: films + mando,
                                         enabled: true, matchedChannel: "STAR WARS")
        XCTAssertFalse(FranchiseCollectionFold.carriesEveryShow(of: mixed, filmsOnlyTarget))

        let withShow = FranchiseCollectionFold.Target(label: "STAR WARS", itemIDs: Set((films + [mando[2]]).map(\.id)))
        XCTAssertTrue(FranchiseCollectionFold.carriesEveryShow(of: mixed, withShow))

        let filmsOnly = DiscoveredCollection(id: "films", title: "STAR WARS", movieCount: 3, items: films, enabled: true)
        XCTAssertTrue(FranchiseCollectionFold.carriesEveryShow(of: filmsOnly, filmsOnlyTarget),
                      "films-only collections fold exactly as before")
    }

    /// Through `folds`. Both collections name-match a stock franchise channel, which folds a
    /// collection on its own (step 3). The films-only one folds as before; the mix holds a
    /// show the channel does not air, so the guard keeps it as its own channel.
    func testFoldsKeepsAMixedCollectionWhoseShowsTheFranchiseLacks() {
        let films = [film("m1", "John Wick"), film("m2", "John Wick: Chapter 2"), film("m3", "Parabellum")]
        let continental = episodes(of: "The Continental", showKey: "s1", count: 3)
        let label = "CH 104 JOHN WICK"
        let target = FranchiseCollectionFold.Target(label: label, itemIDs: Set(films.map(\.id)), stockChannelID: 104)
        let mixed = DiscoveredCollection(id: "mixed", title: "JOHN WICK", movieCount: 3, items: films + continental,
                                         enabled: true, matchedChannel: label)
        let filmsOnly = DiscoveredCollection(id: "films", title: "JOHN WICK", movieCount: 3, items: films,
                                             enabled: true, matchedChannel: label)
        let folds = FranchiseCollectionFold.folds(collections: [mixed, filmsOnly], targets: [target],
                                                  enrichmentFor: { _ in nil }, definitions: [])
        XCTAssertEqual(folds["films"], label)
        XCTAssertNil(folds["mixed"])

        // Once the channel airs the show too, the mix folds like any other duplicate.
        let airsShow = FranchiseCollectionFold.Target(label: label, itemIDs: Set((films + continental).map(\.id)),
                                                      stockChannelID: 104)
        let foldsWithShow = FranchiseCollectionFold.folds(collections: [mixed], targets: [airsShow],
                                                          enrichmentFor: { _ in nil }, definitions: [])
        XCTAssertEqual(foldsWithShow["mixed"], label)
    }

    // MARK: - Item model

    func testShowKeyRoundTripsAndOldItemsDecodeWithout() throws {
        let ep = episode("e1", show: "Alpha Island", showKey: "s1", season: 1, number: 1)
        let data = try JSONEncoder().encode(ep)
        XCTAssertEqual(try JSONDecoder().decode(PlexMediaItem.self, from: data).showKey, "s1")

        // An item written by a build without the field.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "showKey")
        let old = try JSONDecoder().decode(PlexMediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.showKey)
        XCTAssertEqual(old.id, ep.id)

        // Films never write the key, so their snapshot rows do not grow.
        let filmJSON = try XCTUnwrap(String(data: JSONEncoder().encode(film("m1", "Delta Run")), encoding: .utf8))
        XCTAssertFalse(filmJSON.contains("showKey"))
    }

    func testWithPartKeyKeepsShowKey() {
        let ep = episode("e1", show: "Alpha Island", showKey: "s1", season: 1, number: 1)
        XCTAssertEqual(ep.withPartKey("/library/parts/2/file.mp4").showKey, "s1")
    }

    /// The v3 snapshot stores a collection's members as indexes into the item chunks, so a
    /// collection of episodes needs no format change. Round-trip one.
    func testSnapshotRoundTripsACollectionOfEpisodes() throws {
        LibrarySnapshotStore.clear()
        defer { LibrarySnapshotStore.clear() }
        let films = [film("m1", "Delta Run")]
        let alpha = episodes(of: "Alpha Island", showKey: "s1", count: 4)
        let bravo = episodes(of: "Bravo Kitchen", showKey: "s2", count: 3)
        let all = films + alpha + bravo
        let collection = DiscoveredCollection(id: "c-tv", title: "REALITY TV", movieCount: 0,
                                              items: alpha + bravo, enabled: true)
        try LibrarySnapshotStore.save(
            identity: "collections-with-shows-test", serverName: "Lab", librarySignature: "sig",
            lastLoadAtUnix: Int(Date().timeIntervalSince1970), allItems: all, channelConfigChannels: [],
            allChannels: [], bundles: [], enabledBundleIDs: [], exclusiveRules: [],
            discoveredCollections: [collection])
        let loaded = try XCTUnwrap(LibrarySnapshotStore.loadSnapshot(identity: "collections-with-shows-test"))
        XCTAssertEqual(LibrarySnapshotStore.formatVersion, 3, "no format bump")
        let lookup = Dictionary(loaded.snapshot.allItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let restored = try XCTUnwrap(loaded.snapshot.discoveredCollectionRows.first).resolve(itemLookup: lookup)
        XCTAssertEqual(restored.items.map(\.id), (alpha + bravo).map(\.id))
        XCTAssertEqual(restored.items.map(\.showKey), (alpha + bravo).map(\.showKey))
        XCTAssertEqual(restored.memberSummary, "2 shows · 7 episodes")
    }

    // MARK: - Scan, materialize, schedule (AppState end to end, canned server)

    private final class CollectionServer: MediaBackend, @unchecked Sendable {
        let serverID = ""
        var authHeaders: [String: String] { [:] }
        let sections: [PlexSection]
        let collectionsBySection: [String: [PlexCollection]]
        let children: [String: [String]]

        init(sections: [PlexSection], collectionsBySection: [String: [PlexCollection]], children: [String: [String]]) {
            self.sections = sections
            self.collectionsBySection = collectionsBySection
            self.children = children
        }

        func testConnection() async throws -> String { "lab" }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress?) async throws -> [PlexMediaItem] { [] }
        func loadSections() async throws -> [PlexSection] { sections }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { collectionsBySection[sectionKey] ?? [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { children[collectionKey] ?? [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { nil }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private func collection(_ key: String, _ title: String) -> PlexCollection {
        PlexCollection(ratingKey: key, title: title, childCount: nil, thumb: nil)
    }

    /// Plex shape: the show collection lives in the TV library and lists shows. It is found,
    /// classified OTHER COLLECTIONS, built at CH 450 up with the films-only collection beside
    /// it, and its day of schedule is episodes, shuffled the way TV channels shuffle them.
    func testScanBuildsAShowChannelAndSchedulesItsEpisodes() async throws {
        let alpha = episodes(of: "Alpha Island", showKey: "s1", count: 8)
        let bravo = episodes(of: "Bravo Kitchen", showKey: "s2", count: 6)
        let charlie = episodes(of: "Charlie Court", showKey: "s3", count: 5)
        let hanks = [film("m1", "Big"), film("m2", "Cast Away"), film("m3", "Forrest Gump")]
        let pair = [film("m4", "Delta Run"), film("m5", "Echo Point")]

        let state = AppState()
        let server = CollectionServer(
            sections: [PlexSection(key: "1", title: "Movies", type: "movie"),
                       PlexSection(key: "2", title: "TV Shows", type: "show")],
            collectionsBySection: ["1": [collection("c-hanks", "Tom Hanks"), collection("c-pair", "Two Films")],
                                   "2": [collection("c-tv", "Reality TV")]],
            children: ["c-hanks": ["m1", "m2", "m3"], "c-pair": ["m4", "m5"], "c-tv": ["s1", "s2", "s3"]])
        state.backendOverride = { _ in server }
        state.allItems = hanks + pair + alpha + bravo + charlie
        state.enabledCollectionKeys = ["c-hanks", "c-pair", "c-tv"]

        await state.scanCollections()

        XCTAssertEqual(state.discoveredCollections.map(\.title), ["REALITY TV", "TOM HANKS"],
                       "two films is still too few; the TV-library collection is listed")
        let tv = try XCTUnwrap(state.discoveredCollections.first { $0.id == "c-tv" })
        XCTAssertEqual(tv.category, .custom)
        XCTAssertEqual(tv.movieCount, 0)
        XCTAssertEqual(tv.showCount, 3)
        XCTAssertEqual(tv.items.count, 19)
        XCTAssertEqual(tv.memberSummary, "3 shows · 19 episodes")
        let hanksRow = try XCTUnwrap(state.discoveredCollections.first { $0.id == "c-hanks" })
        XCTAssertEqual(hanksRow.memberSummary, "3 movies")
        XCTAssertEqual(hanksRow.items.map(\.id), hanks.map(\.id))

        let channels = state.allChannels.filter { ChannelIDSpace.isDynamic($0.id) }.sorted { $0.number < $1.number }
        XCTAssertEqual(channels.map(\.number), [450, 451])
        XCTAssertEqual(channels.map(\.name), ["REALITY TV", "TOM HANKS"])
        let channel = channels[0]
        XCTAssertEqual(channel.id, CollectionCategory.custom.idBase)
        XCTAssertEqual(Set(channel.itemPool.map(\.id)), Set((alpha + bravo + charlie).map(\.id)))
        XCTAssertTrue(channel.itemPool.allSatisfy { $0.type == .episode })
        XCTAssertTrue(state.bundles.contains { $0.id == CollectionCategory.custom.bundleID && $0.channelIDs == channels.map(\.id) })

        // A day of schedule through the same scheduler every channel uses.
        let fp = "collections-with-shows-\(UUID().uuidString)"
        defer { DailyManifestStore.clearAll(credentialFingerprint: fp) }
        DailyManifestScheduler.invalidateMemo()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = DateComponents(calendar: calendar, year: 2026, month: 10, day: 14, hour: 12).date!
        let blocks = DailyManifestScheduler.blocks(for: channel, at: day, credentialFingerprint: fp, calendar: calendar)
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(blocks.last?.endTime, calendar.startOfDay(for: day).addingTimeInterval(86400), "fills the day")
        XCTAssertTrue(blocks.allSatisfy { $0.item.type == .episode })

        // The first pass airs every episode once before any repeat ...
        let firstPass = Array(blocks.prefix(19)).map(\.item)
        XCTAssertEqual(Set(firstPass.map(\.id)).count, 19)
        // ... never more than two of one show in a row (interleaveByShow) ...
        var run = 1
        for (a, b) in zip(firstPass, firstPass.dropFirst()) {
            run = a.title == b.title ? run + 1 : 1
            XCTAssertLessThanOrEqual(run, 2, "\(b.title) ran \(run) in a row")
        }
        // ... and not in season/episode order.
        let alphaOrder = firstPass.filter { $0.title == "Alpha Island" }.compactMap(\.seTag)
        XCTAssertNotEqual(alphaOrder, alphaOrder.sorted(), "episodes are shuffled, not aired in order")
    }

    /// Jellyfin / Emby shape: one global BoxSet list for every library, a mixed BoxSet, and
    /// (Emby) episode ids instead of series ids. Both become one channel each.
    func testScanBuildsMixedAndEpisodeChildCollections() async throws {
        let films = [film("m1", "Delta Run"), film("m2", "Echo Point")]
        let lima = episodes(of: "Hotel Lima", showKey: "s4", count: 2)
        let alpha = episodes(of: "Alpha Island", showKey: "s1", count: 4, stampShowKey: false)
        let boxSets = [collection("b-mixed", "Mixed Bag"), collection("b-emby", "Reality TV")]

        let state = AppState()
        let server = CollectionServer(
            sections: [PlexSection(key: "v1", title: "Movies", type: "movie"),
                       PlexSection(key: "v2", title: "Shows", type: "show")],
            collectionsBySection: ["v1": boxSets, "v2": boxSets],
            children: ["b-mixed": ["m1", "m2", "s4"], "b-emby": alpha.map(\.ratingKey)])
        state.backendOverride = { _ in server }
        state.allItems = films + lima + alpha
        state.enabledCollectionKeys = ["b-mixed", "b-emby"]

        await state.scanCollections()

        XCTAssertEqual(state.discoveredCollections.map(\.id), ["b-mixed", "b-emby"], "listed once each, sorted by title")
        let mixed = state.discoveredCollections[0]
        XCTAssertEqual(mixed.items.map(\.id), (films + lima).map(\.id))
        XCTAssertEqual(mixed.memberSummary, "2 movies · 1 show")
        XCTAssertEqual(state.discoveredCollections[1].memberSummary, "1 show · 4 episodes")
        let dynamic = state.allChannels.filter { ChannelIDSpace.isDynamic($0.id) }
        XCTAssertEqual(dynamic.count, 2)
    }
}
