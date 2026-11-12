import XCTest
import Darwin
import os
import UIKit
@testable import Nostalgex

/// I-076 (#146): each library section is written to `library_scan_progress/` as soon as it has been read, on a
/// background queue. The queued write holds that section's items array (and encodes it in 10k-item chunks) until it
/// has run, so the scan's peak memory can be up to one section higher than without it. `BigLibraryHarness` cannot
/// show that: its fixture backend only implements the plain `loadLibrary`, and the protocol's default for the
/// checkpoint version ignores the checkpoint, so nothing is ever queued.
///
/// This harness feeds the REAL `AppState.loadLibrary` through a backend that behaves like `PlexAPIService`: it hands
/// the library over one section at a time and calls `checkpoint.record(...)` after each, with the checkpoint switch on
/// or off. Same library, same recorder (`BigLibraryHarness.Recorder`: phys_footprint, resident size, main-thread
/// stalls, a trail file flushed every 2 s so a jetsam kill still leaves the last reading).
///
/// Off by default. One size and one mode per process:
///
///     TEST_RUNNER_NOSTALGEX_SCANCP_N=65000 TEST_RUNNER_NOSTALGEX_SCANCP_MODE=on \
///     TEST_RUNNER_NOSTALGEX_SCANCP_SECTIONS=3 TEST_RUNNER_NOSTALGEX_SCANCP_OUT=/path/out.txt \
///       xcodebuild test ... -only-testing:NostalgexTests/ScanCheckpointMemoryHarness
///
/// MODE is `on` (sections recorded, as the app does) or `off` (nothing recorded). SECTIONS splits the library into
/// that many sections, 60% / 25% / 15% for 3, one section of everything for 1 (the worst case: the reporter's
/// single 105,000 movie section). On a device also set `TEST_RUNNER_NOSTALGEX_HARNESS_ROOT=<name>` so the host app's own
/// launch is isolated; the trail is then `Library/Caches/NostalgexHarness/<name>/biglib-trail.txt` in the app container.
/// The app's real stores are fingerprinted before and after (`RealStoreFingerprint`) and a difference fails the run.
@MainActor
final class ScanCheckpointMemoryHarness: XCTestCase {

    private final class SectionedBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        private let lock = NSLock()
        private var sections: [(key: String, title: String, items: [PlexMediaItem])]
        private let record: Bool
        private let onSection: @Sendable (String) -> Void
        var authHeaders: [String: String] { [:] }

        init(serverID: String, sections: [(key: String, title: String, items: [PlexMediaItem])], record: Bool,
             onSection: @escaping @Sendable (String) -> Void) {
            self.serverID = serverID; self.sections = sections; self.record = record; self.onSection = onSection
        }

        func testConnection() async throws -> String { serverID }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress?) async throws -> [PlexMediaItem] {
            try await loadLibrary(excludedSectionKeys: excludedSectionKeys, checkpoint: nil, progress: progress)
        }
        /// Like `PlexAPIService.loadLibrary`: append the section to the running list, record the section, let go of it.
        func loadLibrary(excludedSectionKeys: Set<String>, checkpoint: LibraryScanProgressStore.Checkpoint?,
                         progress: LoadProgress?) async throws -> [PlexMediaItem] {
            lock.lock(); var pending = sections; sections = []; lock.unlock()
            var all: [PlexMediaItem] = []
            for i in pending.indices {
                let section = pending[i]
                pending[i].items = []                     // the fixture lets go, as a fetched page array is
                let items = section.items
                all.append(contentsOf: items)
                if record {
                    checkpoint?.record(sectionKey: section.key, sectionTitle: section.title, signature: nil,
                                       skippedNoRuntime: 0, items: items)
                }
                onSection("section \(section.key) read+recorded(\(items.count))")
            }
            return all
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

    private static func mb(_ b: UInt64) -> String { String(format: "%.0f", Double(b) / 1_048_576) }

    private static func directorySize(_ url: URL?) -> UInt64 {
        guard let url, let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in e { total += UInt64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func testScanCheckpointMemory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["NOSTALGEX_SCANCP_N"], let n = Int(raw), n > 0 else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_SCANCP_N to run the scan-checkpoint memory harness")
        }
        let record = (env["NOSTALGEX_SCANCP_MODE"] ?? "on") != "off"
        let sectionCount = Int(env["NOSTALGEX_SCANCP_SECTIONS"] ?? "3") ?? 3

        let realBefore = RealStoreFingerprint.capture()
        let isolation = HarnessScope.begin("scancp")
        defer { isolation.end() }
        let serverID = "4f0c2b9e8a7d6c5b4a39281706f5e4d3c2b1a090"
        let server = AppState.ServerRef(machineIdentifier: serverID, name: "Vault", baseURL: "http://127.0.0.1:9", owned: true, token: "srv")

        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        DailyManifestScheduler.invalidateMemo()
        LibraryScanProgressStore.clearAll()
        AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        AppDefaults.standard.removeObject(forKey: "nostalgex_enabled_bundles")
        defer {
            LibrarySnapshotStore.clear()
            DailyManifestStore.clearAll()
            LibraryScanProgressStore.clearAll()
            AppDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var out: [String] = []
        let rec = BigLibraryHarness.Recorder()
        rec.writeTrail("start N=\(n) mode=\(record ? "on" : "off") sections=\(sectionCount) avail=\(BigLibraryHarness.Recorder.availableMB())MB root=\(HarnessIsolation.root?.lastPathComponent ?? "none")")
        rec.mark("baseline")

        var fixture: (items: [PlexMediaItem], mix: String)? = BigLibraryHarness.makeLibrary(count: n, serverID: serverID)
        let mix = fixture!.mix
        var sections: [(key: String, title: String, items: [PlexMediaItem])] = []
        let fractions: [Double] = sectionCount == 1 ? [1.0] : [0.60, 0.25, 0.15]
        var start = 0
        for (i, f) in fractions.enumerated() {
            let end = i == fractions.count - 1 ? fixture!.items.count : min(fixture!.items.count, start + Int(Double(n) * f))
            sections.append((key: "\(i + 1)", title: "Section \(i + 1)", items: Array(fixture!.items[start..<end])))
            start = end
        }
        fixture = nil
        let backend = SectionedBackend(serverID: serverID, sections: sections, record: record) { rec.mark($0) }
        sections = []
        rec.mark("fixture(in-memory library)")

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
        // Where the queued section writes stand when the load has returned: bytes on disk, then wait for them.
        let keptAtReturn = Self.directorySize(LibraryScanProgressStore.directoryURL)
        let tDrain = CFAbsoluteTimeGetCurrent()
        await Task.detached { LibraryScanProgressStore.waitForPendingWrites() }.value
        let drainSeconds = CFAbsoluteTimeGetCurrent() - tDrain
        rec.mark("scanprogress.writes.done")
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        rec.mark("snapshot.background.done")

        let itemCount = state!.allItems.count
        let errorMessage = state!.errorMessage
        let keptAfterCommit = Self.directorySize(LibraryScanProgressStore.directoryURL)
        state = nil

        LibraryLoadProbe.handler = nil
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(devnull)
        close(savedStdout)
        rec.stop()

        let realAfter = RealStoreFingerprint.capture()
        let diffs = realBefore.differences(from: realAfter)

        out.append("N=\(n) mode=\(record ? "on" : "off") sections=\(sectionCount) \(mix)")
        out.append("MemoryLayout<PlexMediaItem>.stride=\(MemoryLayout<PlexMediaItem>.stride)B items=\(itemCount) error=\(errorMessage ?? "nil")")
        out.append("scan-progress dir at loadLibrary.return=\(Self.mb(keptAtReturn))MB, after the snapshot committed=\(Self.mb(keptAfterCommit))MB; waiting for the queued writes after the return took \(String(format: "%.1f", drainSeconds)) s")
        out.append("real stores: before [\(realBefore.summary)] after [\(realAfter.summary)] appDifferences=\(diffs.app.count) otherDifferences=\(diffs.other.count)")
        for d in diffs.app { out.append("  APP DIFFERENCE: \(d)") }
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        out.append(pad("stage", 40) + lpad("ms", 9) + lpad("peakFootMB", 12) + lpad("peakResMB", 11) + lpad("endFootMB", 11) + lpad("mainBlockMs", 13))
        for (row, block) in rec.report() {
            out.append(pad(row.stage, 40) + lpad(String(format: "%.0f", (row.end - row.start) * 1000), 9)
                       + lpad(Self.mb(row.peakFoot), 12) + lpad(Self.mb(row.peakRes), 11)
                       + lpad(Self.mb(row.endFoot), 11) + lpad(String(format: "%.0f", block * 1000), 13))
        }
        let hang = rec.longestHang()
        out.append(String(format: "overallPeakFootprint=%@MB longestMainBlock=%.0fms at t=%.1fs availableAtEnd=%dMB",
                          Self.mb(rec.overallPeakFoot), hang.seconds * 1000, hang.start, BigLibraryHarness.Recorder.availableMB()))
        out.append("DONE")
        for line in out { print("[SCANCP] \(line)") }
        for line in out { rec.writeTrail("[SCANCP] \(line)") }
        if let path = env["NOSTALGEX_SCANCP_OUT"] {
            try? out.map { "[SCANCP] \($0)" }.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(itemCount, n)
        XCTAssertTrue(diffs.app.isEmpty, "the run changed the app's real stores: \(diffs.app)")
    }
}
