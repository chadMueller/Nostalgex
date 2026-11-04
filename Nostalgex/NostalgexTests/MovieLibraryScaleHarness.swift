import XCTest
import UIKit
import SwiftUI
@testable import Nostalgex

/// Discord report, 2026-11-03: an Emby (and Plex) library of about 15,000 movies, every one
/// with genres and a TMDB match, never gets past "Channel 60 of 142" on the loading screen,
/// and the app closes about an hour in.
///
/// `BigLibraryHarness` models a TV-heavy library with no TMDB ids. This one models the
/// reporter's shape: movies only, every title with a TMDB id, its enrichment row already
/// cached (as a shared Supabase cache would hand it back), a real slice of the membership
/// manifest's ids, and franchise ids on a share of titles. It drives the REAL `loadLibrary`
/// through `backendOverride` and then builds the guide's schedules the way TunerView does,
/// recording time per stage, time per channel pool, time per channel schedule and peak
/// memory.
///
/// Off by default. One size per process:
///
///     TEST_RUNNER_NOSTALGEX_MOVIELIB_N=15000 TEST_RUNNER_NOSTALGEX_MOVIELIB_OUT=/path/out.txt \
///       xcodebuild test ... -only-testing:NostalgexTests/MovieLibraryScaleHarness
@MainActor
final class MovieLibraryScaleHarness: XCTestCase {

    private final class FixtureBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        private let lock = NSLock()
        private var items: [PlexMediaItem]?
        var authHeaders: [String: String] { [:] }
        init(serverID: String, items: [PlexMediaItem]) { self.serverID = serverID; self.items = items }
        func testConnection() async throws -> String { serverID }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress?) async throws -> [PlexMediaItem] {
            lock.lock(); let out = items ?? []; lock.unlock()
            return out
        }
        func loadSections() async throws -> [PlexSection] {
            [PlexSection(key: "1", title: "Movies", type: "movie", scannedAt: 1, updatedAt: 1, contentChangedAt: 1)]
        }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { nil }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    /// Movies only, every one with genres, a TMDB id, an IMDb id and an enrichment row.
    /// A third of the ids (up to the manifest's size) are real membership-manifest movie ids,
    /// so the manifest paths in `filterItems` run the way they do on a big real library.
    static func makeMovieLibrary(count n: Int, serverID: String)
        -> (items: [PlexMediaItem], enrichments: [MediaEnrichment], mix: String) {
        typealias RNG = BigLibraryHarness.RNG
        var rng = RNG(state: 0xF11_0000 &+ UInt64(n))
        let config = ChannelConfigLoader.loadBundled()
        let rules = config.channels.compactMap(\.rules)
        let curatedTitles = Array(Set(rules.flatMap { $0.titleContains ?? [] })).sorted()
        let ruleKeywords = Array(Set(rules.flatMap { ($0.keywords ?? []) + ($0.keywordsExclude ?? []) })).sorted()
        let ruleCompanies = Array(Set(rules.flatMap { ($0.productionCompanies ?? []) + ($0.studios ?? []) })).sorted()
        let fillerKeywords = ["based on novel or book", "friendship", "revenge", "new york city", "murder",
                              "love", "small town", "police", "family relationships", "high school",
                              "biography", "sequel", "remake", "duringcreditsstinger", "woman director",
                              "los angeles, california", "suspense", "dystopia", "road trip", "heist"]
        let fillerCompanies = ["Warner Bros. Pictures", "Universal Pictures", "Paramount Pictures",
                               "20th Century Fox", "Columbia Pictures", "Lionsgate", "Miramax", "New Line Cinema",
                               "Metro-Goldwyn-Mayer", "Canal+", "StudioCanal", "Legendary Pictures"]
        let genres = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama",
                      "Family", "Fantasy", "History", "Horror", "Music", "Mystery", "Romance",
                      "Science Fiction", "Thriller", "War", "Western", "TV Movie"]
        let ratings: [String?] = ["G", "PG", "PG-13", "PG-13", "R", "R", "NR", nil]
        let codecs: [(String, String, String)] = [("mkv", "h264", "ac3"), ("mkv", "hevc", "eac3"),
                                                  ("mp4", "h264", "aac"), ("mkv", "h264", "dts")]

        let manifest = ChannelMembershipsLoader.loadBundled()
        var manifestMovies: [(String, String)] = manifest.items.compactMap { key, entry in
            guard key.hasPrefix("movie:") else { return nil }
            return (String(key.dropFirst(6)), entry.name ?? "")
        }.sorted { $0.0 < $1.0 }
        // Deterministic shuffle.
        for i in stride(from: manifestMovies.count - 1, to: 0, by: -1) {
            manifestMovies.swapAt(i, rng.int(0...i))
        }
        let fromManifest = min(n / 3, manifestMovies.count)

        var items: [PlexMediaItem] = []
        var enrichments: [MediaEnrichment] = []
        items.reserveCapacity(n)
        enrichments.reserveCapacity(n)
        let baseAdded = 1_500_000_000
        var franchiseCount = 0
        for i in 0..<n {
            let key = 200_000 + i
            let rk = String(key)
            let tmdbID: String
            let title: String
            if i < fromManifest {
                tmdbID = manifestMovies[i].0
                title = manifestMovies[i].1.isEmpty ? BigLibraryHarness.titleCase(&rng, words: 2) : manifestMovies[i].1
            } else {
                tmdbID = String(5_000_000 + i)
                title = (i % 7 == 0 && !curatedTitles.isEmpty)
                    ? rng.pick(curatedTitles)
                    : BigLibraryHarness.titleCase(&rng, words: rng.int(1...4))
            }
            let imdbID = String(format: "tt%07d", 1_000_000 + i)
            let year = rng.int(1930...2025)
            let g = Array(Set((0..<rng.int(1...3)).map { _ in rng.pick(genres) }))
            let added = baseAdded + rng.int(0...250_000_000)
            let c = rng.pick(codecs)
            items.append(PlexMediaItem(
                id: "\(serverID):\(rk)", title: title, artist: nil, episodeTitle: nil, seTag: nil,
                summary: BigLibraryHarness.sentence(&rng, chars: rng.int(150...500)), year: year,
                originallyAvailableAt: "\(year)-0\(rng.int(1...9))-1\(rng.int(0...9))",
                contentRating: rng.pick(ratings), duration: rng.int(80...170), ratingKey: rk,
                partKey: "/library/parts/\(key + 900_000)/\(added)/file.\(c.0)",
                container: c.0, videoCodec: c.1, audioCodec: c.2, videoProfile: c.1 == "hevc" ? "main 10" : "high",
                bitrate: rng.int(1_500...25_000), genres: g, rating: Double(rng.int(30...95)) / 10,
                userRating: 0, type: .movie, thumb: "/library/metadata/\(rk)/thumb/\(added)",
                art: "/library/metadata/\(rk)/art/\(added)",
                viewCount: rng.chance(0.3) ? rng.int(1...6) : 0, addedAt: added,
                studio: rng.chance(0.5) ? rng.pick(fillerCompanies) : (ruleCompanies.isEmpty ? nil : rng.pick(ruleCompanies)),
                tmdbID: tmdbID, imdbID: imdbID, librarySource: .movie, serverID: serverID,
                videoBitDepth: c.1 == "hevc" ? 10 : 8, doviProfile: nil,
                videoWidth: 1920, videoHeight: 1080))

            var kw = (0..<rng.int(4...18)).map { _ in rng.pick(fillerKeywords) }
            if !ruleKeywords.isEmpty { kw += (0..<rng.int(0...4)).map { _ in rng.pick(ruleKeywords) } }
            var pc = (0..<rng.int(1...4)).map { _ in rng.pick(fillerCompanies) }
            if !ruleCompanies.isEmpty, rng.chance(0.3) { pc.append(rng.pick(ruleCompanies)) }
            // About 15% of a big movie library belongs to a TMDB collection; sizes 2 to 8.
            let inFranchise = rng.chance(0.15)
            if inFranchise { franchiseCount += 1 }
            let franchiseID = inFranchise ? 900_000 + (i / rng.int(2...8)) : nil
            enrichments.append(MediaEnrichment(
                tmdbID: tmdbID, imdbID: imdbID, mediaType: "movie",
                keywords: Array(Set(kw)), networks: [], productionCompanies: Array(Set(pc)),
                tmdbGenres: Array(Set(g + [rng.pick(genres)])),
                imdbRating: Double(rng.int(30...92)) / 10, imdbVotes: rng.int(500...900_000),
                rottenTomatoesScore: rng.chance(0.7) ? rng.int(5...100) : nil,
                metacriticScore: rng.chance(0.6) ? rng.int(20...98) : nil,
                awards: rng.chance(0.05) ? "Won 1 Oscar. 3 wins & 5 nominations" : "1 nomination",
                franchiseID: franchiseID, franchiseName: franchiseID.map { "Collection \($0)" },
                fetchedAt: Date()))
        }
        return (items, enrichments, "movies=\(n) fromManifest=\(fromManifest) inFranchise=\(franchiseCount)")
    }

    func testMovieLibraryScale() async throws {
        guard let raw = ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_N"], let n = Int(raw), n > 0 else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_MOVIELIB_N to run the movie-library scale harness")
        }
        // The app's real stores stay untouched; see HarnessIsolation.
        let isolation = HarnessScope.begin("testMovieLibraryScale")
        defer { isolation.end() }
        let serverID = "7c1e5a3b9d2f4e6a8b0c1d2e3f4a5b6c7d8e9f01"
        let server = AppState.ServerRef(machineIdentifier: serverID, name: "Vault", baseURL: "http://127.0.0.1:9", owned: true, token: "srv")

        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        DailyManifestScheduler.invalidateMemo()
        AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        AppDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles")
        defer {
            LibrarySnapshotStore.clear()
            DailyManifestStore.clearAll()
            DailyManifestScheduler.invalidateMemo()
            AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
            LibraryLoadProbe.handler = nil
        }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var out: [String] = []
        func emit(_ s: String) {
            out.append(s)
            if let path = ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_OUT"] {
                try? out.map { "[MOVIELIB] \($0)" }.joined(separator: "\n").appending("\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        emit("N=\(n) enrichmentConfigured=\(!TMDBConfig.supabaseURL.isEmpty)")

        let rec = BigLibraryHarness.Recorder()
        rec.mark("baseline")
        let fixture = Self.makeMovieLibrary(count: n, serverID: serverID)
        let backend = FixtureBackend(serverID: serverID, items: fixture.items)
        rec.mark("fixture")
        emit(fixture.mix)

        // Per-channel pool timings come through the probe as "pool:<id>:<name>:<count>".
        let poolLock = NSLock()
        var poolTimes: [(String, Double)] = []
        var lastPoolAt = rec.now()
        LibraryLoadProbe.handler = { stage in
            if stage.hasPrefix("pool:") {
                poolLock.lock()
                let t = rec.now()
                poolTimes.append((stage, t - lastPoolAt))
                lastPoolAt = t
                poolLock.unlock()
                return
            }
            if stage == "filterCache" { poolLock.lock(); lastPoolAt = rec.now(); poolLock.unlock() }
            rec.mark(stage)
        }

        fflush(stdout)
        let savedStdout = dup(STDOUT_FILENO)
        let devnull = open("/dev/null", O_WRONLY)
        dup2(devnull, STDOUT_FILENO)
        defer {
            fflush(stdout)
            dup2(savedStdout, STDOUT_FILENO)
            close(devnull)
            close(savedStdout)
        }

        if ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_ALLBUNDLES"] == "1" {
            let ids = ChannelConfigLoader.loadBundled().bundles.map(\.id)
            AppDefaults.standard.set(ids, forKey: "nostalgex_enabled_bundles")
            emit("enabledBundles=all(\(ids.count))")
        }
        defer { AppDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles") }
        let state = AppState(credentialStore: InMemoryStore())
        state.enrichmentService.seedCache(fixture.enrichments)
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "plex-account-token", servers: [server])
        let loadStart = rec.now()
        await state.loadLibrary()
        let loadSeconds = rec.now() - loadStart
        rec.mark("loadLibrary.return")
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        rec.mark("snapshot.background.done")

        let poolEntries = state.allChannels.reduce(0) { $0 + $1.itemPool.count }
        let biggest = state.allChannels.sorted { $0.itemPool.count > $1.itemPool.count }.prefix(6)
            .map { "\($0.number):\($0.itemPool.count)" }.joined(separator: " ")
        emit("loadLibrary=\(String(format: "%.2f", loadSeconds))s items=\(state.allItems.count) allChannels=\(state.allChannels.count) guide=\(state.channels.count) poolEntries=\(poolEntries) biggest=\(biggest) error=\(state.errorMessage ?? "nil")")

        let pt = poolLock.withLock { poolTimes }
        let poolTotal = pt.reduce(0) { $0 + $1.1 }
        emit("poolBuild channels=\(pt.count) total=\(String(format: "%.0f", poolTotal * 1000))ms slowest=" +
             pt.sorted { $0.1 > $1.1 }.prefix(6).map { "\($0.0.dropFirst(5))=\(String(format: "%.0f", $0.1 * 1000))ms" }.joined(separator: " "))

        // The guide, as TunerView.buildAllSchedules does it, timed per channel.
        let guideChannels = state.channels
        let fp = state.scheduleCredentialFingerprint
        let (schedTimes, built) = await Task.detached(priority: .userInitiated) { () -> ([(String, Double)], Int) in
            var times: [(String, Double)] = []
            var schedules: [Int: ChannelSchedule] = [:]
            for channel in guideChannels {
                let t0 = CFAbsoluteTimeGetCurrent()
                if let s = ChannelScheduleBuilder.buildSchedule(for: channel, at: Date(), credentialFingerprint: fp) {
                    schedules[channel.id] = s
                }
                times.append(("\(channel.number):\(channel.name):\(channel.itemPool.count)", CFAbsoluteTimeGetCurrent() - t0))
            }
            ChannelScheduleBuilder.resolveConflicts(&schedules)
            return (times, schedules.count)
        }.value
        rec.mark("guide.firstBuild")
        let schedTotal = schedTimes.reduce(0) { $0 + $1.1 }
        emit("guide.firstBuild schedules=\(built)/\(guideChannels.count) total=\(String(format: "%.0f", schedTotal * 1000))ms slowest=" +
             schedTimes.sorted { $0.1 > $1.1 }.prefix(6).map { "\($0.0)=\(String(format: "%.0f", $0.1 * 1000))ms" }.joined(separator: " "))

        // TunerView rebuilds every 30 s while the guide is open: the warm cost.
        let warm = await Task.detached(priority: .userInitiated) { () -> Double in
            let t0 = CFAbsoluteTimeGetCurrent()
            var schedules: [Int: ChannelSchedule] = [:]
            for channel in guideChannels {
                if let s = ChannelScheduleBuilder.buildSchedule(for: channel, at: Date(), credentialFingerprint: fp) {
                    schedules[channel.id] = s
                }
            }
            ChannelScheduleBuilder.resolveConflicts(&schedules)
            return CFAbsoluteTimeGetCurrent() - t0
        }.value
        rec.mark("guide.warmBuild")
        emit("guide.warmBuild total=\(String(format: "%.0f", warm * 1000))ms")

        rec.stop()
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        func mb(_ b: UInt64) -> String { String(format: "%.0f", Double(b) / 1_048_576) }
        emit(pad("stage", 28) + lpad("ms", 10) + lpad("peakFootMB", 12) + lpad("endFootMB", 11) + lpad("mainBlockMs", 13))
        for (row, block) in rec.report() {
            emit(pad(row.stage, 28) + lpad(String(format: "%.0f", (row.end - row.start) * 1000), 10)
                 + lpad(mb(row.peakFoot), 12) + lpad(mb(row.endFoot), 11)
                 + lpad(String(format: "%.0f", block * 1000), 13))
        }
        let hang = rec.longestHang()
        emit(String(format: "overallPeakFootprint=%@MB longestMainBlock=%.0fms at t=%.1fs", mb(rec.overallPeakFoot), hang.seconds * 1000, hang.start))

        XCTAssertEqual(state.allItems.count, n)
    }

    /// Same library, but through the real UI: `RootView` is put in the app's window with
    /// this AppState, so the loading screen, the guide and their timers run on the main
    /// thread while the load does, as on a TV. Then the guide stays up for
    /// NOSTALGEX_MOVIELIB_SIT seconds (memory sampled), then RESCAN LIBRARY runs.
    func testMovieLibraryScaleThroughUI() async throws {
        guard let raw = ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_UI_N"], let n = Int(raw), n > 0 else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_MOVIELIB_UI_N to run the UI scale harness")
        }
        // The app's real stores stay untouched; see HarnessIsolation.
        let isolation = HarnessScope.begin("testMovieLibraryScaleThroughUI")
        defer { isolation.end() }
        let sit = Double(ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_SIT"] ?? "60") ?? 60
        let serverID = "7c1e5a3b9d2f4e6a8b0c1d2e3f4a5b6c7d8e9f01"
        let server = AppState.ServerRef(machineIdentifier: serverID, name: "Vault", baseURL: "http://127.0.0.1:9", owned: true, token: "srv")
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        DailyManifestScheduler.invalidateMemo()
        AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        AppDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles")
        LaunchGuard.resetUnfinishedLoads()
        defer {
            LibrarySnapshotStore.clear()
            DailyManifestStore.clearAll()
            DailyManifestScheduler.invalidateMemo()
            AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
            LaunchGuard.resetUnfinishedLoads()
            LibraryLoadProbe.handler = nil
        }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var out: [String] = []
        func emit(_ s: String) {
            out.append(s)
            if let path = ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_OUT"] {
                try? out.map { "[MOVIELIB-UI] \($0)" }.joined(separator: "\n").appending("\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let rec = BigLibraryHarness.Recorder()
        let fixture = Self.makeMovieLibrary(count: n, serverID: serverID)
        let backend = FixtureBackend(serverID: serverID, items: fixture.items)
        emit("N=\(n) \(fixture.mix) sit=\(Int(sit))s")
        let poolLock = NSLock()
        var poolTicks: [Double] = []
        LibraryLoadProbe.handler = { stage in
            if stage.hasPrefix("pool:") { poolLock.lock(); poolTicks.append(rec.now()); poolLock.unlock(); return }
            rec.mark(stage)
        }

        if ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_ALLBUNDLES"] == "1" {
            let ids = ChannelConfigLoader.loadBundled().bundles.map(\.id)
            AppDefaults.standard.set(ids, forKey: "nostalgex_enabled_bundles")
            emit("enabledBundles=all(\(ids.count))")
        }
        defer { AppDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles") }
        let state = AppState(credentialStore: InMemoryStore())
        state.enrichmentService.seedCache(fixture.enrichments)
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "plex-account-token", servers: [server])

        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first else {
            throw XCTSkip("no window in the test host")
        }
        let previousRoot = window.rootViewController
        defer { window.rootViewController = previousRoot }
        rec.mark("start")
        let t0 = rec.now()
        window.rootViewController = UIHostingController(rootView: RootView().environment(state))

        // The launch load runs from RootView.task. Wait for the guide.
        var sawLoading = false
        while rec.now() - t0 < 3600 {
            if state.isLoading { sawLoading = true }
            if sawLoading, !state.isLoading, !state.channels.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let firstLoad = rec.now() - t0
        rec.mark("ui.guideUp")
        let ticks = poolLock.withLock { poolTicks }
        let gaps = zip(ticks.dropFirst(), ticks).map { $0 - $1 }
        emit(String(format: "firstLoad=%.1fs channels=%d poolTicks=%d maxTickGap=%.0fms", firstLoad, state.channels.count, ticks.count, (gaps.max() ?? 0) * 1000))

        // Sit on the guide, sampling memory.
        var samples: [String] = []
        let sitStart = rec.now()
        while rec.now() - sitStart < sit {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            samples.append("\(Int(rec.now() - sitStart))s:\(BigLibraryHarness.footprintBytes() / 1_048_576)MB")
        }
        rec.mark("ui.sit")
        emit("guide sit memory: " + samples.joined(separator: " "))

        // RESCAN LIBRARY, as the Settings row does it.
        poolLock.withLock { poolTicks = [] }
        let r0 = rec.now()
        await state.rescanLibrary()
        let rescan = rec.now() - r0
        rec.mark("ui.rescan")
        let ticks2 = poolLock.withLock { poolTicks }
        let gaps2 = zip(ticks2.dropFirst(), ticks2).map { $0 - $1 }
        emit(String(format: "rescan=%.1fs channels=%d poolTicks=%d maxTickGap=%.0fms", rescan, state.channels.count, ticks2.count, (gaps2.max() ?? 0) * 1000))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        rec.stop()

        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        func mb(_ b: UInt64) -> String { String(format: "%.0f", Double(b) / 1_048_576) }
        emit(pad("stage", 28) + lpad("ms", 10) + lpad("peakFootMB", 12) + lpad("endFootMB", 11) + lpad("mainBlockMs", 13))
        for (row, block) in rec.report() {
            emit(pad(row.stage, 28) + lpad(String(format: "%.0f", (row.end - row.start) * 1000), 10)
                 + lpad(mb(row.peakFoot), 12) + lpad(mb(row.endFoot), 11)
                 + lpad(String(format: "%.0f", block * 1000), 13))
        }
        let hang = rec.longestHang()
        emit(String(format: "overallPeakFootprint=%@MB longestMainBlock=%.0fms at t=%.1fs", mb(rec.overallPeakFoot), hang.seconds * 1000, hang.start))
        XCTAssertFalse(state.channels.isEmpty)
    }

    /// The real `EmbyAPIService` against a fake Emby (scratch `fakeemby/server.py`) serving
    /// one big Movies library with a fixed delay per page, through the real `loadLibrary`
    /// and its stall watch. Records what the stall watch sees (scanItemsFound every 2 s),
    /// whether the scan finished, and how many items made it.
    ///
    ///     TEST_RUNNER_NOSTALGEX_FAKEEMBY_URL=http://127.0.0.1:8765 TEST_RUNNER_NOSTALGEX_FAKEEMBY_N=15000
    func testEmbyMovieScanUnderStallWatch() async throws {
        guard let url = ProcessInfo.processInfo.environment["NOSTALGEX_FAKEEMBY_URL"],
              let n = Int(ProcessInfo.processInfo.environment["NOSTALGEX_FAKEEMBY_N"] ?? "") else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_FAKEEMBY_URL and _N to run against a fake Emby")
        }
        // The app's real stores stay untouched; see HarnessIsolation.
        let isolation = HarnessScope.begin("testEmbyMovieScanUnderStallWatch")
        defer { isolation.end() }
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        DailyManifestScheduler.invalidateMemo()
        AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        AppDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles")
        defer {
            LibrarySnapshotStore.clear()
            DailyManifestStore.clearAll()
            AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        }
        var out: [String] = []
        func emit(_ s: String) {
            out.append(s)
            if let path = ProcessInfo.processInfo.environment["NOSTALGEX_MOVIELIB_OUT"] {
                try? out.map { "[FAKEEMBY] \($0)" }.joined(separator: "\n").appending("\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let serverID = "fakeemby0000000000000000000000000000001"
        let emby = EmbyAPIService(serverURL: url, accessToken: "token", userId: "user", serverID: serverID)
        let server = AppState.ServerRef(machineIdentifier: serverID, name: "FakeEmby", baseURL: url, owned: true, token: "token")
        let state = AppState(credentialStore: InMemoryStore())
        state.backendOverride = { _ in emby }
        state.completePlexSignIn(token: "token", servers: [server])

        let t0 = Date()
        let sampler = Task { @MainActor in
            var line: [String] = []
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                line.append("\(Int(Date().timeIntervalSince(t0)))s:\(state.scanItemsFound)\(state.isLoadStalling ? "!" : "")")
            }
            return line
        }
        await state.loadLibrary()
        let seconds = Date().timeIntervalSince(t0)
        sampler.cancel()
        let samples = await sampler.value
        emit(String(format: "N=%d load=%.1fs items=%d stale=%@ channels=%d error=%@", n, seconds, state.allItems.count,
                    state.isLibraryStale ? "true" : "false", state.channels.count, state.errorMessage ?? "nil"))
        emit("scanItemsFound every 2s (! = STOP WAITING shown): " + samples.joined(separator: " "))
    }
}
