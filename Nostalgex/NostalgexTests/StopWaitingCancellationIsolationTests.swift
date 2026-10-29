import XCTest
import Darwin
@testable import Nostalgex

/// Isolates one question raised while investigating GitHub issue #146: does cancelling the
/// Swift `Task` wrapping a `URLSession.data(for:)` call actually interrupt that call quickly
/// when the server has accepted the TCP connection but sent nothing back (the "stopped
/// responding" case), or does the call keep running underneath until its own 60s
/// `timeoutIntervalForRequest` fires regardless of cancellation?
///
/// Runs in a couple of seconds, independent of `PlexAPIService`'s hardcoded 60s timeout and
/// the real stall watch's 2s poll / 210s threshold, so this isolates the `URLSession` /
/// `Task` cancellation behavior itself.
final class StopWaitingCancellationIsolationTests: XCTestCase {

    final class HungServer: @unchecked Sendable {
        private let fd: Int32
        let port: UInt16
        private var stopped = false
        private let lock = NSLock()

        init() throws {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { throw XCTSkip("could not open a socket") }
            var reuse: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { close(s); throw XCTSkip("could not bind a loopback port") }
            var assigned = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
            }
            self.port = UInt16(bigEndian: assigned.sin_port)
            self.fd = s
            listen(s, 16)
            let thread = Thread { [weak self] in self?.acceptLoop() }
            thread.start()
        }

        private func acceptLoop() {
            while true {
                let client = accept(fd, nil, nil)
                lock.lock(); let shouldStop = stopped; lock.unlock()
                if shouldStop { if client >= 0 { close(client) }; break }
                if client < 0 { break }
                // never read or write
            }
        }

        func stop() { lock.lock(); stopped = true; lock.unlock(); close(fd) }
    }

    /// A plain `URLSession.data(for:)` call against a server that never answers, cancelled
    /// from another Task about 500ms in. If `URLSession` honours `Task` cancellation here,
    /// this test finishes in well under a second past the cancel. If it doesn't, it will
    /// hang until this test's own 5s guard timeout fires, which is the measurement.
    func testPlainURLSessionDataForCancelsPromptlyOnAHungConnection() async throws {
        let server = try HungServer()
        defer { server.stop() }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60 // same as PlexAPIService.session
        let session = URLSession(configuration: config)
        let url = URL(string: "http://127.0.0.1:\(server.port)/library/sections")!

        let started = Date()
        let work = Task { try await session.data(for: URLRequest(url: url)) }

        try await Task.sleep(nanoseconds: 500_000_000)
        work.cancel()

        let outcome: String
        do {
            // Race the real call against a 5s guard so a non-responsive cancel doesn't
            // stall this test for the full 60s timeout.
            outcome = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    _ = try await work.value
                    return "completed"
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return "guard-timeout (cancel did not propagate within 5s)"
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            let ns = error as NSError
            outcome = "threw after \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(ns.domain) \(ns.code)"
        }
        let elapsed = Date().timeIntervalSince(started)
        print("[CANCELISO] outcome=\(outcome) elapsedSinceStart=\(String(format: "%.2f", elapsed))s")
        XCTContext.runActivity(named: "measured outcome") { _ in }
        // Not an assertion on which way it goes, this test exists to measure it, per the
        // "never diagnose by reasoning alone" rule. The elapsed time printed above is the
        // answer: well under 60s means URLSession cancellation works here; at/after 5s with
        // "guard-timeout" means it does not propagate promptly against a silent connection.
    }
}
