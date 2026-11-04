import XCTest
import Network
@testable import Nostalgex

/// A big Emby or Jellyfin movie library must look alive to the stall watch while it pages in.
///
/// Discord report, 2026-11-03: an Emby library of about 15,000 movies never finished loading.
/// Measured against a fake Emby (MovieLibraryScaleHarness, 15,000 movies, 200 a page, 3 s a
/// page): the scan reported no progress for the whole section, because Emby and Jellyfin only
/// reported when a section started. The stall watch saw an item count stuck at 0, showed
/// STOP WAITING at 65 s and abandoned the scan at 210 s with the server still answering
/// (71 of 75 pages served). The request it cancelled then threw away all 14,200 movies already
/// read, so the load ended on "Your server stopped sending data" with nothing.
///
/// The Plex scan already did both things right: a progress event per page, and the pages
/// read are kept when a request is cancelled mid-flight. These tests hold Emby and Jellyfin
/// to the same two rules against a small local server (1,000 movies, 5 pages).
final class MovieSectionScanProgressTests: XCTestCase {

    private static let movieCount = 1_000
    private static let pageSize = 200

    private static func movie(_ i: Int) -> [String: Any] {
        let ticks = Int64(90 + i % 60) * 60 * 10_000_000
        return ["Id": "m\(i)", "Name": "Movie \(i)", "Type": "Movie", "RunTimeTicks": ticks,
                "Genres": ["Drama"], "ProviderIds": ["Tmdb": "\(10_000 + i)"],
                "MediaSources": [["Id": "ms\(i)", "Container": "mkv", "RunTimeTicks": ticks]]]
    }

    /// Movies library. `slowFrom`: pages starting at or after this index are held back
    /// `slowMs`, so a test can cancel while one of them is in flight.
    private static func reply(path: String, query: [String: String], slowFrom: Int, slowMs: Int) -> (delayMs: Int, body: Any)? {
        if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
            return (0, ["Items": [["Id": "movies", "Name": "Movies", "CollectionType": "movies"]], "TotalRecordCount": 1])
        }
        guard path.hasSuffix("/Items"), query["ParentId"] == "movies" else { return nil }
        let start = Int(query["StartIndex"] ?? "0") ?? 0
        let limit = Int(query["Limit"] ?? "\(pageSize)") ?? pageSize
        let page = (start..<min(start + limit, movieCount)).map(movie)
        return (start >= slowFrom ? slowMs : 0, ["Items": page, "TotalRecordCount": movieCount])
    }

    private enum Backend: CaseIterable { case emby, jellyfin }

    private func service(_ backend: Backend, url: String) -> any MediaBackend {
        switch backend {
        case .emby: return EmbyAPIService(serverURL: url, accessToken: "t", userId: "u")
        case .jellyfin: return JellyfinAPIService(serverURL: url, accessToken: "t", userId: "u")
        }
    }

    /// Collects progress events from the scan's @Sendable callback.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int] = []
        func add(_ n: Int) { lock.lock(); counts.append(n); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    }

    func testAMovieSectionReportsEveryPage() async throws {
        for backend in Backend.allCases {
            let server = try FakeServer { Self.reply(path: $0, query: $1, slowFrom: .max, slowMs: 0) }
            try await server.start()
            defer { server.stop() }
            let events = Events()
            let items = try await service(backend, url: "http://127.0.0.1:\(server.port)")
                .loadLibrary(excludedSectionKeys: []) { events.add($0.itemsLoadedSoFar) }
            XCTAssertEqual(items.count, Self.movieCount, "\(backend)")
            // Section start (0) then one event per page: 200, 400, ..., 1000.
            let counts = events.all
            XCTAssertEqual(counts, [0] + stride(from: Self.pageSize, through: Self.movieCount, by: Self.pageSize).map { $0 },
                           "\(backend): the item count must move with every page, or the stall watch reads a live scan as dead")
        }
    }

    func testCancellingMidPageKeepsThePagesAlreadyRead() async throws {
        for backend in Backend.allCases {
            // Pages from 600 on take 5 s: cancel while the fourth page is in flight.
            let server = try FakeServer { Self.reply(path: $0, query: $1, slowFrom: 600, slowMs: 5_000) }
            try await server.start()
            defer { server.stop() }
            let events = Events()
            let api = service(backend, url: "http://127.0.0.1:\(server.port)")
            let scan = Task { try await api.loadLibrary(excludedSectionKeys: []) { events.add($0.itemsLoadedSoFar) } }
            let deadline = Date().addingTimeInterval(4)
            while (events.all.last ?? 0) < 600, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try await Task.sleep(nanoseconds: 200_000_000)   // the 600 page is now in flight
            scan.cancel()
            do {
                let items = try await scan.value
                XCTFail("\(backend): a cancelled scan should report itself interrupted, got \(items.count) items")
            } catch let interrupted as LibraryScanInterrupted {
                XCTAssertEqual(interrupted.partialItems.count, 600,
                               "\(backend): the three pages read before the cancel must survive it")
            } catch {
                XCTFail("\(backend): the pages already read were thrown away with the cancelled request (\(error))")
            }
        }
    }

    // MARK: - Fake server

    /// Minimal HTTP/1.1 on 127.0.0.1, one request per connection (as EpisodeBatchOrderHarnessTests).
    private final class FakeServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "movie-scan-fake-server", attributes: .concurrent)
        private let route: @Sendable (String, [String: String]) -> (delayMs: Int, body: Any)?
        private(set) var port: UInt16 = 0

        init(route: @escaping @Sendable (String, [String: String]) -> (delayMs: Int, body: Any)?) throws {
            self.route = route
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            let gate = NSLock()
            var resumed = false
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    gate.lock(); defer { gate.unlock() }
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; cont.resume()
                    case .failed(let e): resumed = true; cont.resume(throwing: e)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            port = listener.port?.rawValue ?? 0
        }

        func stop() { listener.cancel() }

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
            let reply = route(comps?.path ?? target, query)
            let body = (try? JSONSerialization.data(withJSONObject: reply?.body ?? [:])) ?? Data()
            let status = reply == nil ? "404 Not Found" : "200 OK"
            var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(body)
            queue.asyncAfter(deadline: .now() + .milliseconds(reply?.delayMs ?? 0)) {
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }
}
