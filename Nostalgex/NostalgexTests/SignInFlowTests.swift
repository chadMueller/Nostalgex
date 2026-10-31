import XCTest
@testable import Nostalgex

/// The decisions behind the Jellyfin and Emby connect screens: what discovery leads to,
/// which way in a server gets first, and what the address check reads before anyone types.
final class SignInFlowTests: XCTestCase {

    private func server(_ id: String, _ address: String = "http://192.168.1.10:8096") -> DiscoveredServer {
        DiscoveredServer(kind: .jellyfin, name: "Server \(id)", address: address, id: id)
    }

    // MARK: - Discovery outcome

    func testOneServerAnsweringGoesStraightToIt() {
        let only = server("a")
        XCTAssertEqual(SignInFlow.outcome(of: [only]), .single(only))
    }

    /// The same server heard on two interfaces (Wi-Fi and Ethernet) is still one server,
    /// so it must not turn into a pick.
    func testTheSameServerTwiceIsStillOne() {
        let wifi = server("a", "http://192.0.2.45:8096")
        let ethernet = server("a", "http://192.0.2.49:8096")
        XCTAssertEqual(SignInFlow.outcome(of: [wifi, ethernet]), .single(wifi))
    }

    func testTwoServersAreListed() {
        let a = server("a"), b = server("b", "http://192.168.1.11:8096")
        XCTAssertEqual(SignInFlow.outcome(of: [a, b]), .several([a, b]))
    }

    func testNothingAnsweringOffersTheTypedAddress() {
        XCTAssertEqual(SignInFlow.outcome(of: []), .none)
    }

    func testUITestDiscoveryStandInOnlyWhenAsked() {
        XCTAssertNil(SignInFlow.uiTestDiscoveryFixture(kind: .emby, arguments: ["app"]))
        XCTAssertNil(SignInFlow.uiTestDiscoveryFixture(kind: .emby, arguments: ["app", "-uiTestDiscovery"]))
        XCTAssertEqual(SignInFlow.uiTestDiscoveryFixture(kind: .emby, arguments: ["app", "-uiTestDiscovery", "none"]), [])
        XCTAssertEqual(SignInFlow.uiTestDiscoveryFixture(kind: .emby, arguments: ["app", "-uiTestDiscovery none"]), [])
        let several = SignInFlow.uiTestDiscoveryFixture(kind: .jellyfin, arguments: ["-uiTestDiscovery", "several"]) ?? []
        XCTAssertEqual(several.count, 2)
        XCTAssertTrue(several.allSatisfy { $0.kind == .jellyfin })
        if case .several = SignInFlow.outcome(of: several) {} else { XCTFail("two stand-ins should be a pick") }
    }

    // MARK: - Which way in

    func testQuickConnectIsTheDefaultWhenJellyfinSaysItIsOn() {
        XCTAssertEqual(SignInFlow.preferredMethod(kind: .jellyfin, quickConnectEnabled: true), .quickConnect)
    }

    func testPasswordWhenJellyfinQuickConnectIsOffOrUnknown() {
        XCTAssertEqual(SignInFlow.preferredMethod(kind: .jellyfin, quickConnectEnabled: false), .password)
        XCTAssertEqual(SignInFlow.preferredMethod(kind: .jellyfin, quickConnectEnabled: nil), .password)
    }

    func testEmbyIsAlwaysPassword() {
        for answer in [true, false, nil] as [Bool?] {
            XCTAssertEqual(SignInFlow.preferredMethod(kind: .emby, quickConnectEnabled: answer), .password)
            XCTAssertFalse(SignInFlow.offersQuickConnect(kind: .emby, quickConnectEnabled: answer))
        }
    }

    /// Quick Connect stays on offer unless the server said it is off: an older Jellyfin
    /// that can't say still gets the button, and Initiate explains itself if it fails.
    func testQuickConnectButtonHiddenOnlyWhenTheServerSaysOff() {
        XCTAssertTrue(SignInFlow.offersQuickConnect(kind: .jellyfin, quickConnectEnabled: true))
        XCTAssertTrue(SignInFlow.offersQuickConnect(kind: .jellyfin, quickConnectEnabled: nil))
        XCTAssertFalse(SignInFlow.offersQuickConnect(kind: .jellyfin, quickConnectEnabled: false))
    }

    // MARK: - Parsing

    func testQuickConnectEnabledReadsTheBareBoolean() {
        XCTAssertEqual(SignInFlow.parseQuickConnectEnabled(Data("true".utf8), statusCode: 200), true)
        XCTAssertEqual(SignInFlow.parseQuickConnectEnabled(Data(" false\n".utf8), statusCode: 200), false)
        // Emby 4.10 answers 404 with a text page; old Jellyfin has no such route.
        XCTAssertNil(SignInFlow.parseQuickConnectEnabled(Data("The file '/QuickConnect/Enabled' could not be found.".utf8), statusCode: 404))
        XCTAssertNil(SignInFlow.parseQuickConnectEnabled(Data("<html></html>".utf8), statusCode: 200))
    }

    /// Captured from Jellyfin 12.2.0 and Emby 4.10.1.0 (Ids shortened).
    func testPublicInfoNamesTheKind() {
        let jellyfin = #"{"LocalAddress":"http://127.0.0.1:8096","ServerName":"Living Room","Version":"12.2.0","ProductName":"Jellyfin Server","OperatingSystem":"","Id":"d1d2d3d4","StartupWizardCompleted":true}"#
        let emby = #"{"LocalAddresses":[],"RemoteAddresses":[],"ServerName":"Attic-Server","Version":"4.10.1.0","Id":"e5e6e7e8"}"#
        XCTAssertEqual(SignInFlow.parsePublicInfo(Data(jellyfin.utf8)),
                       .init(id: "d1d2d3d4", name: "Living Room", kind: .jellyfin))
        XCTAssertEqual(SignInFlow.parsePublicInfo(Data(emby.utf8)),
                       .init(id: "e5e6e7e8", name: "Attic-Server", kind: .emby))
        XCTAssertNil(SignInFlow.parsePublicInfo(Data(#"{"ServerName":"router"}"#.utf8)), "no Id is not a server")
        XCTAssertNil(SignInFlow.parsePublicInfo(Data("<!doctype html>".utf8)))
    }

    func testPublicUsersKeepNameIdAndPassword() {
        let json = #"[{"Name":"avsync","Id":"u1","HasPassword":true},{"Name":"kids","Id":"u2","HasPassword":false},{"Name":"","Id":"u3"},{"Name":"no id"}]"#
        XCTAssertEqual(SignInFlow.parsePublicUsers(Data(json.utf8)), [
            .init(id: "u1", name: "avsync", hasPassword: true),
            .init(id: "u2", name: "kids", hasPassword: false),
        ])
        XCTAssertEqual(SignInFlow.parsePublicUsers(Data("[]".utf8)), [])
        XCTAssertEqual(SignInFlow.parsePublicUsers(Data("nope".utf8)), [])
    }

    // MARK: - The address check

    /// Answers by path from a table; records every request made.
    private final class FakeServer: @unchecked Sendable {
        var routes: [String: (Int, String)] = [:]
        var refused: Set<String> = []
        private(set) var asked: [String] = []
        private let lock = NSLock()

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!.absoluteString
            lock.withLock { asked.append(url) }
            if refused.contains(where: { url.hasPrefix($0) }) { throw URLError(.cannotConnectToHost) }
            let (status, body) = routes[url] ?? (404, "not found")
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let jellyfinInfo = #"{"ServerName":"Living Room","ProductName":"Jellyfin Server","Id":"jf1"}"#
    private let embyInfo = #"{"ServerName":"Den","Id":"em1"}"#

    func testABareAddressFindsJellyfinOn8096AndOpensOnQuickConnect() async throws {
        let fake = FakeServer()
        fake.routes = [
            "http://192.168.1.10:8096/System/Info/Public": (200, jellyfinInfo),
            "http://192.168.1.10:8096/QuickConnect/Enabled": (200, "true"),
            "http://192.168.1.10:8096/Users/Public": (200, "[]"),
        ]
        let checked = try await SignInFlow.check(address: "192.168.1.10", send: fake.send)
        XCTAssertEqual(checked, .init(kind: .jellyfin, url: "http://192.168.1.10:8096", name: "Living Room",
                                      quickConnectEnabled: true, users: []))
        XCTAssertEqual(checked.preferredMethod, .quickConnect)
    }

    func testJellyfinWithQuickConnectOffOpensOnPassword() async throws {
        let fake = FakeServer()
        fake.routes = [
            "http://jf.local:8096/System/Info/Public": (200, jellyfinInfo),
            "http://jf.local:8096/QuickConnect/Enabled": (200, "false"),
        ]
        let checked = try await SignInFlow.check(address: "http://jf.local:8096", send: fake.send)
        XCTAssertEqual(checked.preferredMethod, .password)
        XCTAssertFalse(checked.offersQuickConnect)
    }

    func testEmbyIsNeverAskedAboutQuickConnectAndShowsItsUsers() async throws {
        let fake = FakeServer()
        fake.routes = [
            "http://192.168.1.20:8096/System/Info/Public": (200, embyInfo),
            "http://192.168.1.20:8096/Users/Public": (200, #"[{"Name":"dad","Id":"d","HasPassword":false}]"#),
        ]
        let checked = try await SignInFlow.check(address: "http://192.168.1.20:8096", send: fake.send)
        XCTAssertEqual(checked.kind, .emby)
        XCTAssertNil(checked.quickConnectEnabled)
        XCTAssertEqual(checked.users, [.init(id: "d", name: "dad", hasPassword: false)])
        XCTAssertEqual(checked.preferredMethod, .password)
        XCTAssertFalse(fake.asked.contains { $0.contains("QuickConnect") }, "asked Emby about Quick Connect: \(fake.asked)")
    }

    /// Nothing on 8096: the portless form is tried next, as sign-in does.
    func testNothingOn8096TriesTheAddressAsTyped() async throws {
        let fake = FakeServer()
        fake.refused = ["http://10.0.0.5:8096"]
        fake.routes = ["http://10.0.0.5/System/Info/Public": (200, embyInfo)]
        let checked = try await SignInFlow.check(address: "10.0.0.5", send: fake.send)
        XCTAssertEqual(checked.url, "http://10.0.0.5")
    }

    func testAWebPageIsNotAServer() async {
        let fake = FakeServer()
        fake.routes = ["http://192.168.1.1:8096/System/Info/Public": (200, "<html>router</html>"),
                       "http://192.168.1.1/System/Info/Public": (200, "<html>router</html>")]
        do {
            _ = try await SignInFlow.check(address: "192.168.1.1", send: fake.send)
            XCTFail("a web page passed as a server")
        } catch {
            XCTAssertEqual(error as? SignInFlow.CheckError, .notAServer)
        }
    }

    @MainActor func testARefusedConnectionComesBackAsTheNetworkError() async {
        let fake = FakeServer()
        fake.refused = ["http://192.168.1.99"]
        do {
            _ = try await SignInFlow.check(address: "192.168.1.99", send: fake.send)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            XCTAssertTrue(AppState.serverUnreachableMessage(error, backend: "Emby").contains("Nothing answered"))
        }
    }

    /// The viewer pressed EMBY but typed a Jellyfin address: the server's own answer wins,
    /// so the right sign-in (and Quick Connect) runs.
    func testTheServerSaysWhichKindItIs() async throws {
        let fake = FakeServer()
        fake.routes = [
            "http://192.168.1.10:8096/System/Info/Public": (200, jellyfinInfo),
            "http://192.168.1.10:8096/QuickConnect/Enabled": (200, "true"),
        ]
        let checked = try await SignInFlow.check(address: "192.168.1.10:8096", send: fake.send)
        XCTAssertEqual(checked.kind, .jellyfin)
        XCTAssertEqual(checked.preferredMethod, .quickConnect)
    }

    // MARK: - Copy

    func testCopyHasNoEmDashesAndNoEmoji() {
        let all = SignInFlow.Copy.all + LANServerDiscovery.Copy.all
        XCTAssertGreaterThan(all.count, 20)
        for text in all {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("—"), "em dash in: \(text)")
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C },
                           "emoji in: \(text)")
        }
    }

    func testFindMyServerIsTheButtonsName() {
        XCTAssertEqual(LANServerDiscovery.Copy.findButton, "FIND MY SERVER")
    }
}
