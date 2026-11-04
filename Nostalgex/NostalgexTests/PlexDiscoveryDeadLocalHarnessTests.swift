import XCTest
@testable import Nostalgex

/// Plex discovery for a server whose local addresses are all dead and whose remote address
/// answers at once (Trello: "Plex discovery waits up to 12s on a server's dead local
/// addresses"). Measured on a living room Apple TV 2026-10-31: a shared server with 8 dead
/// local candidates settled at 7.3 s and 12.0 s in 2 of 4 runs, though its remote answered in
/// 0.2 to 0.4 s and the 3 s grace window for local-only candidates should have ended the wait.
///
/// The first two tests run the REAL `bestReachableURI` with the REAL `testReachable`
/// (URLSession, the app's timeouts) for the remote candidates, and every candidate's start,
/// end and result goes into a timeline that is attached to the result and quoted in every
/// failure message.
///
/// What they assert is the grace window: the wait from the first hit to the answer. Not the
/// total, which also holds how long the stand-in server took to answer, and that is the
/// runner's business (a loaded CI machine with three simulator clones), not the app's.
///
/// Every dead candidate fails the same way on any machine:
/// - seven of the eight locals are stand-ins that take the app's local timeout (12 s) and
///   honour cancellation, as `testAGraceWindowShrinks...` below does. They used to be RFC 5737
///   addresses (192.0.2.x and so on): measured here they black-hole for the full 12 s, but a
///   network can just as well refuse or route them, so what the test measured depended on
///   the runner.
/// - the eighth local is real: a loopback server that accepts and never answers, so a real
///   URLSession request has to be cancelled when the grace ends, or the wait runs to 12 s.
/// - the remote that has already failed is a loopback server that accepts and closes, held
///   open for the whole test. It used to be a port opened and closed just before the run,
///   which relies on the OS refusing at once and on nothing else taking the port; measured
///   here it refused in 30 ms or less every time, but a run on GitHub's macOS runners settled
///   late twice (2026-11-04, runs 41850712310 and 41874032385) and the log could not say which
///   candidate held it.
final class PlexDiscoveryDeadLocalHarnessTests: XCTestCase {

    /// The app's local probe timeout (`testReachable`, patient=false).
    private static let localTimeoutNanos: UInt64 = 12_000_000_000
    /// `bestReachableURI`'s grace while only local candidates are pending.
    private static let localGrace = 3.0

    private static let standInLocals: [PlexAPIService.ConnectionCandidate] =
        (1...4).map { .init(uri: "http://192.0.2.\($0):32400", local: true, relay: false) }
        + (1...2).map { .init(uri: "http://198.51.100.\($0):32400", local: true, relay: false) }
        + [.init(uri: "https://203.0.113.1:32400", local: true, relay: false)]

    /// Answers /identity and /library/sections like a Plex server, after `delayMs`.
    private func remote(delayMs: Int) async throws -> LoopbackJSONServer {
        let server = try LoopbackJSONServer { path, _ in
            switch path {
            case "/identity": return LoopbackReply(delayMs: delayMs, body: ["MediaContainer": ["machineIdentifier": "m"]])
            case "/library/sections": return LoopbackReply(delayMs: delayMs, body: ["MediaContainer": ["Directory": []]])
            default: return nil
            }
        }
        try await server.start()
        return server
    }

    /// One discovery, recorded. `real` candidates go through the app's `testReachable`; every
    /// other one is a stand-in that never answers before the local timeout.
    private struct Run {
        var events: [(t: Double, uri: String, ok: Bool?)] = []
        var uri: String?
        var settledAt = 0.0

        /// When the first candidate answered.
        var firstHitAt: Double? { events.first { $0.ok == true }.map(\.t) }
        /// From the first hit to the answer: the grace window as served.
        var grace: Double? { firstHitAt.map { settledAt - $0 } }
        func endedAt(_ uri: String) -> (t: Double, ok: Bool)? {
            events.first { $0.uri == uri && $0.ok != nil }.map { ($0.t, $0.ok!) }
        }
        var text: String {
            events.map { e in
                String(format: "%6.2fs ", e.t) + (e.ok.map { "end   \(e.uri) ok=\($0)" } ?? "start \(e.uri)")
            }.joined(separator: "\n") + String(format: "\n%6.2fs returned %@", settledAt, uri ?? "nil")
        }
        var summary: String {
            String(format: "firstHit=%@ settled=%.2fs grace=%@", firstHitAt.map { String(format: "%.2fs", $0) } ?? "none",
                   settledAt, grace.map { String(format: "%.2fs", $0) } ?? "n/a")
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date()
        private var events: [(t: Double, uri: String, ok: Bool?)] = []
        func note(_ uri: String, ok: Bool?) {
            lock.lock(); defer { lock.unlock() }
            events.append((Date().timeIntervalSince(start), uri, ok))
        }
        var now: Double { Date().timeIntervalSince(start) }
        var all: [(t: Double, uri: String, ok: Bool?)] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func discover(_ candidates: [PlexAPIService.ConnectionCandidate], real: Set<String>) async -> Run {
        let rec = Recorder()
        let uri = await PlexAPIService.bestReachableURI(connections: candidates) { c, patient in
            rec.note(c.uri, ok: nil)
            let ok: Bool
            if real.contains(c.uri) {
                ok = await PlexAPIService.testReachable(uri: c.uri, token: "t", patient: patient)
            } else {
                try? await Task.sleep(nanoseconds: Self.localTimeoutNanos)
                ok = false
            }
            rec.note(c.uri, ok: ok)
            return ok
        }
        var run = Run()
        run.settledAt = rec.now
        run.uri = uri
        run.events = rec.all
        return run
    }

    /// Every run's timeline, kept with the result so a CI failure shows the numbers.
    private func attach(_ name: String, _ runs: [Run]) {
        let body = runs.enumerated().map { "run \($0 + 1): \($1.summary)\n\($1.text)" }.joined(separator: "\n\n")
        print("[DISCOVERY-HARNESS] \(name)\n\(body)")
        let a = XCTAttachment(string: body)
        a.name = "\(name).txt"
        a.lifetime = .keepAlways
        add(a)
    }

    /// The remote answers in about 0.3 s; nothing local ever does. With only local candidates
    /// pending the grace is 3 s, so the answer comes 3 s after the hit: not at once (the locals
    /// still get their window) and never at the locals' 12 s timeout.
    func testDeadLocalAddressesDoNotHoldUpAFastRemote() async throws {
        let server = try await remote(delayMs: 150)
        defer { server.stop() }
        let blackHole = try await LoopbackSilentServer.start(mode: .neverAnswer)
        defer { blackHole.stop() }
        let realLocal = PlexAPIService.ConnectionCandidate(uri: blackHole.url, local: true, relay: false)
        let live = PlexAPIService.ConnectionCandidate(uri: server.url, local: false, relay: false)
        var runs: [Run] = []
        for _ in 1...4 {
            runs.append(await discover(Self.standInLocals + [realLocal, live], real: [realLocal.uri, live.uri]))
        }
        attach("dead-locals", runs)
        for (i, r) in runs.enumerated() {
            let at = "run \(i + 1) (\(r.summary)):\n\(r.text)"
            XCTAssertEqual(r.uri, server.url, at)
            guard let grace = r.grace else { XCTFail("no candidate answered, " + at); continue }
            XCTAssertLessThan(grace, Self.localGrace + 2, "the wait after the hit ran past the 3 s grace, " + at)
            XCTAssertGreaterThan(grace, Self.localGrace - 0.5, "the locals did not get their grace, " + at)
            XCTAssertNotEqual(r.endedAt(realLocal.uri)?.ok, true, "the black-hole local answered, " + at)
        }
    }

    /// The same, with a second remote ranked ahead of the live one that fails at once (on a TV,
    /// say, an address the network refuses). Once it has failed, only local candidates still
    /// outrank the live remote, so the 3 s grace applies, not the 15 s one for a pending remote.
    func testARemoteThatAlreadyFailedDoesNotStretchTheGrace() async throws {
        let server = try await remote(delayMs: 150)
        defer { server.stop() }
        let refusing = try await LoopbackSilentServer.start(mode: .closeAtOnce)
        defer { refusing.stop() }
        let dead = PlexAPIService.ConnectionCandidate(uri: "https://127.0.0.1:\(refusing.port)", local: false, relay: false)
        let live = PlexAPIService.ConnectionCandidate(uri: server.url, local: false, relay: false)
        var runs: [Run] = []
        for _ in 1...2 {
            runs.append(await discover(Self.standInLocals + [dead, live], real: [dead.uri, live.uri]))
        }
        attach("failed-remote", runs)
        for (i, r) in runs.enumerated() {
            let at = "run \(i + 1) (\(r.summary)):\n\(r.text)"
            XCTAssertEqual(r.uri, server.url, at)
            guard let grace = r.grace, let hit = r.firstHitAt else { XCTFail("no candidate answered, " + at); continue }
            // The precondition the property needs: the remote ahead has failed, and soon.
            guard let deadEnd = r.endedAt(dead.uri) else { XCTFail("the failing remote never reported, " + at); continue }
            XCTAssertFalse(deadEnd.ok, at)
            XCTAssertLessThan(deadEnd.t, hit + Self.localGrace, "the failing remote took too long to fail for this to test anything, " + at)
            XCTAssertLessThan(grace, Self.localGrace + 2, "a remote that had failed still stretched the grace, " + at)
            XCTAssertGreaterThan(grace, Self.localGrace - 0.5, "the locals did not get their grace, " + at)
        }
    }

    /// The order the other way round, with timed stand-ins for the probes so it is exact: the
    /// live remote answers at 0.3 s, the remote ranked ahead of it fails at 1.0 s, the locals
    /// never answer (12 s, the app's local timeout). From 1.0 s nothing patient is left ahead
    /// of the hit, so the wait ends 3 s after the hit, not when the locals time out.
    func testAGraceWindowShrinksWhenThePatientCandidatesAheadFail() async {
        let live = PlexAPIService.ConnectionCandidate(uri: "http://192.0.2.200:32400", local: false, relay: false)
        let dead = PlexAPIService.ConnectionCandidate(uri: "https://192.0.2.201:32400", local: false, relay: false)
        let start = Date()
        let uri = await PlexAPIService.bestReachableURI(connections: Self.standInLocals + [dead, live]) { c, _ in
            let (ms, ok): (UInt64, Bool) = c == live ? (300, true) : c == dead ? (1_000, false) : (12_000, false)
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            return ok && !Task.isCancelled
        }
        let seconds = Date().timeIntervalSince(start)
        print("[DISCOVERY-HARNESS] timed, patient fails after the hit: \(String(format: "%.2f", seconds))s")
        XCTAssertEqual(uri, live.uri)
        XCTAssertLessThan(seconds, 5)
        XCTAssertGreaterThan(seconds, 3, "the locals still get their 3 s")
    }

    /// Control: a remote ranked ahead that is still working on it keeps its long grace, so a
    /// slow but real better connection is never traded away (the 15 s rule).
    func testAPatientCandidateStillPendingKeepsTheLongGrace() async {
        let live = PlexAPIService.ConnectionCandidate(uri: "http://192.0.2.200:32400", local: false, relay: false)
        let slow = PlexAPIService.ConnectionCandidate(uri: "https://192.0.2.201:32400", local: false, relay: false)
        let start = Date()
        let uri = await PlexAPIService.bestReachableURI(connections: [slow, live]) { c, _ in
            let (ms, ok): (UInt64, Bool) = c == live ? (300, true) : (6_000, true)
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            return ok && !Task.isCancelled
        }
        let seconds = Date().timeIntervalSince(start)
        print("[DISCOVERY-HARNESS] timed, slow better remote: \(String(format: "%.2f", seconds))s -> \(uri ?? "nil")")
        XCTAssertEqual(uri, slow.uri, "the better connection answered inside its grace and wins")
    }
}
