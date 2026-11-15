import XCTest
@testable import Nostalgex

/// Replays the ends measured against Emby 4.10.1.0 on 2026-11-15 (see `PlaybackEndRule`): the
/// player plays the last frame Emby sends and parks, because the playlist runs past the file.
final class PlaybackEndRuleTests: XCTestCase {
    struct Measured {
        let name: String
        let runtime: Double
        let playlist: Double
        let lastFrame: Double
    }
    /// Last frame shown, the server's runtime, and the playlist's length (2.1, 12.2, 9.0 and 14.2 s left on it).
    static let measured = [
        Measured(name: "21 min HEVC MKV, copied", runtime: 1260.39, playlist: 1266, lastFrame: 1263.91),
        Measured(name: "90 s HEVC MKV, copied", runtime: 90.03, playlist: 96, lastFrame: 83.80),
        Measured(name: "90 s hev1 MP4, re-encoded", runtime: 90.01, playlist: 93, lastFrame: 83.96),
        Measured(name: "90 s HEVC MKV, copied, on the Apple TV", runtime: 90.028, playlist: 96, lastFrame: 81.79),
    ]

    /// One sample a second: playing up to `lastFrame`, then still there for `stillSeconds`.
    /// Returns the verdict and the sample index it came on: index 0 is the sample that finds
    /// the playhead arriving at the last frame, so index 2 is two seconds of stillness after it.
    private func replay(_ m: Measured, rate: Float, stillSeconds: Int = 60,
                        runtime: Double?? = .none) -> (PlaybackEndWatch.Verdict, Int)? {
        var watch = PlaybackEndWatch()
        let rt = runtime ?? m.runtime
        var wall = 0.0
        for p in stride(from: m.lastFrame - 20, to: m.lastFrame, by: 1.0) {
            XCTAssertNil(watch.observe(playhead: p, wall: wall, rate: 1, playlistDuration: m.playlist, baseOffset: 0, runtime: rt),
                         "\(m.name): ended while still playing at \(p)")
            wall += 1
        }
        for i in 0..<stillSeconds {
            if let v = watch.observe(playhead: m.lastFrame, wall: wall, rate: rate, playlistDuration: m.playlist, baseOffset: 0, runtime: rt) {
                return (v, i)
            }
            wall += 1
        }
        return nil
    }

    func testEachMeasuredEndIsAnEndWhenThePlayerPauses() {
        for m in Self.measured {
            guard let (verdict, index) = replay(m, rate: 0) else {
                XCTFail("\(m.name): parked \(m.playlist - m.lastFrame) s before the playlist's end and never ended"); continue
            }
            XCTAssertEqual(verdict, .stalledAtRealEnd(secondsToRealEnd: m.runtime - m.lastFrame), m.name)
            // Two seconds of stillness after the last frame arrived, not more.
            XCTAssertEqual(index, 2, "\(m.name): ended \(index) s after the last frame arrived")
        }
    }

    func testEachMeasuredEndIsAnEndWhenThePlayerIsLeftWaiting() {
        for m in Self.measured {
            guard let (verdict, index) = replay(m, rate: 1) else {
                XCTFail("\(m.name): waiting at the end and never ended"); continue
            }
            XCTAssertEqual(verdict, .stalledAtRealEnd(secondsToRealEnd: m.runtime - m.lastFrame), m.name)
            XCTAssertEqual(index, 2, m.name)
        }
    }

    func testTheMeasuredEndsAreInsideTheWindowSoAFailureThereIsTheEnd() {
        for m in Self.measured {
            XCTAssertTrue(PlaybackEndRule.isInEndWindow(playhead: m.lastFrame, baseOffset: 0, runtime: m.runtime), m.name)
        }
    }

    func testAStallMidFileStaysWithTheStarvationLadder() {
        let m = Measured(name: "mid-file", runtime: 1260.39, playlist: 1266, lastFrame: 600)
        XCTAssertNil(replay(m, rate: 1), "a stall 10 minutes from the end must not end the programme")
        XCTAssertNil(replay(m, rate: 0))
        XCTAssertFalse(PlaybackEndRule.isInEndWindow(playhead: 600, baseOffset: 0, runtime: 1260.39))
        // Just outside the window: still the old path.
        XCTAssertFalse(PlaybackEndRule.isInEndWindow(playhead: 1260.39 - 15.5, baseOffset: 0, runtime: 1260.39))
        XCTAssertTrue(PlaybackEndRule.isInEndWindow(playhead: 1260.39 - 15, baseOffset: 0, runtime: 1260.39))
    }

    /// Plex or Jellyfin: the playlist is as long as the file. A stall 10 s from the end is a
    /// real one (a Wi-Fi hiccup); it keeps waiting, recovers, and plays the rest.
    func testAStallNearTheEndOnAnHonestPlaylistKeepsWaitingAndRecovers() {
        let runtime = 1260.39, playlist = 1260.4
        var watch = PlaybackEndWatch()
        var wall = 0.0
        for p in stride(from: 1240.0, through: 1250.39, by: 1.0) {
            XCTAssertNil(watch.observe(playhead: p, wall: wall, rate: 1, playlistDuration: playlist, baseOffset: 0, runtime: runtime)); wall += 1
        }
        for _ in 0..<30 {   // 30 s still at 10 s left, the player waiting
            XCTAssertNil(watch.observe(playhead: 1250.39, wall: wall, rate: 1, playlistDuration: playlist, baseOffset: 0, runtime: runtime),
                         "an honest playlist's stall cut the last 10 s")
            wall += 1
        }
        for p in stride(from: 1251.39, through: 1260.0, by: 1.0) {   // it recovers and plays to the end
            XCTAssertNil(watch.observe(playhead: p, wall: wall, rate: 1, playlistDuration: playlist, baseOffset: 0, runtime: runtime)); wall += 1
        }
        XCTAssertFalse(PlaybackEndRule.stillPlayheadIsTheEnd(playhead: 1250.39, playlistDuration: playlist, baseOffset: 0, runtime: runtime),
                       "the starvation monitor must keep its job on an honest playlist")
        // Failures in the window still end it, overrun or not.
        XCTAssertTrue(PlaybackEndRule.isInEndWindow(playhead: 1250.39, baseOffset: 0, runtime: runtime))
    }

    func testEveryMeasuredEmbyEndOverrunsItsFileSoTheStallIsTheEnd() {
        for m in Self.measured {
            XCTAssertTrue(PlaybackEndRule.playlistOverruns(playhead: m.lastFrame, playlistDuration: m.playlist, baseOffset: 0, runtime: m.runtime), m.name)
            XCTAssertTrue(PlaybackEndRule.stillPlayheadIsTheEnd(playhead: m.lastFrame, playlistDuration: m.playlist, baseOffset: 0, runtime: m.runtime), m.name)
        }
        // Under a second of difference is not an overrun.
        XCTAssertFalse(PlaybackEndRule.playlistOverruns(playhead: 80, playlistDuration: 90.9, baseOffset: 0, runtime: 90.03))
        XCTAssertTrue(PlaybackEndRule.playlistOverruns(playhead: 80, playlistDuration: 91.03, baseOffset: 0, runtime: 90.03))
        XCTAssertFalse(PlaybackEndRule.playlistOverruns(playhead: 80, playlistDuration: nil, baseOffset: 0, runtime: 90.03), "no playlist length, no overrun")
    }

    /// A runtime shorter than the version that plays (an extended cut under the theatrical
    /// runtime) must not hold the window open for the rest of the film.
    func testTheWindowClosesFifteenSecondsPastTheRealEnd() {
        let runtime = 5400.0   // the server says 90 minutes, the file is the 100 minute cut
        XCTAssertTrue(PlaybackEndRule.isInEndWindow(playhead: 5415, baseOffset: 0, runtime: runtime))
        XCTAssertFalse(PlaybackEndRule.isInEndWindow(playhead: 5415.5, baseOffset: 0, runtime: runtime))
        XCTAssertFalse(PlaybackEndRule.isInEndWindow(playhead: 5700, baseOffset: 0, runtime: runtime), "a failure 5 minutes past the runtime still retries")
        var watch = PlaybackEndWatch()
        var wall = 0.0
        for p in stride(from: 5680.0, through: 5700, by: 1.0) { _ = watch.observe(playhead: p, wall: wall, rate: 1, playlistDuration: 6000, baseOffset: 0, runtime: runtime); wall += 1 }
        for _ in 0..<30 {
            XCTAssertNil(watch.observe(playhead: 5700, wall: wall, rate: 1, playlistDuration: 6000, baseOffset: 0, runtime: runtime),
                         "a stall 5 minutes past a short runtime ended the film"); wall += 1
        }
    }

    /// A stream the server started at an offset (a Plex mid-programme join) may start at an
    /// earlier keyframe than asked, which reads as an overrun of a few seconds. Its stall near
    /// the end is a real one.
    func testAStallOnAStreamStartedAtAnOffsetIsNotTheEnd() {
        // Asked for 1200 s, the server started at 1195.6: item clock 52 is file 1252, 8.4 s
        // from the real end, while the item's 70 s duration leaves 18 s: a 9.6 s "overrun".
        var watch = PlaybackEndWatch()
        var wall = 0.0
        for p in stride(from: 40.0, through: 52.0, by: 1.0) { _ = watch.observe(playhead: p, wall: wall, rate: 1, playlistDuration: 70, baseOffset: 1200, runtime: 1260.39); wall += 1 }
        for _ in 0..<30 {
            XCTAssertNil(watch.observe(playhead: 52, wall: wall, rate: 1, playlistDuration: 70, baseOffset: 1200, runtime: 1260.39),
                         "a stall on an offset stream cut the tail"); wall += 1
        }
        XCTAssertFalse(PlaybackEndRule.stillPlayheadIsTheEnd(playhead: 52, playlistDuration: 70, baseOffset: 1200, runtime: 1260.39))
    }

    /// A version far longer than the runtime says (an extended cut) is not Emby's rounded-up
    /// last segment: an overrun of more than the window must not end the film on a stall.
    func testAnOverrunLongerThanTheWindowIsNotTheEnd() {
        // Runtime says 5400 s, the playlist is the 6000 s cut: at 5390 s the runtime has 10 s
        // left and the playlist 610.
        var watch = PlaybackEndWatch()
        var wall = 0.0
        for p in stride(from: 5370.0, through: 5390, by: 1.0) { _ = watch.observe(playhead: p, wall: wall, rate: 1, playlistDuration: 6000, baseOffset: 0, runtime: 5400); wall += 1 }
        for _ in 0..<30 {
            XCTAssertNil(watch.observe(playhead: 5390, wall: wall, rate: 1, playlistDuration: 6000, baseOffset: 0, runtime: 5400),
                         "a stall in an extended cut ended it 10 minutes early"); wall += 1
        }
        XCTAssertFalse(PlaybackEndRule.playlistOverruns(playhead: 5390, playlistDuration: 6000, baseOffset: 0, runtime: 5400))
        // At the cap it still counts.
        XCTAssertTrue(PlaybackEndRule.playlistOverruns(playhead: 5390, playlistDuration: 5415, baseOffset: 0, runtime: 5400))
        XCTAssertFalse(PlaybackEndRule.playlistOverruns(playhead: 5390, playlistDuration: 5415.5, baseOffset: 0, runtime: 5400))
    }

    func testAHealthyStreamPlayingThroughTheWindowIsNotEnded() {
        var watch = PlaybackEndWatch()
        for (i, p) in stride(from: 1240.0, through: 1260.0, by: 1.0).enumerated() {
            XCTAssertNil(watch.observe(playhead: p, wall: Double(i), rate: 1, playlistDuration: 1266, baseOffset: 0, runtime: 1260.39))
        }
    }

    func testTheItemClockIsMovedOntoTheFileWithTheBaseOffset() {
        // A stream the server started at 1200 s counts from zero: 63.91 on the item is 1263.91 in the file.
        XCTAssertTrue(PlaybackEndRule.isInEndWindow(playhead: 63.91, baseOffset: 1200, runtime: 1260.39))
        XCTAssertFalse(PlaybackEndRule.isInEndWindow(playhead: 63.91, baseOffset: 0, runtime: 1260.39))
    }

    func testWithoutARuntimeOnlyTheOldPlaylistBackstopApplies() {
        let m = Self.measured[1]
        XCTAssertNil(replay(m, rate: 0, runtime: .some(nil)), "no runtime, 12.2 s left on the playlist: not ended, as before")
        var watch = PlaybackEndWatch()
        _ = watch.observe(playhead: 94.0, wall: 0, rate: 1, playlistDuration: 96, baseOffset: 0, runtime: nil)
        XCTAssertEqual(watch.observe(playhead: 94.5, wall: 1, rate: 0, playlistDuration: 96, baseOffset: 0, runtime: nil),
                       .parkedAtPlaylistEnd(secondsLeft: 1.5))
    }

    func testRuntimeComesFromTheExactFigureAndOnlyForOnePartItems() throws {
        func item(_ json: String) throws -> PlexMediaItem {
            try JSONDecoder().decode(PlexMediaItem.self, from: Data(json.utf8))
        }
        let base = #""id":"1","ratingKey":"1","title":"T","summary":"","type":"movie","duration":21,"genres":[],"rating":0,"userRating":0,"viewCount":0,"addedAt":0"#
        XCTAssertEqual(PlaybackEndRule.runtime(for: try item("{\(base),\"exactDurationSeconds\":1260.39}")), 1260.39)
        XCTAssertNil(PlaybackEndRule.runtime(for: try item("{\(base)}")), "no exact runtime")
        XCTAssertNil(PlaybackEndRule.runtime(for: try item("{\(base),\"exactDurationSeconds\":2000}")), "disagrees with the minutes")
        XCTAssertNil(PlaybackEndRule.runtime(for: try item("{\(base),\"exactDurationSeconds\":1260.39,\"additionalPartKeys\":[\"/p/2\"]}")),
                     "a two-part film's runtime is the whole film")
        XCTAssertNil(PlaybackEndRule.runtime(for: nil))
    }

    /// The rule only helps if the player uses it: the end backstop feeds `PlaybackEndWatch`, the
    /// starvation monitor stands down inside the window, the late failure notification is
    /// heard, and each of the three status observers and the startup watchdog check the
    /// window before retrying (a channel tuned 20 s before the end reached it before the
    /// watchdog's 20 s deadline on the Apple TV, and the watchdog retried it at 1080p).
    func testThePlayerIsWiredToTheRule() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostalgex/App/AppState+Playback.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("source not readable here") }
        XCTAssertTrue(source.contains("PlaybackEndWatch()"), "end backstop does not use PlaybackEndWatch")
        XCTAssertTrue(source.contains(".AVPlayerItemFailedToPlayToEndTime"), "nothing listens for the late failure")
        let failedSites = source.components(separatedBy: "case .failed:").dropFirst()
        XCTAssertEqual(failedSites.count, 3)
        for site in failedSites {
            XCTAssertTrue(site.prefix(400).contains("endsInsideEndWindow("), "a .failed observer retries without checking the end window")
        }
        let watchdog = try XCTUnwrap(source.range(of: "private func installWatchdog"))
        XCTAssertTrue(source[watchdog.lowerBound...].prefix(5000).contains("endsInsideEndWindow("),
                      "the startup watchdog retries a programme that has simply reached its end")
        let starvation = try XCTUnwrap(source.range(of: "private func installStarvationMonitor"))
        let monitorBody = source[starvation.lowerBound...].prefix(4000)
        XCTAssertTrue(monitorBody.contains("PlaybackEndRule.stillPlayheadIsTheEnd("), "the starvation monitor does not stand down where a still playhead is the end")
    }
}
