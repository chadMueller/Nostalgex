import XCTest
@testable import Nostalgex

/// Switching a package on in Settings builds its channels in the background. These tests
/// drive the real `toggleBundle` path and wait for the build to finish.
@MainActor
final class BundleBuildTests: XCTestCase {
    private var savedBundles: Any?
    private var state: AppState!

    override func setUp() {
        savedBundles = UserDefaults.standard.object(forKey: PreferenceSync.enabledBundlesKey)
        let suite = UserDefaults(suiteName: "BundleBuildTests.\(UUID().uuidString)")!
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: suite,
                                  observeNotifications: false, keys: PreferenceSync.syncedKeys)
        state = AppState(preferenceSync: sync)
    }

    override func tearDown() {
        if let savedBundles {
            UserDefaults.standard.set(savedBundles, forKey: PreferenceSync.enabledBundlesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PreferenceSync.enabledBundlesKey)
        }
    }

    private func item(_ title: String) -> PlexMediaItem {
        PlexMediaItem(
            id: title, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2000, originallyAvailableAt: nil, contentRating: nil,
            duration: 90, ratingKey: title, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie
        )
    }

    private func template(_ id: Int, _ word: String) -> Channel {
        var rules = ChannelRules()
        rules.titleContains = [word]
        return Channel(id: id, number: id, name: "CH\(id)", color: .blue, category: nil,
                       rules: rules, timeRestrictions: nil, minItems: 1, itemPool: [])
    }

    /// Two packages of six channels each, every channel matching its own word.
    private func setUpTwoPackages() -> (ChannelBundle, ChannelBundle) {
        let words = (1...12).map { "word\($0)x" }
        state.allItems = words.flatMap { w in (1...20).map { item("\(w) \($0)") } }
        state.channelConfigChannels = (1...12).map { template($0, words[$0 - 1]) }
        let a = ChannelBundle(id: "a", name: "A", description: "", channelIDs: Array(1...6), activeMonths: nil, enabled: false)
        let b = ChannelBundle(id: "b", name: "B", description: "", channelIDs: Array(7...12), activeMonths: nil, enabled: false)
        let base = ChannelBundle(id: "base", name: "BASE", description: "", channelIDs: [], activeMonths: nil, enabled: true)
        state.bundles = [base, a, b]
        state.enabledBundleIDs = ["base"]
        state.allChannels = []
        return (a, b)
    }

    func testTwoQuickTogglesBothKeepTheirChannels() async {
        let (a, b) = setUpTwoPackages()
        state.toggleBundle(a)
        state.toggleBundle(b)
        XCTAssertEqual(state.buildingBundleIDs, ["a", "b"], "both rows show they are building")
        await state.bundleBuildTask?.value

        let built = Set(state.allChannels.map(\.id))
        XCTAssertEqual(built, Set(1...12), "missing \(Set(1...12).subtracting(built).sorted())")
        XCTAssertEqual(Set(state.channels.map(\.id)), Set(1...12))
        XCTAssertTrue(state.buildingBundleIDs.isEmpty, "spinners clear once the channels are in")
    }

    func testSwitchingAPackageOffNeedsNoBuild() {
        let (a, _) = setUpTwoPackages()
        state.enabledBundleIDs.insert("a")
        state.toggleBundle(a)
        XCTAssertTrue(state.buildingBundleIDs.isEmpty)
    }

    func testThreeQuickSwitchesCostOneBuild() async {
        let words = (1...18).map { "word\($0)x" }
        state.allItems = words.flatMap { w in (1...20).map { item("\(w) \($0)") } }
        state.channelConfigChannels = (1...18).map { template($0, words[$0 - 1]) }
        let packs = (0..<3).map { n in
            ChannelBundle(id: "p\(n)", name: "P\(n)", description: "", channelIDs: Array((n * 6 + 1)...(n * 6 + 6)),
                          activeMonths: nil, enabled: false)
        }
        let base = ChannelBundle(id: "base", name: "BASE", description: "", channelIDs: [], activeMonths: nil, enabled: true)
        state.bundles = [base] + packs
        state.enabledBundleIDs = ["base"]
        state.allChannels = []

        for p in packs { state.toggleBundle(p) }
        XCTAssertEqual(state.buildingBundleIDs, ["p0", "p1", "p2"])
        await state.bundleBuildTask?.value

        XCTAssertEqual(state.bundleBuildCommits, 1, "three quick switches should reach the guide in one build")
        XCTAssertEqual(Set(state.channels.map(\.id)), Set(1...18))
        XCTAssertTrue(state.buildingBundleIDs.isEmpty)
    }

    func testSwitchingOffWhileWaitingDropsItFromTheBuild() async {
        let (a, b) = setUpTwoPackages()
        state.toggleBundle(a)
        state.toggleBundle(b)
        state.toggleBundle(a)   // off again before the build starts
        XCTAssertEqual(state.buildingBundleIDs, ["b"])
        await state.bundleBuildTask?.value
        XCTAssertEqual(Set(state.channels.map(\.id)), Set(7...12))
        XCTAssertTrue(state.buildingBundleIDs.isEmpty)
    }

    /// The press flips the switch and returns without filtering anything; the build then
    /// filters off the main actor. A ticker on the main actor measures the longest gap
    /// while a large build runs. The old build filtered on the main actor, three channels
    /// at a time, and held it for 350 to 580 ms per block on an 11,863-item library.
    func testMainActorStaysFreeWhileAPackageBuilds() async {
        let words = (1...30).map { "word\($0)x" }
        state.allItems = (0..<60_000).map { item("\(words[$0 % 30]) title \($0)") }
        state.channelConfigChannels = (1...30).map { template($0, words[$0 - 1]) }
        let big = ChannelBundle(id: "big", name: "BIG", description: "", channelIDs: Array(1...30), activeMonths: nil, enabled: false)
        let base = ChannelBundle(id: "base", name: "BASE", description: "", channelIDs: [], activeMonths: nil, enabled: true)
        state.bundles = [base, big]
        state.enabledBundleIDs = ["base"]
        state.allChannels = []

        let pressStarted = Date()
        state.toggleBundle(big)
        let pressTook = Date().timeIntervalSince(pressStarted)
        XCTAssertTrue(state.bundles[1].enabled, "the switch flips on the press")
        XCTAssertEqual(state.buildingBundleIDs, ["big"], "BUILDING shows on the press")
        XCTAssertTrue(state.allChannels.isEmpty, "the press itself filters nothing")
        XCTAssertLessThan(pressTook, 0.05, "the press took \(Int(pressTook * 1000)) ms")

        // Skip the settle wait and the filter cache (built on the main actor once, before
        // the filtering starts); measure the filtering and the merge.
        try? await Task.sleep(for: AppState.bundleBuildSettle + .milliseconds(150))
        var maxGap: TimeInterval = 0
        let build = state.bundleBuildTask
        let ticker = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                let now = Date()
                maxGap = max(maxGap, now.timeIntervalSince(last))
                last = now
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await build?.value
        ticker.cancel()
        XCTContext.runActivity(named: "Longest main-actor gap during the build: \(Int(maxGap * 1000)) ms") { _ in }
        XCTAssertEqual(Set(state.channels.map(\.id)), Set(1...30))
        XCTAssertLessThan(maxGap, 0.15, "the main actor was held \(Int(maxGap * 1000)) ms during the build")
    }

    /// Same channels and pools as the full build the launch runs, for real packages from
    /// channels.json over a varied library: the coalesced background build changes when
    /// the work happens, not what it makes.
    func testCoalescedBuildMatchesAFullBuild() async {
        let config = ChannelConfigLoader.loadBundled()
        let genres = ["Comedy", "Drama", "Action", "Horror", "Animation", "Family", "Thriller",
                      "Romance", "Crime", "Science Fiction", "Documentary", "Mystery", "Western", "War"]
        let ratings = ["G", "PG", "PG-13", "R", "TV-14", "TV-PG", "TV-Y7", "TV-MA"]
        let studios = ["Disney", "Warner Bros.", "Universal", "A24", "Paramount", "Pixar", "HBO"]
        state.allItems = (0..<4_000).map { k in
            let isEp = k % 3 == 0
            return PlexMediaItem(
                id: "x\(k)", title: "Title \(k)", artist: nil, episodeTitle: nil, seTag: nil,
                summary: "", year: 1960 + (k % 65), originallyAvailableAt: nil,
                contentRating: ratings[k % ratings.count], duration: 90, ratingKey: "x\(k)", partKey: nil,
                container: nil, videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
                genres: [genres[k % genres.count], genres[(k / 7) % genres.count]], rating: 6.5, userRating: 0,
                type: isEp ? .episode : .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0,
                studio: studios[k % studios.count], tmdbID: nil, imdbID: nil,
                librarySource: isEp ? .tv : .movie
            )
        }
        state.channelConfigChannels = config.channels
        state.exclusiveRules = config.exclusiveRules
        let all = config.bundles
            .filter { $0.id != AppState.franchisesBundleID }
            .map { $0.toChannelBundle(enabled: false) }
        XCTAssertGreaterThanOrEqual(all.count, 4)
        let base = ChannelBundle(id: "base", name: "BASE", description: "", channelIDs: [], activeMonths: nil, enabled: true)
        state.bundles = [base] + all
        state.enabledBundleIDs = ["base"]
        state.allChannels = []

        let switched = Array(all.prefix(4))
        for b in switched { state.toggleBundle(b) }
        await state.bundleBuildTask?.value
        XCTAssertEqual(state.bundleBuildCommits, 1)

        let ids = Set(switched.flatMap(\.channelIDs))
        let expected = await state.rebuildStaticChannelPools(
            configChannels: config.channels, items: state.allItems, onlyChannelIDs: ids)
        let got = state.allChannels.filter { ids.contains($0.id) }
        XCTAssertFalse(expected.isEmpty, "the test library should fill some channels")
        XCTAssertEqual(got.map(\.id), expected.map(\.id), "same channels on air")
        for (g, e) in zip(got, expected) {
            XCTAssertEqual(g.itemPool.map(\.id), e.itemPool.map(\.id), "CH \(g.id) pool differs")
        }
    }
}
