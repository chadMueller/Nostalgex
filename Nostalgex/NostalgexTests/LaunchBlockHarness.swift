import XCTest
import Darwin
import UIKit
@testable import Nostalgex

/// 2026-11-10 report: opening the app on the living room Apple TV stalls the remote and the picture for about 40 s,
/// twice in a row. The server log shows the TV tuned the last channel within seconds of each launch and then went
/// quiet until the library snapshot had been rewritten; the enrichment cache was rewritten 1 s after the second
/// launch. That is the path `refillEnrichmentAfterRestoreIfNeeded` takes when the 7 day enrichment cache is missing
/// or past its TTL: `enrichItems`, then on the MAIN ACTOR `refilterChannelsWithEnrichment`, `rebuildFoundFranchises`,
/// `materializeDynamicChannels`, `applyBundleFilter`, `saveLibrarySnapshotIfNeeded` (AppState+Library.swift:~820).
///
/// This times, in a fresh process each time, what a launch does on the main actor with a library shaped like that
/// TV's (1,793 movies with enrichment rows, 8,900 episodes; the snapshot on the TV is 14.7 MB): the snapshot restore
/// (decode off-main, apply on-main, open on last channel) and then that post-enrichment sequence step by step,
/// with a main-thread pinger recording every block over 250 ms.
///
/// Not measured here: the Keychain read (the harness keeps credentials in memory), PreferenceSync (in-memory store),
/// the enrichment network pass itself (it would write to the shared Supabase table; the rows are seeded instead).
///
/// Off by default. Two steps, each its own process:
///
///     TEST_RUNNER_NOSTALGEX_LAUNCHBLK=setup  xcodebuild test ... -only-testing:NostalgexTests/LaunchBlockHarness
///     TEST_RUNNER_NOSTALGEX_LAUNCHBLK=launch TEST_RUNNER_NOSTALGEX_LAUNCHBLK_OUT=/path/out.txt xcodebuild test-without-building ...
///
/// `setup` scans the fixture into the harness root (snapshot, enrichment cache, remembered channel) and keeps it;
/// every `launch` is a cold process that starts from that root, like opening the app, and rewrites the snapshot as
/// the launch does. The harness root is `Caches/NostalgexHarness/launchblk` in the test host's own container.
@MainActor
final class LaunchBlockHarness: XCTestCase {

    private final class FixtureBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        private let lock = NSLock()
        private var items: [PlexMediaItem]?
        var authHeaders: [String: String] { [:] }
        init(serverID: String, items: [PlexMediaItem]?) { self.serverID = serverID; self.items = items }
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

    /// Pings the main queue every 10 ms from a background thread and keeps every wait over 250 ms.
    private final class HangWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var hangs: [(start: Double, seconds: Double)] = []
        let t0 = CFAbsoluteTimeGetCurrent()
        func now() -> Double { CFAbsoluteTimeGetCurrent() - t0 }
        func start() {
            let pinger = Thread { [self] in
                while true {
                    lock.lock(); let go = running; lock.unlock()
                    if !go { break }
                    let sent = now()
                    let sem = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { sem.signal() }
                    sem.wait()
                    let got = now()
                    if got - sent > 0.25 { lock.lock(); hangs.append((sent, got - sent)); lock.unlock() }
                    usleep(10_000)
                }
            }
            pinger.qualityOfService = .userInteractive
            pinger.start()
        }
        func stop() { lock.lock(); running = false; lock.unlock() }
    }

    private static func fixture(serverID: String) -> (items: [PlexMediaItem], enrichments: [MediaEnrichment]) {
        let movies = MovieLibraryScaleHarness.makeMovieLibrary(count: 1_793, serverID: serverID)
        let all = BigLibraryHarness.makeLibrary(count: 15_000, serverID: serverID).items
        let episodes = Array(all.filter { $0.type == .episode }.prefix(8_900))
        return (movies.items + episodes, movies.enrichments)
    }

    private func ms(_ block: () -> Void) -> Double {
        let t = CFAbsoluteTimeGetCurrent(); block(); return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }

    func testLaunchBlocks() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["NOSTALGEX_LAUNCHBLK"], ["setup", "launch"].contains(mode) else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_LAUNCHBLK=setup or launch")
        }
        if !HarnessIsolation.isActive { HarnessIsolation.activate(name: "launchblk") }
        let serverID = "4f0c2b9e8a7d6c5b4a39281706f5e4d3c2b1a090"
        let server = AppState.ServerRef(machineIdentifier: serverID, name: "Vault", baseURL: "http://127.0.0.1:9", owned: true, token: "srv")
        // Setup chooses the lineup (every package on with NOSTALGEX_LAUNCHBLK_ALLBUNDLES=1, else the app's default);
        // a launch reads whatever setup left, as a launch reads what the viewer chose.
        if mode == "setup" {
            if env["NOSTALGEX_LAUNCHBLK_ALLBUNDLES"] == "1" {
                AppDefaults.standard.set(ChannelConfigLoader.loadBundled().bundles.map(\.id), forKey: "nostalgex_enabled_bundles")
            } else {
                AppDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles")
            }
        }
        var out: [String] = []
        func emit(_ s: String) { out.append(s); print("[LAUNCHBLK] \(s)") }

        if mode == "setup" {
            LibrarySnapshotStore.clear(); DailyManifestStore.clearAll(); EnrichmentCacheStore.clear()
            let fx = Self.fixture(serverID: serverID)
            let state = AppState(credentialStore: InMemoryStore())
            state.enrichmentService.seedCache(fx.enrichments)
            state.backendOverride = { _ in FixtureBackend(serverID: serverID, items: fx.items) }
            state.completePlexSignIn(token: "plex-account-token", servers: [server])
            await state.loadLibrary()
            await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
            let bytes = (try? EnrichmentCacheStore.save(state.enrichmentService.cache)) ?? 0
            if let ch = state.allChannels.first(where: { $0.id == 105 }) ?? state.channels.first { state.rememberLaunchChannel(ch) }
            emit("setup: items=\(state.allItems.count) channels=\(state.allChannels.count) guide=\(state.channels.count) enrichmentCache=\(bytes / 1024) KB snapshot=\(Self.dirKB(LibrarySnapshotStore.snapshotDirectoryURL)) KB root=\(HarnessIsolation.root?.path ?? "none")")
            if let path = env["NOSTALGEX_LAUNCHBLK_OUT"] {
                try? out.map { "[LAUNCHBLK] \($0)" }.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            return
        }

        // launch: a new process, a new AppState, the stores as the last run left them.
        let watch = HangWatch(); watch.start()
        let state = AppState(credentialStore: InMemoryStore())
        state.backendOverride = { _ in FixtureBackend(serverID: serverID, items: nil) }
        state.completePlexSignIn(token: "plex-account-token", servers: [server])
        var steps: [(String, Double, Double)] = []   // name, ms, start offset
        func step(_ name: String, _ block: () -> Void) {
            let at = watch.now(); let t = ms(block); steps.append((name, t, at)); emit(String(format: "%-46@ %9.1f ms (main actor, blocking)", name as NSString, t))
        }
        step("enrichment cache load (disk, 1 MB)") { _ = state.enrichmentService.loadDiskCache() }

        var marks: [(Double, String)] = []
        LibraryLoadProbe.handler = { marks.append((watch.now(), $0)) }
        let tRestore = watch.now(); let c0 = CFAbsoluteTimeGetCurrent()
        let restored = await state.restoreLibraryFromSnapshotIfNeeded()
        let restoreMs = (CFAbsoluteTimeGetCurrent() - c0) * 1000
        LibraryLoadProbe.handler = nil
        emit(String(format: "restoreLibraryFromSnapshotIfNeeded (whole, decode is off-main) %9.1f ms restored=%@ items=%d channels=%d", restoreMs, restored ? "yes" : "NO", state.allItems.count, state.channels.count))
        for (t, m) in marks { emit(String(format: "   probe %.3f s after restore start: %@", t - tRestore, m)) }
        emit("   current channel after restore: \(state.currentChannel.map { "CH \($0.number) \($0.name)" } ?? "none") (open on last channel)")

        // What the refill Task runs once enrichItems lands (AppState+Library.swift ~822 to 830). With
        // NOSTALGEX_LAUNCHBLK_OFFMAIN=1 it is the off-main version the app now runs: the filter pass and the franchise
        // builder in a background task, each applied on the main actor in one step. Without it, the old synchronous
        // calls, for the before numbers.
        if env["NOSTALGEX_LAUNCHBLK_OFFMAIN"] == "1" {
            let c = CFAbsoluteTimeGetCurrent()
            let applied = await state.refilterChannelsWithEnrichmentOffMain()
            emit(String(format: "refilterChannelsWithEnrichmentOffMain (wall clock, work is off-main) %9.1f ms applied=%@", (CFAbsoluteTimeGetCurrent() - c) * 1000, applied ? "yes" : "NO"))
            let c2 = CFAbsoluteTimeGetCurrent()
            await state.rebuildFoundFranchisesOffMain()
            emit(String(format: "rebuildFoundFranchisesOffMain (wall clock, work is off-main) %9.1f ms", (CFAbsoluteTimeGetCurrent() - c2) * 1000))
        } else {
            step("refilterChannelsWithEnrichment (pools, audit)") { state.refilterChannelsWithEnrichment() }
            step("rebuildFoundFranchises") { state.rebuildFoundFranchises() }
        }
        step("materializeDynamicChannels") { state.materializeDynamicChannels() }
        step("applyBundleFilter") { state.applyBundleFilter() }
        step("saveLibrarySnapshotIfNeeded (capture only)") { state.saveLibrarySnapshotIfNeeded() }
        let tw = CFAbsoluteTimeGetCurrent()
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        emit(String(format: "snapshot write after capture (background queue): %.1f ms", (CFAbsoluteTimeGetCurrent() - tw) * 1000))
        // The result, as a fixed-width fingerprint so a before run and an after run can be compared: every channel's
        // id and pool in order, the guide's order, and the found franchises (FNV-1a, not the per-process String hash).
        func fnv(_ strings: [String]) -> UInt64 {
            var h: UInt64 = 14695981039346656037
            for str in strings { for byte in str.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }; h = (h ^ 0x1F) &* 1099511628211 }
            return h
        }
        let poolHash = fnv(state.allChannels.map { "\($0.id):\($0.itemPool.map(\.id).joined(separator: ","))" })
        let guideHash = fnv(state.channels.map { "\($0.id)" })
        let franchiseHash = fnv(state.foundFranchises.map { "\($0.id):\($0.name):\($0.items.map(\.id).joined(separator: ","))" })
        emit("RESULT allChannels=\(state.allChannels.count) guide=\(state.channels.count) found=\(state.foundFranchises.count) poolHash=\(String(poolHash, radix: 16)) guideHash=\(String(guideHash, radix: 16)) franchiseHash=\(String(franchiseHash, radix: 16))")
        watch.stop()
        let total = steps.reduce(0) { $0 + $1.1 }
        emit(String(format: "SUM of main-actor steps after enrichment lands: %.1f ms", total - (steps.first?.1 ?? 0)))
        for h in watch.hangs { emit(String(format: "HANG >250ms: %.2f s starting at t=%.2f s", h.seconds, h.start)) }
        emit("hangs over 250 ms: \(watch.hangs.count), longest \(String(format: "%.0f", (watch.hangs.map(\.seconds).max() ?? 0) * 1000)) ms")
        if let path = env["NOSTALGEX_LAUNCHBLK_OUT"] {
            try? out.map { "[LAUNCHBLK] \($0)" }.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func dirKB(_ url: URL?) -> Int {
        guard let url, let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total / 1024
    }
}
