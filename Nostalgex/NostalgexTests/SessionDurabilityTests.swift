import XCTest
@testable import Nostalgex

/// The rule these lock down: a sign-in, once made, is never lost by the app's own doing.
@MainActor
final class SessionDurabilityTests: XCTestCase {
    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    // MARK: - Keychain mirror

    // The simulator keychain always refuses (-34018), so a value that still round-trips
    // here proves the container mirror carries the sign-in when the keychain cannot.
    func testCredentialSurvivesWhenTheKeychainRefuses() {
        let key = "test_mirror_\(UUID().uuidString)"
        defer { KeychainService.delete(key: key) }

        XCTAssertTrue(KeychainService.save(key: key, value: "tok-1"))
        XCTAssertEqual(KeychainService.load(key: key), "tok-1")

        XCTAssertTrue(KeychainService.save(key: key, value: "tok-2"))
        XCTAssertEqual(KeychainService.load(key: key), "tok-2")

        KeychainService.delete(key: key)
        XCTAssertNil(KeychainService.load(key: key))
    }

    // MARK: - Token-only sign-in

    func testPlexTokenAloneCountsAsSignedIn() {
        let state = AppState(credentialStore: InMemoryStore())
        state.backendKind = .plex
        state.token = "abc"
        state.serverURL = ""
        state.selectedServers = []
        XCTAssertTrue(state.hasCredentials, "servers are rediscovered from plex.tv; losing the list must not sign the user out")
    }

    func testJellyfinNeedsAServerURL() {
        let state = AppState(credentialStore: InMemoryStore())
        state.backendKind = .jellyfin
        state.token = "abc"
        state.serverURL = ""
        state.selectedServers = []
        XCTAssertFalse(state.hasCredentials)
        state.serverURL = "https://jf.local"
        XCTAssertTrue(state.hasCredentials)
    }

    func testNoTokenIsNotSignedIn() {
        let state = AppState(credentialStore: InMemoryStore())
        state.backendKind = .plex
        state.token = ""
        state.serverURL = "https://plex.local"
        XCTAssertFalse(state.hasCredentials)
    }

    // MARK: - A Plex sign-in is actually written to disk

    // Regression: from 7fc1629 (2026-05-29) the PIN flow persisted the server list but
    // not the account token, so a fresh sign-in never survived a relaunch.
    func testPlexSignInPersistsTokenAndServers() {
        let store = InMemoryStore()
        let state = AppState(credentialStore: store)
        let server = AppState.ServerRef(machineIdentifier: "m1", name: "Den", baseURL: "https://plex.local:32400", owned: true, token: "srv")

        state.completePlexSignIn(token: "account-token", servers: [server])

        XCTAssertEqual(store.values["plex_token"], "account-token")
        XCTAssertNotNil(store.values[AppState.serversKey])

        let relaunched = AppState(credentialStore: store)
        relaunched.loadCredentials()
        XCTAssertEqual(relaunched.token, "account-token")
        XCTAssertEqual(relaunched.selectedServers.map(\.machineIdentifier), ["m1"])
        XCTAssertTrue(relaunched.hasCredentials)
    }

    func testPickerConfirmationPersistsTheToken() {
        let store = InMemoryStore()
        let state = AppState(credentialStore: store)
        state.token = "account-token"
        let server = AppState.ServerRef(machineIdentifier: "m2", name: "Loft", baseURL: "https://loft:32400", owned: true, token: "srv")

        state.confirmServerSelection([server])

        XCTAssertEqual(store.values["plex_token"], "account-token")
    }

    // MARK: - 401 never signs out

    func testUnauthorizedMessagesKeepTheSessionAndPointAtDisconnect() {
        for validity in [TokenValidity.valid, .invalid, .unknown] {
            let msg = AppState.unauthorizedLoadMessage(tokenValidity: validity, backend: .plex)
            XCTAssertFalse(msg.lowercased().contains("sign in again"), "\(validity): must not ask for a fresh sign-in")
        }
        let invalid = AppState.unauthorizedLoadMessage(tokenValidity: .invalid, backend: .plex)
        XCTAssertTrue(invalid.contains("kept"))
        XCTAssertTrue(invalid.contains("Disconnect"))
    }

    // MARK: - Error copy names the server the user actually connected to

    /// A Jellyfin or Emby user whose scan fails used to be told to check Plex: the shared
    /// `PlexAPIService.APIError` carried Plex-only wording for every backend. Issue #6 was
    /// reported with "Plex (or your network path) returned HTTP 404" on an Emby server.
    func testErrorCopyNamesTheConnectedBackendAndNeverTheWrongOne() {
        let cases: [PlexAPIService.APIError] = [
            .unauthorized,
            .invalidResponse,
            .noReachableServer,
            .httpFailure(statusCode: 404),
            .receivedMarkupInsteadOfJSON(statusCode: 200)
        ]

        for backend in [MediaBackendKind.jellyfin, .emby] {
            for error in cases {
                for fresh in [true, false] {
                    let msg = AppState.userFacingPlexAPIServiceError(
                        error, justAuthenticated: fresh, backend: backend
                    )
                    XCTAssertFalse(
                        msg.contains("Plex"),
                        "\(backend) / \(error) / justAuthenticated=\(fresh) names Plex: \(msg)"
                    )
                }
            }
        }

        // The backend is named where there is a server to name. "Session expired" has no
        // server in it by design, so it is the one message that stays generic.
        let emby = AppState.userFacingPlexAPIServiceError(
            .httpFailure(statusCode: 404), backend: .emby
        )
        XCTAssertTrue(emby.contains("Emby"), emby)
        XCTAssertTrue(emby.contains("404"), emby)

        // Plex keeps its own wording, including the paths only Plex serves.
        let plex = AppState.userFacingPlexAPIServiceError(
            .httpFailure(statusCode: 404), backend: .plex
        )
        XCTAssertTrue(plex.contains("/identity"), plex)
    }
}
