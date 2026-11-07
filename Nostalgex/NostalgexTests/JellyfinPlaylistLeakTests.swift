import XCTest
@testable import Nostalgex

/// GitHub #205 / #206: a Jellyfin or Emby playlist is scanned as a film and airs on VHS VAULT.
///
/// The scan asked every library view that is not TV or Music Videos for `IncludeItemTypes=Movie`.
/// Jellyfin's Playlists view answers any request with its playlists (`PlaylistsFolder` sets
/// `IncludeItemTypes = [Playlist]`), and the app turned each row into a film. A playlist has no year,
/// the year rule lets an item with no year through, and a 33 minute workout mix landed on VHS VAULT,
/// DVD SHELF and FLICKS. The fix: views that hold no videos are never scanned, and a row whose `Type`
/// was not asked for is dropped. A MusicVideo in a Music Videos library still loads (I-067).
///
/// The fake server below answers the way those views do: Playlists, Music and Collections reply with
/// their own kind of row whatever the request asks for.
@MainActor
final class JellyfinPlaylistLeakTests: XCTestCase {

    private func scan(_ make: (String) -> any MediaBackend) async throws -> (items: [PlexMediaItem], requests: [(path: String, query: [String: String])]) {
        let http = try LoopbackJSONServer { path, query in PlaylistLeakFixture.reply(path: path, query: query) }
        try await http.start()
        defer { http.stop() }
        let items = try await make(http.url).loadLibrary(excludedSectionKeys: [], progress: nil)
        return (items, http.requests)
    }

    private func poolsHolding(_ items: [PlexMediaItem], backend: MediaBackendKind) async -> [(name: String, titles: Set<String>)] {
        let state = AppState()
        state.backendKind = backend
        state.allItems = items
        let config = ChannelConfigLoader.loadBundled()
        state.exclusiveRules = config.exclusiveRules
        let built = await state.rebuildStaticChannelPools(
            configChannels: config.channels, items: items, onlyChannelIDs: Set(config.channels.map(\.id)))
        return built.map { ($0.name, Set($0.itemPool.map(\.title))) }
    }

    private func check(_ name: String, backend: MediaBackendKind, make: (String) -> any MediaBackend) async throws {
        let (items, requests) = try await scan(make)
        let titles = Set(items.map(\.title))

        // The playlists, tracks, album, box set and clips are not in the library at all.
        XCTAssertTrue(titles.isDisjoint(with: PlaylistLeakFixture.leakedTitles), "\(name): \(titles.intersection(PlaylistLeakFixture.leakedTitles).sorted()) scanned as titles")
        // Views that hold no videos are not asked for items.
        let asked = Set(requests.filter { $0.path.hasSuffix("/Items") }.compactMap { $0.query["ParentId"] })
        XCTAssertTrue(asked.isDisjoint(with: PlaylistLeakFixture.blindViews), "\(name): items asked of \(asked.intersection(PlaylistLeakFixture.blindViews).sorted())")

        // Controls: what should load still loads, as it did.
        for title in PlaylistLeakFixture.filmTitles { XCTAssertTrue(titles.contains(title), "\(name): \(title) is missing") }
        XCTAssertEqual(items.filter { $0.type == .episode }.count, 3, "\(name): the show's episodes")
        XCTAssertTrue(titles.contains("Filed Film"), "\(name): a film filed under Music Videos")
        XCTAssertTrue(titles.contains("Mixed Film"), "\(name): a film in a view with no CollectionType")
        let songs = items.filter { $0.title == "Song A" || $0.title == "Song B" }
        XCTAssertEqual(songs.count, 2, "\(name): MusicVideo rows in a Music Videos library (I-067)")
        XCTAssertTrue(songs.allSatisfy { $0.librarySource == .musicVideo }, "\(name): and they are music videos")

        // And nothing that is not a film reaches a channel. The six 1980s films fill VHS VAULT, so it exists.
        let pools = await poolsHolding(items, backend: backend)
        let vault = pools.first { $0.name == "VHS VAULT" }
        XCTAssertNotNil(vault, "\(name): control, VHS VAULT has its films")
        XCTAssertTrue(vault?.titles.contains("Vault Film 1") ?? false, "\(name): control, a real film is on VHS VAULT")
        for pool in pools {
            XCTAssertTrue(pool.titles.isDisjoint(with: PlaylistLeakFixture.leakedTitles), "\(name): \(pool.titles.intersection(PlaylistLeakFixture.leakedTitles).sorted()) on \(pool.name)")
        }
    }

    func testAJellyfinPlaylistIsNotAFilm() async throws {
        try await check("Jellyfin", backend: .jellyfin) { JellyfinAPIService(serverURL: $0, accessToken: "t", userId: "u") }
    }

    func testAnEmbyPlaylistIsNotAFilm() async throws {
        try await check("Emby", backend: .emby) { EmbyAPIService(serverURL: $0, accessToken: "t", userId: "u") }
    }
}

/// The fake server's data and answers. Outside the main-actor test class so the server can call it.
enum PlaylistLeakFixture {
    static let ticks = Int64(600_000_000)   // one minute

    static func row(_ id: String, _ name: String, _ type: String, year: Int? = nil, minutes: Int,
                            extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["Id": id, "Name": name, "Type": type, "Genres": ["Drama"],
                                "RunTimeTicks": Int64(minutes) * ticks,
                                "ProviderIds": ["Tmdb": "\(abs(id.hashValue % 900_000))"],
                                "MediaSources": [["Id": "ms-\(id)", "Container": "mkv"]]]
        if let year { d["ProductionYear"] = year }
        for (k, v) in extra { d[k] = v }
        return d
    }

    /// Eight views, as a user with the usual folders would have them.
    nonisolated(unsafe) static let views: [[String: Any]] = [
        ["Id": "movies", "Name": "Movies", "CollectionType": "movies"],
        ["Id": "tv", "Name": "TV Shows", "CollectionType": "tvshows"],
        ["Id": "mv", "Name": "Music Videos", "CollectionType": "musicvideos"],
        ["Id": "pl", "Name": "Playlists", "CollectionType": "playlists"],
        ["Id": "music", "Name": "Music", "CollectionType": "music"],
        ["Id": "boxsets", "Name": "Collections", "CollectionType": "boxsets"],
        ["Id": "home", "Name": "Home Videos", "CollectionType": "homevideos"],
        ["Id": "mixed", "Name": "Everything Else"],
    ]

    static let filmTitles = (1...6).map { "Vault Film \($0)" }
    static let leakedTitles: Set<String> = ["Workout Mix", "Chill Mix", "Track 1", "Track 2", "Best Of Album",
                                                    "Action Box Set", "Home Clip", "Mixed Playlist", "Mixed Clip"]
    static let blindViews: Set<String> = ["pl", "music", "boxsets", "home"]

    static func reply(path: String, query: [String: String]) -> LoopbackReply? {
        if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": views.count, "Items": views])
        }
        guard path.hasSuffix("/Items") else { return nil }
        func page(_ rows: [[String: Any]]) -> LoopbackReply {
            LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        }
        switch query["ParentId"] ?? "" {
        case "movies":
            return page(filmTitles.enumerated().map { row("m\($0.offset)", $0.element, "Movie", year: 1984 + $0.offset % 6, minutes: 100,
                                                          extra: ["OfficialRating": "PG"]) })
        case "tv":
            return page([row("show1", "Lab Show", "Series", year: 1990, minutes: 0)])
        case "show1":
            return page((1...3).map { row("e\($0)", "Lab Show \($0)", "Episode", year: 1990, minutes: 22,
                                          extra: ["SeriesName": "Lab Show", "ParentIndexNumber": 1, "IndexNumber": $0]) })
        case "mv":
            return page([row("v1", "Song A", "MusicVideo", year: 1999, minutes: 4),
                         row("v2", "Song B", "MusicVideo", year: 1999, minutes: 4),
                         row("v3", "Filed Film", "Movie", year: 1987, minutes: 95)])
        case "pl":
            // Whatever is asked, a Playlists view answers with its playlists: no year, 33 minutes.
            return page([row("p1", "Workout Mix", "Playlist", minutes: 33), row("p2", "Chill Mix", "Playlist", minutes: 48)])
        case "music":
            return page([row("a1", "Track 1", "Audio", minutes: 3), row("a2", "Track 2", "Audio", minutes: 4),
                         row("a3", "Best Of Album", "MusicAlbum", minutes: 40)])
        case "boxsets":
            return page([row("b1", "Action Box Set", "BoxSet", minutes: 240)])
        case "home":
            return page([row("h1", "Home Clip", "Video", minutes: 12)])
        case "mixed":
            // No CollectionType: a film view, but a row that is not a film is still not a film.
            return page([row("x1", "Mixed Film", "Movie", year: 1991, minutes: 100),
                         row("x2", "Mixed Playlist", "Playlist", minutes: 33),
                         row("x3", "Mixed Clip", "Video", minutes: 9)])
        default:
            return nil
        }
    }

}
