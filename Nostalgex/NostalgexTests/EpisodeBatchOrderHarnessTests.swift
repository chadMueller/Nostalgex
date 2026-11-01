import XCTest
import Network
@testable import Nostalgex

/// A rescan must give the same guide when nothing on the server changed.
///
/// Every backend fetches a TV section's episodes one show at a time, several shows at once.
/// The schedule reads the library in the order it arrives (`interleaveByShow` groups shows
/// in first-seen order before its seeded shuffle), so if that order follows which request
/// happened to finish first, two scans of the same library build two different guides.
///
/// This harness serves one fixed TV library from a local HTTP server inside the test, with
/// each show's episode request held back by a delay, and loads it through the REAL
/// `loadLibrary` of each backend twice: once with the delays in show order, once shuffled.
/// It then builds three days of the guide from each load with the real
/// `DailyManifestScheduler` and counts the channel-minutes that differ. Same library, same
/// guide: the count must be zero.
final class EpisodeBatchOrderHarnessTests: XCTestCase {

    // MARK: - Fixture

    private static let showCount = 40
    private static func showID(_ i: Int) -> String { "show\(i)" }
    private static func episodeCount(_ i: Int) -> Int { 3 + (i * 7) % 9 }
    private static func episodeMinutes(_ show: Int, _ ep: Int) -> Int { [22, 24, 30, 44, 48, 60][(show + ep) % 6] }

    /// Milliseconds to hold back show `i`'s episode request. `shuffled` false: in show
    /// order, so requests finish in the order they were sent. True: a fixed shuffle.
    private static func delayMs(_ i: Int, shuffled: Bool) -> Int {
        guard shuffled else { return 5 * (i % 10) }
        let perm = [7, 2, 9, 0, 5, 3, 8, 1, 6, 4]
        return 25 * perm[i % 10]
    }

    // MARK: - Fake servers

    /// One response: hold `delayMs`, then send `body` as JSON.
    private struct Reply { let delayMs: Int; let body: Any }

    private static func jellyfinReply(path: String, query: [String: String], shuffled: Bool) -> Reply? {
        if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
            return Reply(delayMs: 0, body: ["Items": [["Id": "tv", "Name": "TV", "CollectionType": "tvshows"]], "TotalRecordCount": 1])
        }
        guard path.hasSuffix("/Items") else { return nil }
        let parent = query["ParentId"] ?? ""
        let start = Int(query["StartIndex"] ?? "0") ?? 0
        if parent == "tv", query["IncludeItemTypes"] == "Series" {
            let all: [[String: Any]] = (0..<showCount).map { ["Id": showID($0), "Name": "Show \($0)", "Type": "Series"] }
            return Reply(delayMs: 0, body: ["Items": Array(all.dropFirst(start)), "TotalRecordCount": all.count])
        }
        if parent.hasPrefix("show"), let i = Int(parent.dropFirst(4)), query["IncludeItemTypes"] == "Episode" {
            let eps: [[String: Any]] = (0..<episodeCount(i)).map { e in
                ["Id": "\(showID(i))e\(e)", "Name": "Episode \(e)", "SeriesName": "Show \(i)", "Type": "Episode",
                 "ParentIndexNumber": 1, "IndexNumber": e + 1,
                 "RunTimeTicks": Int64(episodeMinutes(i, e)) * 60 * 10_000_000]
            }
            return Reply(delayMs: delayMs(i, shuffled: shuffled), body: ["Items": Array(eps.dropFirst(start)), "TotalRecordCount": eps.count])
        }
        return nil
    }

    /// Plex. `bulk` false makes the `type=4` sweep come back empty, which sends the app to
    /// its per-show fallback (`fetchEpisodesPerShow`).
    private static func plexReply(path: String, query: [String: String], shuffled: Bool, bulk: Bool) -> Reply? {
        func episodes(_ i: Int) -> [[String: Any]] {
            (0..<episodeCount(i)).map { e in
                ["ratingKey": "\(showID(i))e\(e)", "title": "Episode \(e)", "type": "episode",
                 "grandparentRatingKey": showID(i), "grandparentTitle": "Show \(i)",
                 "parentIndex": 1, "index": e + 1, "duration": episodeMinutes(i, e) * 60_000]
            }
        }
        if path == "/library/sections" {
            return Reply(delayMs: 0, body: ["MediaContainer": ["Directory": [["key": "1", "title": "TV", "type": "show"]]]])
        }
        if path == "/library/sections/1/all" {
            let start = Int(query["X-Plex-Container-Start"] ?? "0") ?? 0
            let size = Int(query["X-Plex-Container-Size"] ?? "500") ?? 500
            let all: [[String: Any]]
            if query["type"] == "4" {
                all = bulk ? (0..<showCount).flatMap { episodes($0) } : []
            } else {
                all = (0..<showCount).map { ["ratingKey": showID($0), "title": "Show \($0)", "type": "show"] }
            }
            let page = Array(all.dropFirst(start).prefix(size))
            return Reply(delayMs: 0, body: ["MediaContainer": ["totalSize": all.count, "Metadata": page]])
        }
        if path.hasPrefix("/library/metadata/show"), path.hasSuffix("/allLeaves") {
            let key = path.dropFirst("/library/metadata/".count).dropLast("/allLeaves".count)
            guard let i = Int(key.dropFirst(4)) else { return nil }
            return Reply(delayMs: delayMs(i, shuffled: shuffled), body: ["MediaContainer": ["Metadata": episodes(i)]])
        }
        return nil
    }

    /// A minimal HTTP/1.1 server on 127.0.0.1: one request per connection, then close.
    private final class FakeServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "fake-server", attributes: .concurrent)
        private let route: @Sendable (String, [String: String]) -> Reply?
        private(set) var port: UInt16 = 0

        init(route: @escaping @Sendable (String, [String: String]) -> Reply?) throws {
            self.route = route
            // Loopback only: nothing off this machine can reach it, and no firewall prompt.
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                listener.stateUpdateHandler = { state in
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

    // MARK: - Loads

    private enum Backend: String, CaseIterable { case jellyfin, emby, plexBulk, plexPerShow }

    private func load(_ backend: Backend, shuffled: Bool) async throws -> [PlexMediaItem] {
        let server = try FakeServer { path, query in
            switch backend {
            case .jellyfin, .emby: return Self.jellyfinReply(path: path, query: query, shuffled: shuffled)
            case .plexBulk: return Self.plexReply(path: path, query: query, shuffled: shuffled, bulk: true)
            case .plexPerShow: return Self.plexReply(path: path, query: query, shuffled: shuffled, bulk: false)
            }
        }
        try await server.start()
        defer { server.stop() }
        let url = "http://127.0.0.1:\(server.port)"
        switch backend {
        case .jellyfin:
            return try await JellyfinAPIService(serverURL: url, accessToken: "t", userId: "u").loadLibrary()
        case .emby:
            return try await EmbyAPIService(serverURL: url, accessToken: "t", userId: "u").loadLibrary()
        case .plexBulk, .plexPerShow:
            return try await PlexAPIService(serverURL: url, token: "t").loadLibrary()
        }
    }

    // MARK: - Schedules

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// One all-shows channel and three channels of a third of the shows each.
    private static func lineup(_ items: [PlexMediaItem]) -> [Channel] {
        func show(of item: PlexMediaItem) -> Int { Int(item.title.dropFirst("Show ".count)) ?? 0 }
        let groups: [(Int, [PlexMediaItem])] = [(9101, items)] + (0..<3).map { k in
            (9102 + k, items.filter { show(of: $0) % 3 == k })
        }
        return groups.map { id, pool in
            Channel(id: id, number: id, name: "CH \(id)", color: .blue, category: nil,
                    rules: nil, timeRestrictions: nil, minItems: 1, itemPool: pool, enabled: true)
        }
    }

    /// What is on air each minute, per channel, over three days. Days are built in order so
    /// "yesterday" exists, as on a TV that was on.
    private static func minutes(_ items: [PlexMediaItem], fingerprint: String) -> [String] {
        DailyManifestStore.clearAll(credentialFingerprint: fingerprint)
        DailyManifestScheduler.invalidateMemo()
        defer {
            DailyManifestStore.clearAll(credentialFingerprint: fingerprint)
            DailyManifestScheduler.invalidateMemo()
        }
        let day0 = Date(timeIntervalSince1970: 1_793_491_200) // 2026-11-01 00:00 UTC
        var out: [String] = []
        for ch in lineup(items) {
            for d in 0..<3 {
                let start = day0.addingTimeInterval(TimeInterval(d * 86_400))
                let blocks = DailyManifestScheduler.blocks(
                    for: ch, at: start.addingTimeInterval(3600), credentialFingerprint: fingerprint, calendar: calendar)
                for m in 0..<1440 {
                    let t = start.addingTimeInterval(TimeInterval(m * 60 + 30))
                    out.append(blocks.first { $0.startTime <= t && t < $0.endTime }?.item.ratingKey ?? "-")
                }
            }
        }
        return out
    }

    // MARK: - The measurement

    func testTwoScansOfTheSameLibraryBuildTheSameGuide() async throws {
        var report: [String] = []
        for backend in Backend.allCases {
            let inOrder = try await load(backend, shuffled: false)
            let shuffled = try await load(backend, shuffled: true)
            let expected = (0..<Self.showCount).reduce(0) { $0 + Self.episodeCount($1) }
            XCTAssertEqual(inOrder.count, expected, "\(backend): fixture did not load")
            XCTAssertEqual(Set(inOrder.map(\.id)), Set(shuffled.map(\.id)), "\(backend): the two loads hold different items")

            let orderDiffers = inOrder.map(\.id) != shuffled.map(\.id)
            let a = Self.minutes(inOrder, fingerprint: "batch-order-a-\(backend)")
            let b = Self.minutes(shuffled, fingerprint: "batch-order-b-\(backend)")
            let changed = zip(a, b).filter { $0 != $1 }.count
            let pct = Double(changed) * 100 / Double(max(a.count, 1))
            let line = "\(backend): item order \(orderDiffers ? "DIFFERS" : "same"), "
                + "\(changed)/\(a.count) channel-minutes differ (\(String(format: "%.1f", pct))%)"
            print("[BATCH-ORDER] \(line)")
            report.append(line)
            XCTAssertFalse(orderDiffers, "\(backend): episode order followed request completion")
            XCTAssertEqual(changed, 0, line)
        }
        print("[BATCH-ORDER] " + report.joined(separator: " | "))
    }
}
