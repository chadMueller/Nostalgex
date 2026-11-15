import Foundation

/// When a programme counts as finished although AVPlayer never said so.
///
/// `AVPlayerItemDidPlayToEndTime` is the normal end. It does not arrive when the server's
/// playlist promises more than the file holds. Emby lists every HLS segment as 6.0 s, the
/// last one too, so the playlist runs up to 6 s past the end of the file; with fMP4
/// segments (every HEVC stream Emby sends, copied or re-encoded) the player plays the last
/// frame it gets and then waits for footage that never comes. Measured against Emby
/// 4.10.1.0 on 2026-11-15, AVPlayer, the stream exactly as the app asks for it:
///
/// | file                         | last frame at | runtime  | playlist left | then                                   |
/// |------------------------------|---------------|----------|---------------|----------------------------------------|
/// | 21 min HEVC MKV, video copied | 1263.91 s    | 1260.39 s | 2.1 s        | paused; "failed to play to end" 41 s later |
/// | 90 s HEVC MKV, video copied   | 83.80 s      | 90.03 s   | 12.2 s       | paused; same, 52 s later               |
/// | 90 s hev1 MP4, re-encoded     | 83.96 s      | 90.01 s   | 9.0 s        | paused; same, 13 s later               |
/// | 90 s HEVC MKV, copied, Apple TV | 81.79 s    | 90.03 s   | 14.2 s       | left waiting (rate 1), twice in a row  |
///
/// and on the Apple TV the same 90 s copy has also ended with the item `.failed` ("Cannot
/// Complete Action") at the last segment. How much is lost depends on the file: a copied
/// stream is cut at the first keyframe after each 6 s, so its real segments are as long as
/// that (8 s for the 4 s keyframe interval of the test files, about 10.4 s for x264 and
/// x265's default of 250 frames at 24 fps), and the last one is what goes missing. The
/// Apple TV lost 8.24 s of the 90 s file. H.264 copied into TS segments
/// ended normally, on its last frame. Emby never sends the missing seconds (2 to 6 s), so
/// the most the app can do is move on promptly. The old backstop (2 s left on the playlist
/// and the rate at 0) caught none of these, the starvation monitor ignores a paused player,
/// and nothing listened for the late failure: the channel sat on the last frame.
///
/// The rule: within `windowSeconds` either side of the programme's real runtime (the
/// server's own runtime, not the playlist's), any failure of the item is the end of the
/// programme; so is a playhead still for `stallSeconds`, but only while the playlist claims
/// at least `overrunSeconds` more than the file has left (`playlistOverruns`). Every Emby
/// case measured overran by 3 to 6 s. An honest playlist (Plex, Jellyfin) does not, so a
/// stall there is a real one, a Wi-Fi hiccup, and keeps waiting and recovering as before
/// instead of losing the last seconds of the programme. Outside the window nothing
/// changes: a stall mid-file is still the starvation ladder's, and a failure still retries.
/// The window closes on the far side too: a runtime shorter than the version on the server
/// (an extended cut under the theatrical runtime) would otherwise hold it open for the rest
/// of the film.
enum PlaybackEndRule {
    /// One copied segment at the common 10.4 s keyframe interval, and slack. 8 s (one 6 s
    /// segment and 2 s) was the first figure and missed the Apple TV's own 8.24 s loss.
    static let windowSeconds: Double = 15
    /// How long the playhead must sit still inside the window.
    static let stallSeconds: Double = 2
    /// How much more the playlist must claim than the file has left for a stall to be the
    /// end. Measured Emby overruns: 5.6, 6.0, 3.0 and 6.0 s.
    static let overrunSeconds: Double = 1
    /// Progress below this between samples is "did not move" (the starvation monitor's figure).
    static let minimumProgressSeconds: Double = PlaybackStarvation.minimumProgressSeconds
    /// The older backstop, which still applies on its own: this close to the playlist's end
    /// with the rate at 0 is the end, runtime or not.
    static let playlistTailSeconds: Double = 2

    /// The programme's real runtime in seconds, or nil when it is not known well enough to
    /// end a programme on: no exact runtime, one that disagrees with the minutes figure by a
    /// minute or more (the same check `slotSeconds` makes), or a multi-part film, whose
    /// runtime is the whole film while the player holds one part.
    static func runtime(for item: PlexMediaItem?) -> Double? {
        guard let item, item.additionalPartKeys?.isEmpty ?? true,
              let exact = item.exactDurationSeconds, exact.isFinite, exact >= 1,
              abs(exact - Double(item.duration * 60)) < 61 else { return nil }
        return exact
    }

    /// Seconds from the playhead to the end of the real runtime (negative once past it).
    /// `baseOffset` turns the item's clock into the file's (a stream the server started at
    /// an offset counts from zero).
    static func secondsToRealEnd(playhead: Double, baseOffset: Double, runtime: Double?) -> Double? {
        guard let runtime, playhead.isFinite, baseOffset.isFinite else { return nil }
        return runtime - (playhead + baseOffset)
    }

    /// Inside the end window, `windowSeconds` either side of the real end: a failure here
    /// ends the programme.
    static func isInEndWindow(playhead: Double, baseOffset: Double, runtime: Double?) -> Bool {
        guard let left = secondsToRealEnd(playhead: playhead, baseOffset: baseOffset, runtime: runtime) else { return false }
        return left <= windowSeconds && left >= -windowSeconds
    }

    /// The playlist claims at least `overrunSeconds` more than the file has left: Emby's
    /// rounded-up last segment. Both sides on their own clocks (the playlist's on the item's,
    /// the runtime's on the file's), as everywhere here.
    static func playlistOverruns(playhead: Double, playlistDuration: Double?, baseOffset: Double, runtime: Double?) -> Bool {
        guard let total = playlistDuration, total.isFinite, total > 0,
              let realLeft = secondsToRealEnd(playhead: playhead, baseOffset: baseOffset, runtime: runtime) else { return false }
        return (total - playhead) - realLeft >= overrunSeconds
    }

    /// A still playhead here is the end of the file, not starvation: inside the window and
    /// the playlist overrunning. The starvation monitor stands down; the end backstop takes it.
    static func stillPlayheadIsTheEnd(playhead: Double, playlistDuration: Double?, baseOffset: Double, runtime: Double?) -> Bool {
        isInEndWindow(playhead: playhead, baseOffset: baseOffset, runtime: runtime)
            && playlistOverruns(playhead: playhead, playlistDuration: playlistDuration, baseOffset: baseOffset, runtime: runtime)
    }
}

/// Fed one sample a second for the item on screen; says when it has ended without saying so.
struct PlaybackEndWatch {
    enum Verdict: Equatable {
        /// Near the playlist's end with the rate at 0 (the older backstop).
        case parkedAtPlaylistEnd(secondsLeft: Double)
        /// Inside the end window of the real runtime, the playlist overrunning, and the playhead
        /// still for `stallSeconds`.
        case stalledAtRealEnd(secondsToRealEnd: Double)
    }

    private var lastPlayhead: Double?
    private var lastWall: Double?
    /// When the playhead was last seen moving: the sample before the first one that found it still.
    private var stillSince: Double?

    /// - Parameters:
    ///   - playhead: the item's current time.
    ///   - wall: wall-clock seconds, monotonic.
    ///   - rate: the player's rate (0 when paused, still 1 while it waits for data).
    ///   - playlistDuration: the item's duration (the playlist's sum for HLS), nil when unknown.
    ///   - baseOffset: see `PlaybackEndRule.secondsToRealEnd`.
    ///   - runtime: `PlaybackEndRule.runtime(for:)`.
    mutating func observe(playhead: Double, wall: Double, rate: Float, playlistDuration: Double?,
                          baseOffset: Double, runtime: Double?) -> Verdict? {
        guard playhead.isFinite else { return nil }
        defer { lastPlayhead = playhead; lastWall = wall }
        if let last = lastPlayhead, playhead - last >= PlaybackEndRule.minimumProgressSeconds {
            stillSince = nil
        } else if stillSince == nil {
            stillSince = lastWall ?? wall
        }

        if let total = playlistDuration, total.isFinite, total > 0, rate == 0 {
            let left = total - playhead
            if left <= PlaybackEndRule.playlistTailSeconds { return .parkedAtPlaylistEnd(secondsLeft: left) }
        }
        guard PlaybackEndRule.stillPlayheadIsTheEnd(playhead: playhead, playlistDuration: playlistDuration,
                                                    baseOffset: baseOffset, runtime: runtime),
              let left = PlaybackEndRule.secondsToRealEnd(playhead: playhead, baseOffset: baseOffset, runtime: runtime),
              let since = stillSince, wall - since >= PlaybackEndRule.stallSeconds else { return nil }
        return .stalledAtRealEnd(secondsToRealEnd: left)
    }
}
