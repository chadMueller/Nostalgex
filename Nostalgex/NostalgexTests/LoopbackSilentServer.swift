import Foundation
import Network

/// A loopback TCP server that never answers HTTP, for tests that need a connection to fail
/// the same way on every machine:
/// - `.closeAtOnce` accepts and closes: the probe fails in milliseconds, http or https.
/// - `.neverAnswer` accepts and holds the connection without a byte: the probe waits out its
///   timeout unless the caller cancels it.
///
/// Held open for the test's whole run, so its port is never free for something else to take.
/// Connections it holds are closed by `stop()`.
final class LoopbackSilentServer: @unchecked Sendable {
    enum Mode { case closeAtOnce, neverAnswer }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-silent-server")
    private let mode: Mode
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var url: String { "http://127.0.0.1:\(port)" }

    private init(mode: Mode) throws {
        self.mode = mode
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    static func start(mode: Mode) async throws -> LoopbackSilentServer {
        let server = try LoopbackSilentServer(mode: mode)
        try await server.run()
        return server
    }

    private func run() async throws {
        listener.newConnectionHandler = { [self] conn in
            conn.start(queue: queue)
            switch mode {
            case .closeAtOnce:
                conn.cancel()
            case .neverAnswer:
                lock.lock(); held.append(conn); lock.unlock()
            }
        }
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

    func stop() {
        listener.cancel()
        lock.lock(); let conns = held; held = []; lock.unlock()
        conns.forEach { $0.cancel() }
    }
}
