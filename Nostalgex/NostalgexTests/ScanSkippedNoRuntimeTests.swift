import XCTest
@testable import Nostalgex

/// "N SKIPPED (NO RUNTIME)" under RESCAN LIBRARY: the movies and episodes a scan read from the
/// server and then dropped, because a title with no runtime cannot be scheduled.
///
/// The definition, held to by every backend: an item is skipped when its runtime, in whole
/// minutes, is zero. That is no runtime at all, zero, or anything under one minute; exactly one
/// minute is kept. Each backend counts its own scan and the load adds the servers up.
///
/// Fixture, the same on all three: a Movies library of ten (six kept, among them one of exactly
/// a minute, and four skipped: no runtime, zero, 30 seconds, 59.999 seconds) and a TV library of
/// one show with four episodes (three kept, one with no runtime). Five skipped, nine loaded.
final class ScanSkippedNoRuntimeTests: XCTestCase {

    private static let keptMovies = 6
    private static let keptEpisodes = 3
    private static let expectedSkipped = 5

    // MARK: Plex

    /// Runtime in milliseconds as Plex reports it; nil leaves the field out.
    private static let plexMovieRuntimes: [Int?] = [90 * 60_000, 120 * 60_000, 60_000, 100 * 60_000, 95 * 60_000, 80 * 60_000,
                                                    nil, 0, 30_000, 59_999]
    private static let plexEpisodeRuntimes: [Int?] = [22 * 60_000, 22 * 60_000, 22 * 60_000, nil]

    private func plexReply(path: String, query: [String: String], bulkEpisodes: Bool = true) -> StopWaitingHarnessTests.Reply {
        func movie(_ i: Int, _ ms: Int?) -> [String: Any] {
            var d = StopWaitingHarnessTests.movie("1", i)
            d["duration"] = ms
            if ms == nil { d.removeValue(forKey: "duration") }
            return d
        }
        func episode(_ e: Int, _ ms: Int?) -> [String: Any] {
            var d = StopWaitingHarnessTests.episode("2", 0, e)
            d["duration"] = ms
            if ms == nil { d.removeValue(forKey: "duration") }
            return d
        }
        let sections: Any = ["MediaContainer": ["Directory": [["key": "1", "title": "Movies", "type": "movie"],
                                                              ["key": "2", "title": "TV Shows", "type": "show"]]]]
        switch path {
        case "/library/sections":
            return .json(sections, delayMs: 0)
        case "/library/sections/1/all":
            let rows = Self.plexMovieRuntimes.enumerated().map { movie($0.offset, $0.element) }
            return .json(["MediaContainer": ["totalSize": rows.count, "Metadata": rows]], delayMs: 0)
        case "/library/sections/2/all":
            if query["type"] == "4" {
                let rows = bulkEpisodes ? Self.plexEpisodeRuntimes.enumerated().map { episode($0.offset, $0.element) } : []
                return .json(["MediaContainer": ["totalSize": rows.count, "Metadata": rows]], delayMs: 0)
            }
            return .json(["MediaContainer": ["totalSize": 1, "Metadata": [StopWaitingHarnessTests.show("2", 0)]]], delayMs: 0)
        case "/library/metadata/s2-0/allLeaves":
            let rows = Self.plexEpisodeRuntimes.enumerated().map { episode($0.offset, $0.element) }
            return .json(["MediaContainer": ["Metadata": rows]], delayMs: 0)
        default:
            return .notFound
        }
    }

    func testPlexCountsWhatItDropsForRuntime() async throws {
        let server = try StopWaitingHarnessTests.FakeServer { [self] path, query in plexReply(path: path, query: query) }
        try await server.start()
        defer { server.stop() }
        let api = PlexAPIService(serverURL: "http://127.0.0.1:\(server.port)", token: "t", serverID: "skip")

        let items = try await api.loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(items.count, Self.keptMovies + Self.keptEpisodes)
        XCTAssertEqual(api.skippedNoRuntime, Self.expectedSkipped, "no runtime, zero, 30 s and 59.999 s movies, and the episode with none")

        _ = try await api.loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(api.skippedNoRuntime, Self.expectedSkipped, "each scan counts for itself, not on top of the last one")
    }

    /// A server that ignores `type=4` sends the scan to the per-show crawl; when the bulk pass
    /// had already dropped every episode for its runtime, the crawl reads the same ones again.
    func testPlexCountsAnEpisodeOnceWhenTheShowCrawlReadsItAgain() async throws {
        let server = try StopWaitingHarnessTests.FakeServer { [self] path, query in
            // The bulk pass answers with the one zero-runtime episode; allLeaves answers with the same one.
            if path == "/library/sections/2/all", query["type"] == "4" {
                var e = StopWaitingHarnessTests.episode("2", 0, 0)
                e["duration"] = 0
                return .json(["MediaContainer": ["totalSize": 1, "Metadata": [e]]], delayMs: 0)
            }
            if path == "/library/metadata/s2-0/allLeaves" {
                var e = StopWaitingHarnessTests.episode("2", 0, 0)
                e["duration"] = 0
                return .json(["MediaContainer": ["Metadata": [e]]], delayMs: 0)
            }
            return plexReply(path: path, query: query)
        }
        try await server.start()
        defer { server.stop() }
        let api = PlexAPIService(serverURL: "http://127.0.0.1:\(server.port)", token: "t", serverID: "skip")
        _ = try await api.loadLibrary(excludedSectionKeys: ["1"], progress: nil)
        XCTAssertEqual(api.skippedNoRuntime, 1, "one episode, however many ways it was read")
    }

    // MARK: Jellyfin and Emby

    /// `RunTimeTicks`, 600,000,000 to the minute.
    private static let ticksMovies: [Int64?] = [5_400_000_000, 7_200_000_000, 600_000_000, 6_000_000_000, 5_700_000_000, 4_800_000_000,
                                                nil, 0, 300_000_000, 599_999_999]
    private static let ticksEpisodes: [Int64?] = [13_200_000_000, 13_200_000_000, 13_200_000_000, nil]

    private func mediaBrowserReply(path: String, query: [String: String]) -> LoopbackReply? {
        func item(_ id: String, _ type: String, _ ticks: Int64?) -> [String: Any] {
            var d: [String: Any] = ["Id": id, "Name": "Item \(id)", "Type": type, "Genres": ["Drama"],
                                    "ProviderIds": ["Tmdb": "\(abs(id.hashValue % 900_000))"]]
            if let ticks { d["RunTimeTicks"] = ticks }
            d["MediaSources"] = [["Id": "ms-\(id)", "Container": "mkv"]]
            return d
        }
        if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": 2, "Items": [
                ["Id": "movies", "Name": "Movies", "CollectionType": "movies"],
                ["Id": "tv", "Name": "TV Shows", "CollectionType": "tvshows"]]])
        }
        guard path.hasSuffix("/Items") else { return nil }
        switch (query["ParentId"] ?? "", query["IncludeItemTypes"] ?? "") {
        case ("movies", _):
            let rows = Self.ticksMovies.enumerated().map { item("m\($0.offset)", "Movie", $0.element) }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        case ("tv", _):
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": 1, "Items": [item("show1", "Series", nil)]])
        case ("show1", _):
            let rows = Self.ticksEpisodes.enumerated().map { item("e\($0.offset)", "Episode", $0.element) }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        default:
            return nil
        }
    }

    func testJellyfinCountsWhatItDropsForRuntime() async throws {
        let server = try LoopbackJSONServer { [self] path, query in mediaBrowserReply(path: path, query: query) }
        try await server.start()
        defer { server.stop() }
        let api = JellyfinAPIService(serverURL: server.url, accessToken: "t", userId: "u")

        let items = try await api.loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(items.count, Self.keptMovies + Self.keptEpisodes)
        XCTAssertEqual(api.skippedNoRuntime, Self.expectedSkipped)
        _ = try await api.loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(api.skippedNoRuntime, Self.expectedSkipped, "each scan counts for itself")
    }

    func testEmbyCountsWhatItDropsForRuntime() async throws {
        let server = try LoopbackJSONServer { [self] path, query in mediaBrowserReply(path: path, query: query) }
        try await server.start()
        defer { server.stop() }
        let api = EmbyAPIService(serverURL: server.url, accessToken: "t", userId: "u")

        let items = try await api.loadLibrary(excludedSectionKeys: [], progress: nil)
        XCTAssertEqual(items.count, Self.keptMovies + Self.keptEpisodes)
        XCTAssertEqual(api.skippedNoRuntime, Self.expectedSkipped)
    }

    // MARK: Through the app, and the snapshot

    private final class Memory: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    /// The count rides the library snapshot: a relaunch that restores it shows the same number
    /// without scanning, and a snapshot written before the field existed reads as none.
    @MainActor
    func testTheCountSurvivesARelaunch() async throws {
        let scope = HarnessScope.begin("skipped-no-runtime")
        defer { scope.end() }
        let server = try StopWaitingHarnessTests.FakeServer { [self] path, query in plexReply(path: path, query: query) }
        try await server.start()
        defer { server.stop() }
        let ref = AppState.ServerRef(machineIdentifier: "skip-srv", name: "Skip", baseURL: "http://127.0.0.1:\(server.port)", owned: true, token: "t")

        let first = AppState(credentialStore: Memory())
        first.completePlexSignIn(token: "acct", servers: [ref])
        await first.loadLibrary()
        XCTAssertEqual(first.skippedNoRuntimeCount, Self.expectedSkipped)
        XCTAssertEqual(first.allItems.count, Self.keptMovies + Self.keptEpisodes)
        first.saveLibrarySnapshotIfNeeded()
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value

        let second = AppState(credentialStore: Memory())
        second.completePlexSignIn(token: "acct", servers: [ref])
        XCTAssertEqual(second.skippedNoRuntimeCount, 0, "nothing restored yet")
        let restored = await second.restoreLibraryFromSnapshotIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(second.skippedNoRuntimeCount, Self.expectedSkipped, "restored with the snapshot, no scan")
        XCTAssertEqual(second.allItems.count, Self.keptMovies + Self.keptEpisodes)
        first.disconnect()
        second.disconnect()
    }

    func testASnapshotFromBeforeTheFieldExistedReadsAsNone() throws {
        let old = try JSONDecoder().decode(LibrarySnapshotMetaV3.self, from: Data("""
        {"schemaVersion": \(LibrarySnapshotStore.formatVersion), "credentialFingerprint": "x", "lastLoadAtUnix": 1, "serverName": "s",
         "itemCount": 0, "chunkItemCounts": [], "channelConfigRows": [], "allChannelRows": [], "allChannelPools": [],
         "bundleDefinitions": [], "enabledBundleIDList": [], "exclusiveRuleJSON": [], "discoveredCollectionRows": [],
         "discoveredCollectionItems": []}
        """.utf8))
        XCTAssertNil(old.skippedNoRuntime)
    }
}
