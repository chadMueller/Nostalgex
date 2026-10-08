import XCTest
@testable import Nostalgex

/// Emby is not Jellyfin, however alike the two APIs look.
///
/// Measured against Emby Server 4.10.1.0 on 2026-10-08, signed in as a real user:
///
///     GET /UserViews?userId=<id>   ->  404
///     GET /Users/<id>/Views        ->  200
///
/// `/UserViews` is Jellyfin's spelling. The Emby service had copied it, and because
/// loading libraries is the first thing that happens after sign-in, every Emby user hit
/// a 404 the instant the scan began, whatever their libraries were named or how large
/// they were. Reported as issue #6 by @Jay-Nuvolinq on Emby 4.9.5.0.
///
/// The rest of the Emby surface was checked against the same server at the same time and
/// is correct: `/Items?userId=` 200, `/Users/AuthenticateByName` 200,
/// `/Sessions/Playing/Stopped` 204, `DELETE /Videos/ActiveEncodings` 204.
final class EmbyEndpointTests: XCTestCase {

    func testLibrariesComeFromTheEmbySpellingNotTheJellyfinOne() throws {
        let path = try XCTUnwrap(EmbyAPIService.userViewsPath(userId: "9b83e06be5e842208e2c7a94e6014efa"))
        XCTAssertEqual(path, "/Users/9b83e06be5e842208e2c7a94e6014efa/Views")
        XCTAssertFalse(path.contains("UserViews"),
                       "/UserViews is Jellyfin only and answers 404 on Emby")
        XCTAssertFalse(path.contains("?"),
                       "Emby takes the user in the path, not as a userId query item")
    }

    func testAUserIdNeedingEscapingStaysOnePathComponent() throws {
        let path = try XCTUnwrap(EmbyAPIService.userViewsPath(userId: "a b/c"))
        XCTAssertTrue(path.hasPrefix("/Users/"), path)
        XCTAssertTrue(path.hasSuffix("/Views"), path)
    }

    func testNoUserIdMeansNoRequest() {
        XCTAssertNil(EmbyAPIService.userViewsPath(userId: ""))
    }
}
