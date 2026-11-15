import XCTest
@testable import Nostalgex

/// #315: does a file play to its own end at every programme boundary, and does the guide stay with it?
///
/// A simulated clock walks six hours (20:00 to 02:00, so every channel crosses local midnight) over the demo
/// channels, and plays each programme the way the player does: a file lasts its real length (the server's runtime
/// in seconds, 5 to 55 s past its floored minutes, plus 0 to 0.6 s the metadata does not say), the next file starts
/// `loadSeconds` after the last ended, and the next programme is whatever `advanceToNextItem` picks at the moment a
/// file ends. Per boundary it records the tail of a file that never played (`lost`), the seconds the player is
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
        var advances = 0, cuts = 0
        var lost: [Double] = []
        var lag: [Double] = []
        var headSkipped: [Double] = []
        var samples = 0, mismatches = 0
    }

    private func walk(_ ch: Channel, hours: Double, loadSeconds: Double, useTick: Bool) throws -> Run {
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

        func started(from advanceAt: Date, previous: PlexMediaItem, playedSeconds: Double, natural: Bool) {
            run.advances += 1
            let lost = max(0, Self.realLength(previous) - playedSeconds)
            run.lost.append(lost)
            if lost > 0.5 { run.cuts += 1 }
            item = state.currentItem!
            seek = Double(state.playerSeekSeconds)
            run.headSkipped.append(seek)
            playStart = advanceAt.addingTimeInterval(loadSeconds)
            fileEnd = playStart.addingTimeInterval(Self.realLength(item) - seek)
            if let np = guide(advanceAt)?.nowPlaying {
                let start = np.item.id == item.id ? np.startTime : (guide(advanceAt)?.upNext?.startTime ?? np.startTime)
                run.lag.append(playStart.timeIntervalSince(start))
            }
        }

        var step = 0
        while t < stop {
            t += 1
            step += 1
            if fileEnd <= t {
                clock = fileEnd
                let gen = state.loadGeneration
                let before = item
                let played = Self.realLength(before) - 0 // a natural end plays all of it
                state.handlePartEnded()
                if state.loadGeneration != gen { started(from: clock, previous: before, playedSeconds: played, natural: true) } else { fileEnd = .distantFuture }
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

    private func report(_ label: String, _ pool: Pool, loadSeconds: Double = 2, useTick: Bool = false) throws {
        let lu = lineup(pool)
        state.allChannels = lu; state.channels = lu
        var all = Run()
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            let r = try walk(ch, hours: 6, loadSeconds: loadSeconds, useTick: useTick)
            all.advances += r.advances; all.cuts += r.cuts; all.lost += r.lost; all.lag += r.lag
            all.headSkipped += r.headSkipped; all.samples += r.samples; all.mismatches += r.mismatches
        }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let n = Double(max(1, all.advances))
        let lostSorted = all.lost.sorted()
        let over60 = all.lost.filter { $0 > 60 }.count
        let headCuts = all.headSkipped.filter { $0 > 0 }
        print("[TAILLOSS] \(label): advances=\(all.advances) tailLostMean=\(f(all.lost.reduce(0, +) / n))s tailLostMax=\(f(lostSorted.last ?? 0))s cutsOver0.5s=\(all.cuts) over60s=\(over60) mismatch=\(f(Double(all.mismatches) * 100 / Double(max(1, all.samples))))% (\(all.mismatches)/\(all.samples)) lagMean=\(f(all.lag.reduce(0, +) / Double(max(1, all.lag.count))))s lagMax=\(f(all.lag.max() ?? 0))s headSkips=\(headCuts.count) headSkippedTotal=\(f(headCuts.reduce(0, +)))s")
        XCTAssertGreaterThan(all.advances, 0)
    }

    func testDemoPoolsFillerLoop() throws { try report("demo pools (filler loop) load=2s", .demo) }
    func testMusicSmallPools() throws { try report("music videos, small pools load=2s", .music) }
    func testMusicBigPools() throws { try report("music videos, big pools (first pass) load=2s", .bigMusic) }
    func testMusicBigPoolsNoLoadTime() throws { try report("music videos, big pools load=0s", .bigMusic, loadSeconds: 0) }
    func testMusicBigPoolsWithoutCatchUp() throws {
        AppState.naturalEndCatchUpSeconds = Int.max
        defer { AppState.naturalEndCatchUpSeconds = 10 }
        try report("music videos, big pools load=2s, NO catch-up", .bigMusic)
    }
    func testCatchUpThresholds() throws {
        for threshold in [5, 10, 15, 20, 30, 60] {
            AppState.naturalEndCatchUpSeconds = threshold
            try report("music videos, big pools load=2s catch-up \(threshold)s", .bigMusic)
        }
        AppState.naturalEndCatchUpSeconds = 10
    }
    func testDemoPoolsWithoutCatchUp() throws {
        AppState.naturalEndCatchUpSeconds = Int.max
        defer { AppState.naturalEndCatchUpSeconds = 10 }
        try report("demo pools load=2s, NO catch-up", .demo)
    }
}
