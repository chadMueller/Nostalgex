import XCTest
import UIKit
import SwiftUI
@testable import Nostalgex

/// Chad, 2026-11-10 ~7 PM: the living room Apple TV froze (remote dead, then video frozen too) for about five
/// minutes while he was in the guide on the MISSION IMPOSSIBLE franchise channel (CH 305). The pid did not change.
///
/// This times what the guide does for a channel's row, with the real code and no view: the day's blocks from the
/// daily manifest (packed across a 92-channel lineup, from disk, from the memo), the 24 hour schedule the guide
/// builds, `ProgramRowLayout.segments` for every 2 hour window a viewer can scroll to (slot offsets 0 to 44, one
/// Right press each), the time-cursor lookup the info panel runs per step, and a text measure of each block title.
/// It compares the franchise channel (the real 8 films' durations) with three ordinary channels (60 movies, 400
/// episodes of 40 shows, 1,500 movies) and two larger franchise pools (40 and 150 films), and times the guide's whole
/// 30 second rebuild (`buildAllSchedules`, minus the thread hop) over the lineup.
///
/// What it does NOT time: SwiftUI layout and drawing of the row, the focus engine, and the video. A unit test has no
/// view. A small result here rules out the schedule and row-layout maths, not the view.
///
/// Off by default (like the other harnesses). Simulator only:
///
///     TEST_RUNNER_NOSTALGEX_GUIDEROW=/path/out.txt xcodebuild test -project Nostalgex/Nostalgex.xcodeproj \
///       -scheme Nostalgex -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
///       -only-testing:NostalgexTests/FranchiseGuideRowHarness CODE_SIGN_IDENTITY="-" \
///       CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
///
/// The value is the file the table is written to (it is also printed with the prefix `GUIDEROW|`).
@MainActor
final class FranchiseGuideRowHarness: XCTestCase {

    private let fingerprint = "guide-row-harness"
    private var activatedHere = false
    private var out: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let path = ProcessInfo.processInfo.environment["NOSTALGEX_GUIDEROW"] ?? ""
        try XCTSkipIf(path.isEmpty, "off by default; set TEST_RUNNER_NOSTALGEX_GUIDEROW=<output file>")
        if !HarnessIsolation.isActive {
            HarnessIsolation.activate(name: "guide-row-harness")
            activatedHere = true
        }
    }

    override func tearDown() {
        DailyManifestScheduler.setLineup([], credentialFingerprint: nil)
        DailyManifestScheduler.invalidateMemo()
        DailyManifestStore.clearAll(credentialFingerprint: fingerprint)
        if activatedHere, HarnessIsolation.isActive { HarnessIsolation.deactivate(wipe: true) }
        activatedHere = false
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Deterministic, so two runs build the same pools.
    private struct LCG {
        var s: UInt64
        mutating func next(_ n: Int) -> Int {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Int((s >> 33) % UInt64(n))
        }
    }

    private func item(_ id: String, _ title: String, minutes: Int, episode: String? = nil) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: title, artist: nil, episodeTitle: episode, seTag: episode == nil ? nil : "S01E01",
            summary: "", year: 2000, originallyAvailableAt: nil, contentRating: "PG-13", duration: minutes, ratingKey: id,
            partKey: "/library/parts/\(id)/file.mkv", container: "mkv", videoCodec: "hevc", audioCodec: "eac3",
            videoProfile: "main 10", bitrate: 20_000, genres: [], rating: 0, userRating: 0,
            type: episode == nil ? .movie : .episode, thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil,
            tmdbID: nil, imdbID: nil, librarySource: episode == nil ? .movie : .tv
        )
    }

    /// The 8 films of the real channel: title and Plex minutes (Plex 1.43.4, 2026-11-10).
    private var missionImpossible: [PlexMediaItem] {
        [("20375", "Mission: Impossible", 110), ("20451", "Mission: Impossible - Dead Reckoning", 163),
         ("42887", "Mission: Impossible - Fallout", 147), ("5565", "Mission: Impossible - Ghost Protocol", 132),
         ("5566", "Mission: Impossible - Rogue Nation", 131), ("20466", "Mission: Impossible - The Final Reckoning", 169),
         ("5599", "Mission: Impossible II", 123), ("5600", "Mission: Impossible III", 125)]
            .map { item($0.0, $0.1, minutes: $0.2) }
    }

    private func movies(_ n: Int, prefix: String, seed: UInt64) -> [PlexMediaItem] {
        var g = LCG(s: seed)
        return (0..<n).map { i in item("\(prefix)\(i)", "\(prefix.uppercased()) FILM NUMBER \(i)", minutes: 80 + g.next(100)) }
    }

    private func episodes(_ n: Int, shows: Int, prefix: String, seed: UInt64) -> [PlexMediaItem] {
        var g = LCG(s: seed)
        return (0..<n).map { i in
            item("\(prefix)\(i)", "\(prefix.uppercased()) SHOW \(i % shows)", minutes: [22, 22, 44][g.next(3)], episode: "Episode \(i)")
        }
    }

    private func channel(_ id: Int, _ name: String, _ pool: [PlexMediaItem]) -> Channel {
        Channel(id: id, number: id, name: name, color: .blue, category: nil, rules: nil, timeRestrictions: nil,
                minItems: 1, itemPool: pool, enabled: true)
    }

    // MARK: - Timing helpers

    private func ms(_ block: () -> Void) -> Double {
        let t = ContinuousClock.now
        block()
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    private func emit(_ line: String) {
        out.append(line)
        print("GUIDEROW|" + line)
    }

    // MARK: - The run

    func testChannelRowCostFranchiseVersusOrdinary() throws {
        let now = Date()
        let calendar = Calendar.current
        let measured: [(Channel, String)] = [
            (channel(105, "MISSION IMPOSSIBLE", missionImpossible), "franchise, real 8 films"),
            (channel(1, "ORD MOVIES 60", movies(60, prefix: "m", seed: 1)), "ordinary, 60 movies"),
            (channel(2, "ORD EPISODES 400", episodes(400, shows: 40, prefix: "e", seed: 2)), "ordinary, 400 episodes / 40 shows"),
            (channel(3, "ORD MOVIES 1500", movies(1500, prefix: "x", seed: 3)), "ordinary, 1500 movies"),
            (channel(106, "FRANCHISE 40", movies(40, prefix: "f", seed: 4)), "franchise, 40 films"),
            (channel(107, "FRANCHISE 150", movies(150, prefix: "g", seed: 5)), "franchise, 150 films"),
        ]
        // The rest of a 92-channel lineup: pools from 30 to 600, a fifth of them episode channels.
        var g = LCG(s: 99)
        let filler: [Channel] = (0..<86).map { i in
            let size = 30 + g.next(570)
            let pool = i % 5 == 0 ? episodes(size, shows: max(5, size / 12), prefix: "p\(i)e", seed: UInt64(1000 + i))
                                  : movies(size, prefix: "p\(i)m", seed: UInt64(2000 + i))
            return channel(200 + i, "FILL \(i)", pool)
        }
        let lineup = measured.map(\.0) + filler
        emit("lineup: \(lineup.count) channels, pools \(lineup.map { $0.itemPool.count }.min()!) to \(lineup.map { $0.itemPool.count }.max()!) items; now \(now)")

        DailyManifestStore.clearAll(credentialFingerprint: fingerprint)
        DailyManifestScheduler.invalidateMemo()
        DailyManifestScheduler.setLineup(lineup, credentialFingerprint: fingerprint)

        // Yesterday stored first, the way a TV that is used every day has it.
        let yesterday = now.addingTimeInterval(-86_400)
        let tYesterday = ms { _ = DailyManifestScheduler.blocks(for: lineup[0], at: yesterday, credentialFingerprint: fingerprint) }
        emit(String(format: "pack yesterday for the lineup (not part of the result): %.0f ms", tYesterday))

        // Today, nothing stored: the first channel asked packs the whole lineup.
        let tColdToday = ms { _ = DailyManifestScheduler.blocks(for: lineup[0], at: now, credentialFingerprint: fingerprint) }
        emit(String(format: "COLD pack of today for all %d channels (first ask, one channel's wait): %.0f ms", lineup.count, tColdToday))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let tColdTomorrow = ms { _ = DailyManifestScheduler.blocks(for: lineup[0], at: tomorrow, credentialFingerprint: fingerprint) }
        emit(String(format: "COLD pack of tomorrow for all %d channels (a window that crosses midnight): %.0f ms", lineup.count, tColdTomorrow))

        let font = UIFont(name: "DMMono-Medium", size: 22) ?? UIFont.monospacedSystemFont(ofSize: 22, weight: .medium)
        emit("text measure font: \(font.fontName) (DM Mono available: \(UIFont(name: "DMMono-Medium", size: 22) != nil))")
        emit("")
        emit("channel | pool | entries(24h) | blocks/window max | gaps/window max | memo ms | disk ms | row-layout ms (45 windows total / max) | cursor ms/45 | title measure ms/45 | schedule bytes")

        var franchiseDisk = 0.0, ordinaryDiskMedian: [Double] = []
        var franchiseLayout = 0.0, ordinaryLayout: [Double] = []

        for (ch, label) in measured {
            // Memo hit: what a body re-evaluation pays.
            _ = ChannelScheduleBuilder.buildSchedule(for: ch, at: now, credentialFingerprint: fingerprint)
            let memo = median((0..<20).map { _ in ms { _ = ChannelScheduleBuilder.buildSchedule(for: ch, at: now, credentialFingerprint: fingerprint) } })
            // Disk hit: the memo dropped (library reload), the day read back from its JSON.
            let disk = median((0..<7).map { _ in
                DailyManifestScheduler.invalidateMemo()
                return ms { _ = ChannelScheduleBuilder.buildSchedule(for: ch, at: now, credentialFingerprint: fingerprint) }
            })
            guard let schedule = ChannelScheduleBuilder.buildSchedule(for: ch, at: now, credentialFingerprint: fingerprint) else {
                XCTFail("no schedule for \(ch.name)"); continue
            }
            let day = DailyManifestStore.load(channelId: ch.id, dayKey: DailyManifestStore.localDayKey(for: now),
                                              credentialFingerprint: fingerprint,
                                              expectedPoolFingerprint: DailyManifestStore.poolFingerprint(ratingKeys: ch.itemPool.map(\.id)))

            let intervals = schedule.entries.map { ($0.startTime, $0.endTime) }
            var blocksMax = 0, gapsMax = 0
            var layoutTimes: [Double] = [], cursorTimes: [Double] = [], titleTimes: [Double] = []
            for slot in 0...44 {
                let visibleStart = ChannelScheduleBuilder.visibleWindowStart(at: now, slotOffset: slot)
                var segments: [ProgramRowLayout.Segment] = []
                layoutTimes.append(ms { segments = ProgramRowLayout.segments(intervals: intervals, windowStart: visibleStart, windowDuration: 7200) })
                blocksMax = max(blocksMax, segments.filter { if case .block = $0 { return true } else { return false } }.count)
                gapsMax = max(gapsMax, segments.filter { if case .gap = $0 { return true } else { return false } }.count)
                cursorTimes.append(ms {
                    if let t = GuideTimeCursor.previewTime(slotOffset: slot, windowStart: visibleStart.addingTimeInterval(TimeInterval(-slot * 1800)), now: now),
                       let e = GuideTimeCursor.entry(in: schedule.entries, at: t) { _ = GuideTimeCursor.entry(after: e, in: schedule.entries) }
                })
                titleTimes.append(ms {
                    for case .block(let index, let fraction) in segments {
                        let title = schedule.entries[index].item.title
                        _ = (title as NSString).boundingRect(
                            with: CGSize(width: max(1, fraction * 1500), height: 64), options: [.usesLineFragmentOrigin],
                            attributes: [.font: font], context: nil)
                    }
                })
            }
            let layoutTotal = layoutTimes.reduce(0, +), cursorTotal = cursorTimes.reduce(0, +), titleTotal = titleTimes.reduce(0, +)
            emit(String(format: "%@ | %d | %d | %d | %d | %.3f | %.2f | %.3f / %.3f | %.3f | %.2f | %d",
                        label, ch.itemPool.count, schedule.entries.count, blocksMax, gapsMax, memo, disk,
                        layoutTotal, layoutTimes.max() ?? 0, cursorTotal, titleTotal, day?.blocks.count ?? -1))
            if ch.id == 105 { franchiseDisk = disk; franchiseLayout = layoutTotal }
            if [1, 2, 3].contains(ch.id) { ordinaryDiskMedian.append(disk); ordinaryLayout.append(layoutTotal) }
        }

        // The guide's 30 second rebuild over the whole lineup (TunerView.buildAllSchedules, off the main thread in the app).
        emit("")
        var built = 0
        let rebuildMemo = median((0..<5).map { _ in ms {
            var s: [Int: ChannelSchedule] = [:]
            for c in lineup { if let x = ChannelScheduleBuilder.buildSchedule(for: c, at: now, credentialFingerprint: fingerprint) { s[c.id] = x } }
            built = s.count
            ChannelScheduleBuilder.resolveConflicts(&s)
        } })
        let rebuildDisk = median((0..<3).map { _ in
            DailyManifestScheduler.invalidateMemo()
            return ms {
                var s: [Int: ChannelSchedule] = [:]
                for c in lineup { if let x = ChannelScheduleBuilder.buildSchedule(for: c, at: now, credentialFingerprint: fingerprint) { s[c.id] = x } }
                ChannelScheduleBuilder.resolveConflicts(&s)
            }
        })
        emit(String(format: "guide rebuild, %d schedules, memo warm: %.1f ms; after the memo is dropped (every day read from disk): %.1f ms", built, rebuildMemo, rebuildDisk))

        let ordMed = median(ordinaryDiskMedian), ordLayoutMed = median(ordinaryLayout)
        emit(String(format: "SUMMARY franchise CH305 disk build %.2f ms vs ordinary median %.2f ms; row layout over 45 windows %.3f ms vs %.3f ms",
                    franchiseDisk, ordMed, franchiseLayout, ordLayoutMed))

        try out.joined(separator: "\n").write(toFile: ProcessInfo.processInfo.environment["NOSTALGEX_GUIDEROW"] ?? "/dev/null",
                                               atomically: true, encoding: .utf8)

        // A real outlier fails the run. The bounds are loose on purpose: this is a smoke for "the franchise row is not
        // special", not a benchmark.
        XCTAssertLessThan(franchiseDisk, max(50, ordMed * 5), "the franchise row's day read is an outlier")
        XCTAssertLessThan(franchiseLayout, max(5, ordLayoutMed * 5), "the franchise row's layout is an outlier")
    }
}
