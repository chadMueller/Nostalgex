import Foundation

/// The decisions behind the Jellyfin and Emby connect screens, kept out of SwiftUI so
/// they can be tested. The screens only ask: what did discovery give us, which way in
/// does this server want first, and what does it say about itself before anyone types.
///
/// Sign-in itself is untouched: the screens still end in `AppState.authenticateJellyfin`,
/// `startJellyfinQuickConnect` and `authenticateEmby`, with the address this check found.
enum SignInFlow {

    // MARK: - Discovery

    enum DiscoveryOutcome: Equatable {
        /// Nothing answered: offer the typed address.
        case none
        /// Exactly one server: go straight to it, no pick.
        case single(DiscoveredServer)
        /// Several: list them.
        case several([DiscoveredServer])
    }

    /// Runs LAN discovery. UI tests can stand in a fixed answer with
    /// `-uiTestDiscovery none` or `-uiTestDiscovery several`, so the screens a single
    /// test network never produces can still be looked at.
    static func discover(kind: MediaBackendKind) async -> [DiscoveredServer] {
        if let fixture = uiTestDiscoveryFixture(kind: kind, arguments: ProcessInfo.processInfo.arguments) {
            try? await Task.sleep(for: .seconds(1))
            return fixture
        }
        return await LANServerDiscovery.discover(kind: kind)
    }

    static func uiTestDiscoveryFixture(kind: MediaBackendKind, arguments: [String]) -> [DiscoveredServer]? {
        // Split on spaces too, so the flag works whether a scheme passes it as two
        // arguments or as one "-uiTestDiscovery several" string.
        let tokens = arguments.flatMap { $0.split(separator: " ").map(String.init) }
        guard let flag = tokens.firstIndex(of: "-uiTestDiscovery"), flag + 1 < tokens.count else { return nil }
        switch tokens[flag + 1] {
        case "none":
            return []
        case "otherkind":
            // Only an Emby server on the network, whatever was searched for: what a Jellyfin search on a network
            // with only Emby sees.
            return kind == .emby
                ? [DiscoveredServer(kind: .emby, name: "Living-Room-Server", address: "http://192.0.2.79:8096", id: "fixture-emby")]
                : []
        case "several":
            return [
                DiscoveredServer(kind: kind, name: "Living Room", address: "http://192.0.2.10:8096", id: "fixture-1"),
                DiscoveredServer(kind: kind, name: "Basement NAS", address: "http://192.0.2.11:8096", id: "fixture-2"),
            ]
        default:
            return nil
        }
    }

    /// Jellyfin and Emby speak the same discovery protocol to different probe strings, and each answers only its
    /// own. When a search for one finds nothing, the screen searches for the other, so a viewer who picked the wrong
    /// one is told which server is there (Chad 2026-11-15: picked Jellyfin on a network whose only server is Emby).
    static func otherKind(of kind: MediaBackendKind) -> MediaBackendKind? {
        switch kind {
        case .jellyfin: return .emby
        case .emby: return .jellyfin
        case .plex: return nil
        }
    }

    /// What the screen says after a search for `kind` found nothing and the search for the other kind found
    /// `other`: nil when that found nothing too (the usual "No server answered").
    static func otherKindFound(searched kind: MediaBackendKind, other: [DiscoveredServer]) -> [DiscoveredServer]? {
        guard let otherKind = otherKind(of: kind) else { return nil }
        let found = LANServerDiscovery.dedupe(other.filter { $0.kind == otherKind })
        return found.isEmpty ? nil : found
    }

    static func outcome(of servers: [DiscoveredServer]) -> DiscoveryOutcome {
        let unique = LANServerDiscovery.dedupe(servers)
        switch unique.count {
        case 0: return .none
        case 1: return .single(unique[0])
        default: return .several(unique)
        }
    }

    // MARK: - Which way in

    enum Method: Equatable { case quickConnect, password }

    /// Quick Connect first on a Jellyfin server that says it is switched on: no typing,
    /// the viewer approves a code on their phone. Emby has no Quick Connect.
    static func preferredMethod(kind: MediaBackendKind, quickConnectEnabled: Bool?) -> Method {
        kind == .jellyfin && quickConnectEnabled == true ? .quickConnect : .password
    }

    /// Whether the password screen offers Quick Connect as the other way in. Hidden only
    /// when the server said it is off, so an older server that can't say still gets it
    /// (and Initiate explains itself if it fails).
    static func offersQuickConnect(kind: MediaBackendKind, quickConnectEnabled: Bool?) -> Bool {
        kind == .jellyfin && quickConnectEnabled != false
    }

    // MARK: - What the server says about itself

    /// A user the server lists on its own login screen (`/Users/Public`). Picking one
    /// saves typing the name on a TV keyboard; one with no password signs in on the spot.
    struct PublicUser: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let hasPassword: Bool
    }

    struct CheckedServer: Equatable, Sendable {
        /// What the server says it is, which wins over the button the viewer pressed.
        let kind: MediaBackendKind
        /// The base URL that answered, port included.
        let url: String
        let name: String
        /// nil when the server would not say (older Jellyfin, or Emby).
        let quickConnectEnabled: Bool?
        let users: [PublicUser]

        var preferredMethod: Method { SignInFlow.preferredMethod(kind: kind, quickConnectEnabled: quickConnectEnabled) }
        var offersQuickConnect: Bool { SignInFlow.offersQuickConnect(kind: kind, quickConnectEnabled: quickConnectEnabled) }
    }

    enum CheckError: Error, Equatable {
        /// Something answered, but not with a Jellyfin or Emby server's details.
        case notAServer
    }

    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Asks the address who it is before anyone types a password, so a wrong address
    /// fails on the address screen, a Jellyfin server opens on Quick Connect, and an
    /// Emby server shows its users. A bare IP tries `:8096` first, as sign-in does.
    static func check(address: String, send: Send = defaultSend) async throws -> CheckedServer {
        let candidates = ServerURLNormalizer.candidates(address)
        guard !candidates.isEmpty else { throw CheckError.notAServer }

        var info: PublicInfo?
        var base = candidates[0]
        for (index, candidate) in candidates.enumerated() {
            do {
                let (data, response) = try await send(request(candidate + "/System/Info/Public"))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(status), let parsed = parsePublicInfo(data) {
                    info = parsed
                    base = candidate
                    break
                }
                if index == candidates.count - 1 { throw CheckError.notAServer }
            } catch let error as URLError where error.code == .cannotConnectToHost && index < candidates.count - 1 {
                continue
            }
        }
        guard let info else { throw CheckError.notAServer }

        var quickConnect: Bool?
        if info.kind == .jellyfin,
           let (data, response) = try? await send(request(base + "/QuickConnect/Enabled")) {
            quickConnect = parseQuickConnectEnabled(data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        var users: [PublicUser] = []
        if let (data, response) = try? await send(request(base + "/Users/Public")),
           (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
            users = parsePublicUsers(data)
        }

        return CheckedServer(kind: info.kind, url: base, name: info.name,
                             quickConnectEnabled: quickConnect, users: users)
    }

    static let defaultSend: Send = { request in try await checkSession.data(for: request) }

    /// Short timeouts: this runs while the viewer watches a "connecting" line.
    private static let checkSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    private static func request(_ string: String) -> URLRequest {
        var request = URLRequest(url: URL(string: string) ?? URL(string: "http://invalid.invalid")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Parsing (pure)

    struct PublicInfo: Equatable {
        let id: String
        let name: String
        let kind: MediaBackendKind
    }

    /// `/System/Info/Public`. Jellyfin names itself in `ProductName`; Emby 4.x leaves it
    /// out. A page without an `Id` (a router, a web UI) is not a server.
    static func parsePublicInfo(_ data: Data) -> PublicInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (object["Id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        let product = (object["ProductName"] as? String ?? "").lowercased()
        let kind: MediaBackendKind = product.contains("jellyfin") ? .jellyfin : .emby
        let rawName = (object["ServerName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PublicInfo(id: id, name: rawName.isEmpty ? kind.displayName : rawName, kind: kind)
    }

    /// `/QuickConnect/Enabled` answers a bare JSON `true` or `false`. Anything else
    /// (404 on servers that predate it, a web page) is "can't say".
    static func parseQuickConnectEnabled(_ data: Data, statusCode: Int) -> Bool? {
        guard (200...299).contains(statusCode) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// `/Users/Public`: the users a server shows on its own login screen.
    static func parsePublicUsers(_ data: Data) -> [PublicUser] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["Id"] as? String, !id.isEmpty,
                  let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let hasPassword = (entry["HasPassword"] as? Bool) ?? true
            return PublicUser(id: id, name: name, hasPassword: hasPassword)
        }
    }

    // MARK: - Copy

    /// Every string these screens put up, so the no-em-dash test can read them.
    enum Copy {
        static func connectTitle(_ kind: MediaBackendKind) -> String { "CONNECT TO \(kind.displayName.uppercased())" }
        static func findIntro(_ kind: MediaBackendKind) -> String {
            "Nostalgex can look for your \(kind.displayName) server on this network. Or type its address."
        }
        static let typeAddress = "TYPE AN ADDRESS"
        static let searchAgain = "SEARCH AGAIN"
        static let pickServer = "PICK YOUR SERVER"
        static let addressTitle = "SERVER ADDRESS"
        static let addressHint = "The address and port, like 192.168.1.10:8096"
        static let addressPlaceholder = "192.168.1.10:8096"
        static let connect = "CONNECT"
        static let pressToType = "Press to type"
        static func connecting(_ what: String) -> String { "CONNECTING TO \(what.uppercased())" }
        static let signInTo = "SIGN IN TO"
        static let whoIsWatching = "WHO'S WATCHING?"
        static let someoneElse = "SOMEONE ELSE"
        static let username = "USERNAME"
        static let password = "PASSWORD"
        static let signIn = "SIGN IN"
        static let useQuickConnect = "USE QUICK CONNECT"
        static let usePassword = "SIGN IN WITH A PASSWORD"
        static let back = "BACK"
        static let cancel = "CANCEL"
        static let quickConnectTitle = "APPROVE THIS TV IN JELLYFIN"
        static let quickConnectSteps = "On your phone or computer, open Jellyfin, then your profile, then Quick Connect, and enter this code."
        static let waitingForApproval = "WAITING FOR APPROVAL"
        static let notAServer = "That address answered, but it isn't a Jellyfin or Emby server. Check the port (both use 8096 unless you changed it)."
        static func switchedKind(_ kind: MediaBackendKind) -> String { "That address is a \(kind.displayName) server, so this is a \(kind.displayName) sign-in." }
        /// "No Jellyfin server answered. Found an Emby server: Living-Room-Server. Switch to Emby?"
        static func foundOtherKind(searched: MediaBackendKind, found: MediaBackendKind, names: [String]) -> String {
            let article = found == .emby ? "an" : "a"
            let what = names.count == 1
                ? "\(article) \(found.displayName) server: \(names[0])"
                : "\(names.count) \(found.displayName) servers: \(names.joined(separator: ", "))"
            return "No \(searched.displayName) server answered. Found \(what). Switch to \(found.displayName)?"
        }
        /// The button on each server found that way: "SWITCH TO EMBY: LIVING-ROOM-SERVER".
        static func switchTo(_ kind: MediaBackendKind, name: String) -> String { "SWITCH TO \(kind.displayName.uppercased()): \(name.uppercased())" }

        static var all: [String] {
            let kinds: [MediaBackendKind] = [.jellyfin, .emby]
            return kinds.flatMap { [connectTitle($0), findIntro($0), switchedKind($0)] } + [
                foundOtherKind(searched: .jellyfin, found: .emby, names: ["Server"]),
                foundOtherKind(searched: .emby, found: .jellyfin, names: ["Server", "NAS"]),
                switchTo(.emby, name: "Server"),
            ] + [
                typeAddress, searchAgain, pickServer, addressTitle, addressHint, addressPlaceholder, connect, pressToType,
                connecting("server"), signInTo, whoIsWatching, someoneElse, username, password, signIn,
                useQuickConnect, usePassword, back, cancel, quickConnectTitle, quickConnectSteps,
                waitingForApproval, notAServer,
            ]
        }
    }
}
