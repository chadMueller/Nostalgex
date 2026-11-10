import XCTest
@testable import Nostalgex

/// I-076 (#146), through the real scan code: Plex, Jellyfin and Emby each read three movie
/// sections from a loopback server. The first run is stopped while the third section is still
/// being read (what a kill does to the kept files, and what Stop Waiting does to the scan). The
/// second run, a new checkpoint on the same library the way a relaunch makes one, must not ask the
/// server for the sections the first run finished, and must end with exactly the library a scan
/// from nothing gives.
@MainActor
final class LibraryScanResumeTests: XCTestCase {

    private static let counts = ["1": 300, "2": 200, "3": 150]
    private static let titles = ["1": "Movies", "2": "Documentaries", "3": "Classics"]
    private static let total = 650

    private var scope: HarnessScope!

    override func setUp() async throws {
        try await super.setUp()
        scope = HarnessScope.begin("scan-resume")
        LibraryScanProgressStore.clearAll()
        LibrarySnapshotStore.clear()
    }

    override func tearDown() async throws {
        LibraryScanProgressStore.waitForPendingWrites()
        LibrarySnapshotStore.waitForPendingSaves()
        LibraryScanProgressStore.clearAll()
        LibrarySnapshotStore.clear()
        scope.end()
        try await super.tearDown()
    }

    // MARK: Fake servers

    private enum Backend: String, CaseIterable { case plex, jellyfin, emby }

    /// State a route can read while the test changes it between runs.
    private final class Mode: @unchecked Sendable {
        private let lock = NSLock()
        private var hung: Set<String> = []
        private var lost: Set<String> = []
        func set(hung: Set<String> = [], lost: Set<String> = []) { lock.lock(); self.hung = hung; self.lost = lost; lock.unlock() }
        func isHung(_ k: String) -> Bool { lock.lock(); defer { lock.unlock() }; return hung.contains(k) }
        func isLost(_ k: String) -> Bool { lock.lock(); defer { lock.unlock() }; return lost.contains(k) }
    }

    private func server(_ backend: Backend, mode: Mode) throws -> LoopbackJSONServer {
        switch backend {
        case .plex:
            return try LoopbackJSONServer { path, query in
                let specs = ["1", "2", "3"].map {
                    StopWaitingHarnessTests.SectionSpec(key: $0, title: Self.titles[$0]!, type: "movie", count: Self.counts[$0]!,
                                                        episodesPerShow: 0, hangFromPage: mode.isHung($0) ? 0 : nil, delayMs: 0)
                }
                let parts = path.split(separator: "/")
                if parts.count == 4, mode.isLost(String(parts[2])) { return nil }
                switch StopWaitingHarnessTests.plexReply(path: path, query: query, sections: specs) {
                case .json(let obj, let delay): return LoopbackReply(delayMs: delay, body: obj)
                case .hang: return LoopbackReply(delayMs: 60_000, body: [:])
                case .notFound: return nil
                }
            }
        case .jellyfin, .emby:
            return try LoopbackJSONServer { path, query in
                if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
                    let views = ["1", "2", "3"].map { ["Id": $0, "Name": Self.titles[$0]!, "CollectionType": "movies"] }
                    return LoopbackReply(delayMs: 0, body: ["Items": views, "TotalRecordCount": 3])
                }
                guard path.hasSuffix("/Items"), let parent = query["ParentId"], let total = Self.counts[parent] else { return nil }
                if mode.isLost(parent) { return nil }
                let start = Int(query["StartIndex"] ?? "0") ?? 0
                let limit = Int(query["Limit"] ?? "200") ?? 200
                let page = (start ..< min(start + limit, total)).map { i -> [String: Any] in
                    // Every 50th film has no runtime, so the NO RUNTIME count has something to carry.
                    let ticks = i % 50 == 0 ? 0 : Int64(90 + i % 60) * 60 * 10_000_000
                    return ["Id": "\(parent)-\(i)", "Name": "Movie \(parent)-\(i)", "Type": "Movie", "RunTimeTicks": ticks,
                            "Genres": ["Drama"], "ProviderIds": ["Tmdb": "\(parent)\(10_000 + i)"],
                            "MediaSources": [["Id": "ms\(parent)-\(i)", "Container": "mkv", "RunTimeTicks": ticks]]]
                }
                return LoopbackReply(delayMs: mode.isHung(parent) ? 60_000 : 0, body: ["Items": page, "TotalRecordCount": total])
            }
        }
    }

    private func service(_ backend: Backend, _ server: LoopbackJSONServer) -> any MediaBackend {
        switch backend {
        case .plex: return PlexAPIService(serverURL: server.url, token: "t", serverID: "resume-srv")
        case .jellyfin: return JellyfinAPIService(serverURL: server.url, accessToken: "t", userId: "u")
        case .emby: return EmbyAPIService(serverURL: server.url, accessToken: "t", userId: "u")
        }
    }

    /// Which section a request was for, nil for the section list and anything else.
    private func section(of request: (path: String, query: [String: String]), _ backend: Backend) -> String? {
        switch backend {
        case .plex:
            let parts = request.path.split(separator: "/")
            return parts.count == 4 && parts[1] == "sections" && parts[3] == "all" ? String(parts[2]) : nil
        default:
            return request.path.hasSuffix("/Items") ? request.query["ParentId"] : nil
        }
    }

    private func checkpoint(_ backend: Backend, serverID: String) -> LibraryScanProgressStore.Checkpoint {
        LibraryScanProgressStore.Checkpoint(identity: "\(backend.rawValue)|resume-test", serverID: serverID,
                                            scanFieldsVersion: LibrarySnapshotStore.scanFieldsVersion, build: "100")
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    // MARK: A scan stopped inside its third section, then run again

    func testASecondRunReadsOnlyTheSectionTheFirstOneDidNotFinish() async throws {
        for backend in Backend.allCases {
            LibraryScanProgressStore.clearAll()
            // The answer to compare with: a scan from nothing, no checkpoint.
            let reference = Mode()
            reference.set()
            let refServer = try server(backend, mode: reference)
            try await refServer.start()
            let refService = service(backend, refServer)
            let expected = try await refService.loadLibrary(excludedSectionKeys: [], progress: nil)
            let expectedSkips = refService.skippedNoRuntime
            refServer.stop()
            XCTAssertEqual(expected.count, backend == .plex ? Self.total : Self.total - (6 + 4 + 3), "\(backend): reference scan")

            // Run 1: section 3 never answers; it is stopped while that request is out.
            let mode1 = Mode(); mode1.set(hung: ["3"])
            let s1 = try server(backend, mode: mode1)
            try await s1.start()
            let svc1 = service(backend, s1)
            let first = checkpoint(backend, serverID: svc1.serverID)
            let task = Task { () -> Result<[PlexMediaItem], Error> in
                do { return .success(try await svc1.loadLibrary(excludedSectionKeys: [], checkpoint: first, progress: nil)) }
                catch { return .failure(error) }
            }
            await waitFor { s1.requests.contains { self.section(of: $0, backend) == "3" } }
            XCTAssertTrue(s1.requests.contains { section(of: $0, backend) == "3" }, "\(backend): the scan reached section 3")
            task.cancel()
            let stopped = await task.value
            s1.stop()
            guard case .failure(let error) = stopped, let interrupted = error as? LibraryScanInterrupted else {
                return XCTFail("\(backend): a stopped scan hands back the sections it finished, got \(stopped)")
            }
            XCTAssertEqual(interrupted.partialItems.count, expected.count - Self.expectedCount(backend, "3", in: expected),
                           "\(backend): sections 1 and 2 were read in full")
            LibraryScanProgressStore.waitForPendingWrites()

            // "Relaunch": new checkpoint, same library, a server that answers everything.
            let mode2 = Mode(); mode2.set()
            let s2 = try server(backend, mode: mode2)
            try await s2.start()
            defer { s2.stop() }
            let svc2 = service(backend, s2)
            let second = checkpoint(backend, serverID: svc2.serverID)
            let resumed = try await svc2.loadLibrary(excludedSectionKeys: [], checkpoint: second, progress: nil)

            let asked = Set(s2.requests.compactMap { section(of: $0, backend) })
            XCTAssertEqual(asked, ["3"], "\(backend): only the unfinished section was requested again")
            XCTAssertEqual(second.resumedSectionKeys, ["1", "2"], "\(backend)")
            XCTAssertEqual(resumed.map(\.id), expected.map(\.id), "\(backend): exactly the library a scan from nothing gives, in the same order")
            XCTAssertEqual(svc2.skippedNoRuntime, expectedSkips, "\(backend): the NO RUNTIME count is the same too")
            XCTAssertEqual(Set(resumed.map { $0.serverID ?? "" }).count, 1, "\(backend): every item still belongs to the one server")
        }
    }

    private static func expectedCount(_ backend: Backend, _ section: String, in items: [PlexMediaItem]) -> Int {
        items.filter { $0.ratingKey.hasPrefix(backend == .plex ? "m\(section)-" : "\(section)-") }.count
    }

    /// A section that is lost (its requests fail for good) is not kept; the others are.
    func testALostSectionIsNotKeptAndTheOthersAre() async throws {
        for backend in Backend.allCases {
            LibraryScanProgressStore.clearAll()
            let mode = Mode(); mode.set(lost: ["2"])
            let s = try server(backend, mode: mode)
            try await s.start()
            defer { s.stop() }
            let svc = service(backend, s)
            let c = checkpoint(backend, serverID: svc.serverID)
            do {
                _ = try await svc.loadLibrary(excludedSectionKeys: [], checkpoint: c, progress: nil)
                XCTFail("\(backend): the lost section is reported")
            } catch let interrupted as LibraryScanInterrupted {
                XCTAssertEqual(interrupted.failedSections, ["Documentaries"], "\(backend)")
            }
            LibraryScanProgressStore.waitForPendingWrites()
            let next = checkpoint(backend, serverID: svc.serverID)
            XCTAssertNotNil(next.resumable(sectionKey: "1", signature: nil), "\(backend): section 1 kept")
            XCTAssertNil(next.resumable(sectionKey: "2", signature: nil), "\(backend): the lost section is not")
            XCTAssertNotNil(next.resumable(sectionKey: "3", signature: nil), "\(backend): section 3 kept")
        }
    }

    // MARK: Through the app

    private final class Memory: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    private func signedInState(on server: LoopbackJSONServer) -> AppState {
        let state = AppState(credentialStore: Memory())
        state.completePlexSignIn(token: "acct", servers: [
            AppState.ServerRef(machineIdentifier: "resume-srv", name: "Remote", baseURL: server.url, owned: true, token: "t")
        ])
        return state
    }

    private func keptSections() -> Int {
        guard let dir = LibraryScanProgressStore.directoryURL,
              let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return 0 }
        return all.filter { $0.lastPathComponent == "done.json" }.count
    }

    /// The first setup finishes with a section lost, so its snapshot is partial and the finished
    /// sections stay on disk. The next foreground load (a relaunch with no usable snapshot) takes
    /// them from disk, reads the missing one, and a complete scan then removes them.
    func testTheAppResumesAFirstSetupAndClearsWhenItIsComplete() async throws {
        let mode = Mode(); mode.set(lost: ["2"])
        let s = try server(.plex, mode: mode)
        try await s.start()
        defer { s.stop() }
        let state = signedInState(on: s)
        defer { state.disconnect() }

        await state.loadLibrary()
        XCTAssertEqual(state.lostSectionsLastLoad, ["Documentaries"])
        XCTAssertEqual(state.allItems.count, Self.counts["1"]! + Self.counts["3"]!)
        LibrarySnapshotStore.waitForPendingSaves(); LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertEqual(keptSections(), 2, "the scan was partial, so the finished sections stay for the next launch")

        // The relaunch: no snapshot to restore, a server that now answers everything.
        LibrarySnapshotStore.waitForPendingSaves()
        mode.set()
        let mark = s.requests.count
        await state.loadLibrary()
        let asked = Set(s.requests.dropFirst(mark).compactMap { section(of: $0, .plex) })
        XCTAssertEqual(asked, ["2"], "only the section that was lost is read again")
        XCTAssertEqual(state.allItems.count, Self.total)
        XCTAssertTrue(state.lostSectionsLastLoad.isEmpty)
        XCTAssertNil(state.errorMessage)
        LibrarySnapshotStore.waitForPendingSaves(); LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertEqual(keptSections(), 0, "a complete scan, saved, leaves nothing behind")
        XCTAssertNotNil(try LibrarySnapshotStore.loadSnapshot(identity: state.snapshotIdentitySeed), "and the snapshot is the whole library")
    }

    /// A background refresh has a guide on screen and wants a fresh read: it neither reads nor
    /// writes the kept sections.
    func testABackgroundRefreshAlwaysReadsEverySection() async throws {
        let mode = Mode(); mode.set(lost: ["2"])
        let s = try server(.plex, mode: mode)
        try await s.start()
        defer { s.stop() }
        let state = signedInState(on: s)
        defer { state.disconnect() }
        await state.loadLibrary()
        LibrarySnapshotStore.waitForPendingSaves(); LibraryScanProgressStore.waitForPendingWrites()
        XCTAssertEqual(keptSections(), 2)
        XCTAssertFalse(state.channels.isEmpty, "there is a guide on screen, so the next load is a background one")

        mode.set()
        let mark = s.requests.count
        await state.loadLibrary(background: true)
        let asked = Set(s.requests.dropFirst(mark).compactMap { section(of: $0, .plex) })
        XCTAssertEqual(asked, ["1", "2", "3"], "every section read again")
        XCTAssertEqual(state.allItems.count, Self.total)
    }
}
