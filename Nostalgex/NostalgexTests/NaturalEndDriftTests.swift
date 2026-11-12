import XCTest
@testable import Nostalgex

/// Real libraries: Plex, Jellyfin and Emby floor a runtime to whole minutes, and the
/// schedule slot is that floored length, so a file runs 0 to 59 s past its slot. The
/// player starts the next item at 0 on a natural end (a seek would skip into the next
/// episode), so every boundary it falls a little further behind the clock. The Now
/// Playing headline (`currentItem`) was set from the schedule at the moment the file
/// ended, so it kept naming the programme that was on at that instant while the guide's
/// clock moved on, and named the next one early when a file ended short of its slot.
///
/// These walk a simulated clock the way DemoNowPlayingAgreementTests does: the file
/// ending is `handlePartEnded()` at the moment a real player would reach the end of a
/// file of the given exact length. Nothing needs the network.
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

    /// A lineup whose files run `extra(item)` seconds past their floored-minute slot.
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

    /// Fraction of a minute the file runs past its slot, stable per item and spread over 5 to 55 s.
    private static func spread(_ item: PlexMediaItem) -> Double {
        let h = abs(item.ratingKey.unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) })
        return Double(5 + (h % 51))
    }

    private struct Run { var samples = 0, mismatches = 0, boundaries = 0, tickAdvances = 0, first: String? }

    /// Tune a few minutes into a block, then let files end where their exact length says,
    /// sampling the headline against the guide's live block every 15 s for `hours` hours.
    private func walk(_ ch: Channel, hours: Double, withTick: Bool = true, fileSeconds: (PlexMediaItem) -> Double) throws -> Run {
        var run = Run()
        var t = Self.base
        // A tune 2 to 3 minutes into a block with at least 10 left.
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

        func endsAt() -> Date {
            let len = fileSeconds(state.currentItem!)
            return clock.addingTimeInterval(max(1, len - Double(state.playerSeekSeconds)))
        }
        var fileEnd = endsAt()
        var lastLive = raw(ch, t)?.nowPlaying?.item.id
        let stop = tunedAt.addingTimeInterval(hours * 3600)
        var events = 0
        var step = 0
        while t < stop {
            t += 1
            step += 1
            // The file ending, when its length says so, then the once-a-second slot tick.
            if fileEnd <= t, events < 4000 {
                events += 1
                clock = fileEnd
                let gen = state.loadGeneration
                state.handlePartEnded()
                fileEnd = state.loadGeneration != gen ? endsAt() : .distantFuture
            }
            clock = t
            if withTick {
                let gen = state.loadGeneration
                state.liveScheduleTick()
                if state.loadGeneration != gen { run.tickAdvances += 1; fileEnd = endsAt() }
            }
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
        let b = runs.reduce(0) { $0 + $1.boundaries }, t = runs.reduce(0) { $0 + $1.tickAdvances }
        return "\(label): samples=\(s) panel!=guide=\(m) (\(String(format: "%.1f", Double(m) * 100 / Double(max(1, s))))%) boundaries=\(b) tickAdvances=\(t) first=\(runs.compactMap(\.first).first ?? "-")"
    }

    private func exact(_ i: PlexMediaItem) -> Double { i.exactDurationSeconds ?? Double(i.duration * 60) }

    /// Files 5 to 55 s past their slot, six hours on every demo channel. Without the slot tick
    /// (the 1.0.31 behaviour) the headline disagreed with the guide in 1,647 of 7,200 samples
    /// (22.9%, measured 2026-11-09); with it, in none.
    func testHeadlineFollowsGuideWhenFilesRunPastTheirSlot() throws {
        let lu = lineup(extra: Self.spread)
        state.allChannels = lu; state.channels = lu
        var before: [Run] = [], after: [Run] = []
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            before.append(try walk(ch, hours: 6, withTick: false, fileSeconds: exact))
            after.append(try walk(ch, hours: 6, withTick: true, fileSeconds: exact))
        }
        XCTAssertGreaterThan(before.reduce(0) { $0 + $1.mismatches }, 0, "the model must reproduce the drift without the tick: \(summary("without", before))")
        XCTAssertEqual(after.reduce(0) { $0 + $1.mismatches }, 0, summary("with tick", after))
        XCTAssertGreaterThanOrEqual(after.reduce(0) { $0 + $1.boundaries }, lu.count * 3, "each channel crosses real boundaries")
        XCTAssertGreaterThan(after.reduce(0) { $0 + $1.tickAdvances }, 0)
    }

    /// A file that ends before its slot is still advanced by the file ending, as before: the
    /// tick has nothing to do.
    func testTickLeavesFilesThatEndBeforeTheirSlot() throws {
        let lu = lineup(extra: { _ in -20 })
        state.allChannels = lu; state.channels = lu
        var runs: [Run] = []
        for ch in lu {
            DailyManifestScheduler.invalidateMemo()
            runs.append(try walk(ch, hours: 3, withTick: true, fileSeconds: exact))
        }
        XCTAssertEqual(runs.reduce(0) { $0 + $1.tickAdvances }, 0, summary("short files", runs))
    }

    // MARK: - The tick's guards

    private func tunedInDeep(_ ch: Channel) throws -> ScheduleEntry {
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
        return try XCTUnwrap(raw(ch, t)?.nowPlaying)
    }

    func testTickWaitsForTheSlotThenStartsTheGuidesProgrammeAtZero() throws {
        let lu = lineup(extra: { _ in 30 })
        state.allChannels = lu; state.channels = lu
        let ch = try XCTUnwrap(lu.first)
        let live = try tunedInDeep(ch)
        XCTAssertEqual(state.liveSlotEnd, live.endTime)

        let gen = state.loadGeneration
        clock = live.endTime.addingTimeInterval(-1)
        state.liveScheduleTick()
        XCTAssertEqual(state.loadGeneration, gen, "before the slot ends the file plays on")
        XCTAssertEqual(state.currentItem?.id, live.item.id)

        clock = live.endTime
        state.liveScheduleTick()
        XCTAssertNotEqual(state.loadGeneration, gen)
        let next = try XCTUnwrap(raw(ch, clock)?.nowPlaying)
        XCTAssertNotEqual(next.item.id, live.item.id)
        XCTAssertEqual(state.currentItem?.id, next.item.id, "the headline is the guide's programme")
        XCTAssertEqual(state.seekOffset, 0, "the next programme starts at its beginning")
        XCTAssertEqual(state.liveSlotEnd, next.endTime, "the next slot is watched in turn")
    }

    func testTickDoesNotCutAFileMoreThanTheGraceOverItsSlot() throws {
        let lu = lineup(extra: { _ in 30 })
        state.allChannels = lu; state.channels = lu
        let live = try tunedInDeep(try XCTUnwrap(lu.first))
        let gen = state.loadGeneration
        clock = live.endTime.addingTimeInterval(AppState.liveSlotGraceSeconds + 1)
        state.liveScheduleTick()
        XCTAssertEqual(state.loadGeneration, gen, "past the grace the drift has another cause: leave the file to end itself")
        clock = live.endTime.addingTimeInterval(AppState.liveSlotGraceSeconds)
        state.liveScheduleTick()
        XCTAssertNotEqual(state.loadGeneration, gen, "at the grace it still moves")
    }

    func testTickIsOffForDemoMultiDiscAndOffScheduleItems() throws {
        let lu = lineup(extra: { _ in 30 })
        state.allChannels = lu; state.channels = lu
        let ch = try XCTUnwrap(lu.first)
        let live = try tunedInDeep(ch)

        var disc = live.item
        disc.additionalPartKeys = ["/part/2"]
        XCTAssertNil(state.liveSlotEnd(for: disc), "a multi-disc film's parts end on their own")

        let upNext = try XCTUnwrap(raw(ch, clock)?.upNext)
        XCTAssertNil(state.liveSlotEnd(for: upNext.item), "an item the schedule does not have on air has no slot to hold")

        state.enterDemoMode()
        XCTAssertNil(state.liveSlotEnd(for: live.item), "demo mode has its own tick")
        let gen = state.loadGeneration
        state.liveScheduleTick()
        XCTAssertEqual(state.loadGeneration, gen)
    }

}
