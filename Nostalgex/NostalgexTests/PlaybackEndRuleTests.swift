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
    /// Last frame shown, the server's runtime, and the playlist's length (2.1, 12.2 and 9.0 s left on it).
    static let measured = [
        Measured(name: "21 min HEVC MKV, copied", runtime: 1260.39, playlist: 1266, lastFrame: 1263.91),
        Measured(name: "90 s HEVC MKV, copied", runtime: 90.03, playlist: 96, lastFrame: 83.80),
        Measured(name: "90 s hev1 MP4, re-encoded", runtime: 90.01, playlist: 93, lastFrame: 83.96),
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
        XCTAssertFalse(PlaybackEndRule.isInEndWindow(playhead: 1260.39 - 8.5, baseOffset: 0, runtime: 1260.39))
        XCTAssertTrue(PlaybackEndRule.isInEndWindow(playhead: 1260.39 - 8, baseOffset: 0, runtime: 1260.39))
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
    /// heard, and each of the three status observers checks the window before retrying.
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
        let starvation = try XCTUnwrap(source.range(of: "private func installStarvationMonitor"))
        let monitorBody = source[starvation.lowerBound...].prefix(4000)
        XCTAssertTrue(monitorBody.contains("PlaybackEndRule.isInEndWindow("), "the starvation monitor does not stand down in the end window")
    }
}
