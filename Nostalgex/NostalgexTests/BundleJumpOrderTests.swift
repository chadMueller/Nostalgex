import XCTest
@testable import Nostalgex

/// The guide's package jump list (press Left in the guide). It used to follow the order of
/// the `bundles` array, so CASE FILES sat third although it airs from CH 120, HIGH ROTATION
/// came before the collection packages, and the server's franchise collections showed as a
/// second FRANCHISES.
@MainActor
final class BundleJumpOrderTests: XCTestCase {

    private let bundlesKey = "nostalgex_enabled_bundles"
    private var savedBundles: Any?

    override func setUp() {
        super.setUp()
        savedBundles = UserDefaults.standard.object(forKey: bundlesKey)
    }

    override func tearDown() {
        if let savedBundles { UserDefaults.standard.set(savedBundles, forKey: bundlesKey) }
        else { UserDefaults.standard.removeObject(forKey: bundlesKey) }
        super.tearDown()
    }

    private func movie(_ id: String) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: id, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2000, originallyAvailableAt: nil, contentRating: nil,
            duration: 120, ratingKey: id, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: id, imdbID: nil, librarySource: .movie
        )
    }

    private func films(_ prefix: String) -> [PlexMediaItem] { (1...3).map { movie("\(prefix)-\($0)") } }

    /// The shipped lineup with every package on, one found franchise, one franchise
    /// collection and one other collection.
    private func fullLineup() throws -> AppState {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "channels", withExtension: "json"))
        let config = try XCTUnwrap(ChannelConfigLoader.loadConfig(from: Data(contentsOf: url)))
        let state = AppState()
        state.bundles = config.bundles.map { $0.toChannelBundle(enabled: true) }
        state.enabledBundleIDs = Set(config.bundles.map(\.id))
            .union([CollectionCategory.franchises.bundleID, CollectionCategory.custom.bundleID])
        state.allChannels = config.channels
        state.foundFranchises = [
            FoundFranchise(id: "tmdb:1", name: "JOHN WICK", movies: films("wick"), tvItems: [],
                           coveredByChannelID: nil, fromDictionary: false, enabled: true)
        ]
        state.discoveredCollections = [
            DiscoveredCollection(id: "c-alien", title: "ALIEN SAGA", movieCount: 3, items: films("alien"),
                                 enabled: true, matchedChannel: nil, contentOverlap: nil, category: .franchises),
            DiscoveredCollection(id: "c-hanks", title: "TOM HANKS", movieCount: 3, items: films("hanks"),
                                 enabled: true, matchedChannel: nil, contentOverlap: nil, category: .custom),
        ]
        state.materializeDynamicChannels()
        state.applyBundleFilter()
        return state
    }

    private func describe(_ state: AppState) -> [String] {
        state.bundleJumpTargets.map { t in
            let number = state.channels.first { $0.id == t.firstChannelID }?.number ?? -1
            return "\(t.bundleName)@\(number)"
        }
    }

    /// What the list read before this change, measured with this lineup on a tvOS
    /// simulator on 2026-10-31, on the numbers of the time (SCREAM in season, so it led
    /// the guide but not the list): NOSTALGEX@1, KIDZ ZONE@30, CASE FILES@120,
    /// PRIME TIME@50, MARQUEE@70, ARTHOUSE@150, ADVENTURELAND@90, OVERTIME@110,
    /// DECADES@130, FRANCHISES@300, NETWORKS@160, SCREAM@180, TIS THE SEASON@190,
    /// HIGH ROTATION@500, FRANCHISES@400, OTHER COLLECTIONS@450.
    func testTheListFollowsTheGuideWithOneFranchisesEntry() throws {
        let state = try fullLineup()
        let names = state.bundleJumpTargets.map(\.bundleName)
        XCTAssertEqual(names.filter { $0 == "FRANCHISES" }.count, 1, "\(describe(state))")
        XCTAssertEqual(names.last, "HIGH ROTATION")
        // Each entry's first channel sits further down the guide than the one before.
        let at = state.bundleJumpTargets.map { t in state.channels.firstIndex { $0.id == t.firstChannelID } ?? -1 }
        XCTAssertEqual(at, at.sorted(), "\(describe(state))")
        print("JUMPLIST " + describe(state).joined(separator: ", "))
    }

    /// The order pinned, with the guide in plain number order and with SCREAM leading it.
    func testPinnedOrderWithAndWithoutASeasonalLead() throws {
        let state = try fullLineup()
        let franchisesInOne = state.bundles.filter { [AppState.franchisesBundleID, CollectionCategory.franchises.bundleID].contains($0.id) }
        XCTAssertEqual(franchisesInOne.count, 2, "the stock package and the collections category both exist")
        let visible = state.allChannels

        func list(_ seasonal: [Int]) -> [String] {
            let channels = GuideChannelOrder.sorted(visible, seasonalFirst: seasonal)
            return AppState.bundleJumpTargets(bundles: state.bundles, enabledBundleIDs: state.enabledBundleIDs,
                                              channels: channels, foundFranchiseChannelIDs: state.foundFranchiseChannelIDs)
                .map { t in "\(t.bundleName)@\(channels.first { $0.id == t.firstChannelID }!.number)" }
        }

        let plain = ["NOSTALGEX@1", "KIDZ ZONE@30", "PRIME TIME@50", "MARQUEE@70", "ADVENTURELAND@90",
                     "OVERTIME@110", "CASE FILES@120", "DECADES@130", "ARTHOUSE@150", "NETWORKS@160",
                     "SCREAM@180", "TIS THE SEASON@190", "FRANCHISES@300", "OTHER COLLECTIONS@400",
                     "HIGH ROTATION@500"]
        XCTAssertEqual(list([]), plain)

        let scream = try XCTUnwrap(state.bundles.first { $0.id == "seasonal" })
        var leading = ["SCREAM@180"]
        leading += plain.filter { $0 != "SCREAM@180" }
        XCTAssertEqual(list(scream.channelIDs), leading, "a seasonal package leading the guide leads the list")
    }

    /// The FRANCHISES switch is every franchise channel's: off, no classic, found franchise
    /// or franchise collection airs, and the list has no FRANCHISES; on, the entry jumps to
    /// the first franchise channel shown.
    func testTheFranchisesSwitchGatesEveryFranchiseChannel() throws {
        let state = try fullLineup()
        let franchiseNames: Set<String> = ["STAR WARS", "JOHN WICK", "ALIEN SAGA"]
        XCTAssertEqual(Set(state.channels.map(\.name)).intersection(franchiseNames), franchiseNames)

        state.enabledBundleIDs.remove(AppState.franchisesBundleID)
        state.rebuildLineupAfterBundleChange(newlyEnabled: [], byViewer: false)
        XCTAssertTrue(state.channels.allSatisfy { $0.number < 300 || $0.number >= 400 },
                      "\(state.channels.filter { (300...399).contains($0.number) }.map(\.name))")
        XCTAssertFalse(state.bundleJumpTargets.contains { $0.bundleName == "FRANCHISES" })
        XCTAssertTrue(state.channels.contains { $0.name == "TOM HANKS" }, "other collections are not franchises")

        state.enabledBundleIDs.insert(AppState.franchisesBundleID)
        state.applyBundleFilter()
        XCTAssertTrue(state.channels.contains { $0.name == "ALIEN SAGA" })
        let franchises = state.bundleJumpTargets.filter { $0.bundleName == "FRANCHISES" }
        XCTAssertEqual(franchises.count, 1)
        XCTAssertEqual(state.channels.first { $0.id == franchises.first?.firstChannelID }?.number, 300)
    }
}
