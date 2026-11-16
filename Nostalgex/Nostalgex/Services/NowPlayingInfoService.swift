import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Publishes what is currently airing to the system Now Playing Info Center.
///
/// Without this the Apple TV Control Center, the iOS Remote's now-playing card
/// and the system's own media state all show nothing while Nostalgex is
/// playing, which reads as a half-finished app to anyone who looks.
///
/// **No transport commands are registered, on purpose.** Nostalgex is a
/// simulated live channel whose position is derived from the wall clock. A
/// pause or a scrub from Control Center would desync the schedule from the
/// time, and `PlayerView.onPlayPauseCommand` already flashes the OSD instead of
/// pausing for exactly that reason. Registering handlers here would put
/// controls on screen that lie about what they do. Channel up/down could be
/// mapped to next/previous track later; that is a product decision, not a
/// technical gap.
@MainActor
enum NowPlayingInfoService {

    /// Set once at launch. Now Playing only surfaces for an app with an active
    /// `.playback` audio session, which is also the correct category for a
    /// video app that should keep playing rather than duck or mix.
    static func configureAudioSession() {
        do {
            // .longFormAudio is what makes tvOS send this app's audio to the
            // AirPlay speakers the user picked as the Apple TV's audio output.
            // The video equivalent (.longFormVideo) is iOS-only and unavailable
            // here. Without a long-form policy, playback stays on the TV's own
            // speakers even while the system is routing other apps elsewhere.
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                policy: .longFormAudio
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Not fatal: playback still works, the system just will not show a
            // now-playing card. Never let this take the app down.
            print("[Plex90] NOWPLAYING: audio session unavailable: \(error.localizedDescription)")
        }
    }

    /// Identifies the artwork currently loaded, so a slow image fetch that
    /// finishes after the channel changed cannot overwrite the new programme.
    private static var artworkToken: String?

    static func clear() {
        artworkToken = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Publish the current programme.
    ///
    /// - Parameters:
    ///   - item: what is airing
    ///   - channel: the channel it is airing on, shown as the subtitle
    ///   - isPlaying: drives the system's play/pause indicator
    ///   - elapsed: seconds into the programme, from the player
    ///   - artworkURL: resolved by the caller, since only `AppState` knows which
    ///     backend and server the item came from
    static func update(
        item: PlexMediaItem,
        channel: Channel?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        artworkURL: URL?
    ) {
        var info: [String: Any] = [:]

        // Music videos read better as "Artist · Track" than a bare filename.
        info[MPMediaItemPropertyTitle] = item.isMusicVideo ? item.musicDisplayLine : item.title

        if let channel {
            // Mirrors the on-screen OSD: "CH 03 · VHS VAULT".
            let label = "CH \(String(format: "%02d", channel.number)) · \(channel.name)"
            info[MPMediaItemPropertyArtist] = label
            info[MPMediaItemPropertyAlbumTitle] = label
        }

        if item.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = TimeInterval(item.slotSeconds)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        // Keep any artwork already loaded for this same item so a metadata
        // refresh (a tick of elapsed time) does not blank the poster.
        if artworkToken == item.ratingKey,
           let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        if artworkToken != item.ratingKey {
            artworkToken = item.ratingKey
            loadArtwork(from: artworkURL, for: item.ratingKey)
        }
    }

    private static func loadArtwork(from url: URL?, for ratingKey: String) {
        guard let url else { return }
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            // The channel may have changed while this was in flight.
            guard artworkToken == ratingKey else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = art
        }
    }
}
