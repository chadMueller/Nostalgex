import XCTest
@testable import Nostalgex

/// The parse and dedupe half of LAN discovery. The socket half is exercised against a
/// real server in the simulator, not here, because a unit test cannot promise a server
/// is listening on the test machine's network.
final class LANServerDiscoveryTests: XCTestCase {

    // Captured verbatim from an Emby 4.10.1.0 reply. Jellyfin adds EndpointAddress.
    private let embyReply = #"{"Address":"http://192.168.1.10:8096","Id":"fb66e05eaa284eb48076f8e1e550a7dc","Name":"Medias-Mac-mini"}"#
    private let jellyfinReply = #"{"Address":"http://192.168.1.20:8096","Id":"3d1f0a9e8c7b4a5d9e2f1c0b8a7d6e5f","Name":"Living Room Jellyfin","EndpointAddress":null}"#

    func testParsesAJellyfinReply() {
        let server = LANServerDiscovery.parse(reply: Data(jellyfinReply.utf8), kind: .jellyfin)
        XCTAssertEqual(server, DiscoveredServer(kind: .jellyfin,
                                                name: "Living Room Jellyfin",
                                                address: "http://192.168.1.20:8096",
                                                id: "3d1f0a9e8c7b4a5d9e2f1c0b8a7d6e5f"))
    }

    func testParsesAnEmbyReply() {
        let server = LANServerDiscovery.parse(reply: Data(embyReply.utf8), kind: .emby)
        XCTAssertEqual(server, DiscoveredServer(kind: .emby,
                                                name: "Medias-Mac-mini",
                                                address: "http://192.168.1.10:8096",
                                                id: "fb66e05eaa284eb48076f8e1e550a7dc"))
    }

    func testRejectsMalformedReplies() {
        let bad: [String] = [
            "",
            "who is EmbyServer?",                              // our own probe echoed back
            "{not json",
            "[]",
            #"{"Id":"abc","Name":"No address"}"#,              // missing Address
            #"{"Address":"http://x:8096","Name":"No id"}"#,    // missing Id
            #"{"Address":"","Id":"abc"}"#,                      // empty Address
            #"{"Address":"http://x:8096","Id":"   "}"#,         // blank Id
            #"{"Address":123,"Id":"abc"}"#,                     // wrong type
        ]
        for text in bad {
            XCTAssertNil(LANServerDiscovery.parse(reply: Data(text.utf8), kind: .emby), "accepted: \(text)")
        }
    }

    func testFallsBackToTheAddressWhenTheNameIsMissing() {
        let server = LANServerDiscovery.parse(reply: Data(#"{"Address":"http://192.168.1.10:8096","Id":"abc"}"#.utf8), kind: .emby)
        XCTAssertEqual(server?.name, "http://192.168.1.10:8096")
    }

    func testDedupesByIdKeepingTheFirstSeen() {
        let a = DiscoveredServer(kind: .emby, name: "A", address: "http://192.168.1.10:8096", id: "same")
        let aAgain = DiscoveredServer(kind: .emby, name: "A via other interface", address: "http://10.0.0.10:8096", id: "same")
        let b = DiscoveredServer(kind: .emby, name: "B", address: "http://192.168.1.11:8096", id: "other")
        XCTAssertEqual(LANServerDiscovery.dedupe([a, aAgain, b, a]), [a, b])
        XCTAssertEqual(LANServerDiscovery.dedupe([]), [])
    }

    func testEachKindHasItsOwnProbeAndPlexHasNone() {
        XCTAssertEqual(LANServerDiscovery.probe(for: .jellyfin), "who is JellyfinServer?")
        XCTAssertEqual(LANServerDiscovery.probe(for: .emby), "who is EmbyServer?")
        XCTAssertNil(LANServerDiscovery.probe(for: .plex))
    }

    /// The real Emby ignored 255.255.255.255 on a /22 and answered the directed
    /// broadcast, so this arithmetic is load-bearing.
    func testDirectedBroadcastFromAddressAndMask() {
        XCTAssertEqual(LANServerDiscovery.directedBroadcast(address: "192.168.4.29", netmask: "255.255.252.0"), "192.168.7.255")
        XCTAssertEqual(LANServerDiscovery.directedBroadcast(address: "192.168.1.10", netmask: "255.255.255.0"), "192.168.1.255")
        XCTAssertEqual(LANServerDiscovery.directedBroadcast(address: "10.0.0.5", netmask: "255.0.0.0"), "10.255.255.255")
        XCTAssertNil(LANServerDiscovery.directedBroadcast(address: "not an ip", netmask: "255.255.255.0"))
    }

    func testBroadcastTargetsAlwaysIncludeTheLimitedBroadcast() {
        let targets = LANServerDiscovery.broadcastTargets()
        XCTAssertEqual(targets.first, "255.255.255.255")
        XCTAssertEqual(Set(targets).count, targets.count, "targets repeat: \(targets)")
    }

    /// Chad's copy rules, which a search button is no excuse to break.
    func testCopyHasNoEmDashesAndNoEmoji() {
        XCTAssertFalse(LANServerDiscovery.Copy.all.isEmpty)
        for text in LANServerDiscovery.Copy.all {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("—"), "em dash in: \(text)")
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C },
                           "emoji in: \(text)")
        }
    }
}
