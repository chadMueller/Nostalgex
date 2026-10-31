import XCTest
@testable import Nostalgex

/// Demo mode plays one 600 s clip (Apple's bipbop sample) in place of every programme.
/// Tuned 600 s or more into a block, the clip used to seek past its own end, finish at
/// once, and the natural-end path then took the schedule's upNext: the Now Playing panel
/// named the next programme while the guide still showed the current one (measured
/// 2026-10-30: 226 of 250 samples across five channels). App Review sees demo mode.
///
/// These walk a simulated clock, standing in for the two real events: the clip ending
/// (`handlePartEnded`, what AVPlayerItemDidPlayToEndTime calls) 600 s minus the clip seek
/// after each load, and the once-a-second demo tick. Nothing here needs the network:
/// player items are built in a task that never runs before the test returns.
@MainActor
final class DemoNowPlayingAgreementTests: XCTestCase {

    private var state: AppState!
    private var clock = Date()

    /// A fixed evening, so the schedule walked is the same on every run.
    private static let base: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 30; c.hour = 20
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

    private func resetManifests() {
        DailyManifestStore.clearAll(credentialFingerprint: fp)
        DailyManifestScheduler.invalidateMemo()
    }

    private func raw(_ ch: Channel, _ t: Date) -> ChannelSchedule? {
        ChannelScheduleBuilder.buildSchedule(for: ch, at: t, credentialFingerprint: fp)
    }

    /// The guide's schedules, built the way TunerView.buildAllSchedules builds them.
    private func guide(at t: Date) -> [Int: ChannelSchedule] {
        var all: [Int: ChannelSchedule] = [:]
        for c in state.channels { if let s = raw(c, t) { all[c.id] = s } }
        ChannelScheduleBuilder.resolveConflicts(&all)
        return all
    }

    /// First instant from `from` that sits at least 700 s into a block with 300 s left.
    private func deepInBlock(_ ch: Channel, from: Date) throws -> Date {
        var t = from
        for _ in 0..<200 {
            let np = try XCTUnwrap(raw(ch, t)?.nowPlaying)
            if t.timeIntervalSince(np.startTime) >= 700, np.endTime.timeIntervalSince(t) >= 300 { return t }
            t += 300
        }
        throw XCTSkip("no deep block on CH \(ch.number)")
    }

    // MARK: - Demo: the panel follows the guide

    func testDemoPanelMatchesGuideAcrossBoundaries() throws {
        state.enterDemoMode()
        resetManifests()
        XCTAssertTrue(state.isDemoMode)
        XCTAssertFalse(state.channels.isEmpty)

        var samples = 0, mismatches = 0, timeLineMismatches = 0, boundaries = 0
        var firstFailure: String?

        for ch in state.channels {
            clock = try deepInBlock(ch, from: Self.base)
            let tunedAt = clock
            let guideAtTune = guide(at: clock)
            let liveAtTune = try XCTUnwrap(guideAtTune[ch.id]?.nowPlaying)
            state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: guideAtTune[ch.id])

            let elapsed = Int(clock.timeIntervalSince(liveAtTune.startTime))
            XCTAssertEqual(state.seekOffset, elapsed, "CH \(ch.number): seekOffset is the schedule's elapsed time")
            XCTAssertGreaterThanOrEqual(elapsed, 600, "CH \(ch.number): the case under test is a tune past the clip's length")
            XCTAssertLessThan(state.playerSeekSeconds, AppState.demoClipSeconds,
                              "CH \(ch.number): the demo tune seek must land inside the clip")

            var clipEndsAt = clock.addingTimeInterval(TimeInterval(AppState.demoClipSeconds - state.playerSeekSeconds))
            // Two full block boundaries past the tune.
            let firstEnd = liveAtTune.endTime
            let secondEnd = try XCTUnwrap(raw(ch, firstEnd.addingTimeInterval(1))?.nowPlaying?.endTime)
            let stopAt = secondEnd.addingTimeInterval(600)
            var lastLive = liveAtTune.item.id
            var events = 0

            var t = tunedAt
            while t < stopAt {
                t += 15
                // Every clip end and block end due by `t`, in clock order.
                while events < 500 {
                    let blockEnd = state.demoBlockEnd ?? .distantFuture
                    let next = min(clipEndsAt, blockEnd)
                    guard next <= t else { break }
                    events += 1
                    clock = next
                    let gen = state.loadGeneration
                    if clipEndsAt <= blockEnd { state.handlePartEnded() } else { state.demoScheduleTick() }
                    if state.loadGeneration != gen {
                        clipEndsAt = clock.addingTimeInterval(TimeInterval(AppState.demoClipSeconds - state.playerSeekSeconds))
                    } else if next == clipEndsAt {
                        clipEndsAt = .distantFuture
                    }
                }
                clock = t
                let live = guide(at: t)[ch.id]?.nowPlaying
                if live?.item.id != lastLive { boundaries += 1; lastLive = live?.item.id ?? "" }
                samples += 1
                if state.currentItem?.id != live?.item.id {
                    mismatches += 1
                    if firstFailure == nil {
                        firstFailure = "CH \(ch.number) at +\(Int(t.timeIntervalSince(tunedAt)))s: panel=\"\(state.currentItem?.title ?? "nil")\" guide=\"\(live?.item.title ?? "nil")\""
                    }
                }
                // OSD time line: elapsed / total from the live block, beside the panel's title.
                if let total = raw(ch, t)?.livePlayback(at: t)?.totalSeconds,
                   let item = state.currentItem, total != item.duration * 60 {
                    timeLineMismatches += 1
                }
            }
            // The clip seek always lands inside the clip, before and after every boundary.
            XCTAssertLessThan(state.playerSeekSeconds, AppState.demoClipSeconds)
        }

        print("[DemoNowPlaying] channels=\(state.channels.count) samples=\(samples) panel!=guide=\(mismatches) timeLine!=panel=\(timeLineMismatches) boundariesCrossed=\(boundaries)")
        XCTAssertGreaterThanOrEqual(boundaries, state.channels.count * 2, "every channel crosses two real programme boundaries")
        XCTAssertEqual(mismatches, 0, "panel headline vs guide live block: \(mismatches) of \(samples) samples. First: \(firstFailure ?? "-")")
        XCTAssertEqual(timeLineMismatches, 0, "time line vs panel headline")
    }

    /// The clip running out mid-block keeps the programme and rejoins at the clock.
    func testDemoClipEndStaysOnLiveBlock() throws {
        state.enterDemoMode()
        resetManifests()
        let ch = try XCTUnwrap(state.channels.first)
        clock = try deepInBlock(ch, from: Self.base)
        state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: guide(at: clock)[ch.id])
        let live = try XCTUnwrap(raw(ch, clock)?.nowPlaying)
        let upNext = try XCTUnwrap(raw(ch, clock)?.upNext)
        XCTAssertNotEqual(upNext.item.id, live.item.id)

        clock += 120
        state.handlePartEnded()
        XCTAssertEqual(state.currentItem?.id, live.item.id, "demo clip end stays on the live block, not upNext")
        let elapsed = Int(clock.timeIntervalSince(live.startTime))
        XCTAssertEqual(state.seekOffset, elapsed)
        XCTAssertEqual(state.playerSeekSeconds, elapsed % AppState.demoClipSeconds)
        XCTAssertEqual(state.demoBlockEnd, live.endTime)

        // Before the block ends the tick leaves it alone; at the end it moves with the guide.
        let gen = state.loadGeneration
        clock = live.endTime.addingTimeInterval(-1)
        state.demoScheduleTick()
        XCTAssertEqual(state.loadGeneration, gen)
        clock = live.endTime
        state.demoScheduleTick()
        XCTAssertEqual(state.currentItem?.id, guide(at: clock)[ch.id]?.nowPlaying?.item.id)
        XCTAssertNotEqual(state.currentItem?.id, live.item.id)
    }

    // MARK: - Real library: natural end still advances to upNext

    func testRealNaturalEndStillAdvancesToUpNext() throws {
        XCTAssertFalse(state.isDemoMode)
        let lineup = DemoData.channels()
        state.allChannels = lineup
        state.channels = lineup
        resetManifests()

        for ch in lineup {
            clock = try deepInBlock(ch, from: Self.base)
            state.tuneChannelFromUser(ch, method: .guide, precomputedSchedule: guide(at: clock)[ch.id])
            let schedule = try XCTUnwrap(raw(ch, clock))
            let live = try XCTUnwrap(schedule.nowPlaying)
            XCTAssertEqual(state.currentItem?.id, live.item.id)
            XCTAssertEqual(state.playerSeekSeconds, state.seekOffset, "real seek is not folded into a clip")
            XCTAssertGreaterThanOrEqual(state.playerSeekSeconds, 600)
            XCTAssertNil(state.demoBlockEnd)

            // The file ends a little early against its slot: the advance takes upNext at 0.
            clock += 30
            var expected = try XCTUnwrap(schedule.upNext?.item)
            if ChannelScheduleBuilder.findConflict(item: expected, excludingChannelID: ch.id, in: lineup,
                                                   at: clock, credentialFingerprint: fp) != nil,
               let idx = schedule.entries.firstIndex(where: { $0.item.ratingKey == expected.ratingKey }),
               idx + 1 < schedule.entries.count {
                expected = schedule.entries[idx + 1].item
            }
            state.handlePartEnded()
            XCTAssertEqual(state.currentItem?.id, expected.id, "CH \(ch.number): real natural end advances as before")
            XCTAssertEqual(state.seekOffset, 0, "CH \(ch.number): real natural end starts the next item at 0")

            // The demo tick is inert outside demo mode.
            let gen = state.loadGeneration
            clock = live.endTime.addingTimeInterval(5)
            state.demoScheduleTick()
            XCTAssertEqual(state.loadGeneration, gen)
            XCTAssertEqual(state.currentItem?.id, expected.id)
        }
    }
}
