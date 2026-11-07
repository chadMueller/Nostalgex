import XCTest
import Network
@testable import Nostalgex

/// N-038: Plex logs "Missing X-Plex-Container-Size header, will fail with status 400 in the
/// future" for the collection requests, because only the section item fetch sent one.
///
/// The fake server does what that warning promises and a bit more:
/// - a list request without `X-Plex-Container-Size` (query or header) gets a 400;
/// - no response carries more than 100 rows, however many were asked for, and each says how
///   many there are in all (`totalSize`) and how many it holds (`size`).
///
/// So a client that sends no size fails, and one that sends a single big size and stops
/// after the first page loses everything past row 100. The 318 collections are I-068's case.
final class PlexContainerSizeTests: XCTestCase {

    private static let collectionCount = 318
    private static let bigCollectionChildren = 1_250
    private static let episodeCount = 250
    private static let serverPageCap = 100

    // MARK: Fake Plex

    struct Hit { let path: String; let hadSize: Bool; let status: Int }

    private final class Server: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "plex-container-size-server", attributes: .concurrent)
        private let lock = NSLock()
        private var log: [Hit] = []
        private(set) var port: UInt16 = 0
        /// A legacy server: ignores paging and sends everything in one response, with no totals.
        let ignoresPaging: Bool

        init(ignoresPaging: Bool = false) throws {
            self.ignoresPaging = ignoresPaging
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        var hits: [Hit] { lock.lock(); defer { lock.unlock() }; return log }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .global())
                self?.read(conn, buffer: Data())
            }
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
            let lines = head.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://x\(target)")
            var query: [String: String] = [:]
            for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
            let path = comps?.path ?? target
            let headerSize = lines.dropFirst().contains { $0.lowercased().hasPrefix("x-plex-container-size:") }
            let hadSize = query["X-Plex-Container-Size"] != nil || headerSize

            let (status, body) = answer(path: path, query: query, hadSize: hadSize)
            lock.lock(); log.append(Hit(path: path, hadSize: hadSize, status: status)); lock.unlock()
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            var out = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(data)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }

        private func page(_ rows: [[String: Any]], query: [String: String]) -> [String: Any] {
            if ignoresPaging { return ["MediaContainer": ["Metadata": rows]] }
            let start = Int(query["X-Plex-Container-Start"] ?? "0") ?? 0
            let asked = Int(query["X-Plex-Container-Size"] ?? "0") ?? 0
            let take = min(asked, PlexContainerSizeTests.serverPageCap)
            let slice = Array(rows.dropFirst(start).prefix(take))
            return ["MediaContainer": ["size": slice.count, "totalSize": rows.count, "offset": start, "Metadata": slice]]
        }

        private func answer(path: String, query: [String: String], hadSize: Bool) -> (Int, Any) {
            let parts = path.split(separator: "/").map(String.init)
            if path == "/library/sections" {
                return (200, ["MediaContainer": ["Directory": [
                    ["key": "1", "title": "Movies", "type": "movie"],
                    ["key": "2", "title": "TV Shows", "type": "show"],
                ]]])
            }
            // /library/sections/{k}/collections
            if parts.count == 4, parts[2] == "1", parts[3] == "collections" {
                guard ignoresPaging || hadSize else { return (400, [:]) }
                let rows = (0 ..< PlexContainerSizeTests.collectionCount).map { i -> [String: Any] in
                    ["ratingKey": "c\(i)", "title": "Collection \(i)", "childCount": i == 0 ? PlexContainerSizeTests.bigCollectionChildren : 3, "thumb": "/t/\(i)"]
                }
                return (200, page(rows, query: query))
            }
            // /library/collections/{k}/children
            if parts.count == 4, parts[1] == "collections", parts[3] == "children" {
                guard ignoresPaging || hadSize else { return (400, [:]) }
                let n = parts[2] == "c0" ? PlexContainerSizeTests.bigCollectionChildren : (parts[2] == "c1" ? 400 : 7)
                let rows = (0 ..< n).map { ["ratingKey": "\(parts[2])-m\($0)", "title": "Movie \($0)"] as [String: Any] }
                return (200, page(rows, query: query))
            }
            // /library/metadata/{show}/allLeaves
            if parts.count == 4, parts[1] == "metadata", parts[3] == "allLeaves" {
                guard ignoresPaging || hadSize else { return (400, [:]) }
                let rows = (0 ..< PlexContainerSizeTests.episodeCount).map { e in
                    StopWaitingHarnessTests.episode("2", 0, e)
                }
                return (200, page(rows, query: query))
            }
            // /library/sections/{k}/all: the section items, paged by the app already.
            if parts.count == 4, parts[3] == "all" {
                if parts[2] == "2", query["type"] == "4" {
                    return (200, ["MediaContainer": ["size": 0, "totalSize": 0, "Metadata": []]])   // a server that ignores type=4
                }
                if parts[2] == "2" {
                    return (200, ["MediaContainer": ["size": 1, "totalSize": 1, "Metadata": [StopWaitingHarnessTests.show("2", 0)]]])
                }
                return (200, ["MediaContainer": ["size": 0, "totalSize": 0, "Metadata": []]])
            }
            return (404, [:])
        }
    }

    private func api(_ server: Server) -> PlexAPIService {
        PlexAPIService(serverURL: "http://127.0.0.1:\(server.port)", token: "t", serverID: "container-size")
    }

    // MARK: Collections

    func testAllCollectionsLoadAcrossPages() async throws {
        let server = try Server()
        try await server.start()
        defer { server.stop() }
        let collections = try await api(server).loadCollections(sectionKey: "1")
        XCTAssertEqual(collections.count, Self.collectionCount, "318 collections, a server that never sends more than 100 at a time")
        XCTAssertEqual(collections.map(\.ratingKey), (0 ..< Self.collectionCount).map { "c\($0)" }, "in order, none twice")
    }

    func testALargeCollectionLoadsEveryChild() async throws {
        let server = try Server()
        try await server.start()
        defer { server.stop() }
        let keys = try await api(server).loadCollectionItems(collectionKey: "c0")
        XCTAssertEqual(keys.count, Self.bigCollectionChildren)
        XCTAssertEqual(keys, (0 ..< Self.bigCollectionChildren).map { "c0-m\($0)" })
        let small = try await api(server).loadCollectionItems(collectionKey: "c2")
        XCTAssertEqual(small.count, 7)
    }

    func testEveryListRequestCarriesAContainerSize() async throws {
        let server = try Server()
        try await server.start()
        defer { server.stop() }
        _ = try? await api(server).loadCollections(sectionKey: "1")
        _ = try? await api(server).loadCollectionItems(collectionKey: "c0")
        let hits = server.hits.filter { $0.path.hasSuffix("/collections") || $0.path.hasSuffix("/children") }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.filter { !$0.hadSize }.map(\.path), [], "requests with no X-Plex-Container-Size")
        XCTAssertEqual(hits.filter { $0.status == 400 }.count, 0, "a server that answers 400 without one")
    }

    // MARK: A server that ignores paging

    func testAServerThatIgnoresPagingStillReturnsEverythingOnce() async throws {
        let server = try Server(ignoresPaging: true)
        try await server.start()
        defer { server.stop() }
        // More rows than one page asks for: a client that trusts "a full page means more" would ask again forever.
        let keys = try await api(server).loadCollectionItems(collectionKey: "c1")
        XCTAssertEqual(keys.count, 400)
        XCTAssertLessThanOrEqual(server.hits.filter { $0.path.hasSuffix("/children") }.count, 2, "no loop")
        let few = try await api(server).loadCollectionItems(collectionKey: "c2")
        XCTAssertEqual(few.count, 7)
    }

    // MARK: Episodes, one show at a time

    /// A server that ignores `type=4` sends the app to the per-show crawl, which asks for
    /// `/library/metadata/{show}/allLeaves`. 250 episodes, 100 a response.
    func testTheShowCrawlLoadsEveryEpisode() async throws {
        let server = try Server()
        try await server.start()
        defer { server.stop() }
        let items = try await api(server).loadLibrary(excludedSectionKeys: ["1"], progress: nil)
        XCTAssertEqual(items.count, Self.episodeCount, "every episode of the show, not the first page of them")
        let leaves = server.hits.filter { $0.path.hasSuffix("/allLeaves") }
        XCTAssertFalse(leaves.isEmpty)
        XCTAssertEqual(leaves.filter { !$0.hadSize }.count, 0, "allLeaves requests with no container size")
    }
}
