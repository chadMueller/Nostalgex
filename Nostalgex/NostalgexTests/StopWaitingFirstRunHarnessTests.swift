import XCTest
import Network
import UIKit
import SwiftUI
@testable import Nostalgex

/// Issue #146, second round. After 1.0.29 the reporter still reaches the Apple TV home screen
/// on STOP WAITING: Plex 1.43.5, a REMOTE server, a 105k-movie library that stalls and then a
/// 1k library that crashes too, and they never get past onboarding.
///
/// `StopWaitingHarnessTests` drives `loadLibrary` directly against a local server whose
/// sections either answer or hang. This one adds what that leaves out:
/// - the first-run path as the app takes it: `confirmServerSelection`, the section list,
///   `confirmLibrarySelection`, then the scan, with `RootView` mounted when `UI` is on;
/// - the ways a remote link goes quiet: a section that never answers, a body that stalls half
///   way, a body that trickles, a connection that drops mid-body (which the retry ladder
///   then works through), and the slow-link page size (a sections list that takes over 0.8 s);
/// - library sizes from 1k to 105k movies, with memory sampled.
///
/// Off by default. Every iteration is written to a host file (flushed) BEFORE it runs, so a
/// crash leaves the iteration that killed the process as the last line:
///
///     TEST_RUNNER_NOSTALGEX_SWFR_N=100 TEST_RUNNER_NOSTALGEX_SWFR_OUT=/path/swfr.log \
///     xcodebuild test ... -only-testing:NostalgexTests/StopWaitingFirstRunHarnessTests/testFirstRunSoak
@MainActor
final class StopWaitingFirstRunHarnessTests: XCTestCase {

    typealias Spec = StopWaitingHarnessTests.SectionSpec

    // MARK: - The faulty remote

    enum Fault: String, CaseIterable, Sendable {
        /// Nothing is ever sent.
        case hang
        /// Headers and half the body, then nothing.
        case midBodyHang
        /// The whole body, 2 KB every 150 ms.
        case trickle
        /// Headers and half the body, then the connection closes.
        case reset
    }

    struct Shape: Sendable {
        var name: String
        var sections: [Spec]
        /// Section key -> (fault, first page it applies to).
        var faults: [String: FaultAt]
        /// Delay of the sections list. Over 0.8 s the app treats the link as slow and pages by 150.
        var sectionsDelayMs: Int
        /// Added to every answer: the round trip to a remote server.
        var rttMs: Int
    }

    struct FaultAt: Sendable { let fault: Fault; let fromPage: Int }

    nonisolated static func smallShape() -> [Spec] {
        [
            Spec(key: "1", title: "Movies", type: "movie", count: 1_000, episodesPerShow: 0, hangFromPage: nil, delayMs: 0),
            Spec(key: "2", title: "TV Shows", type: "show", count: 40, episodesPerShow: 10, hangFromPage: nil, delayMs: 0),
        ]
    }

    nonisolated static func hugeShape() -> [Spec] {
        [
            Spec(key: "1", title: "Movies", type: "movie", count: 105_000, episodesPerShow: 0, hangFromPage: nil, delayMs: 0),
            Spec(key: "2", title: "TV Shows", type: "show", count: 60, episodesPerShow: 12, hangFromPage: nil, delayMs: 0),
        ]
    }

    enum Action: Sendable {
        case json(Data, delayMs: Int)
        case hang
        case midBodyHang(Data)
        case trickle(Data)
        case reset(Data)
        case notFound
    }

    nonisolated static func route(path: String, query: [String: String], shape: Shape) -> Action {
        let parts = path.split(separator: "/")
        let healthy = shape.sections.map { s -> Spec in var c = s; c.hangFromPage = nil; return c }
        guard case .json(let obj, let delay) = StopWaitingHarnessTests.plexReply(path: path, query: query, sections: healthy),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return .notFound }
        if path == "/library/sections" { return .json(data, delayMs: shape.sectionsDelayMs) }
        guard parts.count == 4, let at = shape.faults[String(parts[2])] else {
            return .json(data, delayMs: delay + shape.rttMs)
        }
        let start = Int(query["X-Plex-Container-Start"] ?? "0") ?? 0
        let size = max(Int(query["X-Plex-Container-Size"] ?? "500") ?? 500, 1)
        guard start / size >= at.fromPage else { return .json(data, delayMs: delay + shape.rttMs) }
        switch at.fault {
        case .hang: return .hang
        case .midBodyHang: return .midBodyHang(data)
        case .trickle: return .trickle(data)
        case .reset: return .reset(data)
        }
    }

    final class Server: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "swfr-fake-plex", attributes: .concurrent)
        private let lock = NSLock()
        private var held: [NWConnection] = []
        private let handler: @Sendable (String, [String: String]) -> Action
        private(set) var port: UInt16 = 0
        private var served = 0
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return served }

        init(handler: @escaping @Sendable (String, [String: String]) -> Action) throws {
            self.handler = handler
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .global())
                self?.read(conn, buffer: Data())
            }
            final class Once: @unchecked Sendable { var done = false }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
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

        private func headers(_ count: Int, status: String = "200 OK") -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(count)\r\nConnection: close\r\n\r\n".utf8)
        }

        private func respond(_ conn: NWConnection, head: String) {
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://x\(target)")
            var query: [String: String] = [:]
            for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
            lock.lock(); served += 1; lock.unlock()
            switch handler(comps?.path ?? target, query) {
            case .hang:
                lock.lock(); held.append(conn); lock.unlock()
            case .notFound:
                var out = headers(2, status: "404 Not Found"); out.append(Data("{}".utf8))
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            case .json(let body, let delayMs):
                var out = headers(body.count); out.append(body)
                queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
                }
            case .midBodyHang(let body):
                var out = headers(body.count); out.append(body.prefix(body.count / 2))
                lock.lock(); held.append(conn); lock.unlock()
                conn.send(content: out, completion: .contentProcessed { _ in })
            case .reset(let body):
                var out = headers(body.count); out.append(body.prefix(body.count / 2))
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            case .trickle(let body):
                lock.lock(); held.append(conn); lock.unlock()
                conn.send(content: headers(body.count), completion: .contentProcessed { _ in })
                trickle(conn, body: body, offset: 0)
            }
        }

        private func trickle(_ conn: NWConnection, body: Data, offset: Int) {
            guard offset < body.count else { conn.cancel(); return }
            let end = min(offset + 2_048, body.count)
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
                conn.send(content: body[offset ..< end], completion: .contentProcessed { error in
                    if error != nil { conn.cancel(); return }
                    self?.trickle(conn, body: body, offset: end)
                })
            }
        }
    }

    // MARK: - Memory

    final class PeakMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var running = true
        func start() {
            let t = Thread { [self] in
                while true {
                    lock.lock(); let go = running; lock.unlock()
                    if !go { return }
                    let f = BigLibraryHarness.footprintBytes()
                    lock.lock(); peak = max(peak, f); lock.unlock()
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            t.qualityOfService = .utility
            t.start()
        }
        func stop() -> Int { lock.lock(); running = false; let p = peak; lock.unlock(); return Int(p / 1_048_576) }
    }

    // MARK: - One run

    enum Moment: String, CaseIterable, Sendable {
        /// While the section list is up (onboarding): STOP WAITING is on no screen yet.
        case duringSelection
        /// A moment after the viewer confirms the section list, before the scan has a stall.
        case rightAfterConfirm
        /// At a random moment in the scan.
        case anytime
        /// Once the scan reaches a section that faults.
        case onFaultedSection
        /// Press whenever the scan sits still, as a viewer does once the button is up.
        case perStall
        /// Tap, then keep tapping while the partial guide is built.
        case lateTap
        /// Wait for the real STOP WAITING block (needs a minute of quiet), then press.
        case fromStallBlock
    }

    struct Outcome { let items: Int; let channels: Int; let guide: Int; let error: String?; let seconds: Double; let peakMB: Int; let tapsUsed: Int }

    private final class Memory: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    private func runOnce(servers shapes: [Shape], moment: Moment, tapAfter: Double, second: Double, ui: Bool, timeout: Double, heartbeat: ((String) -> Void)? = nil) async throws -> Outcome? {
        var fakes: [Server] = []
        defer { fakes.forEach { $0.stop() } }
        var refs: [AppState.ServerRef] = []
        for (n, shape) in shapes.enumerated() {
            let fake = try Server { path, query in Self.route(path: path, query: query, shape: shape) }
            try await fake.start()
            fakes.append(fake)
            refs.append(AppState.ServerRef(machineIdentifier: "swfr-srv-\(n)", name: "Remote \(n)", baseURL: "http://127.0.0.1:\(fake.port)", owned: n == 0, token: "t\(n)"))
        }
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(s, 0) * 1_000_000_000)) }
        func waitFor(_ limit: Double, _ cond: () -> Bool) async {
            let deadline = Date().addingTimeInterval(limit)
            while !cond(), Date() < deadline { await sleep(0.02) }
        }

        let state = AppState(credentialStore: Memory())
        var window: UIWindow?
        var previousRoot: UIViewController?
        if ui {
            window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
            previousRoot = window?.rootViewController
            window?.rootViewController = UIHostingController(rootView: RootView().environment(state))
            // Let the launch task finish its (empty) credential read, as on a first run.
            await waitFor(5) { state.didAttemptCredentialHydration }
        }
        defer { if let window { window.rootViewController = previousRoot } }

        let memory = PeakMemory()
        memory.start()
        var taps = 0
        func tap() { taps += 1; state.stopWaitingForLibraryScan() }

        // Onboarding, the way the app takes it: PIN auth leaves a token, the server picker
        // confirms, the section list is read, the viewer confirms it.
        state.token = "acct"
        state.backendKind = .plex
        state.confirmServerSelection(refs)
        await waitFor(30) { state.needsLibrarySelection || state.isLoading }
        if state.needsLibrarySelection {
            if moment == .duringSelection { tap(); await sleep(0.3) }
            await sleep(0.1)
            state.confirmLibrarySelection(includedIDs: Set(state.pendingLibrarySections.map(\.id)))
        }
        let started = Date()
        // Every 10 s: where the load is, so a slow finish and a stuck one read differently.
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                heartbeat?(String(format: "  +%3.0fs phase=%@ loading=%@ items=%d section=%d/%d build=%d/%d stalling=%@ mem=%dMB taps=%d",
                                  Date().timeIntervalSince(started), String(describing: state.libraryLoadPhase),
                                  state.isLoading ? "y" : "n", state.scanItemsFound, state.scanSectionIndex, state.scanTotalSections,
                                  state.channelBuildIndex, state.channelBuildTotal, state.isLoadStalling ? "y" : "n",
                                  Int(BigLibraryHarness.footprintBytes() / 1_048_576), taps))
            }
        }
        defer { beat.cancel() }
        final class Seen { var loading = false }
        let seen = Seen()
        var finished: Bool {
            if state.isLoading { seen.loading = true }
            return seen.loading && !state.isLoading
        }

        let faultIndex = shapes.first?.sections.firstIndex { shapes[0].faults[$0.key] != nil } ?? 0

        func pressWheneverStuck(quiet: Double) async {
            var last = (state.scanSectionIndex, state.scanItemsFound, state.libraryLoadDetail, state.libraryLoadPhase.rawValue)
            var lastChange = Date()
            while !finished, Date().timeIntervalSince(started) < timeout {
                await sleep(0.05)
                let now = (state.scanSectionIndex, state.scanItemsFound, state.libraryLoadDetail, state.libraryLoadPhase.rawValue)
                if now != last { last = now; lastChange = Date(); continue }
                if state.libraryLoadPhase == .scanningLibrary, Date().timeIntervalSince(lastChange) >= quiet {
                    tap(); lastChange = Date()
                }
            }
        }

        switch moment {
        case .duringSelection:
            break
        case .rightAfterConfirm:
            await sleep(tapAfter / 10)
            tap()
        case .anytime:
            await sleep(tapAfter)
            tap()
        case .onFaultedSection:
            await waitFor(25) { finished || (state.scanTotalSections > 0 && state.scanSectionIndex >= faultIndex) }
            await sleep(tapAfter)
            tap()
        case .perStall:
            await pressWheneverStuck(quiet: 0.4 + tapAfter / 2)
        case .lateTap:
            await waitFor(25) { finished || (state.scanTotalSections > 0 && state.scanSectionIndex >= faultIndex) }
            await sleep(tapAfter)
            tap()
            while !finished, Date().timeIntervalSince(started) < timeout {
                await sleep(second)
                tap()
            }
        case .fromStallBlock:
            // The real button only exists once the scan has been quiet for a minute.
            await waitFor(timeout) { finished || state.isLoadStalling }
            await sleep(tapAfter)
            tap()
        }
        if moment != .perStall { await pressWheneverStuck(quiet: 1.0) }

        await waitFor(timeout) { finished }
        guard finished else {
            _ = memory.stop()
            state.disconnect()
            await sleep(1)
            return nil
        }
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
        let out = Outcome(items: state.allItems.count, channels: state.allChannels.count, guide: built,
                          error: state.errorMessage, seconds: Date().timeIntervalSince(started), peakMB: memory.stop(), tapsUsed: taps)
        state.disconnect()
        await sleep(0.3)
        return out
    }

    // MARK: - Soak

    private func env(_ k: String) -> String? {
        let e = ProcessInfo.processInfo.environment
        return e["NOSTALGEX_SWFR_\(k)"] ?? e["TEST_RUNNER_NOSTALGEX_SWFR_\(k)"]
    }

    func testFirstRunSoak() async throws {
        guard let n = env("N").flatMap(Int.init), n > 0 else {
            throw XCTSkip("Set TEST_RUNNER_NOSTALGEX_SWFR_N to run the first-run STOP WAITING soak")
        }
        let scope = HarnessScope.begin("swfr")
        defer { scope.end() }
        let log = StopWaitingHarnessTests.HostLog(path: env("OUT"))
        let seed = env("SEED").flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970)
        let ui = env("UI") == "1"
        let maxServers = env("SERVERS").flatMap(Int.init) ?? 2
        let shapeNames = (env("SHAPES") ?? "small,base").split(separator: ",").map(String.init)
        let moments: [Moment] = env("MOMENTS").map { $0.split(separator: ",").compactMap { Moment(rawValue: String($0)) } }
            ?? [.duringSelection, .rightAfterConfirm, .anytime, .onFaultedSection, .perStall, .lateTap]
        let only: Set<Int>? = env("ONLY").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let timeoutOverride = env("TIMEOUT").flatMap(Double.init)
        let faultsAllowed: [Fault] = env("FAULTS").map { $0.split(separator: ",").compactMap { Fault(rawValue: String($0)) } } ?? Fault.allCases
        var rng = StopWaitingHarnessTests.SplitMix(seed: seed)
        var lines: [String] = []
        func say(_ s: String) { print("[SWFR] \(s)"); log?.line(s); lines.append(s) }
        say("start n=\(n) seed=\(seed) ui=\(ui) shapes=\(shapeNames) servers<=\(maxServers) moments=\(moments.map(\.rawValue)) faults=\(faultsAllowed.map(\.rawValue))")

        var hangs = 0, errors = 0, peak = 0
        for i in 0 ..< n {
            let serverCount = 1 + Int(rng.next() % UInt64(max(maxServers, 1)))
            var shapes: [Shape] = []
            for s in 0 ..< serverCount {
                let name = shapeNames[Int(rng.next() % UInt64(shapeNames.count))]
                let sections: [Spec]
                switch name {
                case "small": sections = Self.smallShape()
                case "huge": sections = Self.hugeShape()
                default: sections = StopWaitingHarnessTests.baseSections()
                }
                var faults: [String: FaultAt] = [:]
                let faultCount = (s == 0 ? 1 : 0) + Int(rng.next() % 2)
                for sec in sections.shuffled(using: &rng).prefix(faultCount) {
                    let maxPage: UInt64 = (name == "huge" && sec.type == "movie") ? 80 : 3
                    faults[sec.key] = FaultAt(fault: faultsAllowed[Int(rng.next() % UInt64(faultsAllowed.count))],
                                              fromPage: Int(rng.next() % maxPage))
                }
                let slow = rng.next() % 2 == 0
                shapes.append(Shape(name: name, sections: sections, faults: faults,
                                    sectionsDelayMs: slow ? 900 : 0, rttMs: 10 + Int(rng.next() % 120)))
            }
            let moment = moments[Int(rng.next() % UInt64(moments.count))]
            let tapAfter = Double(rng.next() % 3000) / 1000
            let second = Double(rng.next() % 2500) / 1000 + 0.05
            let shape = shapes.map { s in
                "\(s.name)[\(s.faults.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.fault.rawValue)@\($0.value.fromPage)" }.joined(separator: ","))] slow=\(s.sectionsDelayMs > 0) rtt=\(s.rttMs)"
            }.joined(separator: " | ")
            say("iter \(i) moment=\(moment.rawValue) tap=\(String(format: "%.2f", tapAfter)) second=\(String(format: "%.2f", second)) servers=\(serverCount) \(shape)")

            if let only, !only.contains(i) { continue }
            let limit = timeoutOverride ?? ((moment == .fromStallBlock ? 200 : 60) + 25 * Double(serverCount))
            guard let out = try await runOnce(servers: shapes, moment: moment, tapAfter: tapAfter, second: second, ui: ui, timeout: limit,
                                              heartbeat: { say($0) }) else {
                hangs += 1
                say("iter \(i) HANG: the load did not finish")
                continue
            }
            if out.error != nil { errors += 1 }
            peak = max(peak, out.peakMB)
            say("iter \(i) ok items=\(out.items) channels=\(out.channels) guide=\(out.guide) taps=\(out.tapsUsed) error=\(out.error ?? "-") t=\(String(format: "%.1f", out.seconds))s peak=\(out.peakMB)MB")
        }
        say("done n=\(n) hangs=\(hangs) errors=\(errors) peakMB=\(peak)")
        let a = XCTAttachment(string: lines.joined(separator: "\n"))
        a.name = "swfr-report.txt"
        a.lifetime = .keepAlways
        add(a)
        XCTAssertEqual(hangs, 0, "every load must return after STOP WAITING")
    }

    // MARK: - Several servers in one onboarding (the reporter's second message)

    /// "All servers worked fine when adding individually. Maybe adding them all sequentially,
    /// during onboarding, hit a memory limit." The server picker lets someone tick several
    /// servers; one `loadLibrary` then reads them one after another and merges the lists.
    /// This runs that load for the sizes in `NOSTALGEX_SWFR_MULTI` (movies per server, comma
    /// separated, e.g. `105000,50000,10000,10000`), every server healthy, nobody pressing
    /// anything, and samples the process footprint every 0.25 s: per server while it is read
    /// (start, peak, end), per phase afterwards, what is still held when the load is done,
    /// and what is released when the sign-in ends.
    func testMultiServerOnboardingMemory() async throws {
        guard let sizes = env("MULTI").map({ $0.split(separator: ",").compactMap { Int($0) } }), !sizes.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NOSTALGEX_SWFR_MULTI (movies per server, comma separated) to run the multi-server memory test")
        }
        let scope = HarnessScope.begin("swfr-multi")
        defer { scope.end() }
        let log = StopWaitingHarnessTests.HostLog(path: env("OUT"))
        var lines: [String] = []
        func say(_ s: String) { print("[SWFR-MULTI] \(s)"); log?.line(s); lines.append(s) }
        func mb() -> Int { Int(BigLibraryHarness.footprintBytes() / 1_048_576) }
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(s, 0) * 1_000_000_000)) }
        func waitFor(_ limit: Double, _ cond: () -> Bool) async {
            let deadline = Date().addingTimeInterval(limit)
            while !cond(), Date() < deadline { await sleep(0.02) }
        }

        var fakes: [Server] = []
        defer { fakes.forEach { $0.stop() } }
        var refs: [AppState.ServerRef] = []
        for (n, movies) in sizes.enumerated() {
            let shape = Shape(name: "m\(movies)", sections: [
                Spec(key: "1", title: "Movies", type: "movie", count: movies, episodesPerShow: 0, hangFromPage: nil, delayMs: 0),
                Spec(key: "2", title: "TV Shows", type: "show", count: 40, episodesPerShow: 12, hangFromPage: nil, delayMs: 0),
            ], faults: [:], sectionsDelayMs: 0, rttMs: 5)
            let sid = "swfr-multi-\(n)"
            let fake: Server
            if env("REALISTIC") == "1" {
                // The shared scale fixture: titles, genres, studios and ratings the channel
                // rules actually match, so pool sizes look like a real library's.
                let lib = MovieLibraryScaleHarness.makeMovieLibrary(count: movies, serverID: sid)
                let items = lib.items
                fake = try Server { path, query in
                    switch path {
                    case "/identity":
                        return .json((try? JSONSerialization.data(withJSONObject: ["MediaContainer": ["machineIdentifier": sid, "friendlyName": sid]])) ?? Data(), delayMs: 0)
                    case "/library/sections":
                        let dir: [String: Any] = ["key": "1", "title": "Movies", "type": "movie",
                                                  "scannedAt": 1_790_000_000, "updatedAt": 1_790_000_000, "contentChangedAt": 1_790_000_000]
                        return .json((try? JSONSerialization.data(withJSONObject: ["MediaContainer": ["Directory": [dir]]])) ?? Data(), delayMs: 0)
                    case "/library/sections/1/all":
                        let start = Int(query["X-Plex-Container-Start"] ?? "0") ?? 0
                        let size = Int(query["X-Plex-Container-Size"] ?? "500") ?? 500
                        let page = items.dropFirst(start).prefix(size).map { ColdPlexScaleHarness.plexJSON($0) }
                        let body: [String: Any] = ["MediaContainer": ["totalSize": items.count, "size": page.count, "Metadata": page]]
                        return .json((try? JSONSerialization.data(withJSONObject: body)) ?? Data(), delayMs: 5)
                    default:
                        return .notFound
                    }
                }
            } else {
                fake = try Server { path, query in Self.route(path: path, query: query, shape: shape) }
            }
            try await fake.start()
            fakes.append(fake)
            refs.append(AppState.ServerRef(machineIdentifier: sid, name: "Remote \(n)", baseURL: "http://127.0.0.1:\(fake.port)", owned: n == 0, token: "t\(n)"))
        }

        let state = AppState(credentialStore: Memory())
        let ui = env("UI") == "1"
        var window: UIWindow?
        var previousRoot: UIViewController?
        if ui {
            window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
            previousRoot = window?.rootViewController
            window?.rootViewController = UIHostingController(rootView: RootView().environment(state))
            await waitFor(5) { state.didAttemptCredentialHydration }
        }
        defer { if let window { window.rootViewController = previousRoot } }

        struct Sample { let t: Double; let mb: Int; let phase: String; let detail: String; let items: Int; let build: String }
        final class Samples { var all: [Sample] = [] }
        let samples = Samples()
        let t0 = Date()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                samples.all.append(Sample(t: Date().timeIntervalSince(t0), mb: mb(), phase: String(describing: state.libraryLoadPhase),
                                          detail: state.libraryLoadDetail, items: state.scanItemsFound,
                                          build: "\(state.channelBuildIndex)/\(state.channelBuildTotal)"))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { sampler.cancel() }

        // Stage marks from the load itself, each with the footprint at that moment.
        final class Marks: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var all: [(String, Int)] = []
            func add(_ s: String, _ mb: Int) { lock.lock(); all.append((s, mb)); lock.unlock() }
        }
        let marks = Marks()
        let tStart = Date()
        LibraryLoadProbe.handler = { stage in
            if stage.hasPrefix("pool:") || stage.hasPrefix("tick:") { return }
            marks.add(String(format: "%6.1fs %@", Date().timeIntervalSince(tStart), stage), Int(BigLibraryHarness.footprintBytes() / 1_048_576))
        }
        defer { LibraryLoadProbe.handler = nil }
        let baseline = mb()
        say("servers=\(sizes) (movies each, +40 shows x 12 episodes) baseline=\(baseline)MB ui=\(ui)")
        state.token = "acct"
        state.backendKind = .plex
        state.confirmServerSelection(refs)
        await waitFor(60) { state.needsLibrarySelection || state.isLoading }
        if state.needsLibrarySelection {
            state.confirmLibrarySelection(includedIDs: Set(state.pendingLibrarySections.map(\.id)))
        }
        final class Seen { var loading = false }
        let seen = Seen()
        var finished: Bool {
            if state.isLoading { seen.loading = true }
            return seen.loading && !state.isLoading
        }
        await waitFor(Double(env("TIMEOUT").flatMap(Double.init) ?? 1800)) { finished }
        XCTAssertTrue(finished, "the load did not finish")
        let doneAt = Date().timeIntervalSince(t0)
        let atDone = mb()
        await sleep(2)
        let settled = mb()

        // The guide, as TunerView builds it.
        let guideChannels = state.channels
        let fp = state.scheduleCredentialFingerprint
        let built = await Task.detached(priority: .userInitiated) { () -> Int in
            var schedules: [Int: ChannelSchedule] = [:]
            for channel in guideChannels {
                if let sch = ChannelScheduleBuilder.buildSchedule(for: channel, at: Date(), credentialFingerprint: fp) { schedules[channel.id] = sch }
            }
            ChannelScheduleBuilder.resolveConflicts(&schedules)
            return schedules.count
        }.value
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        await sleep(1)
        let afterGuide = mb()
        let items = state.allItems.count
        sampler.cancel()
        for (stage, m) in marks.all { say("stage \(stage): \(m)MB") }
        let pooled = state.allChannels.reduce(0) { $0 + $1.itemPool.count }
        let capacity = state.allChannels.reduce(0) { $0 + $1.itemPool.capacity }
        let stride = MemoryLayout<PlexMediaItem>.stride
        let guidePooled = state.channels.reduce(0) { $0 + $1.itemPool.count }
        say("PlexMediaItem stride=\(stride)B; allChannels=\(state.allChannels.count) pools hold \(pooled) items in \(capacity) slots = \(pooled * stride / 1_048_576)MB used, \(capacity * stride / 1_048_576)MB allocated; guide channels=\(state.channels.count) pool items=\(guidePooled); library=\(items) items = \(items * stride / 1_048_576)MB of structs")

        // Per server: footprint when its section list starts, the peak while it is read, and
        // the value when the next one begins. The detail line names the server once more than
        // one is being read ("Remote 2 · Section 1/2 · 4000 items").
        var order: [String] = []
        var first: [String: Sample] = [:], peak: [String: Sample] = [:], last: [String: Sample] = [:]
        for sm in samples.all where sm.phase == "scanningLibrary" {
            guard let name = sm.detail.components(separatedBy: " · ").first, name.hasPrefix("Remote") else { continue }
            if first[name] == nil { first[name] = sm; order.append(name) }
            if sm.mb > (peak[name]?.mb ?? 0) { peak[name] = sm }
            last[name] = sm
        }
        for name in order {
            say(String(format: "scan %@: start=%dMB peak=%dMB end=%dMB items at end=%d (%.0fs..%.0fs)",
                       name, first[name]!.mb, peak[name]!.mb, last[name]!.mb, last[name]!.items, first[name]!.t, last[name]!.t))
        }
        var byPhase: [String: (peak: Int, first: Double, last: Double)] = [:]
        for sm in samples.all {
            let cur = byPhase[sm.phase] ?? (0, sm.t, sm.t)
            byPhase[sm.phase] = (max(cur.peak, sm.mb), cur.first, sm.t)
        }
        for (phase, v) in byPhase.sorted(by: { $0.value.first < $1.value.first }) {
            say(String(format: "phase %@: peak=%dMB (%.0fs..%.0fs)", phase, v.peak, v.first, v.last))
        }
        let overall = samples.all.map(\.mb).max() ?? 0
        say("items=\(items) channels=\(state.allChannels.count) guide=\(built) done at \(String(format: "%.0f", doneAt))s")
        say("footprint: baseline=\(baseline)MB peak=\(overall)MB at load end=\(atDone)MB settled=\(settled)MB after guide and snapshot=\(afterGuide)MB (\(items > 0 ? (afterGuide - baseline) * 1024 / max(items / 1000, 1) : 0) KB per 1000 items retained)")

        state.disconnect()
        await sleep(3)
        say("after sign-out: \(mb())MB (released \(afterGuide - mb())MB)")
        let a = XCTAttachment(string: lines.joined(separator: "\n"))
        a.name = "swfr-multi-report.txt"
        a.lifetime = .keepAlways
        add(a)
    }
}
