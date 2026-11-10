import XCTest
@testable import Nostalgex

/// I-076 (#146): a first setup that is killed part way keeps the sections it finished.
///
/// The rules these hold, in order of how much damage a mistake does:
///  1. The library snapshot is never written from a partial scan, its format does not change,
///     and the kept sections live in their own directory.
///  2. A section is kept only if it was read in full. A section killed mid-write, cancelled mid-fetch,
///     lost, or never reached is not kept, and nothing reads a half-written section back.
///  3. A kept section is reused only when it is young, from this build, from this scan version, and
///     (on Plex) the server's own change counters for it have not moved.
///  4. Disconnect, RESCAN and a finished scan remove what was kept.
@MainActor
final class LibraryScanProgressTests: XCTestCase {

    private var scope: HarnessScope!
    private var savedChunkSize = 0

    override func setUp() async throws {
        try await super.setUp()
        scope = HarnessScope.begin("scan-progress")
        LibraryScanProgressStore.clearAll()
        LibrarySnapshotStore.clear()
        LibraryScanProgressStore.afterChunkWritten = nil
        LibrarySnapshotStore.afterChunkWritten = nil
    }

    override func tearDown() async throws {
        LibraryScanProgressStore.afterChunkWritten = nil
        LibrarySnapshotStore.afterChunkWritten = nil
        LibraryScanProgressStore.waitForPendingWrites()
        LibrarySnapshotStore.waitForPendingSaves()
        LibraryScanProgressStore.clearAll()
        LibrarySnapshotStore.clear()
        scope.end()
        try await super.tearDown()
    }

    // MARK: Fixtures

    private func items(_ section: String, _ n: Int) -> [PlexMediaItem] {
        (0..<n).map { i in
            PlexMediaItem(
                id: "srv:\(section)-\(i)", title: "Movie \(section)-\(i)", artist: nil, episodeTitle: nil, seTag: nil,
                summary: "", year: 1990, originallyAvailableAt: nil, contentRating: "PG", duration: 90 + i % 30,
                ratingKey: "\(section)-\(i)", partKey: "/p/\(section)-\(i)", container: "mkv", videoCodec: "h264",
                audioCodec: "aac", videoProfile: nil, bitrate: nil, genres: ["Drama"], rating: 7, userRating: 0,
                type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: "\(section)\(i)",
                imdbID: nil, librarySource: .movie, serverID: "srv")
        }
    }

    private func checkpoint(build: String = "100", scanVersion: Int = LibrarySnapshotStore.scanFieldsVersion,
                            now: @escaping @Sendable () -> Date = { Date() },
                            identity: String = "plex|srv", server: String = "srv") -> LibraryScanProgressStore.Checkpoint {
        LibraryScanProgressStore.Checkpoint(identity: identity, serverID: server, scanFieldsVersion: scanVersion, build: build, now: now)
    }

    private func sectionDirs() -> [String] {
        guard let dir = LibraryScanProgressStore.directoryURL else { return [] }
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL])?.filter { $0.lastPathComponent == "done.json" }.map(\.path) ?? []
    }

    // MARK: 1. The snapshot is untouched

    func testKeptSectionsAreNotASnapshotAndTheSnapshotFormatIsUnchanged() throws {
        XCTAssertEqual(LibrarySnapshotStore.formatVersion, 3, "no new snapshot format: nothing for an upgrading user to migrate")
        let c = checkpoint()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 20))
        LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertFalse(sectionDirs().isEmpty)
        XCTAssertNil(try LibrarySnapshotStore.loadSnapshot(identity: "plex|srv"),
                     "a kept section never restores as a library")
        XCTAssertNotEqual(LibraryScanProgressStore.directoryName, "library_snapshot")
        let snapshotRoot = try XCTUnwrap(LibrarySnapshotStore.snapshotDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotRoot.path), "recording a section creates no snapshot files")
    }

    func testAnExistingSnapshotIsNotTouchedByKeepingSections() throws {
        try LibrarySnapshotStore.save(identity: "plex|srv", serverName: "S", librarySignature: nil,
                                      lastLoadAtUnix: Int(Date().timeIntervalSince1970), allItems: items("9", 30),
                                      channelConfigChannels: [], allChannels: [], bundles: [], enabledBundleIDs: [],
                                      exclusiveRules: [], discoveredCollections: [])
        let before = try XCTUnwrap(try LibrarySnapshotStore.loadSnapshot(identity: "plex|srv")).snapshot.allItems.map(\.id)
        let c = checkpoint()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 20))
        LibraryScanProgressStore.waitForPendingWrites()
        let after = try XCTUnwrap(try LibrarySnapshotStore.loadSnapshot(identity: "plex|srv")).snapshot.allItems.map(\.id)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.count, 30)
    }

    // MARK: 2. Only whole sections are kept

    func testAFinishedSectionComesBackOnTheNextLaunch() throws {
        let one = items("1", 25), two = items("2", 12)
        let c = checkpoint()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 3, items: one)
        c.record(sectionKey: "2", sectionTitle: "Docs", signature: nil, skippedNoRuntime: 0, items: two)
        LibraryScanProgressStore.waitForPendingWrites()

        let relaunched = checkpoint()
        let a = try XCTUnwrap(relaunched.resumable(sectionKey: "1", signature: nil))
        XCTAssertEqual(a.items.map(\.id), one.map(\.id), "same items, same order")
        XCTAssertEqual(a.items.first?.tmdbID, one.first?.tmdbID)
        XCTAssertEqual(a.skippedNoRuntime, 3, "the NO RUNTIME count rides along")
        XCTAssertEqual(try XCTUnwrap(relaunched.resumable(sectionKey: "2", signature: nil)).items.map(\.id), two.map(\.id))
        XCTAssertNil(relaunched.resumable(sectionKey: "3", signature: nil), "a section that was never kept is read from the server")
        XCTAssertEqual(relaunched.resumedSectionKeys, ["1", "2"])
    }

    func testAKillInTheMiddleOfASectionKeepsTheFinishedOnesAndNeverTheHalfWrittenOne() throws {
        // Three sections; the third is killed after its second file, the way jetsam would.
        let sizes = ["1": 17, "2": 9, "3": 45]
        let c = checkpoint()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", sizes["1"]!))
        c.record(sectionKey: "2", sectionTitle: "Docs", signature: nil, skippedNoRuntime: 0, items: items("2", sizes["2"]!))
        LibraryScanProgressStore.waitForPendingWrites()

        LibraryScanProgressStore.afterChunkWritten = { index in
            if index == 1 { throw NSError(domain: "kill", code: 9) }
        }
        let savedChunk = LibraryScanProgressStore.chunkSize
        LibraryScanProgressStore.chunkSize = 10
        defer { LibraryScanProgressStore.chunkSize = savedChunk }
        c.record(sectionKey: "3", sectionTitle: "Classics", signature: nil, skippedNoRuntime: 0, items: items("3", sizes["3"]!))
        LibraryScanProgressStore.waitForPendingWrites()
        LibraryScanProgressStore.afterChunkWritten = nil

        let relaunched = checkpoint()
        XCTAssertEqual(try XCTUnwrap(relaunched.resumable(sectionKey: "1", signature: nil)).items.count, 17)
        XCTAssertEqual(try XCTUnwrap(relaunched.resumable(sectionKey: "2", signature: nil)).items.count, 9)
        XCTAssertNil(relaunched.resumable(sectionKey: "3", signature: nil), "the section killed mid-write is not a section")
        XCTAssertEqual(sectionDirs().count, 2, "and its files are gone")
        XCTAssertEqual(relaunched.resumedSectionKeys, ["1", "2"])
    }

    func testTheFilesOfAKilledWriteWithNoMarkerAreIgnoredAndSweptEvenWithoutAKill() throws {
        let c = checkpoint()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 10))
        LibraryScanProgressStore.waitForPendingWrites()
        // Take the marker away: what is left is exactly a write that died before its last step.
        let marker = try XCTUnwrap(sectionDirs().first)
        try FileManager.default.removeItem(atPath: marker)
        XCTAssertNil(checkpoint().resumable(sectionKey: "1", signature: nil))
        XCTAssertTrue(sectionDirs().isEmpty)
    }

    func testAnUnreadableOrShortFileDropsTheSectionInsteadOfBuildingAShortGuide() throws {
        for damage in ["truncate", "missing", "garbage"] {
            LibraryScanProgressStore.clearAll()
            let c = checkpoint()
            c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 30))
            LibraryScanProgressStore.waitForPendingWrites()
            let marker = URL(fileURLWithPath: try XCTUnwrap(sectionDirs().first))
            let chunk = marker.deletingLastPathComponent().appendingPathComponent("items-0000.json")
            switch damage {
            case "truncate": try Data(contentsOf: chunk).prefix(200).write(to: chunk)
            case "missing": try FileManager.default.removeItem(at: chunk)
            default: try Data("not json".utf8).write(to: chunk)
            }
            XCTAssertNil(checkpoint().resumable(sectionKey: "1", signature: nil), damage)
        }
    }

    // MARK: 3. When a kept section may be reused

    func testAgeAndTheServersChangeCounters() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Int) -> @Sendable () -> Date { { t0.addingTimeInterval(TimeInterval(s)) } }
        func keep(signature: String?) {
            LibraryScanProgressStore.clearAll()
            let c = checkpoint(now: at(0))
            c.record(sectionKey: "1", sectionTitle: "Movies", signature: signature, skippedNoRuntime: 0, items: items("1", 10))
            LibraryScanProgressStore.waitForPendingWrites()
        }
        // No counters (Jellyfin, Emby): one hour.
        keep(signature: nil)
        XCTAssertNotNil(checkpoint(now: at(3_599)).resumable(sectionKey: "1", signature: nil))
        keep(signature: nil)
        XCTAssertNil(checkpoint(now: at(3_601)).resumable(sectionKey: "1", signature: nil), "an hour old with nothing to confirm it: read again")
        // Plex, counters unchanged: six hours.
        keep(signature: "u5/c9")
        XCTAssertNotNil(checkpoint(now: at(6 * 3600 - 1)).resumable(sectionKey: "1", signature: "u5/c9"))
        keep(signature: "u5/c9")
        XCTAssertNil(checkpoint(now: at(6 * 3600 + 1)).resumable(sectionKey: "1", signature: "u5/c9"))
        // Plex, counters moved since: never.
        keep(signature: "u5/c9")
        XCTAssertNil(checkpoint(now: at(60)).resumable(sectionKey: "1", signature: "u5/c10"), "the section changed on the server")
        // A clock set back is not trusted.
        keep(signature: nil)
        XCTAssertNil(checkpoint(now: at(-5)).resumable(sectionKey: "1", signature: nil))
    }

    func testAnotherBuildAnotherScanVersionOrAnotherServerNeverResumes() throws {
        let c = checkpoint(build: "100")
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 10))
        LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertNil(checkpoint(build: "101").resumable(sectionKey: "1", signature: nil), "an upgrade starts the scan over")

        LibraryScanProgressStore.clearAll()
        checkpoint(build: "100", scanVersion: 1).record(sectionKey: "1", sectionTitle: "M", signature: nil, skippedNoRuntime: 0, items: items("1", 10))
        LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertNil(checkpoint(build: "100", scanVersion: 2).resumable(sectionKey: "1", signature: nil), "items read by an older scan request are not merged")

        LibraryScanProgressStore.clearAll()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 10))
        LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertNil(checkpoint(server: "other").resumable(sectionKey: "1", signature: nil))
        XCTAssertNil(checkpoint(identity: "plex|someone-else").resumable(sectionKey: "1", signature: nil))
        XCTAssertNotNil(checkpoint().resumable(sectionKey: "1", signature: nil), "the same library still does")
    }

    // MARK: 4. When they go

    func testClearAllAndSnapshotClearRemoveThem() throws {
        let c = checkpoint()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 10))
        LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertFalse(sectionDirs().isEmpty)
        LibrarySnapshotStore.clear()   // what Disconnect, START OVER and RESCAN LIBRARY all call
        XCTAssertTrue(sectionDirs().isEmpty)
        XCTAssertNil(checkpoint().resumable(sectionKey: "1", signature: nil))
    }

    func testAWriteStillRunningWhenTheUserDisconnectsNeverCommits() throws {
        let saved = LibraryScanProgressStore.chunkSize
        LibraryScanProgressStore.chunkSize = 10
        defer { LibraryScanProgressStore.chunkSize = saved }
        LibraryScanProgressStore.afterChunkWritten = { index in
            if index == 0 { LibraryScanProgressStore.clearAll() }   // Disconnect lands between two files
        }
        checkpoint().record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 35))
        LibraryScanProgressStore.waitForPendingWrites()
        LibraryScanProgressStore.afterChunkWritten = nil
        XCTAssertTrue(sectionDirs().isEmpty, "the old library's section did not come back after Disconnect")
        XCTAssertNil(checkpoint().resumable(sectionKey: "1", signature: nil))
    }

    func testTheKeptSectionsGoOnlyWhenTheSnapshotHasCommitted() throws {
        let c = checkpoint()
        c.record(sectionKey: "1", sectionTitle: "Movies", signature: nil, skippedNoRuntime: 0, items: items("1", 10))
        LibraryScanProgressStore.waitForPendingWrites()

        func payload() -> LibrarySnapshotStore.Payload {
            LibrarySnapshotStore.makePayload(identity: "plex|srv", serverName: "S", librarySignature: nil,
                lastLoadAtUnix: Int(Date().timeIntervalSince1970), allItems: items("1", 10), channelConfigChannels: [],
                allChannels: [], bundles: [], enabledBundleIDs: [], exclusiveRules: [], discoveredCollections: [])
        }
        // A snapshot save killed before it commits must leave them.
        LibrarySnapshotStore.afterChunkWritten = { _ in throw NSError(domain: "kill", code: 9) }
        LibrarySnapshotStore.saveInBackground(payload(), onCommit: { LibraryScanProgressStore.clearAll() })
        LibrarySnapshotStore.waitForPendingSaves()
        LibrarySnapshotStore.afterChunkWritten = nil
        XCTAssertFalse(sectionDirs().isEmpty, "no snapshot, so the kept sections are all there is")
        XCTAssertNil(try LibrarySnapshotStore.loadSnapshot(identity: "plex|srv"))

        // One that commits takes them with it.
        LibrarySnapshotStore.saveInBackground(payload(), onCommit: { LibraryScanProgressStore.clearAll() })
        LibrarySnapshotStore.waitForPendingSaves()
        XCTAssertTrue(sectionDirs().isEmpty)
        XCTAssertNotNil(try LibrarySnapshotStore.loadSnapshot(identity: "plex|srv"))
    }
}
