import XCTest
@testable import Nostalgex

/// Jellyfin (and Emby) file the videos in a Music Videos library as `MusicVideo`, not
/// `Movie` (@owenvoke, PR #151). The app asked every non-TV library for
/// `IncludeItemTypes=Movie`, so a Music Videos library came back empty and HIGH ROTATION
/// never filled on Jellyfin or Emby (I-067).
///
/// A loopback server answers `/Items` the way both servers do: only the item types asked
/// for. The library is loaded through each backend's REAL `loadLibrary`.
final class MusicVideoItemTypeTests: XCTestCase {

    private static func ticks(_ minutes: Int) -> Int64 { Int64(minutes) * 60 * 10_000_000 }

    /// Two libraries: Music Videos (three MusicVideo items and one Movie, a concert film
    /// someone filed there) and Movies (one Movie, and one MusicVideo that must stay out of it).
    private static let byLibrary: [String: [[String: Any]]] = [
        "mv": [
            ["Id": "mv1", "Name": "a-ha - Take On Me", "Type": "MusicVideo", "RunTimeTicks": ticks(4)],
            ["Id": "mv2", "Name": "Toto - Africa", "Type": "MusicVideo", "RunTimeTicks": ticks(5)],
            ["Id": "mv3", "Name": "Blondie - Call Me", "Type": "MusicVideo", "RunTimeTicks": ticks(4)],
            ["Id": "mv4", "Name": "Stop Making Sense", "Type": "Movie", "RunTimeTicks": ticks(88)],
        ],
        "movies": [
            ["Id": "m1", "Name": "Big", "Type": "Movie", "RunTimeTicks": ticks(104), "Genres": ["Comedy"]],
            ["Id": "m2", "Name": "Madonna - Vogue", "Type": "MusicVideo", "RunTimeTicks": ticks(5)],
        ],
    ]

    private static func reply(path: String, query: [String: String]) -> LoopbackReply? {
        if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
            return LoopbackReply(delayMs: 0, body: ["Items": [
                ["Id": "mv", "Name": "Music Videos", "CollectionType": "musicvideos"],
                ["Id": "movies", "Name": "Movies", "CollectionType": "movies"],
            ], "TotalRecordCount": 2])
        }
        guard path.hasSuffix("/Items"), let all = byLibrary[query["ParentId"] ?? ""] else { return nil }
        let types = Set((query["IncludeItemTypes"] ?? "").split(separator: ",").map(String.init))
        let items = all.filter { types.contains($0["Type"] as? String ?? "") }
        let start = Int(query["StartIndex"] ?? "0") ?? 0
        return LoopbackReply(delayMs: 0, body: ["Items": Array(items.dropFirst(start)), "TotalRecordCount": items.count])
    }

    private enum Backend: String, CaseIterable { case jellyfin, emby }

    private func load(_ backend: Backend) async throws -> (items: [PlexMediaItem], server: LoopbackJSONServer) {
        let server = try LoopbackJSONServer { Self.reply(path: $0, query: $1) }
        try await server.start()
        defer { server.stop() }
        switch backend {
        case .jellyfin:
            return (try await JellyfinAPIService(serverURL: server.url, accessToken: "t", userId: "u").loadLibrary(), server)
        case .emby:
            return (try await EmbyAPIService(serverURL: server.url, accessToken: "t", userId: "u").loadLibrary(), server)
        }
    }

    func testAMusicVideosLibraryLoadsItsMusicVideoItems() async throws {
        for backend in Backend.allCases {
            let (items, _) = try await load(backend)
            let musicVideos = items.filter { $0.librarySource == .musicVideo }
            XCTAssertEqual(Set(musicVideos.map(\.ratingKey)), ["mv1", "mv2", "mv3", "mv4"],
                           "\(backend): the Music Videos library's items, MusicVideo and Movie alike")
            XCTAssertEqual(musicVideos.first { $0.ratingKey == "mv2" }?.artist, "Toto", "\(backend)")
        }
    }

    /// Only Music Videos libraries widen the question. A Movies library still asks for
    /// films only, so a stray music video there never lands on a film channel.
    func testAMoviesLibraryStillAsksForMoviesOnly() async throws {
        for backend in Backend.allCases {
            let (items, server) = try await load(backend)
            let asked = Dictionary(
                server.requests.filter { $0.path.hasSuffix("/Items") }.map { ($0.query["ParentId"] ?? "", $0.query["IncludeItemTypes"] ?? "") },
                uniquingKeysWith: { a, _ in a })
            XCTAssertEqual(asked["movies"], "Movie", "\(backend)")
            XCTAssertEqual(asked["mv"], "Movie,MusicVideo", "\(backend)")
            XCTAssertEqual(items.filter { $0.librarySource != .musicVideo }.map(\.ratingKey), ["m1"], "\(backend)")
        }
    }
}
