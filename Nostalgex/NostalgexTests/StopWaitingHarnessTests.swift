import XCTest
import Network
@testable import Nostalgex

/// Issue #146: on a Plex server with several large libraries, a few sections stop
/// answering during the first scan. Tapping STOP WAITING either moves on to a guide or
/// takes the app down, roughly half the time each.
///
/// This harness serves a Plex library from a loopback HTTP server inside the test. Some
/// sections answer, some answer slowly, and some never answer at all (the connection is
/// held open and nothing is sent). It drives the REAL first load (`AppState.loadLibrary`,
/// the real `PlexAPIService`, the real stall watch, the real partial-guide path), taps
/// STOP WAITING (`stopWaitingForLibraryScan`, what the button calls) at varied moments,
/// then builds the guide the way TunerView does and waits for the snapshot write.
///
/// The soak is off by default. Each iteration is written (and flushed) to a host file
/// BEFORE it runs, so if the process dies the last line names the iteration that killed
/// it:
///
///     TEST_RUNNER_NOSTALGEX_STOPWAIT_N=60 \
///     TEST_RUNNER_NOSTALGEX_STOPWAIT_OUT=/path/on/host/stopwait.log \
///     xcodebuild test ... -only-testing:NostalgexTests/StopWaitingHarnessTests/testStopWaitingSoak
@MainActor
final class StopWaitingHarnessTests: XCTestCase {

    // MARK: - Fixture library

    /// Each section's shape. `hangFromPage` nil = every page answers; 0 = the first
    /// request never answers; k = pages before k answer, page k never does.
    struct SectionSpec: Sendable {
        let key: String
        let title: String
        let type: String           // "movie" or "show"
        let count: Int             // movies, or shows for a TV section
        let episodesPerShow: Int
        var hangFromPage: Int?
        var delayMs: Int
    }

    nonisolated static func baseSections() -> [SectionSpec] {
        [
            SectionSpec(key: "1", title: "Movies", type: "movie", count: 1_400, episodesPerShow: 0, hangFromPage: nil, delayMs: 0),
            SectionSpec(key: "2", title: "TV Shows", type: "show", count: 90, episodesPerShow: 12, hangFromPage: nil, delayMs: 0),
            SectionSpec(key: "3", title: "4K Movies", type: "movie", count: 1_800, episodesPerShow: 0, hangFromPage: nil, delayMs: 0),
            SectionSpec(key: "4", title: "Anime", type: "show", count: 70, episodesPerShow: 20, hangFromPage: nil, delayMs: 0),
            SectionSpec(key: "5", title: "Documentaries", type: "movie", count: 600, episodesPerShow: 0, hangFromPage: nil, delayMs: 0),
        ]
    }

    nonisolated static let genres = ["Action", "Comedy", "Drama", "Horror", "Science Fiction", "Animation", "Documentary", "Thriller", "Family", "Romance"]

    nonisolated static func movie(_ section: String, _ i: Int) -> [String: Any] {
        [
            "ratingKey": "m\(section)-\(i)", "title": "Movie \(section)-\(i)", "type": "movie",
            "year": 1970 + i % 50, "duration": (85 + i % 60) * 60_000, "contentRating": ["G", "PG", "PG-13", "R"][i % 4],
            "Genre": [["tag": genres[i % genres.count]], ["tag": genres[(i * 3 + 1) % genres.count]]],
            "Media": [["container": "mkv", "videoCodec": "h264", "audioCodec": "aac", "Part": [["key": "/library/parts/\(section)\(i)/file.mkv"]]]],
        ]
    }

    nonisolated static func show(_ section: String, _ i: Int) -> [String: Any] {
        [
            "ratingKey": "s\(section)-\(i)", "title": "Show \(section)-\(i)", "type": "show", "year": 1980 + i % 40,
            "contentRating": ["TV-G", "TV-PG", "TV-14"][i % 3],
            "Genre": [["tag": genres[i % genres.count]]],
        ]
    }

    nonisolated static func episode(_ section: String, _ show: Int, _ e: Int) -> [String: Any] {
        [
            "ratingKey": "e\(section)-\(show)-\(e)", "title": "Episode \(e + 1)", "type": "episode",
            "grandparentRatingKey": "s\(section)-\(show)", "grandparentTitle": "Show \(section)-\(show)",
            "parentIndex": 1 + e / 10, "index": 1 + e % 10, "duration": [22, 24, 30, 44][(show + e) % 4] * 60_000,
            "Media": [["container": "mkv", "videoCodec": "h264", "audioCodec": "aac", "Part": [["key": "/library/parts/e\(section)\(show)\(e)/file.mkv"]]]],
        ]
    }

    // MARK: - Fake Plex

    enum Reply { case json(Any, delayMs: Int), hang, notFound }

    nonisolated static func plexReply(path: String, query: [String: String], sections: [SectionSpec]) -> Reply {
        if path == "/library/sections" {
            let dirs = sections.map { ["key": $0.key, "title": $0.title, "type": $0.type] }
            return .json(["MediaContainer": ["Directory": dirs]], delayMs: 0)
        }
        let parts = path.split(separator: "/")
        if parts.count == 4, parts[0] == "library", parts[1] == "sections", parts[3] == "all",
           let spec = sections.first(where: { $0.key == String(parts[2]) }) {
            let start = Int(query["X-Plex-Container-Start"] ?? "0") ?? 0
            let size = Int(query["X-Plex-Container-Size"] ?? "500") ?? 500
            let page = size > 0 ? start / size : 0
            if let hang = spec.hangFromPage, page >= hang { return .hang }
            let total: Int
            let rows: [[String: Any]]
            if spec.type == "movie" {
                total = spec.count
                rows = (start ..< min(start + size, total)).map { movie(spec.key, $0) }
            } else if query["type"] == "4" {
                total = spec.count * spec.episodesPerShow
                rows = (start ..< min(start + size, total)).map { idx in episode(spec.key, idx / spec.episodesPerShow, idx % spec.episodesPerShow) }
            } else {
                total = spec.count
                rows = (start ..< min(start + size, total)).map { show(spec.key, $0) }
            }
            return .json(["MediaContainer": ["totalSize": total, "Metadata": rows]], delayMs: spec.delayMs)
        }
        return .notFound
    }

    /// Minimal HTTP/1.1 on 127.0.0.1, one request per connection. `.hang` keeps the
    /// connection open and never answers, the way a wedged section looks from the client.
    final class FakeServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "stopwait-fake-plex", attributes: .concurrent)
        private let lock = NSLock()
        private var held: [NWConnection] = []
        private let route: @Sendable (String, [String: String]) -> Reply
        private(set) var port: UInt16 = 0

        init(route: @escaping @Sendable (String, [String: String]) -> Reply) throws {
            self.route = route
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            final class Once: @unchecked Sendable { var done = false }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // State updates arrive on `queue`, one at a time.
                let once = Once()
                listener.stateUpdateHandler = { state in
                    guard !once.done else { return }
                    switch state {
                    case .ready: once.done = true; cont.resume()
                    case .failed(let e): once.done = true; cont.resume(throwing: e)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            port = listener.port?.rawValue ?? 0
        }

        func stop() {
            listener.cancel()
            lock.lock(); let conns = held; held = []; lock.unlock()
            conns.forEach { $0.cancel() }
        }

        private func serve(_ conn: NWConnection) {
            conn.start(queue: queue)
            read(conn, buffer: Data())
        }

        private func read(_ conn: NWConnection, buffer: Data) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(conn, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
                } else if done || error != nil {
                    conn.cancel()
                } else {
                    self.read(conn, buffer: buf)
                }
            }
        }

        private func respond(_ conn: NWConnection, head: String) {
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://x\(target)")
            var query: [String: String] = [:]
            for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
            switch route(comps?.path ?? target, query) {
            case .hang:
                lock.lock(); held.append(conn); lock.unlock()
            case .notFound:
                send(conn, status: "404 Not Found", body: Data("{}".utf8), delayMs: 0)
            case .json(let obj, let delayMs):
                let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                send(conn, status: "200 OK", body: body, delayMs: delayMs)
            }
        }

        private func send(_ conn: NWConnection, status: String, body: Data, delayMs: Int) {
            var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(body)
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: - Host log (survives a crash)

    final class HostLog: @unchecked Sendable {
        private let fd: Int32
        init?(path: String?) {
            guard let path, !path.isEmpty else { return nil }
            fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd < 0 { return nil }
        }
        func line(_ s: String) {
            let data = Array((s + "\n").utf8)
            _ = data.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            fsync(fd)
        }
        deinit { close(fd) }
    }

    // MARK: - Fixtures

    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    override func setUp() {
        super.setUp()
        resetPersistedState()
    }

    override func tearDown() {
        resetPersistedState()
        super.tearDown()
    }

    private func resetPersistedState() {
        LibrarySnapshotStore.waitForPendingSaves()
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        DailyManifestScheduler.invalidateMemo()
        UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        UserDefaults.standard.removeObject(forKey: "nostalgex_deselected_library_sections")
        UserDefaults.standard.set(["nostalgex"], forKey: "nostalgex_enabled_bundles")
    }

    // MARK: - One run

    enum TapMode: String, CaseIterable, Sendable {
        /// Wait for the scan to reach a section that never answers, then tap.
        case onStuckSection
        /// Tap at a random moment, often while pages are still arriving.
        case anytime
        /// Tap, then tap again a moment later (the button stays up while the partial
        /// guide is built).
        case doubleTap
        /// Tap during the post-scan phases (collections, enrichment, channel build).
        case lateTap
        /// Tap every time the scan sits still, once per stuck server.
        case perStall
    }

    struct Outcome { let itemCount: Int; let channels: Int; let guide: Int; let error: String?; let seconds: Double }

    /// Runs one first load against `sections`, tapping per `mode`. Returns nil if the load
    /// did not return within `timeout` (a hang, which is its own finding).
    private func runOnce(sections: [SectionSpec], mode: TapMode, tapAfter: Double, secondTapAfter: Double, timeout: Double = 45) async throws -> Outcome? {
        try await runOnce(servers: [sections], mode: mode, tapAfter: tapAfter, secondTapAfter: secondTapAfter, timeout: timeout)
    }

    /// Same, across several servers (one fake Plex each), scanned in order by the app.
    private func runOnce(servers serverSpecs: [[SectionSpec]], mode: TapMode, tapAfter: Double, secondTapAfter: Double, timeout: Double = 45) async throws -> Outcome? {
        var fakes: [FakeServer] = []
        defer { fakes.forEach { $0.stop() } }
        var refs: [AppState.ServerRef] = []
        for (n, specs) in serverSpecs.enumerated() {
            let fake = try FakeServer { path, query in Self.plexReply(path: path, query: query, sections: specs) }
            try await fake.start()
            fakes.append(fake)
            refs.append(AppState.ServerRef(machineIdentifier: "stopwait-srv-\(n)", name: "Harness \(n)", baseURL: "http://127.0.0.1:\(fake.port)", owned: n == 0, token: "t\(n)"))
        }
        let sections = serverSpecs.first ?? []
        let state = AppState(credentialStore: InMemoryStore())
        state.completePlexSignIn(token: "acct", servers: refs)

        let started = Date()
        final class Flag { var value = false }
        let done = Flag()
        let load = Task { @MainActor in await state.loadLibrary(); done.value = true }
        var finished: Bool { done.value }

        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(s, 0) * 1_000_000_000)) }
        func waitFor(_ limit: Double, _ cond: () -> Bool) async {
            let deadline = Date().addingTimeInterval(limit)
            while !cond(), Date() < deadline { await sleep(0.02) }
        }

        /// What a viewer does: the button shows once nothing has moved for a while, and
        /// they press it. `quiet` is the still spell that counts as stuck here.
        func pressWheneverStuck(quiet: Double) async {
            var last = (state.scanSectionIndex, state.scanItemsFound, state.libraryLoadDetail, state.libraryLoadPhase.rawValue)
            var lastChange = Date()
            while !finished, Date().timeIntervalSince(started) < timeout {
                await sleep(0.05)
                let now = (state.scanSectionIndex, state.scanItemsFound, state.libraryLoadDetail, state.libraryLoadPhase.rawValue)
                if now != last { last = now; lastChange = Date(); continue }
                if state.libraryLoadPhase == .scanningLibrary, Date().timeIntervalSince(lastChange) >= quiet {
                    state.stopWaitingForLibraryScan()
                    lastChange = Date()
                }
            }
        }

        let stuckIndex = sections.firstIndex(where: { $0.hangFromPage != nil }) ?? 0
        switch mode {
        case .perStall:
            await pressWheneverStuck(quiet: 0.4 + tapAfter / 2)
        case .onStuckSection:
            await waitFor(20) { finished || (state.scanTotalSections > 0 && state.scanSectionIndex >= stuckIndex) }
            await sleep(tapAfter)
            state.stopWaitingForLibraryScan()
        case .anytime:
            await sleep(tapAfter)
            state.stopWaitingForLibraryScan()
        case .doubleTap:
            await waitFor(20) { finished || (state.scanTotalSections > 0 && state.scanSectionIndex >= stuckIndex) }
            await sleep(tapAfter)
            state.stopWaitingForLibraryScan()
            await sleep(secondTapAfter)
            state.stopWaitingForLibraryScan()
        case .lateTap:
            await waitFor(20) { finished || (state.scanTotalSections > 0 && state.scanSectionIndex >= stuckIndex) }
            await sleep(tapAfter)
            state.stopWaitingForLibraryScan()
            // Keep pressing while the load runs on, the way a viewer leans on a button
            // that is still on screen.
            while !finished, Date().timeIntervalSince(started) < timeout {
                await sleep(secondTapAfter)
                state.stopWaitingForLibraryScan()
            }
        }
        // A later server can stall too. The scripted presses above were spent on the
        // first one (a press belongs to the server it was made on), so from here the
        // viewer presses again whenever the scan sits still, as they would on the TV.
        if mode != .perStall { await pressWheneverStuck(quiet: 1.0) }

        await waitFor(timeout) { finished }
        guard finished else {
            load.cancel()
            // Let the cancelled load unwind before the next run: it shares the snapshot
            // store and defaults with it.
            await waitFor(60) { finished }
            return nil
        }

        // The guide: TunerView.buildAllSchedules, same calls, same detached task.
        let guideChannels = state.channels
        let fp = state.scheduleCredentialFingerprint
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
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value

        return Outcome(itemCount: state.allItems.count, channels: state.allChannels.count, guide: built,
                       error: state.errorMessage, seconds: Date().timeIntervalSince(started))
    }

    // MARK: - A tap belongs to the server it was made on

    /// Scripted backend: optionally presses STOP WAITING as its scan ends (a tap that lands
    /// in the gap between the scan finishing and the stall watch's next poll), and
    /// otherwise takes `seconds` to finish while reporting progress all the way.
    private final class ScriptedBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        let items: [PlexMediaItem]
        let seconds: Double
        let tapAtEnd: (@MainActor () -> Void)?
        var authHeaders: [String: String] { [:] }

        init(serverID: String, items: [PlexMediaItem], seconds: Double, tapAtEnd: (@MainActor () -> Void)? = nil) {
            self.serverID = serverID; self.items = items; self.seconds = seconds; self.tapAtEnd = tapAtEnd
        }

        func testConnection() async throws -> String { serverID }
        func loadSections() async throws -> [PlexSection] { [PlexSection(key: "1", title: "Movies", type: "movie")] }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress? = nil) async throws -> [PlexMediaItem] {
            let steps = max(Int(seconds / 0.2), 1)
            for step in 0 ..< steps {
                try await Task.sleep(nanoseconds: 200_000_000)
                progress?(LoadProgressEvent(sectionIndex: 0, totalSections: 1, sectionTitle: "Movies", sectionType: "movie",
                                            itemsLoadedSoFar: step + 1, showsCompleted: nil, totalShows: nil))
            }
            if let tapAtEnd { await tapAtEnd() }
            return items
        }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { nil }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private func movieItems(_ prefix: String, _ n: Int, serverID: String) -> [PlexMediaItem] {
        (0 ..< n).map { i in
            PlexMediaItem(
                id: "\(serverID)|\(prefix)\(i)", title: "\(prefix) \(i)", artist: nil, episodeTitle: nil, seTag: nil,
                summary: "", year: 1990 + i % 30, originallyAvailableAt: nil, contentRating: "PG",
                duration: 95, ratingKey: "\(prefix)\(i)", partKey: "/p/\(i)", container: "mp4",
                videoCodec: "h264", audioCodec: "aac", videoProfile: nil, bitrate: 4000,
                genres: [Self.genres[i % Self.genres.count]], rating: 7, userRating: 0, type: .movie,
                thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil,
                imdbID: nil, librarySource: .movie, serverID: serverID)
        }
    }

    /// The viewer presses STOP WAITING on server A just as A's scan finishes. Nothing is
    /// left for that press to stop, so it must not stop server B, a healthy scan the
    /// viewer never asked to cut short.
    func testStopWaitingPressedAsOneServerFinishesDoesNotAbandonTheNext() async throws {
        let a = AppState.ServerRef(machineIdentifier: "srv-a", name: "A", baseURL: "http://127.0.0.1:9", owned: true, token: "a")
        let b = AppState.ServerRef(machineIdentifier: "srv-b", name: "B", baseURL: "http://127.0.0.2:9", owned: false, token: "b")
        let state = AppState(credentialStore: InMemoryStore())
        let backendA = ScriptedBackend(serverID: "srv-a", items: movieItems("a", 40, serverID: "srv-a"), seconds: 0.2) { [weak state] in
            state?.stopWaitingForLibraryScan()
        }
        // Longer than the stall watch's first poll (2s), progressing the whole time.
        let backendB = ScriptedBackend(serverID: "srv-b", items: movieItems("b", 40, serverID: "srv-b"), seconds: 4.4)
        state.backendOverride = { ref in ref?.machineIdentifier == "srv-b" ? backendB : backendA }
        state.completePlexSignIn(token: "acct", servers: [a, b])

        await state.loadLibrary()

        let fromB = state.allItems.filter { $0.serverID == "srv-b" }.count
        XCTAssertEqual(fromB, 40, "server B was abandoned by a STOP WAITING pressed on server A")
        XCTAssertFalse(state.isLibraryStale, "nothing was abandoned, so the library is not partial")
    }

    // MARK: - Soak

    /// Off by default. Many first loads with stuck sections and STOP WAITING taps.
    func testStopWaitingSoak() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let n = Int(env["NOSTALGEX_STOPWAIT_N"] ?? env["TEST_RUNNER_NOSTALGEX_STOPWAIT_N"] ?? "") , n > 0 else {
            throw XCTSkip("Set TEST_RUNNER_NOSTALGEX_STOPWAIT_N to run the STOP WAITING soak")
        }
        let log = HostLog(path: env["NOSTALGEX_STOPWAIT_OUT"] ?? env["TEST_RUNNER_NOSTALGEX_STOPWAIT_OUT"])
        let seed = UInt64(env["NOSTALGEX_STOPWAIT_SEED"] ?? env["TEST_RUNNER_NOSTALGEX_STOPWAIT_SEED"] ?? "") ?? UInt64(Date().timeIntervalSince1970)
        var rng = SplitMix(seed: seed)
        func say(_ s: String) { print("[STOPWAIT] \(s)"); log?.line(s) }
        say("start n=\(n) seed=\(seed)")

        var hangs = 0
        var errors = 0
        let maxServers = Int(env["NOSTALGEX_STOPWAIT_SERVERS"] ?? env["TEST_RUNNER_NOSTALGEX_STOPWAIT_SERVERS"] ?? "") ?? 1
        let modes: [TapMode] = (env["NOSTALGEX_STOPWAIT_MODE"] ?? env["TEST_RUNNER_NOSTALGEX_STOPWAIT_MODE"]).flatMap(TapMode.init(rawValue:)).map { [$0] } ?? TapMode.allCases
        for i in 0 ..< n {
            let serverCount = 1 + Int(rng.next() % UInt64(max(maxServers, 1)))
            var servers: [[SectionSpec]] = []
            for s in 0 ..< serverCount {
                var sections = Self.baseSections()
                // The first server: two or three of sections 3-5 stop answering, at
                // varied points. Later servers: any section, the first included.
                let pool = s == 0 ? [2, 3, 4] : [0, 1, 2, 3, 4]
                let stuckCount = (s == 0 ? 2 : 1) + Int(rng.next() % 2)
                for idx in pool.shuffled(using: &rng).prefix(stuckCount) {
                    sections[idx].hangFromPage = Int(rng.next() % 3)
                }
                for idx in sections.indices where sections[idx].hangFromPage == nil {
                    sections[idx].delayMs = Int(rng.next() % 400)
                }
                servers.append(sections)
            }
            let mode = modes[Int(rng.next() % UInt64(modes.count))]
            let tapAfter = Double(rng.next() % 3000) / 1000
            let second = Double(rng.next() % 2500) / 1000 + 0.05
            let shape = servers.map { $0.map { "\($0.key):\($0.hangFromPage.map { "h\($0)" } ?? "ok")" }.joined(separator: ",") }.joined(separator: " | ")
            say("iter \(i) mode=\(mode.rawValue) tap=\(String(format: "%.2f", tapAfter)) second=\(String(format: "%.2f", second)) servers=\(serverCount) sections=\(shape)")

            resetPersistedState()
            guard let out = try await runOnce(servers: servers, mode: mode, tapAfter: tapAfter, secondTapAfter: second, timeout: 45 + 20 * Double(serverCount)) else {
                hangs += 1
                say("iter \(i) HANG: loadLibrary did not return")
                continue
            }
            if out.error != nil { errors += 1 }
            say("iter \(i) ok items=\(out.itemCount) channels=\(out.channels) guide=\(out.guide) error=\(out.error ?? "-") t=\(String(format: "%.1f", out.seconds))s")
        }
        say("done n=\(n) hangs=\(hangs) errors=\(errors)")
        XCTAssertEqual(hangs, 0, "every load must return after STOP WAITING")
    }

    /// Deterministic RNG so a failing seed replays.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
