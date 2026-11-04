import XCTest
import os
import UIKit
import SwiftUI
@testable import Nostalgex

/// N-033: a new Plex user with about 15,000 movies. On Apple TV 1.0.29 the loading screen
/// stopped at "Channel 60 of 142" and the app closed about an hour later.
///
/// `MovieLibraryScaleHarness` handed the app a ready library and a pre-filled enrichment
/// cache, so it skipped exactly what a new user's first load does on the network. This one
/// runs the REAL first load cold, every request answered by a local stand-in with realistic
/// latency:
/// - Plex: the real `PlexAPIService` pages `/library/sections/1/all?includeGuids=1` (500 a
///   page) and reads every collection's children, from a fake Plex holding the library;
/// - enrichment: the real `EnrichmentService` asks a fake Supabase (only `cachedFraction` of
///   the titles have a row), then a fake TMDB proxy for the rest, which rate-limits
///   (429 above `tmdbPerSecond`) the way the real one can, then OMDb through the same proxy;
/// - nothing reaches plex.tv for the library, TMDB, OMDb or the shared Supabase cache.
///
/// Every stage, every channel's pool build, the main actor's delay in taking each
/// "Channel N of M" tick, memory, thread count and requests per endpoint are recorded, then
/// the guide is left up for `soakSeconds` while the same is sampled every 30 s.
///
/// Storage is isolated (`HarnessIsolation`): the run uses its own files, defaults suite and
/// in-memory credentials, and `RealStoreFingerprint` proves the app's real stores are
/// byte-identical before and after. Off by default:
///
///     TEST_RUNNER_NOSTALGEX_HARNESS_ROOT=coldplex TEST_RUNNER_NOSTALGEX_COLDPLEX_N=15000 \
///       TEST_RUNNER_NOSTALGEX_COLDPLEX_UI=1 TEST_RUNNER_NOSTALGEX_COLDPLEX_SOAK=3600 \
///       xcodebuild test ... -only-testing:NostalgexTests/ColdPlexScaleHarness
///
/// The report is attached to the test result and written to
/// `Library/Caches/NostalgexHarness/<root>/coldplex-report.txt`, with a live trail beside it.
@MainActor
final class ColdPlexScaleHarness: XCTestCase {

    struct Config {
        var n = 15_000
        /// Share of titles the shared Supabase cache already has a row for.
        var cachedFraction = 0.0
        /// Cap on Plex collections (franchise groups from the fixture); nil = all of them.
        var collections: Int? = nil
        var plexBaseDelayMs = 300
        var plexPerItemMicros = 2_000
        var collectionDelayMs = 60
        var supabaseDelayMs = 350
        var tmdbDelayMs = 150
        var tmdbPerSecond = 40
        var omdbDelayMs = 250
        var ui = false
        var soakSeconds = 0
        var allBundles = false

        static func fromEnvironment(n: Int) -> Config {
            let env = ProcessInfo.processInfo.environment
            func int(_ k: String) -> Int? { env["NOSTALGEX_COLDPLEX_\(k)"].flatMap(Int.init) }
            var c = Config()
            c.n = n
            if let v = env["NOSTALGEX_COLDPLEX_CACHED"].flatMap(Double.init) { c.cachedFraction = v }
            if let v = int("COLLECTIONS") { c.collections = v }
            if let v = int("PLEX_PAGE_MS") { c.plexBaseDelayMs = v }
            if let v = int("PLEX_ITEM_US") { c.plexPerItemMicros = v }
            if let v = int("COLLECTION_MS") { c.collectionDelayMs = v }
            if let v = int("SUPABASE_MS") { c.supabaseDelayMs = v }
            if let v = int("TMDB_MS") { c.tmdbDelayMs = v }
            if let v = int("TMDB_PER_SECOND") { c.tmdbPerSecond = v }
            if let v = int("OMDB_MS") { c.omdbDelayMs = v }
            c.ui = env["NOSTALGEX_COLDPLEX_UI"] == "1"
            if let v = int("SOAK") { c.soakSeconds = v }
            c.allBundles = env["NOSTALGEX_COLDPLEX_ALLBUNDLES"] == "1"
            return c
        }
    }

    struct Outcome {
        let report: [String]
        let itemCount: Int
        let guideChannels: Int
        let realStoresBefore: RealStoreFingerprint
        let realStoresAfter: RealStoreFingerprint
    }

    // MARK: - The opt-in device / simulator run

    func testColdPlexFirstLoad() async throws {
        guard let raw = ProcessInfo.processInfo.environment["NOSTALGEX_COLDPLEX_N"], let n = Int(raw), n > 0 else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_COLDPLEX_N to run the cold Plex harness")
        }
        let outcome = try await Self.run(Self.Config.fromEnvironment(n: n), testCase: self)
        let attachment = XCTAttachment(string: outcome.report.joined(separator: "\n"))
        attachment.name = "coldplex-report.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        let diff = outcome.realStoresBefore.differences(from: outcome.realStoresAfter)
        XCTAssertEqual(diff.app, [], "the harness changed the app's real stores")
        XCTAssertEqual(outcome.itemCount, n)
    }

    /// The whole cold first load, small: fake Plex, fake Supabase and TMDB proxy, pools,
    /// schedules, snapshot, disconnect. The real stores before and after are identical.
    func testASmallColdRunLeavesTheRealStoresByteIdentical() async throws {
        XCTAssertFalse(HarnessIsolation.isActive)
        var config = Config()
        config.n = 300
        config.collections = 12
        config.cachedFraction = 0.5
        config.plexBaseDelayMs = 5
        config.plexPerItemMicros = 0
        config.collectionDelayMs = 2
        config.supabaseDelayMs = 5
        config.tmdbDelayMs = 5
        config.tmdbPerSecond = 1_000
        config.omdbDelayMs = 5
        let outcome = try await Self.run(config, testCase: self)
        print(outcome.report.joined(separator: "\n"))

        XCTAssertEqual(outcome.itemCount, 300, "the run loaded the library through the fakes")
        XCTAssertGreaterThan(outcome.guideChannels, 0, "and built a guide")
        let diff = outcome.realStoresBefore.differences(from: outcome.realStoresAfter)
        XCTAssertEqual(diff.app, [])
        XCTAssertEqual(outcome.realStoresBefore, outcome.realStoresAfter)
        XCTAssertFalse(HarnessIsolation.isActive, "the run switched off what it switched on")
        XCTAssertTrue(outcome.report.contains { $0.hasPrefix("enrichmentConfigured=true proxy=true") },
                      "enrichment ran against the stand-ins")
    }

    // MARK: - The run

    /// Runs one cold first load. Activates `HarnessIsolation` unless the process already has
    /// it (a device run sets it from the environment at launch), and only deactivates what it
    /// activated.
    static func run(_ config: Config, testCase: XCTestCase) async throws -> Outcome {
        let realBefore = RealStoreFingerprint.capture()
        let activatedHere = !HarnessIsolation.isActive
        if activatedHere { HarnessIsolation.activate(name: "coldplex-\(config.n)") }
        let root = HarnessIsolation.root!
        defer {
            TMDBConfig.harnessEndpoints = nil
            LibraryLoadProbe.handler = nil
            if activatedHere { HarnessIsolation.deactivate(wipe: true) }
        }

        let report = Report(file: root.appendingPathComponent("coldplex-report.txt"),
                            trail: root.appendingPathComponent("coldplex-trail.txt"))
        report.emit("N=\(config.n) cachedFraction=\(config.cachedFraction) collections=\(config.collections.map(String.init) ?? "all") "
                    + "plexPage=\(config.plexBaseDelayMs)ms+\(config.plexPerItemMicros)us/item tmdb=\(config.tmdbDelayMs)ms@\(config.tmdbPerSecond)/s "
                    + "supabase=\(config.supabaseDelayMs)ms omdb=\(config.omdbDelayMs)ms ui=\(config.ui) soak=\(config.soakSeconds)s")
        report.emit("isolation root=\(root.lastPathComponent) activatedHere=\(activatedHere) realStores: \(realBefore.summary)")

        // Fixture: the same movie library MovieLibraryScaleHarness builds, served as Plex.
        let serverID = "c01d91e5a3b9d2f4e6a8b0c1d2e3f4a5b6c7d8e9"
        let fixture = MovieLibraryScaleHarness.makeMovieLibrary(count: config.n, serverID: serverID)
        report.emit(fixture.mix)
        let plexItems = fixture.items.map(Self.plexJSON)
        let enrichByTMDB = Dictionary(fixture.enrichments.map { ($0.tmdbID, $0) }, uniquingKeysWith: { a, _ in a })
        var collectionsByFranchise: [Int: [String]] = [:]
        for (item, e) in zip(fixture.items, fixture.enrichments) {
            if let f = e.franchiseID { collectionsByFranchise[f, default: []].append(item.ratingKey) }
        }
        var collections = collectionsByFranchise.filter { $0.value.count >= 2 }
            .sorted { $0.key < $1.key }.map { (key: "\(500_000 + $0.key)", title: "Collection \($0.key)", members: $0.value) }
        if let cap = config.collections { collections = Array(collections.prefix(cap)) }
        let collectionMembers = Dictionary(uniqueKeysWithValues: collections.map { ($0.key, $0.members) })
        report.emit("plexCollections=\(collections.count) members=\(collections.reduce(0) { $0 + $1.members.count })")

        // Fake Plex.
        let plex = try HarnessFakeServer { req in
            switch req.path {
            case "/identity":
                return .json(["MediaContainer": ["machineIdentifier": serverID, "friendlyName": "Vault"]], label: "plex.identity")
            case "/library/sections":
                return .json(["MediaContainer": ["Directory": [["key": "1", "title": "Movies", "type": "movie",
                                                                 "scannedAt": 1_790_000_000, "updatedAt": 1_790_000_000,
                                                                 "contentChangedAt": 1_790_000_000]]]],
                             label: "plex.sections", delayMs: 40)
            case "/library/sections/1/all":
                let start = Int(req.query["X-Plex-Container-Start"] ?? "0") ?? 0
                let size = Int(req.query["X-Plex-Container-Size"] ?? "500") ?? 500
                let page = Array(plexItems.dropFirst(start).prefix(size))
                return .json(["MediaContainer": ["totalSize": plexItems.count, "size": page.count, "Metadata": page]],
                             label: "plex.page", delayMs: config.plexBaseDelayMs + page.count * config.plexPerItemMicros / 1000)
            case "/library/sections/1/collections":
                return .json(["MediaContainer": ["Metadata": collections.map {
                    ["ratingKey": $0.key, "title": $0.title, "childCount": $0.members.count, "thumb": "/library/collections/\($0.key)/thumb"]
                }]], label: "plex.collections", delayMs: 200)
            default:
                if req.path.hasPrefix("/library/collections/"), req.path.hasSuffix("/children") {
                    let key = String(req.path.dropFirst("/library/collections/".count).dropLast("/children".count))
                    let members = (collectionMembers[key] ?? []).map { ["ratingKey": $0, "title": "m\($0)"] }
                    return .json(["MediaContainer": ["Metadata": members]], label: "plex.collectionChildren",
                                 delayMs: config.collectionDelayMs)
                }
                if req.path.contains("/transcode/") || req.path.hasPrefix("/library/parts/") {
                    return .notFound("plex.playback")
                }
                if req.path.contains("/thumb") || req.path.contains("/art") || req.path.hasPrefix("/photo") {
                    return .notFound("plex.artwork")
                }
                if req.path.hasPrefix("/:/timeline") || req.path.hasPrefix("/:/scrobble") {
                    return .json([:], label: "plex.timeline")
                }
                return .notFound("plex.other:\(req.path.split(separator: "/").prefix(2).joined(separator: "/"))")
            }
        }

        // Fake TMDB/OMDb proxy and Supabase.
        let bucket = TokenBucket(perSecond: config.tmdbPerSecond)
        let isCached: @Sendable (String) -> Bool = { id in
            Double(UInt32(truncatingIfNeeded: id.hashValueStable) % 10_000) / 10_000 < config.cachedFraction
        }
        let services = try HarnessFakeServer { req in
            if req.path.hasPrefix("/rest/v1/media_enrichments") {
                if req.method == "POST" {
                    return HarnessFakeServer.Reply(status: 201, delayMs: config.supabaseDelayMs, body: Data("[]".utf8), label: "supabase.upsert")
                }
                let raw = req.query["tmdb_id"] ?? ""
                let ids = raw.hasPrefix("in.(") ? raw.dropFirst(4).dropLast().split(separator: ",").map(String.init) : []
                let rows = ids.filter(isCached).compactMap { enrichByTMDB[$0] }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let body = (try? encoder.encode(rows)) ?? Data("[]".utf8)
                return HarnessFakeServer.Reply(status: 200, delayMs: config.supabaseDelayMs, body: body, label: "supabase.get")
            }
            if req.path == "/api/tmdb" {
                let path = req.query["path"] ?? ""
                if path.hasPrefix("omdb/") {
                    return .json(["Response": "True", "imdbRating": "7.4", "imdbVotes": "120,331", "Metascore": "64",
                                  "Awards": "N/A", "Ratings": [["Source": "Rotten Tomatoes", "Value": "81%"]]],
                                 label: "omdb", delayMs: config.omdbDelayMs)
                }
                guard bucket.take() else {
                    return .json(["status_message": "rate limited"], label: "tmdb.429", delayMs: 20, status: 429)
                }
                let id = String(path.split(separator: "/").last ?? "")
                guard let e = enrichByTMDB[id] else { return .json(["status_code": 34], label: "tmdb.404", delayMs: config.tmdbDelayMs, status: 404) }
                var doc: [String: Any] = [
                    "id": Int(id) ?? 0, "imdb_id": e.imdbID ?? "",
                    "genres": e.tmdbGenres.map { ["name": $0] },
                    "production_companies": e.productionCompanies.map { ["name": $0] },
                    "keywords": ["keywords": e.keywords.map { ["name": $0] }],
                ]
                if let f = e.franchiseID { doc["belongs_to_collection"] = ["id": f, "name": e.franchiseName ?? ""] }
                let jitter = Int(UInt32(truncatingIfNeeded: id.hashValueStable) % 100)
                return .json(doc, label: "tmdb", delayMs: config.tmdbDelayMs + jitter)
            }
            return .notFound("services.other")
        }
        try await plex.start()
        try await services.start()
        defer { plex.stop(); services.stop() }
        TMDBConfig.harnessEndpoints = .init(proxyURL: "\(services.url)/api/tmdb", supabaseURL: services.url)
        report.emit("enrichmentConfigured=\(!TMDBConfig.supabaseURL.isEmpty) proxy=\(TMDBConfig.tmdbProxyURL.hasPrefix("http://127.0.0.1"))")

        // Probe: stages, each channel's pool time (background) and when the main actor took
        // its tick.
        let timeline = Timeline()
        LibraryLoadProbe.handler = { stage in timeline.mark(stage) }

        if config.allBundles {
            AppDefaults.standard.set(ChannelConfigLoader.loadBundled().bundles.map(\.id), forKey: "nostalgex_enabled_bundles")
        }
        let state = AppState(credentialStore: HarnessCredentials())
        let server = AppState.ServerRef(machineIdentifier: serverID, name: "Vault", baseURL: plex.url, owned: true, token: "srv")
        state.completePlexSignIn(token: "harness-account-token", servers: [server])

        let sampler = Sampler(report: report, timeline: timeline, servers: ["plex": plex, "svc": services])
        sampler.start()
        let watch = Task { @MainActor in
            // What the loading screen says, every second, into the trail.
            var last = ""
            while !Task.isCancelled {
                let line = "\(state.libraryLoadPhase) \(state.channelBuildIndex)/\(state.channelBuildTotal) "
                    + "items=\(state.scanItemsFound) enrich=\(state.enrichmentService.statusMessage) loading=\(state.isLoading)"
                sampler.setPhase(line)
                if line != last { report.trail("screen " + line); last = line }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { watch.cancel() }

        var window: UIWindow?
        var previousRoot: UIViewController?
        let t0 = CFAbsoluteTimeGetCurrent()
        if config.ui {
            window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
            previousRoot = window?.rootViewController
            window?.rootViewController = UIHostingController(rootView: RootView().environment(state))
            var sawLoading = false
            while CFAbsoluteTimeGetCurrent() - t0 < 3 * 3600 {
                if state.isLoading { sawLoading = true }
                if sawLoading, !state.isLoading { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        } else {
            await state.loadLibrary()
        }
        let firstLoad = CFAbsoluteTimeGetCurrent() - t0
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        report.emit(String(format: "firstLoad=%.1fs items=%d guide=%d allChannels=%d error=%@ stale=%@",
                           firstLoad, state.allItems.count, state.channels.count, state.allChannels.count,
                           state.errorMessage ?? "nil", state.isLibraryStale ? "true" : "false"))
        for line in timeline.stageReport() { report.emit(line) }
        for line in timeline.channelReport() { report.emit(line) }
        report.emit("requests after load: plex=\(plex.requestCounts.sorted { $0.key < $1.key }) "
                    + "services=\(services.requestCounts.sorted { $0.key < $1.key }) peakConcurrent plex=\(plex.peakConcurrentRequests) services=\(services.peakConcurrentRequests)")
        report.emit(sampler.summary(since: 0))

        // Soak: the guide up, sampled every 30 s.
        if config.soakSeconds > 0 {
            let soakStart = CFAbsoluteTimeGetCurrent()
            sampler.markSoakStart()
            while CFAbsoluteTimeGetCurrent() - soakStart < Double(config.soakSeconds) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                report.emit(sampler.soakLine(elapsed: CFAbsoluteTimeGetCurrent() - soakStart))
            }
            report.emit(sampler.summary(since: soakStart - t0))
        }
        sampler.stop()

        // Put the app back, let the harness's AppState go, then read the real stores again.
        if let window { window.rootViewController = previousRoot }
        let items = state.allItems.count
        let guide = state.channels.count
        // Sign the harness's AppState out while the isolation is still on: its player, its
        // tasks and its stores stop here, and what it clears is the harness's own.
        state.disconnect()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let realAfter = RealStoreFingerprint.capture()
        let diff = realBefore.differences(from: realAfter)
        report.emit("realStores after: \(realAfter.summary)")
        report.emit("realStores app-owned differences: \(diff.app.isEmpty ? "none" : diff.app.joined(separator: " | "))")
        report.emit("realStores other differences (report only): \(diff.other.isEmpty ? "none" : diff.other.prefix(20).joined(separator: " | "))")
        return Outcome(report: report.lines, itemCount: items, guideChannels: guide,
                       realStoresBefore: realBefore, realStoresAfter: realAfter)
    }

    // MARK: - Plex JSON for a fixture item

    nonisolated static func plexJSON(_ i: PlexMediaItem) -> [String: Any] {
        var d: [String: Any] = [
            "ratingKey": i.ratingKey, "key": "/library/metadata/\(i.ratingKey)", "type": "movie",
            "title": i.title, "summary": i.summary, "duration": i.duration * 60_000,
            "rating": i.rating, "addedAt": i.addedAt, "viewCount": i.viewCount,
            "Genre": i.genres.map { ["tag": $0] },
        ]
        if let y = i.year { d["year"] = y }
        if let a = i.originallyAvailableAt { d["originallyAvailableAt"] = a }
        if let r = i.contentRating { d["contentRating"] = r }
        if let s = i.studio { d["studio"] = s }
        if let t = i.thumb { d["thumb"] = t }
        if let a = i.art { d["art"] = a }
        var guids: [[String: String]] = []
        if let t = i.tmdbID { guids.append(["id": "tmdb://\(t)"]) }
        if let m = i.imdbID { guids.append(["id": "imdb://\(m)"]) }
        d["Guid"] = guids
        d["Media"] = [[
            "container": i.container ?? "mkv", "videoCodec": i.videoCodec ?? "h264", "audioCodec": i.audioCodec ?? "ac3",
            "videoProfile": i.videoProfile ?? "high", "videoResolution": "1080", "bitrate": i.bitrate ?? 8_000,
            "width": 1920, "height": 1080,
            "Part": [["key": i.partKey ?? "/library/parts/0/file.mkv", "container": i.container ?? "mkv",
                      "duration": i.duration * 60_000]],
        ]]
        return d
    }

    // MARK: - Pieces

    private final class HarnessCredentials: Nostalgex.CredentialStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { lock.lock(); values[key] = value; lock.unlock(); return true }
        func load(key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func delete(key: String) { lock.lock(); values[key] = nil; lock.unlock() }
    }

    /// TMDB-style rate limit: `perSecond` requests in any one-second window.
    final class TokenBucket: @unchecked Sendable {
        private let lock = NSLock()
        private let perSecond: Int
        private var window: [Double] = []
        init(perSecond: Int) { self.perSecond = perSecond }
        func take() -> Bool {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock(); defer { lock.unlock() }
            window.removeAll { now - $0 > 1 }
            guard window.count < perSecond else { return false }
            window.append(now)
            return true
        }
    }

    /// The report (kept in memory, rewritten to its file on every line) and a trail file
    /// appended and flushed as things happen, so a run the system kills still leaves its
    /// last readings.
    final class Report: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lines: [String] = []
        private let file: URL
        private let trailHandle: FileHandle?
        private let t0 = CFAbsoluteTimeGetCurrent()

        init(file: URL, trail: URL) {
            self.file = file
            FileManager.default.createFile(atPath: trail.path, contents: nil)
            trailHandle = FileHandle(forWritingAtPath: trail.path)
        }

        func emit(_ s: String) {
            lock.lock()
            lines.append(s)
            let text = lines.map { "[COLDPLEX] \($0)" }.joined(separator: "\n") + "\n"
            lock.unlock()
            try? text.write(to: file, atomically: true, encoding: .utf8)
            trail("report " + s)
        }

        func trail(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            trailHandle?.write(Data((String(format: "%8.1f ", CFAbsoluteTimeGetCurrent() - t0) + s + "\n").utf8))
            try? trailHandle?.synchronize()
        }
    }

    /// Stage marks and the per-channel pool build.
    final class Timeline: @unchecked Sendable {
        private let lock = NSLock()
        private let t0 = CFAbsoluteTimeGetCurrent()
        private var stages: [(String, Double, UInt64)] = []
        private var pools: [(name: String, at: Double)] = []
        private var ticks: [Double] = []
        private var filterCacheAt: Double?

        func now() -> Double { CFAbsoluteTimeGetCurrent() - t0 }

        func mark(_ stage: String) {
            let t = now()
            lock.lock(); defer { lock.unlock() }
            if stage.hasPrefix("pool:") { pools.append((String(stage.dropFirst(5)), t)); return }
            if stage.hasPrefix("tick:") { ticks.append(t); return }
            if stage == "filterCache" { filterCacheAt = t }
            stages.append((stage, t, BigLibraryHarness.footprintBytes()))
        }

        var poolsDone: Int { lock.lock(); defer { lock.unlock() }; return pools.count }
        var ticksDone: Int { lock.lock(); defer { lock.unlock() }; return ticks.count }

        func stageReport() -> [String] {
            lock.lock(); defer { lock.unlock() }
            var out = ["stage                         endsAt(s)  took(ms)  footMB"]
            var prev = 0.0
            for (name, t, foot) in stages {
                let n = name.count >= 28 ? name : name + String(repeating: " ", count: 28 - name.count)
                out.append(n + String(format: "%10.1f%10.0f%8d", t, (t - prev) * 1000, foot / 1_048_576))
                prev = t
            }
            return out
        }

        /// Time per channel pool (background), and how long each tick waited for the main
        /// actor (the "Channel N of M" the screen shows).
        func channelReport() -> [String] {
            lock.lock(); defer { lock.unlock() }
            guard !pools.isEmpty else { return ["pools: none recorded"] }
            var last = filterCacheAt ?? pools[0].at
            var rows: [(Int, String, Double, Double)] = []
            for (i, p) in pools.enumerated() {
                let took = p.at - last
                last = p.at
                let hop = i < ticks.count ? ticks[i] - p.at : -1
                rows.append((i + 1, p.name, took, hop))
            }
            let total = (pools.last?.at ?? 0) - (filterCacheAt ?? pools[0].at)
            var out = [String(format: "pools=%d ticks=%d total=%.1fs", pools.count, ticks.count, total)]
            out.append("slowest pools: " + rows.sorted { $0.2 > $1.2 }.prefix(10)
                .map { "#\($0.0) \($0.1)=\(Int($0.2 * 1000))ms" }.joined(separator: ", "))
            out.append("slowest tick hops: " + rows.sorted { $0.3 > $1.3 }.prefix(10)
                .map { "#\($0.0)=\(Int($0.3 * 1000))ms" }.joined(separator: ", "))
            out.append("pools 55-70: " + rows.filter { (55...70).contains($0.0) }
                .map { "#\($0.0) \($0.1) \(Int($0.2 * 1000))ms hop \(Int($0.3 * 1000))ms" }.joined(separator: " | "))
            return out
        }
    }

    /// Memory, threads, the main thread's longest stall and requests per endpoint, on a
    /// background thread that sleeps between readings (no busy loop stealing the CPU the
    /// load needs on an Apple TV).
    final class Sampler: @unchecked Sendable {
        private let report: Report
        private let timeline: Timeline
        private let servers: [String: HarnessFakeServer]
        private let lock = NSLock()
        private var running = true
        private var phase = ""
        private let t0 = CFAbsoluteTimeGetCurrent()
        private var peakFoot: UInt64 = 0
        private var peakThreads = 0
        private var longestMainBlock = 0.0
        private var longestMainBlockAt = 0.0
        private var soakMainBlock = 0.0
        private var lastCounts: [String: Int] = [:]
        private var samples: [(t: Double, foot: UInt64, threads: Int)] = []

        init(report: Report, timeline: Timeline, servers: [String: HarnessFakeServer]) {
            self.report = report; self.timeline = timeline; self.servers = servers
        }

        func setPhase(_ s: String) { lock.lock(); phase = s; lock.unlock() }
        func stop() { lock.lock(); running = false; lock.unlock() }
        /// Soak lines count requests from here on, not the load's.
        func markSoakStart() {
            var counts: [String: Int] = [:]
            for (name, server) in servers {
                for (label, c) in server.requestCounts { counts["\(name).\(label)"] = c }
            }
            lock.lock(); soakMainBlock = 0; lastCounts = counts; lock.unlock()
        }
        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        func start() {
            let mem = Thread { [self] in
                var n = 0
                while self.isRunning {
                    let f = BigLibraryHarness.footprintBytes()
                    let th = Self.threadCount()
                    let t = CFAbsoluteTimeGetCurrent() - self.t0
                    self.lock.lock()
                    self.peakFoot = max(self.peakFoot, f)
                    self.peakThreads = max(self.peakThreads, th)
                    self.samples.append((t, f, th))
                    let ph = self.phase
                    self.lock.unlock()
                    if n % 5 == 0 {
                        let avail = Int(os_proc_available_memory()) / 1_048_576
                        self.report.trail("sample foot=\(f / 1_048_576)MB avail=\(avail)MB threads=\(th) pools=\(self.timeline.poolsDone) ticks=\(self.timeline.ticksDone) \(ph)")
                    }
                    n += 1
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            mem.qualityOfService = .utility
            mem.start()
            let pinger = Thread { [self] in
                while self.isRunning {
                    let sent = CFAbsoluteTimeGetCurrent()
                    let sem = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { sem.signal() }
                    sem.wait()
                    let took = CFAbsoluteTimeGetCurrent() - sent
                    self.lock.lock()
                    if took > self.longestMainBlock { self.longestMainBlock = took; self.longestMainBlockAt = sent - self.t0 }
                    self.soakMainBlock = max(self.soakMainBlock, took)
                    self.lock.unlock()
                    if took > 1 { self.report.trail(String(format: "main thread blocked %.1fs", took)) }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            pinger.qualityOfService = .utility
            pinger.start()
        }

        func summary(since: Double) -> String {
            lock.lock(); defer { lock.unlock() }
            let s = samples.filter { $0.t >= since }
            let first = s.first, last = s.last
            return String(format: "memory: peak=%dMB start=%dMB end=%dMB threads: peak=%d start=%d end=%d longestMainBlock=%.0fms at t=%.1fs",
                          Int(peakFoot / 1_048_576), Int((first?.foot ?? 0) / 1_048_576), Int((last?.foot ?? 0) / 1_048_576),
                          peakThreads, first?.threads ?? 0, last?.threads ?? 0, longestMainBlock * 1000, longestMainBlockAt)
        }

        /// One soak line: memory and threads now, the main thread's worst stall since the last
        /// line, and requests per endpoint since the last line (anything that keeps climbing
        /// is a retry or a poll that never stops).
        func soakLine(elapsed: Double) -> String {
            var counts: [String: Int] = [:]
            for (name, server) in servers {
                for (label, c) in server.requestCounts { counts["\(name).\(label)"] = c }
            }
            lock.lock()
            let delta = counts.compactMap { k, v -> String? in
                let d = v - (lastCounts[k] ?? 0)
                return d > 0 ? "\(k)+\(d)" : nil
            }.sorted()
            lastCounts = counts
            let block = soakMainBlock
            soakMainBlock = 0
            let f = samples.last?.foot ?? 0
            let th = samples.last?.threads ?? 0
            lock.unlock()
            return String(format: "soak t=%4.0fs foot=%dMB threads=%d mainBlock=%.0fms requests: %@",
                          elapsed, Int(f / 1_048_576), th, block * 1000, delta.isEmpty ? "none" : delta.joined(separator: " "))
        }

        static func threadCount() -> Int {
            var list: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
            return Int(count)
        }
    }
}

private extension String {
    /// FNV-1a: the same on every run, unlike `hashValue`.
    var hashValueStable: UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}
