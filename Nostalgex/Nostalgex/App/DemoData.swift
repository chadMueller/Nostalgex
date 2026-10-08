import Foundation
import SwiftUI

/// Bundled, network-free sample channels and items for App Store review and offline preview.
///
/// Why this exists: Apple's review network can't always reach a tester's Plex Media Server.
/// When discovery or auth fails on their end, the reviewer sees an error screen and the app
/// gets rejected. Demo Mode lets them tap one button and see the full tuner UI populated
/// with sample content — no Plex account, no network, no failure modes. Playback won't work
/// (these items have no real media URLs), but every navigation surface renders.
enum DemoData {

    /// Test-only: `-uiTestManyChannels` pads demo mode out to a guide that actually
    /// scrolls. The five bundled channels fit on screen at once, so they can never
    /// reproduce an edge-wrap bug that only exists once the list is taller than the
    /// viewport — which is every real library. Never set in a shipping run.
    static var manyChannelsForUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestManyChannels")
    }

    /// Enough rows that the bottom of the list is well below the fold on a 1080p/4K
    /// guide (the grid shows roughly 7 rows at 80pt).
    static let uiTestChannelCount = 20

    static func channels() -> [Channel] {
        manyChannelsForUITest ? paddedChannels() : baseChannels()
    }

    /// The five bundled channels, then filler rows numbered 6...n so the list scrolls.
    private static func paddedChannels() -> [Channel] {
        let base = baseChannels()
        guard base.count < uiTestChannelCount else { return base }
        var out = base
        for number in (base.count + 1)...uiTestChannelCount {
            out.append(
                channel(
                    id: 9000 + number,
                    number: number,
                    name: "DEMO FILLER \(number)",
                    colorHex: "#8899AA",
                    items: (1...5).map {
                        item(
                            id: "d-f\(number)-\($0)",
                            title: "Filler \(number) Feature \($0)",
                            year: 1980 + $0,
                            genres: ["Action"],
                            duration: 90 + $0
                        )
                    }
                )
            )
        }
        return out
    }

    private static func baseChannels() -> [Channel] {
        [
            channel(
                id: 9001, number: 1, name: "DEMO ACTION", colorHex: "#FF2244",
                items: [
                    item(id: "d-act-1", title: "Neon Strike",        year: 1987, genres: ["Action"],   duration: 102),
                    item(id: "d-act-2", title: "Cobra Code",         year: 1991, genres: ["Action"],   duration: 96),
                    item(id: "d-act-3", title: "Velocity 9",         year: 1989, genres: ["Action"],   duration: 110),
                    item(id: "d-act-4", title: "Razor City",         year: 1993, genres: ["Action"],   duration: 105),
                    item(id: "d-act-5", title: "Last Patrol",        year: 1985, genres: ["Action"],   duration: 98),
                ]
            ),
            channel(
                id: 9002, number: 2, name: "DEMO COMEDY", colorHex: "#FFD400",
                items: [
                    item(id: "d-com-1", title: "Tape Deck Heroes",   year: 1988, genres: ["Comedy"],   duration: 92),
                    item(id: "d-com-2", title: "Mall Cops on Vacation", year: 1990, genres: ["Comedy"], duration: 89),
                    item(id: "d-com-3", title: "Summer of Static",   year: 1986, genres: ["Comedy"],   duration: 95),
                    item(id: "d-com-4", title: "Big Hair, Bigger Problems", year: 1992, genres: ["Comedy"], duration: 88),
                    item(id: "d-com-5", title: "Boombox Brothers",   year: 1989, genres: ["Comedy"],   duration: 99),
                ]
            ),
            channel(
                id: 9003, number: 3, name: "DEMO SCI-FI", colorHex: "#00C4FF",
                items: [
                    item(id: "d-sci-1", title: "Quantum Drift",      year: 1984, genres: ["Sci-Fi"],   duration: 118),
                    item(id: "d-sci-2", title: "Orbit Echo",         year: 1992, genres: ["Sci-Fi"],   duration: 124),
                    item(id: "d-sci-3", title: "Signal from Vega",   year: 1979, genres: ["Sci-Fi"],   duration: 132),
                    item(id: "d-sci-4", title: "The Replicant Trial", year: 1987, genres: ["Sci-Fi"],  duration: 108),
                    item(id: "d-sci-5", title: "Synthwave Frontier", year: 1990, genres: ["Sci-Fi"],   duration: 101),
                ]
            ),
            channel(
                id: 9004, number: 4, name: "DEMO 80s TV", colorHex: "#FF66CC",
                items: [
                    episode(id: "d-tv-1", show: "Late Shift Diner",  se: "S01E01", year: 1986, duration: 44),
                    episode(id: "d-tv-2", show: "Late Shift Diner",  se: "S01E02", year: 1986, duration: 44),
                    episode(id: "d-tv-3", show: "Beach Patrol PI",   se: "S02E03", year: 1988, duration: 47),
                    episode(id: "d-tv-4", show: "Beach Patrol PI",   se: "S02E04", year: 1988, duration: 46),
                    episode(id: "d-tv-5", show: "Garage Band USA",   se: "S01E05", year: 1989, duration: 42),
                ]
            ),
            channel(
                id: 9005, number: 5, name: "DEMO LATE NIGHT", colorHex: "#7C3AED",
                items: [
                    item(id: "d-ln-1", title: "Midnight Cassette",   year: 1981, genres: ["Thriller"], duration: 96),
                    item(id: "d-ln-2", title: "Static at 3 AM",      year: 1984, genres: ["Horror"],   duration: 84),
                    item(id: "d-ln-3", title: "Channel Phantom",     year: 1988, genres: ["Thriller"], duration: 101),
                    item(id: "d-ln-4", title: "Drive-In Apparition", year: 1979, genres: ["Horror"],   duration: 92),
                    item(id: "d-ln-5", title: "VHS Witness",         year: 1991, genres: ["Mystery"],  duration: 97),
                ]
            ),
        ]
    }

    // MARK: - Helpers

    private static func channel(id: Int, number: Int, name: String, colorHex: String, items: [PlexMediaItem]) -> Channel {
        Channel(
            id: id,
            number: number,
            name: name,
            color: Color(hex: colorHex),
            category: "demo",
            rules: nil,
            timeRestrictions: nil,
            minItems: 0,
            itemPool: items
        )
    }

    private static func item(id: String, title: String, year: Int, genres: [String], duration: Int) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "Sample content for demo mode.",
            year: year, originallyAvailableAt: nil, contentRating: "PG-13", duration: duration,
            ratingKey: id, partKey: nil,
            container: nil, videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: genres, rating: 7.5, userRating: 0,
            type: .movie,
            thumb: nil, art: nil,
            viewCount: 0, addedAt: Int(Date().timeIntervalSince1970),
            studio: "Nostalgex Demo",
            tmdbID: nil, imdbID: nil,
            librarySource: .movie
        )
    }

    private static func episode(id: String, show: String, se: String, year: Int, duration: Int) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: show, artist: nil, episodeTitle: "Demo Episode", seTag: se,
            summary: "Sample episode for demo mode.",
            year: year, originallyAvailableAt: nil, contentRating: "TV-PG", duration: duration,
            ratingKey: id, partKey: nil,
            container: nil, videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
            genres: ["Drama"], rating: 7.2, userRating: 0,
            type: .episode,
            thumb: nil, art: nil,
            viewCount: 0, addedAt: Int(Date().timeIntervalSince1970),
            studio: "Nostalgex Demo",
            tmdbID: nil, imdbID: nil,
            librarySource: .tv
        )
    }
}
