import XCTest
@testable import Nostalgex

/// "N OF M ON CHANNELS" and "N ON NO CHANNEL" under RESCAN LIBRARY.
///
/// The definition: a loaded title is **on a channel** when it is in the pool of at least one
/// channel that would show if its package were on (a static channel whose pool reaches its
/// `minItems`, or a collection or franchise channel the app has built), whether or not that
/// channel's package is on right now. A title on none is **on no channel**. The number does not
/// move when a package is switched on or off; the count for the channels in the guide as it is
/// now, which does, is kept separately for contrast.
@MainActor
final class LibraryCoverageTests: XCTestCase {

    // MARK: Fixtures

    private func movie(_ title: String, source: LibrarySource = .movie, id: String? = nil) -> PlexMediaItem {
        PlexMediaItem(
            id: id ?? title, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2001, originallyAvailableAt: nil, contentRating: "PG",
            duration: 95, ratingKey: id ?? title, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: ["Drama"], rating: 7, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: source)
    }

    private func episode(_ show: String, _ n: Int) -> PlexMediaItem {
        PlexMediaItem(
            id: "\(show)-\(n)", title: show, artist: nil, episodeTitle: "Episode \(n)", seTag: "S01E\(n)",
            summary: "", year: 1999, originallyAvailableAt: nil, contentRating: "TV-PG",
            duration: 22, ratingKey: "\(show)-\(n)", partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: ["Comedy"], rating: 7, userRating: 0, type: .episode, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .tv)
    }

    private func channel(_ id: Int, minItems: Int = 3, configure: (inout ChannelRules) -> Void) -> Channel {
        var rules = ChannelRules()
        configure(&rules)
        return Channel(id: id, number: id, name: "CH\(id)", color: .blue, category: nil,
                       rules: rules, timeRestrictions: nil, minItems: minItems, itemPool: [])
    }

    private func cache(_ items: [PlexMediaItem]) -> [AppState.FilterCache] {
        items.map {
            AppState.FilterCache(item: $0, titleLower: $0.title.lowercased(),
                                 episodeTitleLower: ($0.episodeTitle ?? "").lowercased(),
                                 genresLowerSet: Set($0.genres.map { $0.lowercased() }),
                                 enrichment: nil, itemStudioLower: "")
        }
    }

    /// Ten movies (five "zebra", two "otter", three nobody wants), four episodes of one show,
    /// two music videos (one a channel takes), a dynamic channel's pool of two movies.
    private func library() -> (items: [PlexMediaItem], statics: [Channel], dynamicPools: [[PlexMediaItem]]) {
        var items: [PlexMediaItem] = (1 ... 5).map { movie("zebra film \($0)") }
        items += (1 ... 2).map { movie("otter film \($0)") }
        items += (1 ... 3).map { movie("plain film \($0)") }
        items += (1 ... 4).map { episode("Bluey", $0) }
        items += [movie("Song A", source: .musicVideo), movie("Song B", source: .musicVideo)]
        let zebra = channel(1) { $0.titleContains = ["zebra"] }                        // 5 >= 3: counts
        let otter = channel(2, minItems: 3) { $0.titleContains = ["otter"] }            // 2 < 3: hidden, its titles do not count
        let tv = channel(3) { $0.type = .episode; $0.titleContains = ["bluey"] }        // 4 >= 3: counts
        let mv = channel(4, minItems: 1) { $0.source = .musicVideo; $0.titleContains = ["song a"] } // 1 >= 1: counts
        let dynamic = [items.first { $0.title == "plain film 1" }!, items.first { $0.title == "plain film 2" }!]
        return (items, [zebra, otter, tv, mv], [dynamic])
    }

    private func coverage(_ lib: (items: [PlexMediaItem], statics: [Channel], dynamicPools: [[PlexMediaItem]]),
                          sampleSize: Int = 25) -> LibraryDiagnostics.Coverage {
        LibraryDiagnostics.coverage(items: lib.items, cache: cache(lib.items), staticChannels: lib.statics,
                                    dynamicPools: lib.dynamicPools, memberships: .empty, exclusiveRules: [],
                                    sampleSize: sampleSize)
    }

    // MARK: The definition

    func testCountsByKind() {
        let c = coverage(library())
        XCTAssertEqual(c.loaded[.movie], 10)
        XCTAssertEqual(c.loaded[.episode], 4)
        XCTAssertEqual(c.loaded[.musicVideo], 2)
        XCTAssertEqual(c.totalLoaded, 16)
        // zebra 5 + two from the dynamic pool = 7 films; otter's 2 and one plain film are on none.
        XCTAssertEqual(c.onChannels[.movie], 7)
        XCTAssertEqual(c.onChannels[.episode], 4)
        XCTAssertEqual(c.onChannels[.musicVideo], 1)
        XCTAssertEqual(c.totalOnChannels, 12)
        XCTAssertEqual(c.totalOnNoChannel, 4)
        XCTAssertEqual(c.orphans(.movie), 3)
        XCTAssertEqual(c.orphans(.episode), 0)
        XCTAssertEqual(c.orphans(.musicVideo), 1)
    }

    func testAChannelUnderItsMinimumDoesNotCount() {
        let c = coverage(library())
        let names = Set(c.orphanSample.map(\.title))
        XCTAssertTrue(names.contains("otter film 1"), "the otter channel has 2 of its 3 and is hidden, so its titles are on no channel")
        XCTAssertTrue(names.contains("otter film 2"))
    }

    func testATitleOnSeveralChannelsCountsOnce() {
        var lib = library()
        lib.statics.append(channel(5) { $0.titleContains = ["film"] })   // takes every film: overlaps zebra, otter, plain
        let c = coverage(lib)
        XCTAssertEqual(c.loaded[.movie], 10)
        XCTAssertEqual(c.onChannels[.movie], 10, "all ten films are on the new channel; each counted once, not once a channel")
    }

    func testTheSampleIsByTitleAndCapped() {
        let c = coverage(library(), sampleSize: 2)
        XCTAssertEqual(c.orphanSample.count, 2)
        XCTAssertEqual(c.orphanSample.map(\.title), c.orphanSample.map(\.title).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertEqual(coverage(library()).orphanSample.count, 4, "all four when there are fewer than the cap")
    }

    func testTitlesOnTheGuidesChannelsCountsEachOnce() {
        var a = channel(1) { _ in }; a.itemPool = [movie("x"), movie("y")]
        var b = channel(2) { _ in }; b.itemPool = [movie("y"), movie("z")]
        XCTAssertEqual(LibraryDiagnostics.titlesOnChannels(in: [a, b]), 3)
        XCTAssertEqual(LibraryDiagnostics.titlesOnChannels(in: []), 0)
    }

    // MARK: The wording

    func testWording() {
        func cov(loaded: [LibraryDiagnostics.Kind: Int], on: [LibraryDiagnostics.Kind: Int]) -> LibraryDiagnostics.Coverage {
            var c = LibraryDiagnostics.Coverage(); c.loaded = loaded; c.onChannels = on; return c
        }
        // The example in the brief, movies only: 412 of 484.
        XCTAssertEqual(LibraryDiagnostics.coverageLine(cov(loaded: [.movie: 484], on: [.movie: 412]), skippedNoRuntime: 0),
                       "412 OF 484 ON CHANNELS · 72 ON NO CHANNEL")
        // Nothing orphaned: the second part is left out.
        XCTAssertEqual(LibraryDiagnostics.coverageLine(cov(loaded: [.movie: 484], on: [.movie: 484]), skippedNoRuntime: 0),
                       "484 OF 484 ON CHANNELS")
        // Skipped appears only above zero, after the others.
        XCTAssertEqual(LibraryDiagnostics.coverageLine(cov(loaded: [.movie: 484], on: [.movie: 484]), skippedNoRuntime: 12),
                       "484 OF 484 ON CHANNELS · 12 SKIPPED (NO RUNTIME)")
        // More than one kind with orphans: split them. The calibration library from the web run.
        XCTAssertEqual(LibraryDiagnostics.coverageLine(
            cov(loaded: [.movie: 1_792, .episode: 8_891, .musicVideo: 1_126], on: [.movie: 1_788, .episode: 8_719, .musicVideo: 1_126]),
            skippedNoRuntime: 0),
            "11,633 OF 11,809 ON CHANNELS · 176 ON NO CHANNEL (4 MOVIES, 172 EPISODES)")
        // One kind with orphans among several: no split.
        XCTAssertEqual(LibraryDiagnostics.coverageLine(
            cov(loaded: [.movie: 10, .episode: 5], on: [.movie: 8, .episode: 5]), skippedNoRuntime: 0),
            "13 OF 15 ON CHANNELS · 2 ON NO CHANNEL")
        // Not counted yet: only what is known.
        XCTAssertEqual(LibraryDiagnostics.coverageLine(nil, skippedNoRuntime: 3), "3 SKIPPED (NO RUNTIME)")
        XCTAssertNil(LibraryDiagnostics.coverageLine(nil, skippedNoRuntime: 0))
        // An empty library says nothing about channels.
        XCTAssertNil(LibraryDiagnostics.coverageLine(cov(loaded: [:], on: [:]), skippedNoRuntime: 0))
    }

    func testTheReportNamesTheTitlesAndTheFieldsTheRulesRead() {
        let c = coverage(library())
        let line = LibraryDiagnostics.orphanReport(c, onEnabledChannels: 9)
        XCTAssertTrue(line.hasPrefix("COVERAGE: 12 of 16 on a channel with every package on, 4 on none; 9 on the channels in the guide now"), line)
        XCTAssertTrue(line.contains("\"otter film 1\" (2001, PG, 7.0, Drama, no studio, 95m, no TMDB)"), line)
        XCTAssertTrue(line.contains("Not on any channel (first 4)"), line)
    }

    // MARK: Through the app

    /// 240 titles on twelve channels in two packages. The count with every package on is 240
    /// from the start and stays put; the count for the guide follows the switches.
    func testTheCountIgnoresPackagesAndTheGuideCountFollowsThem() async throws {
        let scope = HarnessScope.begin("coverage")
        defer { scope.end() }
        let suite = UserDefaults(suiteName: "LibraryCoverageTests.\(UUID().uuidString)")!
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: suite, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        let state = AppState(preferenceSync: sync)

        func word(_ k: Int) -> String { "word\(k)x" }
        func template(_ id: Int, _ w: String) -> Channel {
            var rules = ChannelRules(); rules.titleContains = [w]
            return Channel(id: id, number: id, name: "CH\(id)", color: .blue, category: nil, rules: rules,
                           timeRestrictions: nil, minItems: 1, itemPool: [])
        }
        state.allItems = (1 ... 12).flatMap { k in (1 ... 20).map { movie("\(word(k)) \($0)") } }
        state.channelConfigChannels = (1 ... 12).map { template($0, word($0)) }
        let a = ChannelBundle(id: "a", name: "A", description: "", channelIDs: Array(1 ... 6), activeMonths: nil, enabled: false)
        let b = ChannelBundle(id: "b", name: "B", description: "", channelIDs: Array(7 ... 12), activeMonths: nil, enabled: false)
        let base = ChannelBundle(id: "base", name: "BASE", description: "", channelIDs: [], activeMonths: nil, enabled: true)
        state.bundles = [base, a, b]
        state.enabledBundleIDs = ["base"]
        state.allChannels = []

        state.ensureLibraryCoverage()
        await state.libraryCoverageTask?.value
        XCTAssertEqual(state.libraryCoverage?.totalLoaded, 240)
        XCTAssertEqual(state.libraryCoverage?.totalOnChannels, 240, "every title is on a channel, none of whose packages is on yet")
        XCTAssertEqual(state.libraryCoverage?.totalOnNoChannel, 0)

        func settle() async {
            await state.bundleBuildTask?.value
            await state.titlesOnChannelsTask?.value
        }
        state.toggleBundle(a); await settle()
        XCTAssertEqual(state.titlesOnChannelsCount, 120, "package A on: six channels of twenty titles")
        state.toggleBundle(b); await settle()
        XCTAssertEqual(state.titlesOnChannelsCount, 240)
        state.toggleBundle(a); await settle()
        XCTAssertEqual(state.titlesOnChannelsCount, 120, "package A off again")

        state.ensureLibraryCoverage()
        await state.libraryCoverageTask?.value
        XCTAssertEqual(state.libraryCoverage?.totalOnChannels, 240, "the count with every package on did not move")

        // Channel one stops taking its twenty titles, and a new film arrives (a new title changes
        // the key, so the count is taken again): twenty-one titles are now on no channel,
        // whatever is switched on.
        state.channelConfigChannels[0] = template(1, "nothing matches this")
        state.allItems.append(movie("an extra film"))
        state.ensureLibraryCoverage()
        await state.libraryCoverageTask?.value
        XCTAssertEqual(state.libraryCoverage?.totalLoaded, 241)
        XCTAssertEqual(state.libraryCoverage?.totalOnNoChannel, 21, "the extra film and the twenty whose channel no longer takes them")
        state.disconnect()
    }
}
