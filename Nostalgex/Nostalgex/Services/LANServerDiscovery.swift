import Foundation
import Darwin

/// A media server that answered a discovery broadcast on the local network.
struct DiscoveredServer: Equatable, Identifiable, Sendable {
    let kind: MediaBackendKind
    let name: String
    /// The URL the server says to reach it on, e.g. `http://192.168.1.10:8096`.
    let address: String
    let id: String
}

/// Opt-in, user-initiated discovery of Jellyfin and Emby servers on the local network.
///
/// Both servers answer the same UDP protocol: a text probe to port 7359, a JSON reply
/// with `Address`, `Id` and `Name`. Jellyfin answers `who is JellyfinServer?` and Emby
/// answers `who is EmbyServer?`; each ignores the other string (measured against Emby
/// 4.10.1.0). One socket per probe, so the socket a reply arrives on names its kind.
///
/// This is a BSD socket, not Network.framework, on purpose. An `NWConnection` to a
/// broadcast address sends fine but never delivers the reply: the server answers from
/// its own unicast address, and a connected UDP socket drops datagrams from any other
/// peer. The `NWListener` plus bound-sender pattern was tried too and received nothing.
/// Measured on macOS 15 with Xcode 26; the simulator shares that stack.
///
/// Nothing here is stored or sent off the local network. It runs only when the user
/// presses the button on the connect form.
enum LANServerDiscovery {

    static let port: UInt16 = 7359
    /// How long to collect replies after sending the probe.
    static let listenWindow: TimeInterval = 3.0

    /// Copy shown on the connect forms. Kept here so the no-em-dash, no-emoji test can
    /// read every string the feature puts on screen.
    enum Copy {
        static let findButton = "FIND SERVERS ON MY NETWORK"
        static let searching = "SEARCHING..."
        static let noneFound = "No servers found. Check the Apple TV and the server are on the same network, then try again."
        static let all: [String] = [findButton, searching, noneFound]
    }

    /// The text a server of this kind answers to.
    static func probe(for kind: MediaBackendKind) -> String? {
        switch kind {
        case .jellyfin: return "who is JellyfinServer?"
        case .emby:     return "who is EmbyServer?"
        case .plex:     return nil
        }
    }

    // MARK: - Parsing (pure)

    /// Reads one reply datagram. `kind` comes from which probe's socket received it,
    /// because the JSON is identical for Jellyfin and Emby.
    static func parse(reply: Data, kind: MediaBackendKind) -> DiscoveredServer? {
        guard let object = try? JSONSerialization.jsonObject(with: reply),
              let dict = object as? [String: Any],
              let address = dict["Address"] as? String,
              let id = dict["Id"] as? String else { return nil }
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty, !trimmedID.isEmpty else { return nil }
        let rawName = (dict["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? trimmedAddress : rawName
        return DiscoveredServer(kind: kind, name: name, address: trimmedAddress, id: trimmedID)
    }

    /// Keeps the first server seen for each `Id`, in arrival order. A server that
    /// answers both probes, or is reached over two interfaces, shows once.
    static func dedupe(_ servers: [DiscoveredServer]) -> [DiscoveredServer] {
        var seen = Set<String>()
        var out: [DiscoveredServer] = []
        for server in servers where !seen.contains(server.id) {
            seen.insert(server.id)
            out.append(server)
        }
        return out
    }

    /// The subnet-directed broadcast address for an interface, e.g. 192.168.4.29 with
    /// mask 255.255.252.0 is 192.168.7.255. Needed because the limited broadcast
    /// 255.255.255.255 went unanswered by a real Emby on a /22 while the directed
    /// address got a reply every time.
    static func directedBroadcast(address: String, netmask: String) -> String? {
        var addr = in_addr()
        var mask = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1,
              inet_pton(AF_INET, netmask, &mask) == 1 else { return nil }
        let host = UInt32(bigEndian: addr.s_addr)
        let net = UInt32(bigEndian: mask.s_addr)
        let broadcast = host | ~net
        var result = in_addr(s_addr: broadcast.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &result, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Discovery

    /// Broadcasts the probe for `kind` and returns every distinct server that answered
    /// within `listenWindow`. Safe to call from the main actor; the socket work runs on
    /// a background queue.
    static func discover(kind: MediaBackendKind) async -> [DiscoveredServer] {
        guard let probe = probe(for: kind) else { return [] }
        let targets = broadcastTargets()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let found = runProbe(probe, kind: kind, targets: targets, window: listenWindow)
                continuation.resume(returning: dedupe(found))
            }
        }
    }

    /// Every address a probe should go to: the limited broadcast plus the directed
    /// broadcast of each up, non-loopback IPv4 interface.
    static func broadcastTargets() -> [String] {
        var targets = ["255.255.255.255"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return targets }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let addrPtr = ifa.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = ifa.pointee.ifa_netmask else { continue }
            let address = ipv4String(addrPtr)
            let netmask = ipv4String(maskPtr)
            if let address, let netmask, let directed = directedBroadcast(address: address, netmask: netmask),
               !targets.contains(directed) {
                targets.append(directed)
            }
        }
        return targets
    }

    private static func ipv4String(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
            var addr = sin.pointee.sin_addr
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    /// Blocking. Opens one UDP socket with SO_BROADCAST, sends `probe` to each target,
    /// then collects replies until `window` elapses.
    private static func runProbe(_ probe: String, kind: MediaBackendKind, targets: [String], window: TimeInterval) -> [DiscoveredServer] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            print("[LAN] socket() failed errno=\(errno)")
            return []
        }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var recvTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            print("[LAN] bind() failed errno=\(errno)")
            return []
        }

        let payload = Array(probe.utf8)
        for target in targets {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            guard inet_pton(AF_INET, target, &dest.sin_addr) == 1 else { continue }
            let sent = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 {
                print("[LAN] sendto \(target):\(port) failed errno=\(errno)")
            }
        }

        var found: [DiscoveredServer] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }
            guard count > 0 else { continue }
            let data = Data(buffer[0..<count])
            if let server = parse(reply: data, kind: kind) {
                found.append(server)
            } else {
                print("[LAN] ignored \(count) byte reply that was not a server announcement")
            }
        }
        print("[LAN] \(kind.displayName) discovery: \(targets.count) targets, \(found.count) replies")
        return found
    }
}
