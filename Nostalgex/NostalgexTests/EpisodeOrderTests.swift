import XCTest
@testable import Nostalgex

/// EPISODE ORDER (I-103): CLASSIC RERUNS airs two consecutive episodes of a show back to back from a random spot,
/// SHUFFLE airs one at a time in random order, and the order is part of a stored day's fingerprint. The days themselves are pinned by
/// scripts/episode-order-golden.json, which the web engine is checked against too
/// (scripts/nostalgex-episode-order-smoke.mjs). Regenerate it with scripts/schedule-parity-golden.mjs
/// (order-cases, then ScheduleParityTests.testDumpForAFixtureFile, then order-fold).
final class EpisodeOrderTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var saved: EpisodeOrder = .classicReruns

    override func setUp() {
        super.setUp()
        saved = EpisodeOrder.current
        EpisodeOrder.current = .classicReruns
    }

    override func tearDown() {
        EpisodeOrder.current = saved
        super.tearDown()
    }

    private func episode(_ show: String, season: Int? = 1, _ n: Int?, id: String? = nil, showKey: String? = nil,
                         year: Int? = 1990) -> PlexMediaItem {
        let s = season.map { "S\(String(format: "%02d", $0))" } ?? ""
        let e = n.map { "E\(String(format: "%02d", $0))" } ?? ""
        let key = id ?? "\(show)-\(season ?? 0)-\(n ?? 0)"
        var item = PlexMediaItem(
            id: key, title: show, artist: nil, episodeTitle: nil, seTag: (s + e).isEmpty ? nil : s + e, summary: "",
            year: year, originallyAvailableAt: nil, contentRating: nil, duration: 22,
            ratingKey: key, partKey: nil, container: "mp4", videoCodec: nil, audioCodec: nil,
            videoProfile: nil, bitrate: nil, genres: [], rating: 0, userRating: 0,
            type: .episode, thumb: nil, art: nil, viewCount: 0,
            addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .tv, exactDurationSeconds: nil)
        item.showKey = showKey
        return item
    }

    private func film(_ key: String) -> PlexMediaItem {
        PlexMediaItem(
            id: key, title: key, artist: nil, episodeTitle: nil, seTag: nil, summary: "",
            year: 1990, originallyAvailableAt: nil, contentRating: nil, duration: 95,
            ratingKey: key, partKey: nil, container: "mp4", videoCodec: nil, audioCodec: nil,
            videoProfile: nil, bitrate: nil, genres: [], rating: 0, userRating: 0,
            type: .movie, thumb: nil, art: nil, viewCount: 0,
            addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie, exactDurationSeconds: nil)
    }

    /// A: two seasons of three, listed out of order. B: six in one season. C: one episode.
    private var pool: [PlexMediaItem] {
        [episode("A", season: 2, 2), episode("A", season: 1, 3), episode("A", season: 1, 1), episode("A", season: 2, 1),
         episode("A", season: 1, 2), episode("A", season: 2, 3)]
            + (1...6).map { episode("B", $0) } + [episode("C", 1)]
    }

    /// Every run of one show in `ordered`, as the ids in it.
    private func runs(_ ordered: [PlexMediaItem]) -> [[String]] {
        var out: [[String]] = []
        for (i, item) in ordered.enumerated() {
            if i > 0, ordered[i - 1].title == item.title, item.type == .episode { out[out.count - 1].append(item.id) }
            else { out.append([item.id]) }
        }
        return out
    }

    func testTheDefaultIsClassicRerunsAndSavesNothing() {
        XCTAssertEqual(EpisodeOrder.current, .classicReruns)
        XCTAssertNil(AppDefaults.standard.string(forKey: EpisodeOrder.defaultsKey))
        XCTAssertEqual(EpisodeOrder.classicReruns.fingerprintSuffix, "")
        XCTAssertEqual(EpisodeOrder.classicReruns.next, .shuffle)
        XCTAssertEqual(EpisodeOrder.shuffle.next, .classicReruns)
    }

    func testSeriesOrderIsBySeasonThenEpisodeWithTheUnnumberedLast() {
        let mixed = [episode("A", season: nil, nil), episode("A", season: 2, 1), episode("A", season: nil, 5), episode("A", season: 1, 9)]
        XCTAssertEqual(SchedulePoolOrdering.inSeriesOrder(mixed).map(\.id), ["A-0-5", "A-1-9", "A-2-1", "A-0-0"])
    }

    /// Two back to back are always consecutive episodes: the next in the season, the first of the next season after
    /// the last of one, the first of the series after the last.
    func testClassicRerunsPairsAreConsecutiveEpisodes() {
        let next = SchedulePoolOrdering.seriesNext(pool)
        XCTAssertEqual(next["A-1-3"], "A-2-1", "the last of a season is followed by the first of the next")
        XCTAssertEqual(next["A-2-3"], "A-1-1", "the last of the series is followed by the first")
        XCTAssertNil(next["C-1-1"], "a show with one episode has no pair")
        var pairs = 0
        for day in 1...40 {
            let ordered = SchedulePoolOrdering.interleaveByShow(pool, seed: 7, dayNumber: day)
            XCTAssertEqual(Set(ordered.map(\.id)).count, pool.count, "day \(day): every episode once")
            for run in runs(ordered) {
                XCTAssertLessThanOrEqual(run.count, 2, "day \(day): \(run)")
                if run.count == 2 {
                    XCTAssertEqual(next[run[0]], run[1], "day \(day): \(run) are not consecutive episodes")
                    pairs += 1
                }
            }
        }
        XCTAssertGreaterThan(pairs, 150)
    }

    func testClassicRerunsStartsAShowAtADifferentSpotOnDifferentDays() {
        let firsts = Set((1...40).map { day in
            SchedulePoolOrdering.interleaveByShow(pool, seed: 7, dayNumber: day).first { $0.title == "B" }!.id
        })
        XCTAssertGreaterThan(firsts.count, 3)
    }

    /// The day's ordering leaves out what aired yesterday. An episode whose neighbour is gone airs alone.
    func testAnEpisodeWhoseNeighbourAiredYesterdayIsNotPairedWithAStranger() {
        let next = SchedulePoolOrdering.seriesNext(pool)
        let unplayed = pool.filter { !["B-1-3", "A-1-2"].contains($0.id) }
        for day in 1...40 {
            let ordered = SchedulePoolOrdering.interleaveByShow(unplayed, seed: 7, dayNumber: day, seriesNext: next)
            for run in runs(ordered) where run.count > 1 {
                XCTAssertEqual(run.count, 2)
                XCTAssertEqual(next[run[0]], run[1], "day \(day): \(run)")
            }
        }
    }

    func testAChannelOfFilmsIsOrderedAsItWasBeforeTheSetting() {
        // A film is alone in its group and draws nothing from the generator: the films' order is the groups' shuffle.
        let films = (1...12).map { film("f\($0)") }
        var rng = SeededRNG(seed: UInt64(7 + 1) &+ UInt64(20_000))
        var expected = films
        expected.shuffle(using: &rng)
        XCTAssertEqual(SchedulePoolOrdering.interleaveByShow(films, seed: 7, dayNumber: 20_000).map(\.id), expected.map(\.id))
        XCTAssertEqual(SchedulePoolOrdering.interleaveByShow(films, seed: 7, dayNumber: 20_000, order: .shuffle).map(\.id), expected.map(\.id))
    }

    func testShuffleAirsOneEpisodeOfAShowAtATime() {
        for day in 1...40 {
            let ordered = SchedulePoolOrdering.interleaveByShow(pool, seed: 7, dayNumber: day, order: .shuffle)
            XCTAssertEqual(Set(ordered.map(\.id)).count, pool.count)
            // The tail can be one show alone once the others have run out; before that, never two in a row.
            for (i, item) in ordered.enumerated().dropFirst() where ordered[i - 1].title == item.title {
                XCTAssertFalse(ordered[(i + 1)...].contains { $0.title != item.title }, "day \(day): two of \(item.title) with others waiting")
            }
        }
    }

    /// Another channel has the second of a pair on: the pair still airs together, and no later episode of the show
    /// goes ahead of an earlier one.
    func testAnotherChannelCannotSplitAPairOrReorderAShow() {
        let queue = [episode("B", 1), episode("B", 2), film("f1"), episode("B", 3)]
        var occupancy = ScheduleOccupancy()
        occupancy.add(channelID: 99, key: "B-1-1", start: 0, end: 10_000, gated: false)
        let picked = DailyManifestScheduler.pickCandidate(queue, at: 100, playSeconds: { _ in 600 }, occupancy: occupancy,
                                                          channelId: 1, avoidKey: nil, mustFit: true, skippingGated: false,
                                                          keepingShowOrder: true)
        XCTAssertEqual(picked, 2, "the film goes first; episode 2 and 3 wait behind episode 1")
        let before = DailyManifestScheduler.pickCandidate(queue, at: 100, playSeconds: { _ in 600 }, occupancy: occupancy,
                                                          channelId: 1, avoidKey: nil, mustFit: true, skippingGated: false)
        XCTAssertEqual(before, 1, "without the rule the next episode jumps ahead")
    }

    /// Two shows with one title are two shows: by the server's id for the show, else by year.
    func testTwoShowsWithOneTitleAreNotInterleavedAsOne() {
        let byKey = (1...4).map { (n: Int) in episode("The Office", n, id: "uk\(n)", showKey: "uk") }
            + (1...4).map { (n: Int) in episode("The Office", n, id: "us\(n)", showKey: "us") }
        let byYear = (1...4).map { (n: Int) in episode("Dragnet", n, id: "a\(n)", year: 1951) }
            + (1...4).map { (n: Int) in episode("Dragnet", n, id: "b\(n)", year: 1967) }
        for pool in [byKey, byYear] {
            let next = SchedulePoolOrdering.seriesNext(pool)
            XCTAssertEqual(next.count, 8)
            for (a, b) in next { XCTAssertEqual(a.prefix(1), b.prefix(1), "\(a) is followed by \(b), another show's episode") }
            for day in 1...20 {
                let ordered = SchedulePoolOrdering.interleaveByShow(pool, seed: 7, dayNumber: day)
                XCTAssertEqual(ordered.count, 8)
                let pairs = SchedulePoolOrdering.pairs(in: ordered, seriesNext: next)
                XCTAssertEqual(pairs.count, 4, "day \(day): \(ordered.map(\.id))")
            }
        }
    }

    /// A show held twice under one show (two files per episode): one copy of each episode airs, and a pair is never
    /// the same episode twice.
    func testASecondCopyOfAnEpisodeDoesNotAir() {
        let pool = (1...4).flatMap { (n: Int) in [episode("Echo", n, id: "hd\(n)", showKey: "e"), episode("Echo", n, id: "uhd\(n)", showKey: "e")] }
            + (1...4).map { episode("Foxtrot", $0, showKey: "f") }
        XCTAssertEqual(SchedulePoolOrdering.withoutSecondCopies(Array(pool.prefix(8))).map(\.id), ["hd1", "hd2", "hd3", "hd4"])
        for order in EpisodeOrder.allCases {
            for day in 1...20 {
                let ordered = SchedulePoolOrdering.interleaveByShow(pool, seed: 7, dayNumber: day, order: order)
                XCTAssertEqual(ordered.filter { $0.title == "Echo" }.map(\.id).sorted(), ["hd1", "hd2", "hd3", "hd4"], "\(order) day \(day)")
            }
        }
        // Only a tag with both halves says two items are one episode: a show with seasons but no episode numbers is kept whole.
        let unnumbered = (1...3).map { (n: Int) in episode("Golf", season: 1, nil, id: "g\(n)") }
        XCTAssertEqual(SchedulePoolOrdering.withoutSecondCopies(unnumbered).count, 3)
    }

    /// The pairs of an order as it airs: three of a show in a row are a pair and a single.
    func testPairsAreReadFromTheOrderAsBuilt() {
        let run = (1...5).map { episode("B", $0) }
        let next = SchedulePoolOrdering.seriesNext(run)
        XCTAssertEqual(SchedulePoolOrdering.pairs(in: Array(run.prefix(3)), seriesNext: next), ["B-1-1": "B-1-2"])
        XCTAssertEqual(SchedulePoolOrdering.pairs(in: [run[0], run[2], run[3]], seriesNext: next), ["B-1-3": "B-1-4"])
    }

    func testTheShowThatJustHadItsTurnIsPassedOver() {
        let queue = [episode("B", 3), episode("B", 4), film("f1")]
        let picked = DailyManifestScheduler.pickCandidate(queue, at: 100, playSeconds: { _ in 600 }, occupancy: nil,
                                                          channelId: 1, avoidKey: nil, mustFit: true, skippingGated: false,
                                                          keepingShowOrder: true,
                                                          avoidingShow: SchedulePoolOrdering.showIdentity(queue[0]))
        XCTAssertEqual(picked, 2)
        let alone = DailyManifestScheduler.pickCandidate(Array(queue.prefix(2)), at: 100, playSeconds: { _ in 600 }, occupancy: nil,
                                                         channelId: 1, avoidKey: nil, mustFit: true, skippingGated: false,
                                                         keepingShowOrder: true,
                                                         avoidingShow: SchedulePoolOrdering.showIdentity(queue[0]))
        XCTAssertNil(alone, "nothing else fits: the caller asks again without the show")
    }

    /// "Keep the pair whole" (Chad, 2026-11-19): the second episode of a pair airs straight after the first even when
    /// another channel has that episode on. In the golden case channel 22 airs one episode all day; channel 32 opens
    /// its day with that episode's pair, whole.
    func testAPairIsKeptWholeWhenAnotherChannelHasItsSecondEpisodeOn() throws {
        let url = Self.repoRoot.appendingPathComponent("scripts/schedule-parity-golden.json")
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(golden["cases"] as? [[String: Any]])
        let pairs = try XCTUnwrap(cases.first { $0["name"] as? String == "plex-denver-pairs-kept" })
        let fixture = try XCTUnwrap(pairs["fixture"] as? [String: Any])
        let got = try ScheduleParityTests.dump(fixture)
        let days = try XCTUnwrap(got["days"] as? [String: Any])
        let firstDay = try XCTUnwrap(days[try XCTUnwrap(days.keys.sorted().first)] as? [String: Any])
        func blocks(_ channel: String) throws -> [(key: String, start: Int, end: Int)] {
            try XCTUnwrap(firstDay[channel] as? [[Any]]).map {
                (key: $0[0] as? String ?? "", start: ($0[1] as? NSNumber)?.intValue ?? 0, end: ($0[2] as? NSNumber)?.intValue ?? 0)
            }
        }
        let blocker = try blocks("22")
        let channel = try blocks("32")
        let second = try XCTUnwrap(blocker.first?.key)
        XCTAssertTrue(blocker.allSatisfy { $0.key == second }, "setup: channel 22 airs one episode all day")
        XCTAssertEqual(channel.count > 1 ? channel[1].key : "", second, "the second of the pair airs straight after the first")
        XCTAssertTrue(blocker.contains { $0.start < channel[1].end && $0.end > channel[1].start }, "setup: it is on channel 22 at that moment")
    }

    func testTheOrderIsPartOfADaysFingerprintAndClassicKeepsTheOldOne() {
        let classic = DailyManifestStore.poolFingerprint(items: pool)
        EpisodeOrder.current = .shuffle
        let shuffle = DailyManifestStore.poolFingerprint(items: pool)
        XCTAssertNotEqual(classic, shuffle, "a day packed under one order must not be served under another")
        EpisodeOrder.current = .classicReruns
        XCTAssertEqual(DailyManifestStore.poolFingerprint(items: pool), classic)
        XCTAssertNil(AppDefaults.standard.string(forKey: EpisodeOrder.defaultsKey))
    }

    func testAnUnknownSavedValueIsClassicReruns() {
        AppDefaults.standard.set("marathon", forKey: EpisodeOrder.defaultsKey)
        XCTAssertEqual(EpisodeOrder.current, .classicReruns)
        AppDefaults.standard.removeObject(forKey: EpisodeOrder.defaultsKey)
    }

    func testTheAppleTVAirsWhatTheEpisodeOrderGoldenFileSays() throws {
        let url = Self.repoRoot.appendingPathComponent("scripts/episode-order-golden.json")
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(golden["cases"] as? [[String: Any]])
        XCTAssertTrue(cases.contains { ($0["fixture"] as? [String: Any])?["episodeOrder"] as? String == "shuffle" })
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let fixture = try XCTUnwrap(c["fixture"] as? [String: Any], name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            XCTAssertEqual(try ScheduleParityTests.canonical(try ScheduleParityTests.dump(fixture)),
                           try ScheduleParityTests.canonical(expect), "\(name): the Apple TV no longer airs what the golden file says")
        }
        XCTAssertEqual(EpisodeOrder.current, .classicReruns, "a fixture's order must not stay saved")
    }
}
