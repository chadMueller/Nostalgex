import XCTest
@testable import Nostalgex

/// GitHub #204. Emby 4.10 leaves `OfficialRating` and `CommunityRating` out of an Items answer
/// unless the request's `Fields` names them (Jellyfin 12.2 sends both either way). The scan did
/// not name them, so on Emby every title read as unrated: a kids channel aired a TV-MA show,
/// VHS VAULT's 9 PM hold held nothing, and the 13 `ratingMin` channels saw no star rating.
///
/// The fake server below answers as Emby 4.10 does: a rating field is in an item only when
/// `Fields` lists it. Everything is measured through the app's own scan and its own stock channel
/// build, so the tests fail on the old request and pass on the new one.
@MainActor
final class EmbyRatingFieldsTests: XCTestCase {

    // MARK: - The fake server

    private struct Film: Sendable {
        let id: String, name: String, year: Int
        let certificate: String?, community: Double?
        var genres: [String] = ["Action"]
    }

    private struct Show: Sendable {
        let id: String, name: String, year: Int
        let certificate: String?, community: Double?
        let genres: [String]
        var episodes = 8
    }

    /// `.emby410`: a rating comes back only when `Fields` names it. `.jellyfin`: always.
    /// `.withheld`: never, whatever is asked (what the old request got from Emby).
    private enum Server { case emby410, jellyfin, withheld }

    nonisolated private static func reply(path: String, query: [String: String], server: Server, films: [Film], shows: [Show]) -> LoopbackReply? {
        let asked = Set((query["Fields"] ?? "").split(separator: ",").map { $0.lowercased() })
        func ratings(_ certificate: String?, _ community: Double?) -> [String: Any] {
            var d: [String: Any] = [:]
            let sendsCertificate = server == .jellyfin || (server == .emby410 && asked.contains("officialrating"))
            let sendsScore = server == .jellyfin || (server == .emby410 && asked.contains("communityrating"))
            if let certificate, sendsCertificate { d["OfficialRating"] = certificate }
            if let community, sendsScore { d["CommunityRating"] = community }
            return d
        }
        func base(_ id: String, _ name: String, _ type: String, year: Int, genres: [String], minutes: Int) -> [String: Any] {
            ["Id": id, "Name": name, "Type": type, "Genres": genres, "ProductionYear": year,
             "RunTimeTicks": Int64(minutes) * 600_000_000, "ProviderIds": ["Tmdb": "\(abs(id.hashValue % 900_000))"],
             "MediaSources": [["Id": "ms-\(id)", "Container": "mkv"]]]
        }
        if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": 2, "Items": [
                ["Id": "movies", "Name": "Movies", "CollectionType": "movies"],
                ["Id": "tv", "Name": "TV Shows", "CollectionType": "tvshows"]]])
        }
        guard path.hasSuffix("/Items") else { return nil }
        let parent = query["ParentId"] ?? ""
        if parent == "movies" {
            let rows = films.map { f in base(f.id, f.name, "Movie", year: f.year, genres: f.genres, minutes: 100).merging(ratings(f.certificate, f.community)) { a, _ in a } }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        }
        if parent == "tv" {
            let rows = shows.map { s in base(s.id, s.name, "Series", year: s.year, genres: s.genres, minutes: 0).merging(ratings(s.certificate, s.community)) { a, _ in a } }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        }
        if let show = shows.first(where: { $0.id == parent }) {
            let rows = (1...show.episodes).map { n -> [String: Any] in
                var d = base("\(show.id)-e\(n)", "\(show.name) \(n)", "Episode", year: show.year, genres: [], minutes: 22)
                d["SeriesName"] = show.name; d["ParentIndexNumber"] = 1; d["IndexNumber"] = n
                return d
            }
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
        }
        return nil
    }

    // MARK: - The fixture

    /// Sixteen late-1980s films for VHS VAULT (seven R, seven PG, two PG-13), with star ratings
    /// either side of 8 and 8.2. Five of them reach 8.2 (ALL TIME GREATS needs five) and six reach 8.
    private static let films: [Film] = [
        Film(id: "r1", name: "Vault R 1", year: 1984, certificate: "R", community: 6.5),
        Film(id: "r2", name: "Vault R 2", year: 1985, certificate: "R", community: 7.0),
        Film(id: "r3", name: "Vault R 3", year: 1986, certificate: "R", community: 7.5),
        Film(id: "r4", name: "Vault R 4", year: 1987, certificate: "R", community: 8.1),
        Film(id: "r5", name: "Vault R 5", year: 1988, certificate: "R", community: 8.5),
        Film(id: "r6", name: "Vault R 6", year: 1989, certificate: "R", community: 5.0),
        Film(id: "r7", name: "Vault R 7", year: 1989, certificate: "R", community: 8.9),
        Film(id: "p1", name: "Vault PG 1", year: 1984, certificate: "PG", community: 6.2),
        Film(id: "p2", name: "Vault PG 2", year: 1985, certificate: "PG", community: 6.8),
        Film(id: "p3", name: "Vault PG 3", year: 1986, certificate: "PG", community: 7.2),
        Film(id: "p4", name: "Vault PG 4", year: 1987, certificate: "PG", community: 8.3),
        Film(id: "p5", name: "Vault PG 5", year: 1988, certificate: "PG", community: 4.0),
        Film(id: "p6", name: "Vault PG 6", year: 1989, certificate: "PG", community: 5.5),
        Film(id: "p7", name: "Vault PG 7", year: 1989, certificate: "PG", community: 8.6),
        Film(id: "t1", name: "Vault PG-13 1", year: 1988, certificate: "PG-13", community: 8.4),
        Film(id: "t2", name: "Vault PG-13 2", year: 1989, certificate: "PG-13", community: 7.9),
    ]

    /// Four cartoons for SAT MORNING CARTOONS: a TV-MA one and a TV-14 one that must leave, a
    /// TV-Y7 one that must stay, and one the server has no certificate for, which stays too
    /// (the channel allows unrated).
    private static let shows: [Show] = [
        Show(id: "sp", name: "South Park", year: 1997, certificate: "TV-MA", community: 8.7, genres: ["Animation", "Comedy"]),
        Show(id: "tt", name: "Teen Toon", year: 1995, certificate: "TV-14", community: 6.9, genres: ["Animation"]),
        Show(id: "kc", name: "Kid Cartoon Hour", year: 1985, certificate: "TV-Y7", community: 7.0, genres: ["Animation", "Kids"]),
        Show(id: "mc", name: "Mystery Cartoon", year: 1990, certificate: nil, community: nil, genres: ["Animation"]),
    ]

    private func scan(_ server: Server, films: [Film]? = nil, shows: [Show]? = nil, api: (String) -> any MediaBackend = { url in
        EmbyAPIService(serverURL: url, accessToken: "t", userId: "u") }
    ) async throws -> (items: [PlexMediaItem], requests: [(path: String, query: [String: String])]) {
        let f = films ?? Self.films, s = shows ?? Self.shows
        let http = try LoopbackJSONServer { path, query in Self.reply(path: path, query: query, server: server, films: f, shows: s) }
        try await http.start()
        defer { http.stop() }
        let items = try await api(http.url).loadLibrary(excludedSectionKeys: [], progress: nil)
        return (items, http.requests)
    }

    /// The app's own stock pool build over `items`, on `backend`.
    private func pools(_ items: [PlexMediaItem], backend: MediaBackendKind = .emby) async -> [Int: Channel] {
        let state = AppState()
        state.backendKind = backend
        state.allItems = items
        let config = ChannelConfigLoader.loadBundled()
        state.exclusiveRules = config.exclusiveRules
        let built = await state.rebuildStaticChannelPools(
            configChannels: config.channels, items: items, onlyChannelIDs: Set(config.channels.map(\.id)))
        return Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
    }

    private func at(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    // MARK: - The request

    /// The scan names both fields, on every Items request that reads titles, in both backends.
    func testTheScanAsksForBothRatingFields() async throws {
        for (name, make) in [("Emby", { (url: String) -> any MediaBackend in EmbyAPIService(serverURL: url, accessToken: "t", userId: "u") }),
                             ("Jellyfin", { (url: String) -> any MediaBackend in JellyfinAPIService(serverURL: url, accessToken: "t", userId: "u") })] {
            let (_, requests) = try await scan(.emby410, api: make)
            let scans = requests.filter { $0.path.hasSuffix("/Items") }
            XCTAssertFalse(scans.isEmpty, name)
            for r in scans {
                let fields = Set((r.query["Fields"] ?? "").split(separator: ",").map(String.init))
                XCTAssertTrue(fields.contains("OfficialRating"), "\(name) \(r.query["ParentId"] ?? "") asks for OfficialRating: \(fields.sorted())")
                XCTAssertTrue(fields.contains("CommunityRating"), "\(name) \(r.query["ParentId"] ?? "") asks for CommunityRating: \(fields.sorted())")
            }
        }
    }

    // MARK: - The titles

    /// A film and a show's episodes carry the certificate as contentRating and the community
    /// score as rating; a title the server has neither for stays unrated, with rating 0.
    func testEmbyTitlesCarryTheirCertificateAndStarRating() async throws {
        let (items, _) = try await scan(.emby410)
        let byTitle = Dictionary(grouping: items, by: \.title)
        XCTAssertEqual(byTitle["Vault R 4"]?.first?.contentRating, "R")
        XCTAssertEqual(byTitle["Vault R 4"]?.first?.rating, 8.1)
        XCTAssertEqual(byTitle["Vault PG 4"]?.first?.rating, 8.3)
        XCTAssertEqual(byTitle["South Park"]?.count, 8)
        XCTAssertTrue(byTitle["South Park"]?.allSatisfy { $0.contentRating == "TV-MA" && $0.rating == 8.7 } ?? false,
                      "episodes take the show's certificate and score")
        XCTAssertTrue(byTitle["Mystery Cartoon"]?.allSatisfy { $0.contentRating == nil && $0.rating == 0 } ?? false)
    }

    /// Jellyfin sends them anyway, so its result is the same as Emby's with the fields asked for.
    func testJellyfinAndEmbyReadTheSameTitles() async throws {
        let emby = try await scan(.emby410).items
        let jelly = try await scan(.jellyfin, api: { JellyfinAPIService(serverURL: $0, accessToken: "t", userId: "u") }).items
        func key(_ i: PlexMediaItem) -> String { "\(i.title)|\(i.contentRating ?? "-")|\(i.rating)" }
        XCTAssertEqual(emby.map(key).sorted(), jelly.map(key).sorted())
    }

    // MARK: - What the viewer sees

    /// SAT MORNING CARTOONS (TV-Y, TV-Y7, TV-G, G, and unrated): no TV-MA and no TV-14 show, the
    /// TV-Y7 one and the one with no certificate still on. Fails when the scan does not ask.
    func testAKidsChannelAirsNoAdultShowOnEmby() async throws {
        let (items, _) = try await scan(.emby410)
        let built = await pools(items)
        let saturday = try XCTUnwrap(built[4], "SAT MORNING CARTOONS")
        XCTAssertEqual(saturday.name, "SAT MORNING CARTOONS")
        let titles = Set(saturday.itemPool.map(\.title))
        XCTAssertTrue(titles.contains("Kid Cartoon Hour"), "control: the TV-Y7 cartoon is on it \(titles)")
        XCTAssertTrue(titles.contains("Mystery Cartoon"), "control: a show with no certificate is allowed on it \(titles)")
        XCTAssertFalse(titles.contains("South Park"), "TV-MA on a kids channel")
        XCTAssertFalse(titles.contains("Teen Toon"), "TV-14 on a kids channel")
    }

    /// VHS VAULT before 9 PM holds the R titles back and shows them from 9 PM.
    func testVHSVaultHoldsItsRTitlesBeforeNineOnEmby() async throws {
        let (items, _) = try await scan(.emby410)
        let built = await pools(items)
        let vault = try XCTUnwrap(built[7], "VHS VAULT")
        XCTAssertEqual(vault.name, "VHS VAULT")
        XCTAssertEqual(vault.itemPool.count, Self.films.count, "control: all sixteen films are in its pool")

        let afternoon = Set(vault.filteredPool(now: at(hour: 15), watershedEnabled: false).map(\.title))
        XCTAssertFalse(afternoon.contains { $0.hasPrefix("Vault R") }, "an R title at 3 PM: \(afternoon.sorted())")
        XCTAssertEqual(afternoon.count, 9, "the seven PG and two PG-13 titles stay")

        let night = Set(vault.filteredPool(now: at(hour: 22), watershedEnabled: false).map(\.title))
        XCTAssertEqual(night.count, 16, "at 10 PM it airs all sixteen")
    }

    /// WATERSHED (the setting) holds a channel's R and TV-MA titles until 9 PM too.
    func testWatershedHoldsAdultTitlesOnEmby() async throws {
        let (items, _) = try await scan(.emby410)
        let built = await pools(items)
        let channel = try XCTUnwrap(built.values.first { ch in
            ch.timeRestrictions?.blockRatings == nil && ch.itemPool.contains { $0.contentRating == "R" } && ch.itemPool.contains { $0.contentRating == "PG" }
        }, "a channel holding both R and PG films")
        let day = Set(channel.filteredPool(now: at(hour: 15), watershedEnabled: true).map { $0.contentRating ?? "" })
        XCTAssertFalse(day.contains("R"), "CH \(channel.number) \(channel.name) shows R at 3 PM with WATERSHED on")
        XCTAssertTrue(day.contains("PG"), "and keeps its PG titles")
    }

    /// A `ratingMin` channel reads the server's own star rating, with no OMDb behind it.
    /// CERTIFIED GOLD asks for 8 and up: six films. ALL TIME GREATS asks for 8.2: five.
    func testARatingMinChannelReadsEmbyStarRating() async throws {
        let (items, _) = try await scan(.emby410)
        let built = await pools(items)
        let gold = try XCTUnwrap(built[68], "CERTIFIED GOLD")
        XCTAssertEqual(gold.name, "CERTIFIED GOLD")
        XCTAssertEqual(Set(gold.itemPool.map(\.title)),
                       ["Vault R 4", "Vault R 5", "Vault R 7", "Vault PG 4", "Vault PG 7", "Vault PG-13 1"], "8 and up")
        let greats = try XCTUnwrap(built[67], "ALL TIME GREATS")
        XCTAssertEqual(Set(greats.itemPool.map(\.title)),
                       ["Vault R 5", "Vault R 7", "Vault PG 4", "Vault PG 7", "Vault PG-13 1"], "8.2 and up")
    }

    // MARK: - What changes for a library already on Emby

    /// A `ratingMin` channel's gate is "the server's rating clears the bar OR the OMDb rating
    /// does", so a rating that was missing before can only add titles. Measured on the same
    /// fake library read as Emby gave it before (no fields) and now.
    func testRatingMinChannelsOnlyGrow() async throws {
        let library = Self.generatedLibrary()
        let after = try await scan(.emby410, films: library.films, shows: library.shows).items
        // What the old request got: the same library, the two fields left out.
        let before = try await scan(.withheld, films: library.films, shows: library.shows).items
        XCTAssertEqual(before.count, after.count)
        XCTAssertTrue(before.allSatisfy { $0.contentRating == nil && $0.rating == 0 }, "control: nothing rated before")
        let poolsBefore = await pools(before)
        let poolsAfter = await pools(after)

        var report: [String] = ["library: \(library.films.count) films, \(library.shows.count) shows, \(after.count) titles (synthetic)"]
        let config = ChannelConfigLoader.loadBundled().channels
        for ch in config where ch.rules?.ratingMin != nil {
            let b = Set(poolsBefore[ch.id]?.itemPool.map(\.id) ?? []), a = Set(poolsAfter[ch.id]?.itemPool.map(\.id) ?? [])
            XCTAssertTrue(b.isSubset(of: a), "\(ch.name) lost titles")
            report.append("ratingMin \(ch.id) \(ch.name) (\(ch.rules?.ratingMin ?? 0)), min \(ch.minItems): \(b.count) -> \(a.count)")
        }
        var moved = 0, appeared: [String] = [], vanished: [String] = []
        for ch in config {
            let b = poolsBefore[ch.id]?.itemPool.count ?? 0, a = poolsAfter[ch.id]?.itemPool.count ?? 0
            if a != b {
                moved += 1
                report.append("\(ch.id) \(ch.name): \(b) -> \(a)\(b >= ch.minItems && a < ch.minItems ? " (falls under its minimum)" : "")\(b < ch.minItems && a >= ch.minItems ? " (reaches its minimum)" : "")")
            }
            if b < ch.minItems && a >= ch.minItems { appeared.append(ch.name) }
            if b >= ch.minItems && a < ch.minItems { vanished.append(ch.name) }
        }
        report.append("channels whose pool changed: \(moved) of \(config.count); reach their minimum: \(appeared.count) \(appeared); fall under it: \(vanished.count) \(vanished)")
        if let path = ProcessInfo.processInfo.environment["NOSTALGEX_RATING_OUT"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_NOSTALGEX_RATING_OUT"] {
            try report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// A deterministic library with real-looking spread: star ratings centred on 6.4, a tenth with
    /// none, certificates in film and TV proportions, years 1960 to 2024.
    private static func generatedLibrary() -> (films: [Film], shows: [Show]) {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        func gaussian() -> Double { (next() + next() + next() + next() - 2) * 1.7 }
        func pick<T>(_ weighted: [(T, Double)]) -> T {
            var x = next() * weighted.reduce(0) { $0 + $1.1 }
            for (v, w) in weighted { x -= w; if x <= 0 { return v } }
            return weighted[weighted.count - 1].0
        }
        func score() -> Double? { next() < 0.10 ? nil : max(2.5, min(9.3, ((6.4 + gaussian()) * 10).rounded() / 10)) }
        let filmGenres: [[String]] = [["Action"], ["Comedy"], ["Drama"], ["Thriller"], ["Action", "Adventure"], ["Science Fiction"], ["Family", "Comedy"], ["Animation", "Family"], ["Horror"], ["Romance", "Comedy"]]
        let films = (0..<400).map { i in
            Film(id: "f\(i)", name: "Film \(i)", year: 1960 + Int(next() * 65),
                 certificate: pick([("G", 8), ("PG", 22), ("PG-13", 25), ("R", 40), (nil, 5)] as [(String?, Double)]),
                 community: score(), genres: filmGenres[Int(next() * Double(filmGenres.count))])
        }
        let showGenres: [[String]] = [["Comedy"], ["Drama"], ["Animation", "Comedy"], ["Animation", "Kids"], ["Crime", "Drama"], ["Science Fiction"], ["Reality"], ["Animation"]]
        let shows = (0..<25).map { i in
            Show(id: "s\(i)", name: "Show \(i)", year: 1960 + Int(next() * 62),
                 certificate: pick([("TV-Y", 10), ("TV-Y7", 10), ("TV-G", 8), ("TV-PG", 20), ("TV-14", 27), ("TV-MA", 20), (nil, 5)] as [(String?, Double)]),
                 community: score(), genres: showGenres[Int(next() * Double(showGenres.count))], episodes: 14)
        }
        return (films, shows)
    }

    // MARK: - The saved library

    /// A library saved before the scan asked for ratings has none on any Emby title, and the
    /// 24-hour hold on "the server says nothing changed" would keep it that way. It is stale
    /// and its signature is dropped, so the background refresh scans. Jellyfin and Plex are
    /// untouched, and a snapshot the new scan wrote is not stale.
    func testASavedEmbyLibraryFromBeforeTheFieldsRefreshesOnce() async throws {
        XCTAssertTrue(LibrarySnapshotStore.scanNeedsRatingFields(backend: .emby, savedVersion: nil))
        XCTAssertFalse(LibrarySnapshotStore.scanNeedsRatingFields(backend: .emby, savedVersion: LibrarySnapshotStore.scanFieldsVersion))
        XCTAssertFalse(LibrarySnapshotStore.scanNeedsRatingFields(backend: .jellyfin, savedVersion: nil))
        XCTAssertFalse(LibrarySnapshotStore.scanNeedsRatingFields(backend: .plex, savedVersion: nil))
    }

    private final class Memory: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    func testARestoredOldEmbySnapshotIsStaleAndSignatureless() async throws {
        let scope = HarnessScope.begin("emby-rating-fields")
        defer { scope.end() }
        let http = try LoopbackJSONServer { path, query in
            Self.reply(path: path, query: query, server: .emby410, films: Self.films, shows: Self.shows)
        }
        try await http.start()
        defer { http.stop() }
        let auth = EmbyAPIService.AuthResult(accessToken: "tok", userId: "u1", serverID: "emby-lab", serverName: "Emby Lab")

        func connect() -> AppState {
            let s = AppState(credentialStore: Memory())
            s.backendOverride = { _ in EmbyAPIService(serverURL: http.url, accessToken: "tok", userId: "u1") }
            return s
        }
        let first = connect()
        await first.completeEmbyAuth(serverURL: http.url, result: auth)
        if first.needsLibrarySelection { await first.loadLibrary() }   // two sections: the app asks which to scan
        XCTAssertFalse(first.allItems.isEmpty, "the fake Emby library loaded")
        first.librarySignature = "sig-1"
        first.saveLibrarySnapshotIfNeeded()
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value

        // Control: a snapshot the new scan wrote restores fresh, signature and all.
        let second = connect()
        second.backendKind = .emby; second.serverURL = http.url; second.jellyfinUserId = "u1"
        second.token = "tok"; second.serverName = "Emby Lab"
        second.setSelectedServers(first.selectedServers)
        let restored = await second.restoreLibraryFromSnapshotIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertFalse(second.isLibraryStale, "a snapshot from the new scan is fresh")
        XCTAssertEqual(second.librarySignature, "sig-1")

        // The same file as the build before this one wrote it: no scan-fields marker.
        try Self.stripScanFieldsMarker()
        let third = connect()
        third.backendKind = .emby; third.serverURL = http.url; third.jellyfinUserId = "u1"
        third.token = "tok"; third.serverName = "Emby Lab"
        third.setSelectedServers(first.selectedServers)
        let restoredOld = await third.restoreLibraryFromSnapshotIfNeeded()
        XCTAssertTrue(restoredOld, "it still restores, so the guide is up straight away")
        XCTAssertTrue(third.isLibraryStale, "and a refresh is due")
        XCTAssertNil(third.librarySignature, "with no signature to skip it on")
        // Disconnect clears the saved library, so these come last.
        third.disconnect()
        second.disconnect()
        first.disconnect()
    }

    /// Rewrites the saved snapshot's meta.json without `scanFieldsVersion`, as an older build left it.
    private static func stripScanFieldsMarker() throws {
        let root = try XCTUnwrap(LibrarySnapshotStore.snapshotDirectoryURL)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("current.json"))) as? [String: Any]
        let generation = try XCTUnwrap(manifest?["generation"] as? String)
        let metaURL = root.appendingPathComponent(generation).appendingPathComponent("meta.json")
        var meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        XCTAssertNotNil(meta["scanFieldsVersion"], "the new build writes the marker")
        meta.removeValue(forKey: "scanFieldsVersion")
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
    }
}
