import Foundation
import Network

/// One response from `LoopbackJSONServer`: hold `delayMs`, then send `body` as JSON.
struct LoopbackReply {
    let delayMs: Int
    let body: Any
}

/// A minimal HTTP/1.1 server on 127.0.0.1 for tests that load a library through a backend's
/// REAL network code: one request per connection, then close. `route` gets the path and the
/// query and returns the reply, or nil for a 404. Every request's path and query is kept in
/// `requests`, in arrival order.
final class LoopbackJSONServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-json-server", attributes: .concurrent)
    private let route: @Sendable (String, [String: String]) -> LoopbackReply?
    private let lock = NSLock()
    private var log: [(path: String, query: [String: String])] = []
    private(set) var port: UInt16 = 0

    init(route: @escaping @Sendable (String, [String: String]) -> LoopbackReply?) throws {
        self.route = route
        // Loopback only: nothing off this machine can reach it, and no firewall prompt.
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    var requests: [(path: String, query: [String: String])] {
        lock.lock()
        defer { lock.unlock() }
        return log
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
        let path = comps?.path ?? target
        lock.lock()
        log.append((path, query))
        lock.unlock()
        let reply = route(path, query)
        let body = (try? JSONSerialization.data(withJSONObject: reply?.body ?? [:])) ?? Data()
        let status = reply == nil ? "404 Not Found" : "200 OK"
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        queue.asyncAfter(deadline: .now() + .milliseconds(reply?.delayMs ?? 0)) {
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
