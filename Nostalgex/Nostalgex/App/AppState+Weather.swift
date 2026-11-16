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

    /// The guide row: hour-long blocks from the top of the hour before now, 26 of them, each one the loop.
    static func schedule(at now: Date) -> ChannelSchedule {
        let hour: TimeInterval = 3600
        let start = (now.timeIntervalSince1970 / hour).rounded(.down) * hour - hour
        let place = WeatherGuideInfo.placeTitle
        let summary = WeatherGuideInfo.summary
        var entries: [ScheduleEntry] = []
        var nowEntry: ScheduleEntry?
        for i in 0..<26 {
            let s = Date(timeIntervalSince1970: start + Double(i) * hour)
            let e = s.addingTimeInterval(hour)
            let live = s <= now && now < e
            let key = "nostalgex-weather-\(Int(s.timeIntervalSince1970))"
            let item = PlexMediaItem(
                id: key, title: WeatherEngine.channelName, artist: nil, episodeTitle: place.isEmpty ? nil : place, seTag: nil,
                summary: summary, year: nil, originallyAvailableAt: nil, contentRating: nil,
                duration: 60, ratingKey: key, partKey: nil, container: nil,
                videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
                genres: [], rating: 0, userRating: 0, type: .episode, thumb: nil, art: nil,
                viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: nil)
            let entry = ScheduleEntry(id: key, item: item, startTime: s, endTime: e, isNowPlaying: live)
            if live { nowEntry = entry }
            entries.append(entry)
        }
        let elapsed = nowEntry.map { now.timeIntervalSince($0.startTime) } ?? 0
        // No UP NEXT: the loop is the same every hour (the web tuner leaves the line empty too).
        return ChannelSchedule(entries: entries, nowPlaying: nowEntry, upNext: nil,
                               progress: min(1, max(0, elapsed / hour)), elapsedSeconds: Int(elapsed))
    }
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
