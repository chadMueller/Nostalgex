import XCTest
@testable import Nostalgex

/// #315: does a file play to its own end at every programme boundary, and does the guide stay with it?
///
/// A simulated clock walks six hours (20:00 to 02:00, so every channel crosses local midnight) over the demo
/// channels, and plays each programme the way the player does: a file lasts its real length (the server's runtime
/// in seconds, 5 to 55 s past its floored minutes, plus 0 to 0.6 s the metadata does not say), the next file starts
/// `loadSeconds` after the last ended, and the next programme is whatever `advanceToNextItem` picks at the moment a
/// file ends. Per boundary it records how much longer the file that just ended is than the slot the guide gave it (`overrun`: 0 or less means the guide never moved on before the file finished, so no tail is cut), the seconds the player is
/// behind the guide when a programme starts (`lag`), the opening seconds a catch-up skipped (`head`), and every 15 s
/// whether the Now Playing headline names the programme the guide has on air (`mismatch`). It prints `[TAILLOSS]`
/// lines and asserts only what the code under test is meant to guarantee; see NaturalEndDriftTests.
///
/// Pools: `demo` is the demo channels as they are (small pools, so the day is filled by the filler loop, which is where
/// the midnight edge lives), `music` the same channels at music-video lengths (3 to 5 minute slots), `bigMusic` the
/// music pool cloned 40 times so the day is filled by the first pass, as on a real library.
@MainActor
final class TailLossMeasureTests: XCTestCase {

    private var state: AppState!
    private var clock = Date()

    private static let base: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 9; c.hour = 20
        return Calendar.current.date(from: c)!
    }()

    override func setUp() async throws {
        try await super.setUp()
        state = AppState()
        clock = Self.base
        state.scheduleClock = { [unowned self] in self.clock }
    }

    override func tearDown() async throws {
        if let state {
            state.playbackResolutionTask?.cancel()
            state.playbackWatchdogTask?.cancel()
            state.playbackSkipTask?.cancel()
            state.cancellables.removeAll()
            state.loadGeneration += 1
            DailyManifestStore.clearAll(credentialFingerprint: state.scheduleCredentialFingerprint)
            DailyManifestScheduler.invalidateMemo()
        }
        state = nil
        try await super.tearDown()
    }

    private static func hash(_ item: PlexMediaItem) -> Int {
        abs(item.ratingKey.unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) })
    }

    private static func rebuilt(_ item: PlexMediaItem, minutes: Int?, cloneIndex: Int) -> PlexMediaItem {
        let data = try! JSONEncoder().encode(item)
        var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let minutes { obj["duration"] = minutes }
        if cloneIndex > 0 {
            obj["id"] = "\(item.id)-c\(cloneIndex)"
            obj["ratingKey"] = "\(item.ratingKey)-c\(cloneIndex)"
        }
        return try! JSONDecoder().decode(PlexMediaItem.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    enum Pool { case demo, music, bigMusic }

    private func lineup(_ pool: Pool) -> [Channel] {
        DemoData.channels().map { ch in
            var c = ch
            var out: [PlexMediaItem] = []
            for item in c.itemPool {
                let copies = pool == .bigMusic ? 40 : 1
                for k in 0..<copies {
                    var i = Self.rebuilt(item, minutes: pool == .demo ? nil : 3 + Self.hash(item) % 3, cloneIndex: k)
                    i.exactDurationSeconds = Double(i.duration * 60) + Double(5 + Self.hash(item) % 51)
                    out.append(i)
                }
            }
            c.itemPool = out
            return c
        }
    }

    /// What the file really lasts: the server's runtime plus a little the metadata does not say.
    private static func realLength(_ i: PlexMediaItem) -> Double {
        (i.exactDurationSeconds ?? Double(i.duration * 60)) + Double(hash(i) % 7) / 10
    }

    struct Run {
        var advances = 0
        var overrun: [Double] = []
        var lag: [Double] = []
        var headSkipped: [Double] = []
        var samples = 0, mismatches = 0
    }

    private func walk(_ ch: Channel, hours: Double, loadSeconds: Double) throws -> Run {
        var run = Run()
        let fp = state.scheduleCredentialFingerprint
        func guide(_ t: Date) -> ChannelSchedule? { ChannelScheduleBuilder.buildSchedule(for: ch, at: t, credentialFingerprint: fp) }
        var t = Self.base
        for _ in 0..<400 {
            let np = try XCTUnwrap(guide(t)?.nowPlaying)
            if t.timeIntervalSince(np.startTime) >= 60, np.endTime.timeIntervalSince(t) >= 120 { break }
            t += 60
        }
        clock = t
        var all: [Int: ChannelSchedule] = [:]
        for c in state.channels { if let s = ChannelScheduleBuilder.buildSchedule(for: c, at: t, credentialFingerprint: fp) { all[c.id] = s } }
        ChannelScheduleBuilder.resolveConflicts(&all)
        state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: all[ch.id])
        let stop = t.addingTimeInterval(hours * 3600)

        var item = state.currentItem!
        var seek = Double(state.playerSeekSeconds)
        var playStart = clock.addingTimeInterval(-seek)
        var fileEnd = playStart.addingTimeInterval(Self.realLength(item))
        var lastSample = 0
        // How long the guide gives the programme now playing. A file longer than this is one the guide moves on from
        // before it finishes; that is what cut a tail. (Not how late the file ends: a file that starts late, after a load
        // or a catch-up, ends late by as much, which is the lag, measured separately.)
        func blockLength(_ e: ScheduleEntry?) -> Double { e.map { $0.endTime.timeIntervalSince($0.startTime) } ?? .infinity }
        var slot = blockLength(guide(t)?.nowPlaying)

        func started(from advanceAt: Date) {
            run.advances += 1
            item = state.currentItem!
            seek = Double(state.playerSeekSeconds)
            run.headSkipped.append(seek)
            playStart = advanceAt.addingTimeInterval(loadSeconds)
            fileEnd = playStart.addingTimeInterval(Self.realLength(item) - seek)
            if let np = guide(advanceAt)?.nowPlaying {
                let start = np.item.id == item.id ? np.startTime : (guide(advanceAt)?.upNext?.startTime ?? np.startTime)
                run.lag.append(playStart.timeIntervalSince(start))
                slot = blockLength(np.item.id == item.id ? np : guide(advanceAt)?.upNext ?? np)
            }
        }

        var step = 0
        while t < stop {
            t += 1
            step += 1
            if fileEnd <= t {
                clock = fileEnd
                let gen = state.loadGeneration
                // How much longer the file that just ended is than the slot the guide gave it: 0 or less means the guide
                // never moved on before the file finished.
                let ranPast = Self.realLength(item) - slot
                state.handlePartEnded()
                if state.loadGeneration != gen { run.overrun.append(ranPast); started(from: clock) } else { fileEnd = .distantFuture }
            }
            clock = t
            if step - lastSample >= 15, let live = guide(t)?.nowPlaying {
                lastSample = step
                run.samples += 1
                if state.currentItem?.id != live.item.id { run.mismatches += 1 }
            }
        }
        return run
    }

    struct Summary {
        var advances = 0, samples = 0, mismatches = 0, headSkips = 0
        var overrunMax = -Double.infinity, lagMax = 0.0
        var mismatchPercent: Double { Double(mismatches) * 100 / Double(max(1, samples)) }
    }

    @discardableResult
    private func report(_ label: String, _ pool: Pool, loadSeconds: Double = 2) throws -> Summary {
        let lu = lineup(pool)
        state.allChannels = lu; state.channels = lu
        var all = Run()
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            let r = try walk(ch, hours: 6, loadSeconds: loadSeconds)
            all.advances += r.advances; all.overrun += r.overrun; all.lag += r.lag
            all.headSkipped += r.headSkipped; all.samples += r.samples; all.mismatches += r.mismatches
        }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let headCuts = all.headSkipped.filter { $0 > 0 }
        var out = Summary(advances: all.advances, samples: all.samples, mismatches: all.mismatches, headSkips: headCuts.count)
        out.overrunMax = all.overrun.max() ?? 0
        out.lagMax = all.lag.max() ?? 0
        print("[TAILLOSS] \(label): advances=\(all.advances) fileLongerThanItsSlotMax=\(f(out.overrunMax))s mismatch=\(f(out.mismatchPercent))% (\(all.mismatches)/\(all.samples)) lagMean=\(f(all.lag.reduce(0, +) / Double(max(1, all.lag.count))))s lagMax=\(f(out.lagMax))s headSkips=\(headCuts.count) headSkippedTotal=\(f(headCuts.reduce(0, +)))s")
        XCTAssertGreaterThan(all.advances, 0)
        return out
    }

    /// Nothing moves a file on before it ends (no programme ends in the guide before its file, but for the 0 to 0.6 s the
    /// runtime does not say), so no tail is cut; and the headline stays within the catch-up of the guide.
    private func assertPlaysThrough(_ s: Summary, _ label: String) {
        XCTAssertLessThanOrEqual(s.overrunMax, 0.61, "\(label): a file was \(s.overrunMax) s longer than its slot, the guide moved on before it ended")
        XCTAssertLessThan(s.mismatchPercent, 5, "\(label): Now Playing differs from the guide in \(s.mismatchPercent)% of samples")
        XCTAssertLessThanOrEqual(s.lagMax, Double(AppState.naturalEndCatchUpSeconds) + 2 + 5, "\(label)")
    }

    func testDemoPoolsFillerLoop() throws { assertPlaysThrough(try report("demo pools (filler loop) load=2s", .demo), "demo") }
    func testMusicSmallPools() throws { assertPlaysThrough(try report("music videos, small pools load=2s", .music), "music small") }
    func testMusicBigPools() throws { assertPlaysThrough(try report("music videos, big pools (first pass) load=2s", .bigMusic), "music big") }
    func testMusicBigPoolsNoLoadTime() throws { assertPlaysThrough(try report("music videos, big pools load=0s", .bigMusic, loadSeconds: 0), "music big, no load") }

    /// Without the catch-up the lag from load time grows for the whole run: the reason it exists.
    func testWithoutTheCatchUpTheHeadlineFallsFarBehind() throws {
        let saved = AppState.naturalEndCatchUpSeconds
        AppState.naturalEndCatchUpSeconds = Int.max
        defer { AppState.naturalEndCatchUpSeconds = saved }
        let off = try report("music videos, big pools load=2s, NO catch-up", .bigMusic)
        AppState.naturalEndCatchUpSeconds = saved
        let on = try report("music videos, big pools load=2s, catch-up \(saved)s", .bigMusic)
        XCTAssertGreaterThan(off.mismatchPercent, on.mismatchPercent * 3)
        XCTAssertGreaterThan(off.lagMax, on.lagMax * 3)
        XCTAssertEqual(off.headSkips, 0)
        XCTAssertGreaterThan(on.headSkips, 0)
    }

    /// The threshold sweep behind `naturalEndCatchUpSeconds` (about 100 s): set TEST_RUNNER_NX_TAILLOSS_SWEEP=1 to run it. A
    /// lower threshold skips the opening of more programmes and keeps the headline closer to the guide.
    func testCatchUpThresholdSweep() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NX_TAILLOSS_SWEEP"] != nil, "set TEST_RUNNER_NX_TAILLOSS_SWEEP=1 to run the sweep")
        let saved = AppState.naturalEndCatchUpSeconds
        defer { AppState.naturalEndCatchUpSeconds = saved }
        var runs: [(Int, Summary)] = []
        for threshold in [5, 10, 15, 20, 30, 60] {
            AppState.naturalEndCatchUpSeconds = threshold
            runs.append((threshold, try report("music videos, big pools load=2s catch-up \(threshold)s", .bigMusic)))
        }
        for (a, b) in zip(runs, runs.dropFirst()) {
            XCTAssertLessThanOrEqual(a.1.mismatchPercent, b.1.mismatchPercent, "\(a.0) s against \(b.0) s")
            XCTAssertGreaterThanOrEqual(a.1.headSkips, b.1.headSkips, "\(a.0) s against \(b.0) s")
        }
    }
}
