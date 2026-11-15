import XCTest
@testable import Nostalgex

/// A search for Jellyfin on a network whose only server is Emby (or the other way round) says which server is there
/// and offers to switch, instead of "No server answered" (Chad 2026-11-15, Emby 4.10.1.0 answers only its own probe).
final class DiscoveryOtherKindTests: XCTestCase {
    /// An Emby 4.10.1.0 reply to "who is EmbyServer?", as it arrives on the socket.
    private let embyReply = Data(#"{"Address":"http://192.0.2.79:8096","Id":"4d1c2b9e0f6a4f3e8b7c6d5e4f3a2b1c","Name":"Living-Room-Server"}"#.utf8)
    private let jellyfinReply = Data(#"{"Address":"http://192.0.2.80:8096","Id":"jf-1","Name":"NAS","EndpointAddress":null}"#.utf8)

    func testAJellyfinSearchThatFindsOnlyEmbyOffersEmby() throws {
        let emby = try XCTUnwrap(LANServerDiscovery.parse(reply: embyReply, kind: .emby))
        let found = try XCTUnwrap(SignInFlow.otherKindFound(searched: .jellyfin, other: [emby, emby]))
        XCTAssertEqual(found.map(\.name), ["Living-Room-Server"], "deduped")
        XCTAssertEqual(found.first?.address, "http://192.0.2.79:8096")
        XCTAssertEqual(SignInFlow.Copy.foundOtherKind(searched: .jellyfin, found: .emby, names: found.map(\.name)),
                       "No Jellyfin server answered. Found an Emby server: Living-Room-Server. Switch to Emby?")
        XCTAssertEqual(SignInFlow.Copy.switchTo(.emby, name: "Living-Room-Server"), "SWITCH TO EMBY: LIVING-ROOM-SERVER")
    }

    func testAnEmbySearchThatFindsOnlyJellyfinOffersJellyfin() throws {
        let jf = try XCTUnwrap(LANServerDiscovery.parse(reply: jellyfinReply, kind: .jellyfin))
        let found = try XCTUnwrap(SignInFlow.otherKindFound(searched: .emby, other: [jf]))
        XCTAssertEqual(SignInFlow.Copy.foundOtherKind(searched: .emby, found: .jellyfin, names: found.map(\.name)),
                       "No Emby server answered. Found a Jellyfin server: NAS. Switch to Jellyfin?")
        XCTAssertEqual(SignInFlow.Copy.foundOtherKind(searched: .emby, found: .jellyfin, names: ["NAS", "Den"]),
                       "No Emby server answered. Found 2 Jellyfin servers: NAS, Den. Switch to Jellyfin?")
    }

    /// Neither answered: the usual message. A reply of the searched kind in the other list does not count.
    func testNothingEitherWayKeepsTheUsualMessage() throws {
        XCTAssertNil(SignInFlow.otherKindFound(searched: .jellyfin, other: []))
        let jf = try XCTUnwrap(LANServerDiscovery.parse(reply: jellyfinReply, kind: .jellyfin))
        XCTAssertNil(SignInFlow.otherKindFound(searched: .jellyfin, other: [jf]))
        XCTAssertNil(SignInFlow.otherKind(of: .plex))
        XCTAssertEqual(SignInFlow.otherKind(of: .jellyfin), .emby)
        XCTAssertEqual(SignInFlow.otherKind(of: .emby), .jellyfin)
    }

    /// The UI test fixture for this: an Emby server only.
    func testTheOtherKindFixture() {
        let args = ["-uiTestDiscovery", "otherkind"]
        XCTAssertEqual(SignInFlow.uiTestDiscoveryFixture(kind: .jellyfin, arguments: args), [])
        XCTAssertEqual(SignInFlow.uiTestDiscoveryFixture(kind: .emby, arguments: args)?.count, 1)
    }
}
