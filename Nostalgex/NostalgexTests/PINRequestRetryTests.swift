import XCTest
@testable import Nostalgex

@MainActor
final class PINRequestRetryTests: XCTestCase {

    // An Apple TV waking from sleep fails the first plex.tv call instantly with "not
    // connected" rather than timing out. That must be retried, not surfaced as a dead end.
    func testWakeFromSleepNetworkErrorsAreTransient() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                    .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost] {
            XCTAssertTrue(AppState.isTransientPINRequestError(URLError(code)), "\(code) should retry")
        }
    }

    func testServerSideFailuresRetryButClientSideDoNot() {
        XCTAssertTrue(AppState.isTransientPINRequestError(PlexAPIService.APIError.httpFailure(statusCode: 503)))
        XCTAssertFalse(AppState.isTransientPINRequestError(PlexAPIService.APIError.httpFailure(statusCode: 429)))
        XCTAssertFalse(AppState.isTransientPINRequestError(PlexAPIService.APIError.httpFailure(statusCode: 400)))
        XCTAssertFalse(AppState.isTransientPINRequestError(PlexAPIService.APIError.invalidResponse))
        XCTAssertFalse(AppState.isTransientPINRequestError(URLError(.cancelled)))
    }

    // Every failure used to collapse into one "could not reach plex.tv" line, which made
    // repeat reports of this screen undiagnosable. The cause must be visible.
    func testFailureMessagesNameTheCause() {
        XCTAssertTrue(AppState.pinRequestFailureMessage(URLError(.notConnectedToInternet)).contains("No internet"))
        XCTAssertTrue(AppState.pinRequestFailureMessage(URLError(.timedOut)).contains("too long"))
        XCTAssertTrue(AppState.pinRequestFailureMessage(URLError(.cannotFindHost)).contains("\(URLError.Code.cannotFindHost.rawValue)"))
        XCTAssertTrue(AppState.pinRequestFailureMessage(PlexAPIService.APIError.httpFailure(statusCode: 429)).contains("rate-limiting"))
        XCTAssertTrue(AppState.pinRequestFailureMessage(PlexAPIService.APIError.httpFailure(statusCode: 502)).contains("HTTP 502"))
        XCTAssertTrue(AppState.pinRequestFailureMessage(nil).contains("Could not reach plex.tv"))
    }

    func testRetriesAreBoundedSoAConnectTapNeverHangs() {
        XCTAssertGreaterThan(AppState.pinRequestAttempts, 1)
        XCTAssertLessThanOrEqual(AppState.pinRequestAttempts, 5)
    }
}

// A Tailscale address (100.x) is not "local" to App Transport Security, so with arbitrary
// loads off tvOS refused plain http:// to it and the app said the server was unreachable.
// The user could reach the same server from every other app on the box.
@MainActor
final class ServerUnreachableMessageTests: XCTestCase {
    func testTransportSecurityRefusalIsNamed() {
        let m = AppState.serverUnreachableMessage(URLError(.appTransportSecurityRequiresSecureConnection), backend: "Jellyfin")
        XCTAssertTrue(m.contains("http://"), m)
        XCTAssertFalse(m.contains("Could not reach"), "this is not a reachability problem")
    }

    func testCommonCausesAreDistinguished() {
        XCTAssertTrue(AppState.serverUnreachableMessage(URLError(.cannotConnectToHost), backend: "Emby").contains("8096"))
        XCTAssertTrue(AppState.serverUnreachableMessage(URLError(.cannotFindHost), backend: "Jellyfin").contains("host"))
        XCTAssertTrue(AppState.serverUnreachableMessage(URLError(.serverCertificateUntrusted), backend: "Jellyfin").contains("certificate"))
        XCTAssertTrue(AppState.serverUnreachableMessage(NSError(domain: "x", code: 1), backend: "Emby").contains("Could not reach the Emby server"))
    }

    func testArbitraryLoadsAreAllowedSoVPNAddressesWork() throws {
        let ats = try Self.appTransportSecurity()
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true, "Tailscale/VPN http:// servers need this; local-only ATS blocks 100.x addresses")
    }

    /// The previous version of this suite asserted only that NSAllowsArbitraryLoads was
    /// true, and passed for two releases while the shipped app refused every plain
    /// http:// LAN server. On tvOS 10+ the system IGNORES NSAllowsArbitraryLoads (and
    /// uses NO) whenever one of these companion keys is present, so asserting the flag
    /// alone proves nothing about what the app can actually reach.
    func testNoCompanionATSKeyCancelsArbitraryLoads() throws {
        let ats = try Self.appTransportSecurity()
        for key in ["NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"] {
            XCTAssertNil(ats[key], "\(key) makes tvOS ignore NSAllowsArbitraryLoads — http:// servers on 192.168/10.x/100.x then fail with -1022")
        }
    }

    private static func appTransportSecurity() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: AppState.self).url(forResource: "Info", withExtension: "plist"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url))
        return try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
    }

    // MARK: - How long a code is waited for (N-007)

    /// The reply plex.tv sent for a new code on 2026-11-09 (code and client id left out):
    /// 900 s, 15 minutes after createdAt.
    func testTheRecordedReplyCarriesFifteenMinutes() throws {
        let json = #"{"id":804507600,"code":"ABCD","product":"Nostalgex","trusted":false,"qr":"https://plex.tv/api/v2/pins/qr/ABCD","expiresIn":900,"createdAt":"2026-11-10T01:21:05Z","expiresAt":"2026-11-10T01:36:05Z","authToken":null,"newRegistration":null}"#
        let grant = try PlexAPIService.decodePINGrant(Data(json.utf8))
        XCTAssertEqual(grant, PlexAPIService.PINGrant(id: 804507600, code: "ABCD", expiresIn: 900))
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: grant.expiresIn), 900, "the app waits what plex.tv keeps, not 5 minutes")
    }

    func testAReplyWithoutExpiresInKeepsTheOldFiveMinutes() throws {
        let grant = try PlexAPIService.decodePINGrant(Data(#"{"id":1,"code":"WXYZ"}"#.utf8))
        XCTAssertNil(grant.expiresIn)
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: grant.expiresIn), 300)
    }

    func testOddSpellingsOfExpiresInStillSignInAndNeverFailTheDecode() throws {
        for (json, want) in [(#"{"id":1,"code":"A","expiresIn":1800.0}"#, 1800), (#"{"id":1,"code":"A","expiresIn":"600"}"#, 600)] {
            XCTAssertEqual(try PlexAPIService.decodePINGrant(Data(json.utf8)).expiresIn, want, json)
        }
        let junk = try PlexAPIService.decodePINGrant(Data(#"{"id":1,"code":"A","expiresIn":"soon"}"#.utf8))
        XCTAssertNil(junk.expiresIn, "an unreadable value is dropped, the code itself still works")
    }

    func testLifetimeIsBoundedBothWays() {
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: nil), 300)
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: 0), 300)
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: -5), 300)
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: 120), 120, "a short code is not stretched past what plex.tv keeps")
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: 900), 900)
        XCTAssertEqual(AppState.plexPINLifetime(expiresIn: 86_400), 1800, "a bad value cannot wait for a day")
    }
}
