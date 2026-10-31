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
        if guideTextFixtureRequested { return guideTextFixtureChannels() }
        return manyChannelsForUITest ? paddedChannels() : baseChannels()
    }

    /// Test-only: `-uiTestGuideTextFixture` gives demo mode three-digit channel numbers
    /// and titles of 40+ characters, the widest text the guide has to fit, for GUIDE
    /// TEXT SIZE screenshots. Never set in a shipping run.
    static var guideTextFixtureRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestGuideTextFixture")
    }

    private static func guideTextFixtureChannels() -> [Channel] {
        let long = [
            "The Extraordinary Midnight Adventures of Cassette Kid",   // 53
            "Revenge of the Neon Ninjas from Outer Space",             // 43
            "A Very Long Weekend at the Roller Disco Palace",          // 46
            "Attack of the Fifty Foot Video Store Clerk",              // 42
            "Return to the Haunted Drive-In on Route Sixty-Six",       // 49
        ]
        let rows: [(id: Int, number: Int, name: String, hex: String)] = [
            (9001, 100, "DEMO ACTION", "#FF2244"),
            (9002, 216, "DEMO COMEDY", "#FFD400"),
            (9003, 452, "DEMO SCI-FI", "#00C4FF"),
            (9004, 888, "DEMO 80s TV", "#FF66CC"),
            (9005, 999, "DEMO LATE NIGHT THEATRE", "#7C3AED"),
        ]
        return rows.enumerated().map { index, row in
            channel(
                id: row.id, number: row.number, name: row.name, colorHex: row.hex,
                items: (0..<5).map { n in
                    item(
                        id: "d-gt-\(row.number)-\(n)",
                        title: n % 2 == 0 ? long[(index + n) % long.count] : "Short One \(n)",
                        year: 1985 + n,
                        genres: ["Action"],
                        duration: [96, 34, 118, 52, 101][n]
                    )
                }
            )
        }
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

    private static func episode(id: String, show: String, se: String, year: Int, duration: Int,
                                tmdbID: String? = nil) -> PlexMediaItem {
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
            tmdbID: tmdbID, imdbID: nil,
            librarySource: .tv
        )
    }

    // MARK: - Franchise fixture (test only)

    /// `-uiTestFranchiseFixture`: demo mode plus a small enriched library, so the FOUND IN
    /// YOUR LIBRARY block and a found-franchise channel can be seen on a simulator with no
    /// server and before the shared enrichment table carries the franchise columns.
    /// Never set in a shipping run.
    static var franchiseFixtureRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestFranchiseFixture")
    }

    struct FranchiseFixture {
        let items: [PlexMediaItem]
        let enrichment: [MediaEnrichment]
        let collections: [DiscoveredCollection]
    }

    /// Real TMDB collection ids (the same ones FranchiseDictionary lists) over invented
    /// item ids. Covers every row kind Settings can show:
    ///   - STAR WARS: titled so CH100's own `titleContains` rule builds the stock channel,
    ///     so the found franchise folds into it and lists as the CH 100 row.
    ///   - JOHN WICK, THE HUNGER GAMES, BACK TO THE FUTURE, STAR TREK: dictionary
    ///     franchises with no stock channel, listed with a switch. STAR TREK carries a show.
    ///   - SPY KIDS: no dictionary entry, found purely from `belongs_to_collection`.
    ///   - SPIDER-MAN (two TMDB collections, dictionary) and AMERICAN PIE (two
    ///     collections, general name rule) each list as one franchise; Loki puts a show
    ///     on MARVEL CH101 next to three Marvel Studios films.
    ///   - Two server collections: one that IS John Wick (folds away), one actor set that
    ///     stays under OTHER COLLECTIONS.
    static func franchiseFixture() -> FranchiseFixture {
        func film(_ id: String, _ title: String, _ year: Int, tmdb: String,
                  studio: String = "Nostalgex Demo") -> PlexMediaItem {
            PlexMediaItem(
                id: id, title: title, artist: nil, episodeTitle: nil, seTag: nil,
                summary: "Sample content for demo mode.",
                year: year, originallyAvailableAt: nil, contentRating: "PG-13", duration: 120,
                ratingKey: id, partKey: nil,
                container: nil, videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil,
                genres: ["Action"], rating: 7.5, userRating: 0,
                type: .movie,
                thumb: nil, art: nil,
                viewCount: 0, addedAt: Int(Date().timeIntervalSince1970),
                studio: studio,
                tmdbID: tmdb, imdbID: nil,
                librarySource: .movie
            )
        }
        func row(tmdb: String, mediaType: String = "movie", franchiseID: Int?, franchiseName: String?) -> MediaEnrichment {
            MediaEnrichment(
                tmdbID: tmdb, imdbID: nil, mediaType: mediaType,
                keywords: [], networks: [], productionCompanies: [], tmdbGenres: [],
                imdbRating: nil, imdbVotes: nil, rottenTomatoesScore: nil, metacriticScore: nil,
                awards: nil, franchiseID: franchiseID, franchiseName: franchiseName, fetchedAt: Date()
            )
        }

        var items: [PlexMediaItem] = []
        var rows: [MediaEnrichment] = []
        func add(_ titles: [(String, Int)], prefix: String, tmdbBase: Int, franchiseID: Int, franchiseName: String,
                 studio: String = "Nostalgex Demo") {
            for (i, entry) in titles.enumerated() {
                let tmdb = "\(tmdbBase + i)"
                items.append(film("fx-\(prefix)-\(i + 1)", entry.0, entry.1, tmdb: tmdb, studio: studio))
                rows.append(row(tmdb: tmdb, franchiseID: franchiseID, franchiseName: franchiseName))
            }
        }

        add([("Star Wars: Episode IV - A New Hope", 1977),
             ("Star Wars: Episode V - The Empire Strikes Back", 1980),
             ("Star Wars: Episode VI - Return of the Jedi", 1983)],
            prefix: "sw", tmdbBase: 900_010, franchiseID: 10, franchiseName: "Star Wars Collection")
        add([("John Wick", 2014), ("John Wick: Chapter 2", 2017),
             ("John Wick: Chapter 3 - Parabellum", 2019), ("John Wick: Chapter 4", 2023)],
            prefix: "jw", tmdbBase: 900_020, franchiseID: 404609, franchiseName: "John Wick Collection")
        add([("The Hunger Games", 2012), ("The Hunger Games: Catching Fire", 2013),
             ("The Hunger Games: Mockingjay - Part 1", 2014), ("The Hunger Games: Mockingjay - Part 2", 2015)],
            prefix: "hg", tmdbBase: 900_030, franchiseID: 131635, franchiseName: "The Hunger Games Collection")
        add([("Back to the Future", 1985), ("Back to the Future Part II", 1989), ("Back to the Future Part III", 1990)],
            prefix: "bttf", tmdbBase: 900_040, franchiseID: 264, franchiseName: "Back to the Future Collection")
        add([("Star Trek", 2009), ("Star Trek Into Darkness", 2013), ("Star Trek Beyond", 2016)],
            prefix: "st", tmdbBase: 900_050, franchiseID: 115575, franchiseName: "Star Trek: Alternate Reality Collection")
        add([("Spy Kids", 2001), ("Spy Kids 2: The Island of Lost Dreams", 2002), ("Spy Kids 3-D: Game Over", 2003)],
            prefix: "sk", tmdbBase: 900_060, franchiseID: 86027, franchiseName: "Spy Kids Collection")
        // Split on TMDB, one franchise to a viewer. SPIDER-MAN merges by dictionary
        // (Raimi + MCU collections); AMERICAN PIE by the general name rule.
        // The MCU pair is also Marvel Studios, so CH101's studio rule airs it; Settings
        // counts it under SPIDER-MAN only.
        add([("Spider-Man", 2002)],
            prefix: "smr", tmdbBase: 900_090, franchiseID: 556, franchiseName: "Spider-Man Collection")
        add([("Spider-Man: Homecoming", 2017), ("Spider-Man: No Way Home", 2021)],
            prefix: "smm", tmdbBase: 900_095, franchiseID: 531241, franchiseName: "Spider-Man (MCU) Collection",
            studio: "Marvel Studios")
        // Three Marvel Studios films with no collection, so CH101 builds from its rule.
        for (i, entry) in [("Iron Man", 2008), ("Thor", 2011), ("The Avengers", 2012)].enumerated() {
            let tmdb = "\(900_110 + i)"
            items.append(film("fx-mcu-\(i + 1)", entry.0, entry.1, tmdb: tmdb, studio: "Marvel Studios"))
            rows.append(row(tmdb: tmdb, franchiseID: nil, franchiseName: nil))
        }
        add([("American Pie", 1999), ("American Pie 2", 2001)],
            prefix: "ap", tmdbBase: 900_100, franchiseID: 2806, franchiseName: "American Pie Collection")
        add([("American Pie Presents: Band Camp", 2005)],
            prefix: "aps", tmdbBase: 900_105, franchiseID: 298820, franchiseName: "American Pie (Spin-off) Collection")

        // Shows join by dictionary title (The Mandalorian -> STAR WARS) or by token
        // (Star Trek: The Next Generation -> STAR TREK). TV rows carry no franchise.
        for se in ["S01E01", "S01E02"] {
            items.append(episode(id: "fx-mando-\(se)", show: "The Mandalorian", se: se, year: 2019, duration: 40, tmdbID: "900_070"))
        }
        for se in ["S03E15", "S03E16"] {
            items.append(episode(id: "fx-tng-\(se)", show: "Star Trek: The Next Generation", se: se, year: 1990, duration: 45, tmdbID: "900_071"))
        }
        // An MCU show: joins MARVEL (CH101) by its exact title.
        for se in ["S01E01", "S01E02"] {
            items.append(episode(id: "fx-loki-\(se)", show: "Loki", se: se, year: 2021, duration: 50, tmdbID: "900_072"))
        }
        rows.append(row(tmdb: "900_072", mediaType: "tv", franchiseID: nil, franchiseName: nil))
        rows.append(row(tmdb: "900_070", mediaType: "tv", franchiseID: nil, franchiseName: nil))
        rows.append(row(tmdb: "900_071", mediaType: "tv", franchiseID: nil, franchiseName: nil))

        // An actor set: three unrelated films, no franchise ids. Stays under OTHER COLLECTIONS.
        let hanks = [
            film("fx-hanks-1", "Big", 1988, tmdb: "900_080"),
            film("fx-hanks-2", "Cast Away", 2000, tmdb: "900_081"),
            film("fx-hanks-3", "Forrest Gump", 1994, tmdb: "900_082")
        ]
        items.append(contentsOf: hanks)
        for h in hanks { rows.append(row(tmdb: h.tmdbID ?? "", franchiseID: nil, franchiseName: nil)) }

        let wick = items.filter { $0.id.hasPrefix("fx-jw-") }
        let collections = [
            DiscoveredCollection(
                id: "fx-col-wick", title: "JOHN WICK COLLECTION", movieCount: wick.count,
                items: wick, enabled: false, matchedChannel: nil, contentOverlap: nil,
                category: .franchises
            ),
            DiscoveredCollection(
                id: "fx-col-hanks", title: "TOM HANKS", movieCount: hanks.count,
                items: hanks, enabled: false, matchedChannel: nil, contentOverlap: nil,
                category: .custom
            )
        ]

        return FranchiseFixture(items: items, enrichment: rows, collections: collections)
    }
}
