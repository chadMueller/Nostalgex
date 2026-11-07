import XCTest
import Network
@testable import Nostalgex

/// One section whose connection drops for good must not take the other sections with it.
///
/// Found in the #146 follow-up (2026-11-04): a fake remote Plex that dropped the connection
/// mid-section threw away the whole server's scan once the retries ran out, four finished
/// sections included, and the viewer read "Can't reach the server address saved on this
/// device ... on the same network as your server". Only a cancel kept what had been read.
/// Trello N-039 is the same rule for Jellyfin and Emby.
///
/// Three movie sections, the middle one ("Documentaries") dropping every connection. The first
/// and third answer. 300 + 150 movies must come through.
final class SectionFailureScanTests: XCTestCase {

    private static let counts = ["1": 300, "2": 200, "3": 150]
    private static let titles = ["1": "Movies", "2": "Documentaries", "3": "Classics"]
    private static let healthyItems = 300 + 150

    // MARK: Fake server

    enum Reply { case json(Any), drop }

    private final class Server: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "section-failure-server", attributes: .concurrent)
        private let route: @Sendable (String, [String: String]) -> Reply
        private let lock = NSLock()
        private var dropped = 0
        private(set) var port: UInt16 = 0
        var droppedCount: Int { lock.lock(); defer { lock.unlock() }; return dropped }

        init(route: @escaping @Sendable (String, [String: String]) -> Reply) throws {
            self.route = route
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

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
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://x\(target)")
            var query: [String: String] = [:]
            for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
            switch route(comps?.path ?? target, query) {
            case .drop:
                lock.lock(); dropped += 1; lock.unlock()
                conn.cancel()
            case .json(let obj):
                let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: Backends

    private enum Backend: String, CaseIterable { case plex, jellyfin, emby }

    private func fakeServer(for backend: Backend, dropping failing: Set<String>) throws -> Server {
        switch backend {
        case .plex:
            let specs = ["1", "2", "3"].map {
                StopWaitingHarnessTests.SectionSpec(key: $0, title: Self.titles[$0]!, type: "movie", count: Self.counts[$0]!,
                                                    episodesPerShow: 0, hangFromPage: nil, delayMs: 0)
            }
            return try Server { path, query in
                let parts = path.split(separator: "/")
                if parts.count == 4, failing.contains(String(parts[2])) { return .drop }
                if case .json(let obj, _) = StopWaitingHarnessTests.plexReply(path: path, query: query, sections: specs) { return .json(obj) }
                return .json([:])
            }
        case .jellyfin, .emby:
            return try Server { path, query in
                if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
                    let views = ["1", "2", "3"].map { ["Id": $0, "Name": Self.titles[$0]!, "CollectionType": "movies"] }
                    return .json(["Items": views, "TotalRecordCount": 3])
                }
                guard path.hasSuffix("/Items"), let parent = query["ParentId"], let total = Self.counts[parent] else { return .json([:]) }
                if failing.contains(parent) { return .drop }
                let start = Int(query["StartIndex"] ?? "0") ?? 0
                let limit = Int(query["Limit"] ?? "200") ?? 200
                let page = (start ..< min(start + limit, total)).map { i -> [String: Any] in
                    let ticks = Int64(90 + i % 60) * 60 * 10_000_000
                    return ["Id": "\(parent)-\(i)", "Name": "Movie \(parent)-\(i)", "Type": "Movie", "RunTimeTicks": ticks,
                            "Genres": ["Drama"], "ProviderIds": ["Tmdb": "\(parent)\(10_000 + i)"],
                            "MediaSources": [["Id": "ms\(parent)-\(i)", "Container": "mkv", "RunTimeTicks": ticks]]]
                }
                return .json(["Items": page, "TotalRecordCount": total])
            }
        }
    }

    private func service(_ backend: Backend, port: UInt16) -> any MediaBackend {
        let url = "http://127.0.0.1:\(port)"
        switch backend {
        case .plex: return PlexAPIService(serverURL: url, token: "t", serverID: "section-failure")
        case .jellyfin: return JellyfinAPIService(serverURL: url, accessToken: "t", userId: "u")
        case .emby: return EmbyAPIService(serverURL: url, accessToken: "t", userId: "u")
        }
    }

    // MARK: The scan keeps what it read

    func testASectionThatDropsItsConnectionKeepsTheOthers() async throws {
        for backend in Backend.allCases {
            let server = try fakeServer(for: backend, dropping: ["2"])
            try await server.start()
            defer { server.stop() }
            do {
                let items = try await service(backend, port: server.port).loadLibrary(excludedSectionKeys: [], progress: nil)
                XCTFail("\(backend): a lost section should be reported, got \(items.count) items as if nothing were wrong")
            } catch let interrupted as LibraryScanInterrupted {
                XCTAssertEqual(interrupted.partialItems.count, Self.healthyItems,
                               "\(backend): Movies and Classics were read and must come through")
                XCTAssertEqual(interrupted.failedSections, ["Documentaries"], "\(backend): the lost section is named")
                XCTAssertGreaterThan(server.droppedCount, 0, "\(backend): the section really was dropped")
            } catch {
                XCTFail("\(backend): the lost section took the others with it (\(error))")
            }
        }
    }

    func testEverySectionDroppingIsStillAFailure() async throws {
        for backend in Backend.allCases {
            let server = try fakeServer(for: backend, dropping: ["1", "2", "3"])
            try await server.start()
            defer { server.stop() }
            do {
                let items = try await service(backend, port: server.port).loadLibrary(excludedSectionKeys: [], progress: nil)
                XCTFail("\(backend): nothing was read, got \(items.count) items")
            } catch is LibraryScanInterrupted {
                XCTFail("\(backend): nothing was read, so this is a failure, not a partial scan")
            } catch {
                // The transport error itself.
            }
        }
    }

    // MARK: Through the app

    private final class Memory: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    @MainActor
    func testTheLoadBuildsAGuideFromTheSectionsThatAnswered() async throws {
        let scope = HarnessScope.begin("section-failure")
        defer { scope.end() }
        let server = try fakeServer(for: .plex, dropping: ["2"])
        try await server.start()
        defer { server.stop() }

        let state = AppState(credentialStore: Memory())
        state.completePlexSignIn(token: "acct", servers: [
            AppState.ServerRef(machineIdentifier: "section-failure", name: "Remote", baseURL: "http://127.0.0.1:\(server.port)", owned: true, token: "t")
        ])
        await state.loadLibrary()

        XCTAssertNil(state.errorMessage, "a lost section is not a failed load")
        XCTAssertEqual(state.allItems.count, Self.healthyItems)
        XCTAssertTrue(state.isLibraryStale, "partial, so a later refresh fills the missing section in")
        XCTAssertEqual(state.lostSectionsLastLoad, ["Documentaries"], "the load report names the section that was lost")
        XCTAssertFalse(state.isLoading)
        state.disconnect()
    }

    // MARK: The message

    @MainActor
    func testTheDroppedConnectionMessageDoesNotBlameTheNetworkOfARemoteServer() {
        let remoteAddresses = ["https://203-0-113-9.abc.plex.direct:32400", "https://media.example.com:32400", "http://203.0.113.9:32400"]
        for address in remoteAddresses {
            let dropped = AppState.userFacingLoadLibraryError(URLError(.networkConnectionLost), serverURL: address)
            XCTAssertFalse(dropped.contains("same network"), "\(address): \(dropped)")
            XCTAssertTrue(dropped.contains("dropped"), "\(address): \(dropped)")
            let unreachable = AppState.userFacingLoadLibraryError(URLError(.cannotConnectToHost), serverURL: address)
            XCTAssertFalse(unreachable.contains("same network"), "\(address): \(unreachable)")
            XCTAssertTrue(unreachable.contains("remote access"), "\(address): \(unreachable)")
        }
    }

    @MainActor
    func testTheSameNetworkAdviceStaysForAServerOnTheSameNetwork() {
        let localAddresses = ["http://192.168.1.10:32400", "https://192-168-1-50.abc.plex.direct:32400", "http://nas.local:32400", "http://10.0.0.5:8096", "http://127.0.0.1:32400"]
        for address in localAddresses {
            for code in [URLError.Code.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
                let message = AppState.userFacingLoadLibraryError(URLError(code), serverURL: address)
                XCTAssertTrue(message.contains("same network as your server"), "\(address) \(code.rawValue): \(message)")
            }
        }
    }

    @MainActor
    func testAnUnknownAddressMakesNoClaimAboutTheNetwork() {
        for code in [URLError.Code.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertFalse(AppState.userFacingLoadLibraryError(URLError(code)).contains("same network"), "\(code.rawValue)")
        }
    }
}
