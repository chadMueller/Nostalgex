import XCTest
@testable import Nostalgex

/// Every backend must have a rung below its first attempt.
///
/// `handleStarvation` steps a starving stream down to 1080p and only skips to the next
/// programme once there is nothing smaller left to ask for. That rung is
/// `cappedTranscodeURL`, and it was implemented on Plex alone. The `MediaBackend` default
/// returns nil, so Jellyfin and Emby inherited "no rung": a single stall fell straight
/// through to the skip.
///
/// What that looked like on 2026-10-08, on an Emby server producing each 6-second segment
/// in 3.4 seconds: a film jumped to the next scheduled title mid-scene, from the middle of
/// Fast and the Furious to Dodgeball at its first frame. Plex stepped down instead,
/// because Plex had the rung.
///
/// These tests assert the ladder exists on every backend, not that any particular URL is
/// correct. A backend added later fails here until it answers the question.
final class StarvationLadderCoverageTests: XCTestCase {

    private func item() -> PlexMediaItem {
        PlexMediaItem(
            id: "88", title: "Heat", artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 1995, originallyAvailableAt: nil, contentRating: nil,
            duration: 170, ratingKey: "88", partKey: "src-1", container: "mkv",
            videoCodec: "hevc", audioCodec: "eac3", videoProfile: nil, bitrate: 42_000,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: .movie
        )
    }

    private var backends: [(name: String, backend: MediaBackend)] {
        [
            ("Jellyfin", JellyfinAPIService(serverURL: "http://192.168.4.79:8096",
                                            accessToken: "tok", userId: "u1")),
            ("Emby", EmbyAPIService(serverURL: "http://192.168.4.79:8096",
                                    accessToken: "tok", userId: "u1")),
        ]
    }

    func testEveryBackendOffersARungBelowItsFirstAttempt() throws {
        for (name, backend) in backends {
            let url = backend.cappedTranscodeURL(for: item(), offsetSeconds: 2_851, sessionID: "sess-1")
            XCTAssertNotNil(
                url,
                "\(name) has no capped rung, so one stall skips the programme instead of stepping down"
            )
        }
    }

    func testTheCappedRungAsksForMateriallyLessThanTheStreamThatStarved() throws {
        for (name, backend) in backends {
            let url = try XCTUnwrap(backend.cappedTranscodeURL(for: item(), offsetSeconds: 2_851, sessionID: "sess-1"))
            let q = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            func value(_ key: String) -> String? { q.first { $0.name == key }?.value }

            XCTAssertEqual(value("MaxWidth"), "1920", "\(name): the rung is 1080p")

            let bitrate = Int(try XCTUnwrap(value("VideoBitrate"), "\(name): no bitrate cap"))
            XCTAssertLessThan(
                try XCTUnwrap(bitrate), StreamQuality.maximum.maxBitrateBps,
                "\(name): a rung at or above the top preset asks the server for the same work again"
            )

            XCTAssertEqual(value("PlaySessionId"), "sess-1",
                           "\(name): the retry needs its own session, not the one that starved")
        }
    }

    /// Jellyfin and Emby reject a start time on segment requests, which is the whole reason
    /// PR #5 moved the tune-in seek client-side. The capped retry goes down the same path,
    /// so it must not smuggle an offset back onto the URL.
    func testTheCappedRungCarriesNoStartTimeOnTheBackendsThatRefuseOne() throws {
        for (name, backend) in backends {
            XCTAssertFalse(
                backend.cappedStreamStartsAtOffset,
                "\(name) seeks client-side; claiming the URL starts at the offset makes the caller skip the seek"
            )
            let url = try XCTUnwrap(backend.cappedTranscodeURL(for: item(), offsetSeconds: 2_851, sessionID: "s"))
            let raw = url.absoluteString
            XCTAssertFalse(raw.contains("StartTimeTicks"), "\(name): \(raw)")
            XCTAssertFalse(raw.contains("2851"), "\(name): offset leaked onto the URL — \(raw)")
        }
    }

    /// Plex is the other half of the contract: it builds the offset into the request, so the
    /// caller must not seek on top of it.
    func testPlexStillReportsThatItsCappedStreamStartsAtTheOffset() {
        let plex = PlexAPIService(serverURL: "http://192.168.4.79:32400", token: "t")
        XCTAssertTrue(plex.cappedStreamStartsAtOffset)
    }
}
