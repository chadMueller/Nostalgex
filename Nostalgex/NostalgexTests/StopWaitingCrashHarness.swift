import XCTest
import Darwin
@testable import Nostalgex

/// GitHub issue #146 (androbwebb, 2026-10-29): a Plex user with several large libraries
/// (sections) says a couple of them "stop responding" during initial scan, and pressing
/// "Stop Waiting" is "about 50/50 that it accepts and moves on vs just crashing the whole
/// app". Multiple servers/sections stalling in the same scan is what they describe.
///
/// This harness drives the REAL `loadLibrary()` / `stopWaitingForLibraryScan()` path
/// against two servers whose connections never answer (a raw TCP listener that accepts
/// and then reads/writes nothing), so the real `dataWithRetry` → `withLibraryLoadStallWatch`
/// → cancellation plumbing runs exactly as it would against a frozen Plex Media Server,
/// not a fixture that bypasses it. If any step traps (force unwrap, exclusivity violation,
/// anything else fatal), the XCTest process itself dies and the run is reported as a crash,
/// not a normal failure.
///
/// Off by default (opens real sockets, takes a few seconds): run directly with
///     -only-testing:NostalgexTests/StopWaitingCrashHarness
@MainActor
final class StopWaitingCrashHarness: XCTestCase {

    // MARK: - A server that accepts but never answers

    /// Binds to loopback on an OS-assigned port, accepts connections, and does nothing
    /// else: no read, no write, no close. Any request against it hangs exactly the way a
    /// Plex Media Server that has "stopped responding" would, until something external
    /// (our cancellation, or the 60s `timeoutIntervalForRequest`) ends it.
    final class HungServer: @unchecked Sendable {
        private let fd: Int32
        let port: UInt16
        private var stopped = false
        private let lock = NSLock()
        private var clientFDs: [Int32] = []

        init() throws {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { throw XCTSkip("could not open a socket") }
            var reuse: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0 // ask the OS for a free port
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { close(s); throw XCTSkip("could not bind a loopback port") }

            var assigned = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(s, $0, &len)
                }
            }
            self.port = UInt16(bigEndian: assigned.sin_port)
            self.fd = s
            listen(s, 16)

            let thread = Thread { [weak self] in self?.acceptLoop() }
            thread.name = "HungServer-accept"
            thread.start()
        }

        private func acceptLoop() {
            while true {
                let client = accept(fd, nil, nil)
                lock.lock()
                let shouldStop = stopped
                lock.unlock()
                if shouldStop { if client >= 0 { close(client) }; break }
                if client < 0 { break }
                lock.lock(); clientFDs.append(client); lock.unlock()
                // Deliberately never read or write: the connection just sits open.
            }
        }

        func stop() {
            lock.lock()
            stopped = true
            let clients = clientFDs
            clientFDs = []
            lock.unlock()
            for c in clients { close(c) }
            close(fd)
        }
    }

    // MARK: - In-memory credential store (same shape as BigLibraryHarness's)

    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    // MARK: - Tests

    /// Two servers that never answer, standing in for "a couple of libraries stop
    /// responding." Presses STOP WAITING once per server, the way the user describes doing
    /// repeatedly across several stalled libraries in one setup pass.
    func testStopWaitingAcrossTwoStalledServersDoesNotCrash() async throws {
        let serverA = try HungServer()
        let serverB = try HungServer()
        defer { serverA.stop(); serverB.stop() }

        let refA = AppState.ServerRef(machineIdentifier: "hung-a", name: "VaultA",
                                       baseURL: "http://127.0.0.1:\(serverA.port)", owned: true, token: "ta")
        let refB = AppState.ServerRef(machineIdentifier: "hung-b", name: "VaultB",
                                       baseURL: "http://127.0.0.1:\(serverB.port)", owned: true, token: "tb")

        let store = InMemoryStore()
        let state = AppState(credentialStore: store)
        state.backendOverride = { server in
            PlexAPIService(serverURL: server?.baseURL ?? "", token: server?.token ?? "t",
                            serverID: server?.machineIdentifier ?? "")
        }
        state.completePlexSignIn(token: "account-token", servers: [refA, refB])

        let loadTask = Task { await state.loadLibrary() }

        // Give the scan a moment to issue its first (hanging) request against server A.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(state.isLoading, "load should still be running against the hung server")
        state.stopWaitingForLibraryScan() // "Stop Waiting" for server A

        // withLibraryLoadStallWatch polls every 2s; give it two ticks to notice the cancel
        // request, abandon server A, and move on to server B (which will also hang).
        try await Task.sleep(nanoseconds: 4_200_000_000)
        state.stopWaitingForLibraryScan() // "Stop Waiting" again, for server B

        // If any step above traps (force unwrap, exclusivity violation, anything fatal),
        // the test process dies here and the run reports a crash, not a normal failure.
        await loadTask.value

        XCTAssertFalse(state.isLoading, "loadLibrary should have resolved, not hung forever")
        XCTAssertFalse(state.isLoadStalling, "stall flag should be cleared once the load resolves")
        print("[STOPWAIT] single-tap result: channels=\(state.allChannels.count) items=\(state.allItems.count) error=\(state.errorMessage ?? "nil") stale=\(state.isLibraryStale)")
    }

    /// Simulates a Siri Remote double-click / UI lag: several rapid presses on the same
    /// stall, the way a frustrated user mashes a button that looks unresponsive.
    func testRapidRepeatedStopWaitingDoesNotCrash() async throws {
        let server = try HungServer()
        defer { server.stop() }

        let ref = AppState.ServerRef(machineIdentifier: "hung-rapid", name: "VaultRapid",
                                      baseURL: "http://127.0.0.1:\(server.port)", owned: true, token: "t")

        let store = InMemoryStore()
        let state = AppState(credentialStore: store)
        state.backendOverride = { server in
            PlexAPIService(serverURL: server?.baseURL ?? "", token: server?.token ?? "t",
                            serverID: server?.machineIdentifier ?? "")
        }
        state.completePlexSignIn(token: "account-token", servers: [ref])

        let loadTask = Task { await state.loadLibrary() }
        try await Task.sleep(nanoseconds: 300_000_000)

        // Five taps inside one frame's worth of time, before the watcher's first poll.
        for _ in 0..<5 { state.stopWaitingForLibraryScan() }

        await loadTask.value
        XCTAssertFalse(state.isLoading)
        print("[STOPWAIT] rapid-tap result: channels=\(state.allChannels.count) error=\(state.errorMessage ?? "nil")")
    }

    /// Presses STOP WAITING, then immediately starts a brand-new `loadLibrary()` call
    /// before the first one has unwound (a relaunch, or the user backing out and back in
    /// while the cancelled scan is still resolving). This is the shape of "crashed and had
    /// to start over from the beginning" if a leftover task from the old scan touches state
    /// a fresh scan is also mutating.
    func testStopWaitingThenImmediateRestartDoesNotCrash() async throws {
        let server = try HungServer()
        defer { server.stop() }

        let ref = AppState.ServerRef(machineIdentifier: "hung-restart", name: "VaultRestart",
                                      baseURL: "http://127.0.0.1:\(server.port)", owned: true, token: "t")

        let store = InMemoryStore()
        let state = AppState(credentialStore: store)
        state.backendOverride = { server in
            PlexAPIService(serverURL: server?.baseURL ?? "", token: server?.token ?? "t",
                            serverID: server?.machineIdentifier ?? "")
        }
        state.completePlexSignIn(token: "account-token", servers: [ref])

        let firstLoad = Task { await state.loadLibrary() }
        try await Task.sleep(nanoseconds: 300_000_000)
        state.stopWaitingForLibraryScan()

        // Don't await firstLoad, start the next one right away, the way a relaunch would,
        // while the cancelled scan's cleanup (watcher.cancel(), work.cancel(), the per-server
        // catch blocks) is still in flight.
        try await Task.sleep(nanoseconds: 50_000_000)
        let secondLoad = Task { await state.loadLibrary() }

        await firstLoad.value
        await secondLoad.value

        XCTAssertFalse(state.isLoading)
        print("[STOPWAIT] restart-race result: channels=\(state.allChannels.count) error=\(state.errorMessage ?? "nil")")
    }
}
