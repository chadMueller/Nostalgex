import Foundation
import Network

/// A small HTTP/1.1 server on 127.0.0.1 for harnesses that drive the app's REAL network
/// code against stand-ins: a Plex server, the TMDB/OMDb proxy, Supabase. One request per
/// connection, then close. Works on a real Apple TV as well as the simulator (loopback only,
/// nothing off the device can reach it).
///
/// Every response carries `Cache-Control: no-store`, so nothing a harness fetches is kept in
/// the app's HTTP cache. Request bodies are read in full (`Content-Length`) before the route
/// runs. Requests are counted per route label, with the times they arrived, so a harness can
/// see whether anything is retried or polled without end.
final class HarnessFakeServer: @unchecked Sendable {

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    struct Reply {
        var status: Int = 200
        var delayMs: Int = 0
        var body: Data = Data("{}".utf8)
        /// Counted under this label (for example "plex.page", "tmdb", "supabase.get").
        var label: String

        static func json(_ object: Any, label: String, delayMs: Int = 0, status: Int = 200) -> Reply {
            Reply(status: status, delayMs: delayMs,
                  body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), label: label)
        }
        static func notFound(_ label: String = "404") -> Reply { Reply(status: 404, body: Data("{}".utf8), label: label) }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "harness-fake-server", qos: .userInitiated, attributes: .concurrent)
    private let route: @Sendable (Request) -> Reply
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var arrivals: [String: [Double]] = [:]
    private var inFlight = 0
    private var maxInFlight = 0
    private let t0 = CFAbsoluteTimeGetCurrent()
    private(set) var port: UInt16 = 0

    init(route: @escaping @Sendable (Request) -> Reply) throws {
        self.route = route
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    var url: String { "http://127.0.0.1:\(port)" }

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

    /// Requests so far, per label.
    var requestCounts: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }

    /// Requests per label that arrived in the last `seconds`.
    func recentCounts(seconds: Double) -> [String: Int] {
        let now = CFAbsoluteTimeGetCurrent() - t0
        lock.lock(); defer { lock.unlock() }
        return arrivals.mapValues { $0.reversed().prefix { now - $0 <= seconds }.count }
    }

    var peakConcurrentRequests: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[end.upperBound...]
                if body.count >= length {
                    self.respond(conn, head: head, body: Data(body.prefix(length)))
                    return
                }
                if done || error != nil { conn.cancel(); return }
                self.read(conn, buffer: buf)
            } else if done || error != nil {
                conn.cancel()
            } else {
                self.read(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, head: String, body: Data) {
        let parts = head.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let target = parts.dropFirst().first.map(String.init) ?? "/"
        let comps = URLComponents(string: "http://x\(target)")
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let request = Request(method: method, path: comps?.path ?? target, query: query, body: body)

        lock.lock()
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        lock.unlock()
        let reply = route(request)
        lock.lock()
        counts[reply.label, default: 0] += 1
        arrivals[reply.label, default: []].append(CFAbsoluteTimeGetCurrent() - t0)
        lock.unlock()

        let reason = reply.status == 200 ? "OK" : (reply.status == 429 ? "Too Many Requests" : "Status")
        var out = Data(("HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: application/json\r\n"
            + "Cache-Control: no-store\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n").utf8)
        out.append(reply.body)
        queue.asyncAfter(deadline: .now() + .milliseconds(reply.delayMs)) { [weak self] in
            conn.send(content: out, completion: .contentProcessed { _ in
                conn.cancel()
                self?.lock.lock(); self?.inFlight -= 1; self?.lock.unlock()
            })
        }
    }
}
