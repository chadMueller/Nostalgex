import XCTest
@testable import Nostalgex

/// A file plays to its own end, always, and the guide, Now Playing and Up Next stay with it (#315, #293).
///
/// Plex, Jellyfin and Emby floor a runtime to whole minutes. Until 1.0.31 the schedule slot was that floored length, so a
/// file ran 0 to 59 s past its slot and the player fell further behind the clock at every boundary (#293, the headline
/// named the programme still playing while the guide had moved on). 1.0.32 fixed that by cutting the file at the slot
/// end, which dropped up to the last minute of every file (a 4:11 song shown as 4:00 and cut at 4:00, #315). Now the
/// slot is the file's real runtime in seconds (`PlexMediaItem.slotSeconds`), so the two end together and nothing is
/// cut and nothing drifts; the day also no longer clips a block at midnight (the filler loop did) and starts after the
/// programme that runs over from yesterday.
///
/// These walk a simulated clock over the real scheduler the way DemoNowPlayingAgreementTests does: a file ending is
/// `handlePartEnded()` at the moment a real player would reach the end of a file of the given exact length. Nothing
/// needs the network. `TailLossMeasureTests` prints the before and after numbers.
@MainActor
final class NaturalEndDriftTests: XCTestCase {

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

    private var fp: String { state.scheduleCredentialFingerprint }

    private func raw(_ ch: Channel, _ t: Date) -> ChannelSchedule? {
        ChannelScheduleBuilder.buildSchedule(for: ch, at: t, credentialFingerprint: fp)
    }

    /// A lineup whose files run `extra(item)` seconds past their floored-minute length, the server's real runtime.
    private func lineup(extra: (PlexMediaItem) -> Double) -> [Channel] {
        DemoData.channels().map { ch in
            var c = ch
            c.itemPool = c.itemPool.map { item in
                var i = item
                i.exactDurationSeconds = Double(item.duration * 60) + extra(item)
                return i
            }
            return c
        }
    }

    /// Fraction of a minute the file runs past its floored minutes, stable per item and spread over 5 to 55 s.
    private static func spread(_ item: PlexMediaItem) -> Double {
        let h = abs(item.ratingKey.unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) })
        return Double(5 + (h % 51))
    }

    private func exact(_ i: PlexMediaItem) -> Double { i.exactDurationSeconds ?? Double(i.duration * 60) }

    // MARK: - The slot is the file

    private func item(minutes: Int, exact: Double?) throws -> PlexMediaItem {
        var i = try XCTUnwrap(DemoData.channels().first?.itemPool.first { $0.duration == minutes } ?? DemoData.channels().first?.itemPool.first)
        let data = try JSONEncoder().encode(i)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["duration"] = minutes
        i = try JSONDecoder().decode(PlexMediaItem.self, from: JSONSerialization.data(withJSONObject: obj))
        i.exactDurationSeconds = exact
        return i
    }

    /// A 4:11 song: Plex says 4 minutes and 251.0 s. The slot is 251 s, not 240.
    func testSlotIsTheRealRuntimeRoundedUpToASecond() throws {
        XCTAssertEqual(try item(minutes: 4, exact: 251.0).slotSeconds, 251)
        XCTAssertEqual(try item(minutes: 4, exact: 250.2).slotSeconds, 251, "rounded up, so the slot never ends before the file")
        XCTAssertEqual(try item(minutes: 4, exact: 240.0).slotSeconds, 240)
        XCTAssertEqual(try item(minutes: 90, exact: 5459.9).slotSeconds, 5460)
    }

    /// No runtime, or one that disagrees with the minutes by a minute or more (a bad value), is the minutes, as before.
    func testSlotFallsBackToTheMinutes() throws {
        XCTAssertEqual(try item(minutes: 4, exact: nil).slotSeconds, 240)
        XCTAssertEqual(try item(minutes: 4, exact: 0).slotSeconds, 240)
        XCTAssertEqual(try item(minutes: 4, exact: .nan).slotSeconds, 240)
        XCTAssertEqual(try item(minutes: 4, exact: 400).slotSeconds, 240, "a runtime minutes away from the minutes is not trusted")
        XCTAssertEqual(try item(minutes: 4, exact: 120).slotSeconds, 240)
    }

    /// Every block on every channel is exactly as long as its file, across a whole day boundary: the guide never moves
    /// on before a file ends, including the filler loop's last block before midnight and its first after it.
    func testEveryBlockIsAsLongAsItsFileAcrossMidnight() throws {
        let lu = lineup(extra: Self.spread)
        state.allChannels = lu; state.channels = lu
        var blocks = 0, crossingMidnight = 0
        let from = Self.base, to = Self.base.addingTimeInterval(30 * 3600)
        let midnight = Calendar.current.startOfDay(for: Self.base.addingTimeInterval(86400))
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            let day = DailyManifestScheduler.blocksInRange(for: ch, from: from, to: to, credentialFingerprint: fp)
            for b in day {
                blocks += 1
                XCTAssertEqual(b.durationSeconds, Double(b.item.slotSeconds), accuracy: 0.001,
                               "CH \(ch.number) \"\(b.item.title)\" is \(b.durationSeconds) s in the guide, its file \(b.item.slotSeconds) s")
                if b.startTime < midnight && b.endTime > midnight { crossingMidnight += 1 }
            }
        }
        XCTAssertGreaterThan(blocks, 20)
        XCTAssertGreaterThan(crossingMidnight, 0, "the lineup has programmes running over midnight to check")
    }

    /// The guide is one unbroken run across midnight: each block starts where the one before ended, so nothing is on
    /// air under a file that is still playing and nothing is missing after it.
    func testTheGuideTilesAcrossMidnightWithNoOverlapOrGap() throws {
        let lu = lineup(extra: Self.spread)
        state.allChannels = lu; state.channels = lu
        let from = Self.base, to = Self.base.addingTimeInterval(30 * 3600)
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            let day = DailyManifestScheduler.blocksInRange(for: ch, from: from, to: to, credentialFingerprint: fp)
            for (a, b) in zip(day, day.dropFirst()) {
                XCTAssertEqual(b.startTime.timeIntervalSince(a.endTime), 0, accuracy: 0.001,
                               "CH \(ch.number): \"\(a.item.title)\" ends \(a.endTime), \"\(b.item.title)\" starts \(b.startTime)")
            }
        }
    }

    /// The edge the 1.0.32 tick cut: a programme that runs over midnight. It is on air until its own end, the guide
    /// shows it at 00:05 (yesterday's stored day), and the next programme starts when it ends.
    func testAProgrammeRunningOverMidnightIsOnAirUntilItEnds() throws {
        let lu = lineup(extra: Self.spread)
        state.allChannels = lu; state.channels = lu
        let midnight = Calendar.current.startOfDay(for: Self.base.addingTimeInterval(86400))
        var checked = 0
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            _ = DailyManifestScheduler.blocksInRange(for: ch, from: Self.base, to: midnight.addingTimeInterval(3600), credentialFingerprint: fp)
            guard let straddler = raw(ch, midnight.addingTimeInterval(-60))?.nowPlaying, straddler.endTime > midnight.addingTimeInterval(1) else { continue }
            checked += 1
            let after = midnight.addingTimeInterval(1)
            let np = try XCTUnwrap(raw(ch, after)?.nowPlaying, "CH \(ch.number) has nothing on air after midnight")
            XCTAssertEqual(np.item.id, straddler.item.id, "CH \(ch.number): the file playing over midnight is not on air in the guide")
            XCTAssertEqual(np.endTime, straddler.endTime)
            let justAfter = try XCTUnwrap(raw(ch, straddler.endTime.addingTimeInterval(0.5))?.nowPlaying)
            XCTAssertNotEqual(justAfter.item.id, straddler.item.id)
            XCTAssertEqual(justAfter.startTime, straddler.endTime, "the next programme starts when the file ends")
        }
        XCTAssertGreaterThan(checked, 0, "no channel had a programme running over midnight")
    }

    // MARK: - Played through: no cut, no drift

    private struct Run { var samples = 0, mismatches = 0, boundaries = 0, advances = 0, first: String?, maxLag = 0.0, minLag = 0.0 }

    /// Tune a few minutes into a block, then let files end where their exact length says (plus `loadSeconds` between a
    /// file ending and the next one starting to play), sampling the headline against the guide's live block every 15 s
    /// for `hours` hours. Only the file ending moves the channel on: there is no clock tick any more.
    private func walk(_ ch: Channel, hours: Double, loadSeconds: Double = 0) throws -> Run {
        var run = Run()
        var t = Self.base
        for _ in 0..<200 {
            let np = try XCTUnwrap(raw(ch, t)?.nowPlaying)
            if t.timeIntervalSince(np.startTime) >= 120, np.endTime.timeIntervalSince(t) >= 600 { break }
            t += 120
        }
        clock = t
        var all: [Int: ChannelSchedule] = [:]
        for c in state.channels { if let s = raw(c, t) { all[c.id] = s } }
        ChannelScheduleBuilder.resolveConflicts(&all)
        state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: all[ch.id])
        let tunedAt = t

        func endsAt(from started: Date) -> Date {
            started.addingTimeInterval(max(1, exact(state.currentItem!) - Double(state.playerSeekSeconds)))
        }
        var fileEnd = endsAt(from: clock)
        var lastLive = raw(ch, t)?.nowPlaying?.item.id
        let stop = tunedAt.addingTimeInterval(hours * 3600)
        var events = 0
        var step = 0
        while t < stop {
            t += 1
            step += 1
            if fileEnd <= t, events < 4000 {
                events += 1
                clock = fileEnd
                let gen = state.loadGeneration
                state.handlePartEnded()
                if state.loadGeneration != gen {
                    run.advances += 1
                    let started = clock.addingTimeInterval(loadSeconds)
                    fileEnd = endsAt(from: started)
                    if let np = raw(ch, clock)?.nowPlaying, np.item.id == state.currentItem?.id {
                        let lag = started.timeIntervalSince(np.startTime)
                        run.maxLag = max(run.maxLag, lag); run.minLag = min(run.minLag, lag)
                    }
                } else { fileEnd = .distantFuture }
            }
            clock = t
            guard step % 15 == 0, let live = raw(ch, t)?.nowPlaying else { continue }
            if live.item.id != lastLive { run.boundaries += 1; lastLive = live.item.id }
            run.samples += 1
            if state.currentItem?.id != live.item.id {
                run.mismatches += 1
                if run.first == nil {
                    run.first = "CH \(ch.number) +\(Int(t.timeIntervalSince(tunedAt)))s panel=\"\(state.currentItem?.title ?? "nil")\" guide=\"\(live.item.title)\""
                }
            }
        }
        return run
    }

    private func summary(_ label: String, _ runs: [Run]) -> String {
        let s = runs.reduce(0) { $0 + $1.samples }, m = runs.reduce(0) { $0 + $1.mismatches }
        let b = runs.reduce(0) { $0 + $1.boundaries }, a = runs.reduce(0) { $0 + $1.advances }
        return "\(label): samples=\(s) panel!=guide=\(m) (\(String(format: "%.1f", Double(m) * 100 / Double(max(1, s))))%) boundaries=\(b) advances=\(a) maxLag=\(String(format: "%.1f", runs.map(\.maxLag).max() ?? 0))s first=\(runs.compactMap(\.first).first ?? "-")"
    }

    /// Files 5 to 55 s past their floored minutes, six hours on every demo channel, across midnight. With the slot the
    /// file's real length the headline names the guide's programme at every sample (0 of 7,200). The 1.0.31 behaviour
    /// (minute slots, nothing cutting the file) disagreed in 22.9% of them (measured 2026-11-09); 1.0.32 cut the
    /// file to get to 0 and lost 38 s of a 4-minute video on average (2026-11-13).
    func testHeadlineFollowsGuideAndNothingIsCut() throws {
        let lu = lineup(extra: Self.spread)
        state.allChannels = lu; state.channels = lu
        var runs: [Run] = []
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            runs.append(try walk(ch, hours: 6))
        }
        XCTAssertEqual(runs.reduce(0) { $0 + $1.mismatches }, 0, summary("exact slots", runs))
        XCTAssertGreaterThanOrEqual(runs.reduce(0) { $0 + $1.boundaries }, lu.count * 3, "each channel crosses real boundaries")
        XCTAssertGreaterThan(runs.reduce(0) { $0 + $1.advances }, 0)
        XCTAssertLessThanOrEqual(runs.map(\.maxLag).max() ?? 0, 0.001, "with no load time the player starts every programme on the guide's second")
    }

    /// A file that ends a little before its slot (the runtime says more than the file has) starts the next programme a
    /// little early, never late and never cut: the headline then names the next programme for a moment before the guide
    /// does, which is as far ahead as it can run.
    func testAShortFileStartsTheNextProgrammeAtItsEndNotLater() throws {
        let lu = lineup(extra: Self.spread)
        state.allChannels = lu; state.channels = lu
        let ch = try XCTUnwrap(lu.first)
        _ = try walk(ch, hours: 0.01)
        let np = try XCTUnwrap(raw(ch, clock)?.nowPlaying)
        clock = np.endTime.addingTimeInterval(-0.4)
        let gen = state.loadGeneration
        state.handlePartEnded()
        XCTAssertNotEqual(state.loadGeneration, gen)
        let next = try XCTUnwrap(raw(ch, np.endTime.addingTimeInterval(0.5))?.nowPlaying)
        XCTAssertEqual(state.currentItem?.id, next.item.id, "the file ending 0.4 s before its slot starts the guide's next programme")
        XCTAssertEqual(state.seekOffset, 0)
    }

    /// Between a file ending and the next one playing the player takes a second or two, so it falls that far behind the
    /// clock at each boundary. Past `naturalEndCatchUpSeconds` the next programme joins where the clock is (its
    /// opening seconds go, the end of nothing does), so the headline cannot lag the guide by more than that and a
    /// little. 0 s of catch-up leaves it growing (190 s after six hours in the measurement).
    func testTheLagFromLoadTimeIsBoundedByTheCatchUp() throws {
        let lu = lineup(extra: Self.spread)
        state.allChannels = lu; state.channels = lu
        var runs: [Run] = []
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            runs.append(try walk(ch, hours: 6, loadSeconds: 2))
        }
        XCTAssertLessThanOrEqual(runs.map(\.maxLag).max() ?? 0, Double(AppState.naturalEndCatchUpSeconds) + 2 + 3, summary("load 2 s", runs))
    }

    func testNaturalEndJoinsWhereTheClockIsOnlyOnceTheGuideIsFarAhead() throws {
        let lu = lineup(extra: { _ in 30 })
        state.allChannels = lu; state.channels = lu
        var checked = 0
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            var t = Self.base
            for _ in 0..<200 {
                let np = try XCTUnwrap(raw(ch, t)?.nowPlaying)
                if t.timeIntervalSince(np.startTime) >= 120, np.endTime.timeIntervalSince(t) >= 600 { break }
                t += 120
            }
            clock = t
            state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: raw(ch, t))
            let live = try XCTUnwrap(raw(ch, t)?.nowPlaying)

            // The file ends a few seconds after the guide moved on: start the next at 0.
            let small = Double(AppState.naturalEndCatchUpSeconds) / 2
            clock = live.endTime.addingTimeInterval(small)
            state.handlePartEnded()
            // A programme another channel has on at that moment is passed over (the conflict skip), which is not this test's subject.
            guard state.currentItem?.id == raw(ch, clock)?.nowPlaying?.item.id else { continue }
            XCTAssertEqual(state.seekOffset, 0, "CH \(ch.number): \(Int(small)) s behind is not worth skipping anything")

            // Well past the catch-up: join the guide's programme where the clock is.
            let far = Double(AppState.naturalEndCatchUpSeconds) * 4
            clock = t
            state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: raw(ch, t))
            clock = live.endTime.addingTimeInterval(far)
            state.handlePartEnded()
            guard state.currentItem?.id == raw(ch, clock)?.nowPlaying?.item.id else { continue }
            XCTAssertEqual(state.seekOffset, Int(far), "CH \(ch.number): past the catch-up it joins where the clock is")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no channel without a conflict to check")
    }

    /// The acceptance case from #315 (1.0.32, Plex 4.163, Original quality): a 4:11 music video. Plex says 4 minutes,
    /// so it showed 4:00 in the guide and was cut at 4:00 with 11 s unplayed. Every programme here is that video: each
    /// slot is 251 s, the guide shows 4:11, a player that plays the file through (251 s) ends exactly where the next
    /// programme starts, and the next one starts at 0 with the file before it played to its last second.
    func testA411SongPlaysAllTwoHundredFiftyOneSeconds() throws {
        let lu: [Channel] = DemoData.channels().map { ch in
            var c = ch
            c.itemPool = c.itemPool.enumerated().map { (n, base) in
                let data = try! JSONEncoder().encode(base)
                var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                obj["duration"] = 4
                obj["id"] = "\(base.id)-411"
                obj["ratingKey"] = "\(base.ratingKey)-411"
                var i = try! JSONDecoder().decode(PlexMediaItem.self, from: JSONSerialization.data(withJSONObject: obj))
                i.exactDurationSeconds = 251
                return i
            }
            return c
        }
        state.allChannels = lu; state.channels = lu
        var checked = 0
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            var t = Self.base
            for _ in 0..<400 {
                let np = try XCTUnwrap(raw(ch, t)?.nowPlaying)
                if t.timeIntervalSince(np.startTime) >= 30, np.endTime.timeIntervalSince(t) >= 120 { break }
                t += 30
            }
            clock = t
            state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: raw(ch, t))
            let live = try XCTUnwrap(raw(ch, t)?.nowPlaying)
            XCTAssertEqual(live.durationSeconds, 251, "CH \(ch.number): the guide gives the 4:11 video \(live.durationSeconds) s, not 240")
            XCTAssertEqual(live.item.slotSeconds, 251)
            // The player reaches the file's last second exactly when the slot ends.
            clock = live.endTime
            let gen = state.loadGeneration
            state.handlePartEnded()
            XCTAssertNotEqual(state.loadGeneration, gen)
            guard let next = raw(ch, clock)?.nowPlaying, state.currentItem?.id == next.item.id else { continue }   // a conflict skip is another test's subject
            XCTAssertEqual(next.startTime, live.endTime, "the next programme starts as the file ends")
            XCTAssertEqual(state.seekOffset, 0)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// The clock tick that 1.0.32 used to cut a file at its slot end is gone: a file past its slot is left to end.
    func testNothingMovesAFileOnWhileItIsStillPlaying() throws {
        let lu = lineup(extra: { _ in 30 })
        state.allChannels = lu; state.channels = lu
        let ch = try XCTUnwrap(lu.first)
        var t = Self.base
        for _ in 0..<200 {
            let np = try XCTUnwrap(raw(ch, t)?.nowPlaying)
            if t.timeIntervalSince(np.startTime) >= 120, np.endTime.timeIntervalSince(t) >= 600 { break }
            t += 120
        }
        clock = t
        state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: raw(ch, t))
        let item = try XCTUnwrap(state.currentItem)
        let live = try XCTUnwrap(raw(ch, t)?.nowPlaying)
        let gen = state.loadGeneration
        clock = live.endTime.addingTimeInterval(-1)
        XCTAssertEqual(state.loadGeneration, gen)
        XCTAssertEqual(state.currentItem?.id, item.id)
        XCTAssertEqual(live.durationSeconds, Double(item.slotSeconds), accuracy: 0.001, "the slot is the file, so a file that plays to its end ends with it")
    }
}
