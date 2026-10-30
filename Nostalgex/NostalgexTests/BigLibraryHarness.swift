import XCTest
import Darwin
import os
import UIKit
@testable import Nostalgex

/// Discord report, 2026-10-12: a Plex user with a "~400k" library sees the loading screen
/// finish, the channel grid appear, then the app dies; the next launch scans from scratch.
///
/// This harness feeds a synthetic library of N items into the REAL `loadLibrary` (through
/// `backendOverride`, so the network fetch is the only step skipped) and records wall time,
/// peak memory and the longest main-thread block between the `LibraryLoadProbe` marks. It
/// then builds the guide's schedules the way TunerView does and restores the snapshot the
/// way the next launch does.
///
/// Off by default: it needs minutes and gigabytes. Run one size per process so stages are
/// not measured on a heap the previous size left behind:
///
///     TEST_RUNNER_NOSTALGEX_BIGLIB_N=400000 xcodebuild test ... \
///       -only-testing:NostalgexTests/BigLibraryHarness
///
/// Output lines start with `[BIGLIB]`. Set TEST_RUNNER_NOSTALGEX_BIGLIB_OUT to a host file
/// path to also get them there (parallel test clones do not forward stdout).
@MainActor
final class BigLibraryHarness: XCTestCase {

    // MARK: - Memory + main-thread sampling

    nonisolated static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    nonisolated static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Polls phys_footprint (what jetsam enforces) and resident size on a background thread,
    /// and pings the main queue to time how long it goes without servicing work.
    final class Recorder: @unchecked Sendable {
        struct Row { let stage: String; let start: Double; let end: Double; let peakFoot: UInt64; let peakRes: UInt64; let endFoot: UInt64 }
        private let lock = NSLock()
        private var rows: [Row] = []
        private var hangs: [(Double, Double)] = []
        private var segStart: Double
        private var segPeakFoot: UInt64 = 0
        private var segPeakRes: UInt64 = 0
        private var running = true
        let t0 = CFAbsoluteTimeGetCurrent()
        private(set) var overallPeakFoot: UInt64 = 0
        /// Appended live and flushed, so a run that is killed (jetsam, sleep) still leaves
        /// the last stage and memory reading on disk. Pull it with devicectl from the app's
        /// Caches/biglib-trail.txt on hardware.
        private let trail: FileHandle?

        static func availableMB() -> Int { Int(os_proc_available_memory()) / 1_048_576 }

        func writeTrail(_ line: String) {
            guard let trail else { return }
            lock.lock(); defer { lock.unlock() }
            trail.write(Data((String(format: "%.1f ", now()) + line + "\n").utf8))
            try? trail.synchronize()
        }

        init() {
            segStart = 0
            let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("biglib-trail.txt").path
            FileManager.default.createFile(atPath: path, contents: nil)
            trail = FileHandle(forWritingAtPath: path)
            let sampler = Thread { [self] in
                var lastTrail = 0.0
                while true {
                    if self.now() - lastTrail >= 2 {
                        lastTrail = self.now()
                        self.writeTrail("sample foot=\(BigLibraryHarness.footprintBytes() / 1_048_576)MB avail=\(Recorder.availableMB())MB")
                    }
                    let f = BigLibraryHarness.footprintBytes()
                    let r = BigLibraryHarness.residentBytes()
                    self.lock.lock()
                    let go = self.running
                    if f > self.segPeakFoot { self.segPeakFoot = f }
                    if r > self.segPeakRes { self.segPeakRes = r }
                    if f > self.overallPeakFoot { self.overallPeakFoot = f }
                    self.lock.unlock()
                    if !go { break }
                    usleep(500)
                }
            }
            sampler.qualityOfService = .userInteractive
            sampler.start()
            let pinger = Thread { [self] in
                while true {
                    self.lock.lock(); let go = self.running; self.lock.unlock()
                    if !go { break }
                    let sent = self.now()
                    let sem = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { sem.signal() }
                    sem.wait()
                    let got = self.now()
                    if got - sent > 0.05 {
                        self.lock.lock(); self.hangs.append((sent, got)); self.lock.unlock()
                    }
                    usleep(10_000)
                }
            }
            pinger.qualityOfService = .userInteractive
            pinger.start()
        }

        func now() -> Double { CFAbsoluteTimeGetCurrent() - t0 }

        func mark(_ stage: String) {
            let f = BigLibraryHarness.footprintBytes()
            let r = BigLibraryHarness.residentBytes()
            let t = now()
            lock.lock()
            segPeakFoot = max(segPeakFoot, f)
            segPeakRes = max(segPeakRes, r)
            overallPeakFoot = max(overallPeakFoot, f)
            rows.append(Row(stage: stage, start: segStart, end: t, peakFoot: segPeakFoot, peakRes: segPeakRes, endFoot: f))
            segStart = t
            segPeakFoot = f
            segPeakRes = r
            lock.unlock()
            writeTrail("mark \(stage) foot=\(f / 1_048_576)MB avail=\(Recorder.availableMB())MB")
        }

        func stop() { lock.lock(); running = false; lock.unlock() }

        func report() -> [(row: Row, maxBlock: Double)] {
            lock.lock(); defer { lock.unlock() }
            return rows.map { row in
                let block = hangs.reduce(0.0) { acc, h in
                    max(acc, max(0, min(h.1, row.end) - max(h.0, row.start)))
                }
                return (row, block)
            }
        }

        func longestHang() -> (start: Double, seconds: Double) {
            lock.lock(); defer { lock.unlock() }
            let h = hangs.max { ($0.1 - $0.0) < ($1.1 - $1.0) }
            return h.map { ($0.0, $0.1 - $0.0) } ?? (0, 0)
        }
    }

    // MARK: - Fixture

    /// Hands its items over exactly once, then lets go of them, so the fixture is not a
    /// second copy of the library for the rest of the run (a real fetch's arrays are freed
    /// when `loadLibrary` returns).
    private final class FixtureBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        private let lock = NSLock()
        private var items: [PlexMediaItem]?
        var authHeaders: [String: String] { [:] }
        init(serverID: String, items: [PlexMediaItem]) { self.serverID = serverID; self.items = items }

        func testConnection() async throws -> String { serverID }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress?) async throws -> [PlexMediaItem] {
            lock.lock(); let out = items ?? []; items = nil; lock.unlock()
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

    /// SplitMix64: deterministic, so every run sees the same library.
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    static let words = """
    the a man woman night day city house love war last first return secret dark light king \
    queen island road river family friend story time world life death heart fire water star \
    blood gold silver iron storm summer winter shadow ghost dream girl boy father mother son \
    daughter brother sister lost found final big little red blue black white wild free young \
    old new dead alive one two three hundred thousand street town country ocean mountain sky \
    escape hunt chase game party wedding school college office prison hospital station \
    detective doctor captain agent soldier pilot driver teacher thief killer stranger hero \
    after before during under over beyond between against without inside outside across \
    when they must find stop save help learn discover decide become begin end fight run hide
    """.split(separator: " ").map(String.init)

    static func sentence(_ rng: inout RNG, chars: Int) -> String {
        var s = ""
        s.reserveCapacity(chars + 12)
        while s.utf8.count < chars {
            if !s.isEmpty { s += " " }
            s += rng.pick(words)
        }
        return s + "."
    }

    static func titleCase(_ rng: inout RNG, words n: Int) -> String {
        (0..<n).map { _ in rng.pick(words).capitalized }.joined(separator: " ")
    }

    /// Shaped like what `PlexAPIService` hands `loadLibrary`: episodes copy their show's
    /// title/studio/art/genre strings (shared storage, as `makeEpisodeItem` does) and carry
    /// their own summary, episode title, thumb and part key. Movies 10%, episodes 60%,
    /// music videos 30%. Music TRACKS are not generated: the Plex fetch never returns them.
    static func makeLibrary(count n: Int, serverID: String) -> (items: [PlexMediaItem], mix: String) {
        var rng = RNG(state: 0x5EED_0000 &+ UInt64(n))
        let config = ChannelConfigLoader.loadBundled()
        let curatedTitles = Array(Set(config.channels.flatMap { $0.rules?.titleContains ?? [] })).sorted()
        let curatedStudios = Array(Set(config.channels.flatMap { $0.rules?.studios ?? [] })).sorted()
        let movieGenres = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama",
                           "Family", "Fantasy", "History", "Horror", "Music", "Mystery", "Romance",
                           "Science Fiction", "Thriller", "War", "Western", "Holiday", "Biography", "Sport"]
        let tvGenres = ["Comedy", "Drama", "Animation", "Kids", "Children", "Reality", "Documentary", "Crime",
                        "Mystery", "Sci-Fi & Fantasy", "Action & Adventure", "Family", "Talk Show", "News",
                        "Western", "Soap", "Sitcom", "Game Show", "War & Politics"]
        let musicGenres = ["Pop", "Rock", "Hip-Hop", "R&B", "Country", "Alternative", "Electronic", "Metal", "Soul"]
        let movieRatings: [String?] = ["G", "PG", "PG-13", "PG-13", "R", "R", "NC-17", "NR", nil]
        let tvRatings: [String?] = ["TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-14", "TV-MA", nil]
        let networks = ["NBC", "CBS", "ABC", "FOX", "HBO", "Nickelodeon", "Cartoon Network", "Disney Channel",
                        "PBS", "AMC", "FX", "Comedy Central", "BBC One", "Netflix", "MTV", "Showtime", "The WB"]
        let movieStudios = (curatedStudios + ["Warner Bros.", "Universal Pictures", "Paramount Pictures",
                                              "20th Century Fox", "Columbia Pictures", "Lionsgate", "Miramax"])
        let codecs: [(String, String, String)] = [("mkv", "h264", "ac3"), ("mkv", "hevc", "eac3"), ("mp4", "h264", "aac"),
                                                  ("mkv", "h264", "dts"), ("avi", "mpeg4", "mp3")]

        let movieCount = n / 10
        let musicCount = n * 3 / 10
        let episodeCount = n - movieCount - musicCount
        var items: [PlexMediaItem] = []
        items.reserveCapacity(n)
        var key = 100_000
        let baseAdded = 1_500_000_000

        func make(title: String, artist: String?, episodeTitle: String?, seTag: String?, summary: String,
                  year: Int?, date: String?, rating: String?, minutes: Int, genres: [String], type: MediaType,
                  thumb: String?, art: String?, studio: String?, source: LibrarySource, rng: inout RNG) -> PlexMediaItem {
            key += 1
            let rk = String(key)
            let added = baseAdded + rng.int(0...250_000_000)
            let c = rng.pick(codecs)
            return PlexMediaItem(
                id: "\(serverID):\(rk)", title: title, artist: artist, episodeTitle: episodeTitle, seTag: seTag,
                summary: summary, year: year, originallyAvailableAt: date, contentRating: rating,
                duration: minutes, ratingKey: rk, partKey: "/library/parts/\(key + 900_000)/\(added)/file.\(c.0)",
                container: c.0, videoCodec: c.1, audioCodec: c.2, videoProfile: c.1 == "hevc" ? "main 10" : "high",
                bitrate: rng.int(1_500...25_000), genres: genres, rating: Double(rng.int(30...95)) / 10,
                userRating: 0, type: type, thumb: thumb ?? "/library/metadata/\(rk)/thumb/\(added)", art: art,
                viewCount: rng.chance(0.3) ? rng.int(1...6) : 0, addedAt: added, studio: studio,
                // No TMDB/IMDb ids: enrichment would otherwise call TMDB/Supabase from a test.
                tmdbID: nil, imdbID: nil, librarySource: source, serverID: serverID,
                videoBitDepth: c.1 == "hevc" ? 10 : 8, doviProfile: nil,
                videoWidth: rng.chance(0.5) ? 1920 : 1280, videoHeight: rng.chance(0.5) ? 1080 : 720)
        }

        for i in 0..<movieCount {
            let title = (i % 5 == 0 && !curatedTitles.isEmpty) ? rng.pick(curatedTitles) : titleCase(&rng, words: rng.int(1...4))
            let year = rng.int(1940...2025)
            let g = (0..<rng.int(1...3)).map { _ in rng.pick(movieGenres) }
            items.append(make(title: title, artist: nil, episodeTitle: nil, seTag: nil,
                              summary: sentence(&rng, chars: rng.int(150...600)), year: year,
                              date: "\(year)-0\(rng.int(1...9))-1\(rng.int(0...9))", rating: rng.pick(movieRatings),
                              minutes: rng.int(80...170), genres: Array(Set(g)), type: .movie, thumb: nil,
                              art: "/library/metadata/\(key + 1)/art/\(baseAdded)", studio: rng.pick(movieStudios),
                              source: .movie, rng: &rng))
        }

        var made = 0
        var showIndex = 0
        while made < episodeCount {
            showIndex += 1
            let showTitle = (showIndex % 4 == 0 && !curatedTitles.isEmpty) ? rng.pick(curatedTitles) : titleCase(&rng, words: rng.int(1...3))
            let showGenres = Array(Set((0..<rng.int(1...3)).map { _ in rng.pick(tvGenres) }))
            let showStudio = rng.pick(networks)
            let showRating = rng.pick(tvRatings)
            let showYear = rng.int(1955...2024)
            let showArt = "/library/metadata/\(key)/art/\(baseAdded + showIndex)"
            let eps = min(episodeCount - made, rng.int(8...120))
            for e in 0..<eps {
                let season = e / 22 + 1, ep = e % 22 + 1
                let s = "S\(String(format: "%02d", season))E\(String(format: "%02d", ep))"
                items.append(make(title: showTitle, artist: nil, episodeTitle: titleCase(&rng, words: rng.int(1...5)),
                                  seTag: s, summary: sentence(&rng, chars: rng.int(80...400)), year: showYear,
                                  date: "\(showYear + season - 1)-0\(rng.int(1...9))-1\(rng.int(0...9))",
                                  rating: showRating, minutes: rng.chance(0.6) ? rng.int(20...24) : rng.int(40...48),
                                  genres: showGenres.map { $0 }, type: .episode, thumb: nil, art: showArt,
                                  studio: showStudio, source: .tv, rng: &rng))
            }
            made += eps
        }

        var artists: [String] = []
        for i in 0..<musicCount {
            if i % 12 == 0 || artists.isEmpty { artists.append(titleCase(&rng, words: rng.int(1...3))) }
            let artist = rng.chance(0.7) ? artists[artists.count - 1] : rng.pick(artists)
            let year = rng.int(1975...2024)
            items.append(make(title: titleCase(&rng, words: rng.int(1...4)), artist: artist, episodeTitle: nil, seTag: nil,
                              summary: rng.chance(0.85) ? "" : sentence(&rng, chars: rng.int(40...200)), year: year,
                              date: nil, rating: nil, minutes: rng.int(3...7),
                              genres: [rng.pick(musicGenres), "Music Video"], type: .movie, thumb: nil, art: nil,
                              studio: nil, source: .musicVideo, rng: &rng))
        }
        return (items, "movies=\(movieCount) episodes=\(episodeCount) (\(showIndex) shows) musicVideos=\(musicCount)")
    }

    // MARK: - Run

    private static func directorySize(_ url: URL?) -> UInt64 {
        guard let url, let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in e {
            total += UInt64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func mb(_ b: UInt64) -> String { String(format: "%.0f", Double(b) / 1_048_576) }

    func testBigLibraryPipeline() async throws {
        guard let raw = ProcessInfo.processInfo.environment["NOSTALGEX_BIGLIB_N"], let n = Int(raw), n > 0 else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_BIGLIB_N to run the big-library harness")
        }
        let serverID = "4f0c2b9e8a7d6c5b4a39281706f5e4d3c2b1a090"
        let server = AppState.ServerRef(machineIdentifier: serverID, name: "Vault", baseURL: "http://127.0.0.1:9", owned: true, token: "srv")

        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        DailyManifestScheduler.invalidateMemo()
        UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        UserDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles")   // app default: ["nostalgex"]
        defer {
            LibrarySnapshotStore.clear()
            DailyManifestStore.clearAll()
            UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        }

        // A run takes longer than the Apple TV's sleep timer; sleeping kills the runner.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var out: [String] = []
        let rec = Recorder()
        rec.writeTrail("start N=\(n) avail=\(Recorder.availableMB())MB")
        rec.mark("baseline")

        var fixture: (items: [PlexMediaItem], mix: String)? = Self.makeLibrary(count: n, serverID: serverID)
        let mix = fixture!.mix
        let backend = FixtureBackend(serverID: serverID, items: fixture!.items)
        fixture = nil
        rec.mark("fixture(in-memory library)")

        // stdout -> /dev/null for the pipeline, as on a device with no debugger attached.
        // print() still formats every line; only the write is cheap.
        fflush(stdout)
        let savedStdout = dup(STDOUT_FILENO)
        let devnull = open("/dev/null", O_WRONLY)
        dup2(devnull, STDOUT_FILENO)

        LibraryLoadProbe.handler = { rec.mark($0) }
        let store = InMemoryStore()
        var state: AppState? = AppState(credentialStore: store)
        state!.backendOverride = { _ in backend }
        state!.completePlexSignIn(token: "plex-account-token", servers: [server])
        await state!.loadLibrary()
        rec.mark("loadLibrary.return")
        // The snapshot is written on a background queue. Wait for it here, off the main
        // actor, so its memory shows as its own stage and the main-thread pinger keeps
        // measuring whether the write blocks the UI.
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        rec.mark("snapshot.background.done")

        let itemCount = state!.allItems.count
        let channelCount = state!.allChannels.count
        let guideCount = state!.channels.count
        let poolEntries = state!.allChannels.reduce(0) { $0 + $1.itemPool.count }
        let biggestPools = state!.allChannels.sorted { $0.itemPool.count > $1.itemPool.count }.prefix(5)
            .map { "\($0.number):\($0.itemPool.count)" }.joined(separator: " ")
        let errorMessage = state!.errorMessage

        // The guide: TunerView.buildAllSchedules, same calls, same detached task.
        let guideChannels = state!.channels
        let fp = state!.scheduleCredentialFingerprint
        let built = await Task.detached(priority: .userInitiated) { () -> Int in
            var schedules: [Int: ChannelSchedule] = [:]
            for channel in guideChannels {
                if let s = ChannelScheduleBuilder.buildSchedule(for: channel, at: Date(), credentialFingerprint: fp) {
                    schedules[channel.id] = s
                }
            }
            ChannelScheduleBuilder.resolveConflicts(&schedules)
            return schedules.count
        }.value
        rec.mark("guide.buildAllSchedules")

        let snapshotBytes = Self.directorySize(LibrarySnapshotStore.snapshotDirectoryURL)
        let manifestBytes = Self.directorySize(LocalStore.rootDirectory.map { $0.appendingPathComponent("daily_manifests") })

        // Optional: replace the chunked snapshot with a legacy single file, to measure the
        // one-time migration on the next launch. Encoding it here costs what the old save
        // cost, so use it at sizes the host can afford.
        let legacyMode = ProcessInfo.processInfo.environment["NOSTALGEX_BIGLIB_LEGACY"] == "1"
        var legacyBytes: UInt64 = 0
        if legacyMode, let loaded = try LibrarySnapshotStore.loadSnapshot(identity: state!.snapshotIdentitySeed) {
            var legacy = loaded.snapshot
            legacy.schemaVersion = 2
            let data = try JSONEncoder().encode(legacy)
            legacy.allItems = []
            LibrarySnapshotStore.clear()
            try data.write(to: LibrarySnapshotStore.legacySnapshotURL!, options: .atomic)
            legacyBytes = UInt64(data.count)
            rec.mark("legacy.fileWritten")
        }

        // Next launch: drop this session, restore from the snapshot.
        state?.backendOverride = nil
        state = nil
        DailyManifestScheduler.invalidateMemo()
        try? await Task.sleep(nanoseconds: 500_000_000)
        rec.mark("release session")
        let relaunch = AppState(credentialStore: store)
        relaunch.backendOverride = { _ in backend }
        relaunch.completePlexSignIn(token: "plex-account-token", servers: [server])
        let restored = await relaunch.restoreLibraryFromSnapshotIfNeeded()
        rec.mark("relaunch.restoreSnapshot")
        let restoredItems = relaunch.allItems.count
        // A legacy restore re-saves in the chunked format; let that land and measure it.
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        rec.mark("relaunch.pendingSaves")
        let legacyLeft = LibrarySnapshotStore.legacySnapshotURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let chunkedAfter = Self.directorySize(LibrarySnapshotStore.snapshotDirectoryURL)

        LibraryLoadProbe.handler = nil
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(devnull)
        close(savedStdout)
        rec.stop()

        out.append("N=\(n) \(mix)")
        out.append("MemoryLayout<PlexMediaItem>.stride=\(MemoryLayout<PlexMediaItem>.stride)B")
        out.append("items=\(itemCount) allChannels=\(channelCount) guideChannels=\(guideCount) poolEntries=\(poolEntries) biggest=\(biggestPools) schedules=\(built) error=\(errorMessage ?? "nil")")
        out.append("snapshot=\(Self.mb(snapshotBytes))MB (\(snapshotBytes) bytes) manifests=\(Self.mb(manifestBytes))MB restored=\(restored) restoredItems=\(restoredItems)")
        if legacyMode {
            out.append("legacy=\(Self.mb(legacyBytes))MB (\(legacyBytes) bytes, cap \(Self.mb(LibrarySnapshotStore.legacyMaxBytes))MB) legacyFileLeftAfterRestore=\(legacyLeft) chunkedAfterRestore=\(Self.mb(chunkedAfter))MB")
        }
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        out.append(pad("stage", 28) + lpad("ms", 9) + lpad("peakFootMB", 12) + lpad("peakResMB", 11) + lpad("endFootMB", 11) + lpad("mainBlockMs", 13))
        for (row, block) in rec.report() {
            out.append(pad(row.stage, 28) + lpad(String(format: "%.0f", (row.end - row.start) * 1000), 9)
                       + lpad(Self.mb(row.peakFoot), 12) + lpad(Self.mb(row.peakRes), 11)
                       + lpad(Self.mb(row.endFoot), 11) + lpad(String(format: "%.0f", block * 1000), 13))
        }
        let hang = rec.longestHang()
        out.append(String(format: "overallPeakFootprint=%@MB longestMainBlock=%.0fms at t=%.1fs", Self.mb(rec.overallPeakFoot), hang.seconds * 1000, hang.start))
        for line in out { print("[BIGLIB] \(line)") }
        for line in out { rec.writeTrail("[BIGLIB] \(line)") }
        // Parallel test clones do not forward stdout; a host path survives (simulator only).
        if let path = ProcessInfo.processInfo.environment["NOSTALGEX_BIGLIB_OUT"] {
            try? out.map { "[BIGLIB] \($0)" }.joined(separator: "\n").appending("\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(itemCount, n)
        if !legacyMode { XCTAssertTrue(restored) }
    }
}
