import XCTest
@testable import Nostalgex

/// Plex discovery for a server whose local addresses are all dead and whose remote address
/// answers at once (Trello: "Plex discovery waits up to 12s on a server's dead local
/// addresses"). Measured on a living room Apple TV 2026-10-31: a shared server with 8 dead
/// local candidates settled at 7.3 s and 12.0 s in 2 of 4 runs, though its remote answered in
/// 0.2 to 0.4 s and the 3 s grace window for local-only candidates should have ended the wait.
///
/// This runs the REAL `bestReachableURI` with the REAL `testReachable` (URLSession, the app's
/// timeouts) against synthetic dead addresses in the documentation ranges (RFC 5737:
/// 192.0.2.x, 198.51.100.x, 203.0.113.x; nothing answers there) and a loopback server that
/// stands in for the server's remote address. Every probe's start, end and result is logged.
final class PlexDiscoveryDeadLocalHarnessTests: XCTestCase {

    private static let deadLocals: [PlexAPIService.ConnectionCandidate] =
        (1...4).map { .init(uri: "http://192.0.2.\($0):32400", local: true, relay: false) }
        + (1...2).map { .init(uri: "http://198.51.100.\($0):32400", local: true, relay: false) }
        + (1...2).map { .init(uri: "https://203.0.113.\($0):32400", local: true, relay: false) }

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

    private final class Timeline: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date()
        private var lines: [String] = []
        func note(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(String(format: "%6.2fs ", Date().timeIntervalSince(start)) + s)
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    /// One discovery: 8 dead local candidates, then `before` (remote candidates plex.tv lists
    /// ahead of the live one), then the live remote. Returns the URI chosen and the seconds
    /// until `bestReachableURI` returned.
    private func discover(remoteURI: String, before: [PlexAPIService.ConnectionCandidate] = []) async -> (uri: String?, seconds: Double, timeline: String) {
        let timeline = Timeline()
        let candidates = Self.deadLocals + before + [.init(uri: remoteURI, local: false, relay: false)]
        let start = Date()
        let uri = await PlexAPIService.bestReachableURI(connections: candidates) { c, patient in
            timeline.note("start \(c.uri) patient=\(patient)")
            let ok = await PlexAPIService.testReachable(uri: c.uri, token: "t", patient: patient)
            timeline.note("end   \(c.uri) ok=\(ok) cancelled=\(Task.isCancelled)")
            return ok
        }
        let seconds = Date().timeIntervalSince(start)
        timeline.note("returned \(uri ?? "nil")")
        return (uri, seconds, timeline.text)
    }

    /// The remote answers in 0.3 s; nothing local ever does. The grace window for local-only
    /// candidates is 3 s, so discovery should be done well inside 5 s, every time.
    func testDeadLocalAddressesDoNotHoldUpAFastRemote() async throws {
        let server = try await remote(delayMs: 150)
        defer { server.stop() }
        var seconds: [Double] = []
        for run in 1...4 {
            let r = await discover(remoteURI: server.url)
            print("[DISCOVERY-HARNESS] run \(run): \(String(format: "%.2f", r.seconds))s -> \(r.uri ?? "nil")\n\(r.timeline)")
            XCTAssertEqual(r.uri, server.url, "run \(run)")
            seconds.append(r.seconds)
        }
        print("[DISCOVERY-HARNESS] settle times: " + seconds.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        for (i, s) in seconds.enumerated() {
            XCTAssertLessThan(s, 5, "run \(i + 1) waited on dead local addresses")
        }
    }

    /// The same, with a second remote address ranked ahead of the live one that fails at once
    /// (here a closed port; on a TV, say, an address the network has no route to). Once it has
    /// failed, only local candidates still outrank the live remote, so the 3 s grace applies.
    func testARemoteThatAlreadyFailedDoesNotStretchTheGrace() async throws {
        let server = try await remote(delayMs: 150)
        defer { server.stop() }
        let closed = try await remote(delayMs: 0)
        let closedPort = closed.port
        closed.stop()
        let dead = PlexAPIService.ConnectionCandidate(uri: "https://127.0.0.1:\(closedPort)", local: false, relay: false)
        var seconds: [Double] = []
        for run in 1...2 {
            let r = await discover(remoteURI: server.url, before: [dead])
            print("[DISCOVERY-HARNESS] refused-remote run \(run): \(String(format: "%.2f", r.seconds))s -> \(r.uri ?? "nil")\n\(r.timeline)")
            XCTAssertEqual(r.uri, server.url, "run \(run)")
            seconds.append(r.seconds)
        }
        print("[DISCOVERY-HARNESS] refused-remote settle times: " + seconds.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        for (i, s) in seconds.enumerated() {
            XCTAssertLessThan(s, 5, "run \(i + 1) waited on dead local addresses")
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
        let uri = await PlexAPIService.bestReachableURI(connections: Self.deadLocals + [dead, live]) { c, _ in
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
