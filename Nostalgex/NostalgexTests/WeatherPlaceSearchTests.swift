import XCTest
@testable import Nostalgex

/// The weather channel's place search and its loop (GitHub #332 and the 2026-11-18 find): a failed read of the place
/// list is never remembered, a search that is cancelled by the next keystroke does not take the fetch down with it,
/// a postcode with many localities is not cut at 8, and a place with no radar coverage gets a loop without the radar.
final class WeatherPlaceSearchTests: XCTestCase {
    private func json(_ any: Any) -> Data { (try? JSONSerialization.data(withJSONObject: any)) ?? Data() }

    private var meta: Data {
        json(["tz": ["America/Toronto"], "postcodes": ["AU"], "split": [String]()])
    }
    private var toronto: Data {
        json([["Toronto", "CA", "ON", 43.65, -79.38, 0]])
    }

    /// Counts the reads of each path, and answers from a script.
    private actor Reads {
        private(set) var counts: [String: Int] = [:]
        func note(_ path: String) -> Int {
            counts[path, default: 0] += 1
            return counts[path]!
        }
        func count(_ path: String) -> Int { counts[path] ?? 0 }
    }

    /// A loader that returns nil the first time it is asked for meta.json, then the file. A network error, then a retry.
    func testAFailedReadIsAskedAgainOnTheNextSearch() async {
        let reads = Reads()
        let files: [String: Data] = ["places/meta.json": meta, "places/c/to.json": toronto]
        let index = WeatherPlaceIndex { path in
            let n = await reads.note(path)
            return (path == "places/meta.json" && n == 1) ? nil : files[path]
        }
        let first = await index.search("toronto")
        XCTAssertEqual(first.hint, "PLACE LIST NOT AVAILABLE")
        XCTAssertTrue(first.places.isEmpty)

        let second = await index.search("toronto")
        XCTAssertEqual(second.places.map(\.label), ["TORONTO, ON, CA"], "hint: \(second.hint)")
        let metaReads = await reads.count("places/meta.json")
        XCTAssertEqual(metaReads, 2, "meta.json is read again after the failure, then kept")
        _ = await index.search("toronto")
        let kept = await reads.count("places/meta.json")
        XCTAssertEqual(kept, 2)
    }

    /// The Apple TV's real loader reads with URLSession inside the search task, which a keystroke cancels, and a
    /// cancelled read answers nil. The read must not be a child of the search that was cancelled.
    func testACancelledSearchDoesNotPoisonLaterOnes() async throws {
        let reads = Reads()
        let gate = Gate()
        let files: [String: Data] = ["places/meta.json": meta, "places/c/to.json": toronto]
        let index = WeatherPlaceIndex { path in
            _ = await reads.note(path)
            if path == "places/meta.json" { await gate.wait() }
            // What URLSession does when its task is cancelled.
            if Task.isCancelled { return nil }
            return files[path]
        }
        let first = Task { await index.search("tor") }
        // Wait until the first read is under way, then cancel the search that started it, as the next letter does.
        for _ in 0..<200 where await reads.count("places/meta.json") == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let started = await reads.count("places/meta.json")
        XCTAssertEqual(started, 1)
        first.cancel()
        let second = Task { await index.search("toronto") }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        _ = await first.value
        let result = await second.value
        XCTAssertEqual(result.places.map(\.label), ["TORONTO, ON, CA"], "hint: \(result.hint)")
        let metaReads = await reads.count("places/meta.json")
        XCTAssertEqual(metaReads, 1, "the second search joins the read that is under way")

        // And it stays: a later search is served from what was read.
        let later = await index.search("toronto")
        XCTAssertEqual(later.places.map(\.label), ["TORONTO, ON, CA"])
        let after = await reads.count("places/meta.json")
        XCTAssertEqual(after, 1)
    }

    /// A file that does not exist (a postcode shard) is remembered; one that could not be read is not.
    func testNotFoundIsRememberedAndFailedIsNot() async {
        let reads = Reads()
        let meta = self.meta, toronto = self.toronto
        let index = WeatherPlaceIndex(fetch: { path in
            let n = await reads.note(path)
            if path == "places/meta.json" { return .data(meta) }
            if path.hasPrefix("places/z/AU/") { return .notFound }
            // A city shard: no answer the first time.
            return n == 1 ? .failed : .data(toronto)
        })
        _ = await index.search("1234")
        _ = await index.search("1234")
        let shard = await reads.count("places/z/AU/12.json")
        XCTAssertEqual(shard, 1, "a 404 is asked once")

        let one = await index.search("toronto")
        XCTAssertTrue(one.places.isEmpty)
        let two = await index.search("toronto")
        XCTAssertEqual(two.places.map(\.label), ["TORONTO, ON, CA"])
    }

    /// GitHub #332: a postcode with more localities than 8 is not cut at 8. The whole code still comes first.
    func testAPostcodeWithManyLocalitiesIsNotCutAtEight() async {
        var rows: [[Any]] = (1...49).map { ["2000\($0)", "Locality \($0)", "NSW", -33.0, 151.0, 0] }
        rows.append(["2000", "Sydney", "NSW", -33.87, 151.21, 0])
        let files: [String: Data] = ["places/meta.json": meta, "places/z/AU/20.json": json(rows)]
        let index = WeatherPlaceIndex { path in files[path] }
        let result = await index.search("2000")
        XCTAssertGreaterThan(WeatherPlaceIndex.maxResults, 8)
        XCTAssertGreaterThanOrEqual(WeatherPlaceIndex.maxResults, 30)
        XCTAssertLessThanOrEqual(WeatherPlaceIndex.maxResults, 40)
        XCTAssertEqual(result.places.count, WeatherPlaceIndex.maxResults)
        XCTAssertEqual(result.places.first?.code, "2000", "the whole code first")
        XCTAssertEqual(result.places.dropFirst().first?.code, "20001", "then the longer ones, in the file's order")
    }

    /// The loop is only screens that carry data: a place with no radar source has no radar screen.
    func testThePlaceWithNoRadarGetsALoopWithoutIt() {
        func place(_ cc: String) -> WeatherEngine.Place {
            .init(name: "X", region: "", cc: cc, lat: 50, lon: 0, tz: "UTC", kind: "city", code: nil, label: nil)
        }
        for cc in ["US", "CA", "DE"] { XCTAssertTrue(WeatherEngine.hasRadar(place(cc)), cc) }
        for cc in ["GB", "AU", "FR", "MX", ""] { XCTAssertFalse(WeatherEngine.hasRadar(place(cc)), cc) }
        XCTAssertTrue(WeatherEngine.hasRadar(nil), "no place yet: the whole loop, as the screens are not shown")

        XCTAssertEqual(WeatherEngine.activeScreens(hasRadar: true).map(\.id), ["current", "today", "week", "radar"])
        XCTAssertEqual(WeatherEngine.activeScreens(hasRadar: false).map(\.id), ["current", "today", "week"])
        XCTAssertEqual(WeatherEngine.loopSeconds(hasRadar: true), 65)
        XCTAssertEqual(WeatherEngine.loopSeconds(hasRadar: false), 45)

        // Across two loops, no moment of a no-radar loop lands on the radar, and every screen gets its time.
        var seen: [String: Int] = [:]
        for s in stride(from: 0.0, to: 90.0, by: 1.0) {
            let at = WeatherEngine.screenAt(s * 1000, hasRadar: false)
            XCTAssertNotEqual(at.screen.id, "radar", "at \(s) s")
            XCTAssertLessThan(at.index, 3)
            seen[at.screen.id, default: 0] += 1
        }
        XCTAssertEqual(seen, ["current": 30, "today": 30, "week": 30])
        XCTAssertEqual(WeatherEngine.screenAt(44_000, hasRadar: false).screen.id, "week")
        XCTAssertEqual(WeatherEngine.screenAt(45_000, hasRadar: false).screen.id, "current")
        // With radar the loop is what it was.
        XCTAssertEqual(WeatherEngine.screenAt(50_000, hasRadar: true).screen.id, "radar")
        XCTAssertEqual(WeatherEngine.screenAt(50_000).screen.id, "radar")
    }
}

/// A door a test holds shut until it opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters = []
    }
}
