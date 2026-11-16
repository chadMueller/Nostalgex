import Foundation
import SwiftUI
import AVFoundation

extension Channel {
    /// CH 299, LOCAL WEATHER (I-016): drawn by the app, never played from a server.
    var isWeather: Bool { id == WeatherEngine.channelID }
}

/// CH 299 in the guide. It is in no bundle and not in channels.json: it joins the lineup while its switch
/// (Settings, PLAYBACK & PICTURE, WEATHER) is on, and never on its own, so an empty library still reads as
/// empty. It has no pool, so the scheduler and every pool builder never see it.
enum WeatherChannel {
    static func make() -> Channel {
        Channel(id: WeatherEngine.channelID, number: WeatherEngine.channelNumber, name: WeatherEngine.channelName,
                color: Color(hex: WeatherEngine.channelColorHex), category: "weather", rules: nil, timeRestrictions: nil,
                minItems: 0)
    }

    /// `lineup` with CH 299 added when `on` and there is at least one library channel, or taken out.
    static func lineup(_ lineup: [Channel], on: Bool) -> [Channel] {
        var out = lineup.filter { !$0.isWeather }
        if on, !out.isEmpty { out.append(make()) }
        return out
    }

    /// How far either side of now the one entry reaches: past both ends of the guide's window (22 hours ahead).
    static let rowReach: TimeInterval = 48 * 3600

    /// The guide row (Chad, 2026-11-16: "1 full width bar ... no scheduled sections because it's an unlimited
    /// loop channel"). One entry that is always on now and runs off both ends of the guide's window, so the row
    /// is one bar with no programme times, the programme cursor has nothing to step to, and there is no UP NEXT.
    /// Its title is LOCAL WEATHER and the current temperature when there is a forecast.
    static func schedule(at now: Date) -> ChannelSchedule {
        let start = now.addingTimeInterval(-rowReach)
        let end = now.addingTimeInterval(rowReach)
        let temperature = WeatherGuideInfo.temperature
        let title = temperature.isEmpty ? WeatherEngine.channelName : "\(WeatherEngine.channelName)  \(temperature)"
        let place = WeatherGuideInfo.placeTitle
        let summary = [place.isEmpty ? nil : "\(place).", WeatherGuideInfo.summary]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let item = PlexMediaItem(
            id: loopKey, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: summary, year: nil, originallyAvailableAt: nil, contentRating: nil,
            duration: Int(2 * rowReach / 60), ratingKey: loopKey, partKey: nil, container: nil,
            videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: nil)
        let entry = ScheduleEntry(id: loopKey, item: item, startTime: start, endTime: end, isNowPlaying: true)
        return ChannelSchedule(entries: [entry], nowPlaying: entry, upNext: nil, progress: 0,
                               elapsedSeconds: Int(rowReach))
    }

    /// The rating key of the loop's one guide entry.
    static let loopKey = "nostalgex-weather-loop"
}

extension PlexMediaItem {
    /// The weather channel's one always-live guide entry: no progress bar, no times.
    var isWeatherLoop: Bool { ratingKey == WeatherChannel.loopKey }
}

extension AppState {
    /// Whether CH 299 is in the guide: its switch is on, and the viewer is not in demo mode (what App Review
    /// sees). `-uiTestWeatherInDemo` puts it in a demo lineup for the simulator walk.
    var weatherChannelApplies: Bool {
        guard WeatherController.shared.channelOn else { return false }
        if isDemoMode {
            #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("-uiTestWeatherInDemo")
            #else
            return false
            #endif
        }
        return true
    }

    /// The switch in Settings moved: the guide takes CH 299 in or out. Leaving it while it is on goes to
    /// the first channel, as any channel leaving the guide does.
    func applyWeatherChannelSetting() {
        channels = WeatherChannel.lineup(channels, on: weatherChannelApplies)
        if let current = currentChannel, current.isWeather, !channels.contains(where: \.isWeather) {
            if let first = channels.first(where: { !$0.isWeather }) { selectChannel(first) } else { currentChannel = nil; currentItem = nil }
        }
    }

    /// Tuned to CH 299: whatever was playing stops, nothing is asked of a server, the weather view draws in
    /// the picture's place (VideoAreaView, PlayerView) and plays its own music.
    func startWeatherChannel() {
        currentItem = nil
        seekOffset = 0
        // Ends the outgoing programme's session, tracker and transcode the way any load does, then goes idle.
        loadCurrentItem()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isVideoPlaying = false
        playbackState = .idle
    }
}
