import XCTest
@testable import Nostalgex

/// #312: an episode's Now Playing poster is its season's poster, then its series', then its own frame.
final class PlexPosterChainTests: XCTestCase {

    private func item(type: MediaType, thumb: String?, showKey: String? = nil, parentRatingKey: String? = nil) -> PlexMediaItem {
        var i = PlexMediaItem(
            id: "s:1", title: "Show", artist: nil, episodeTitle: type == .episode ? "Ep" : nil,
            seTag: type == .episode ? "S01E01" : nil, summary: "", year: 2001,
            originallyAvailableAt: nil, contentRating: nil, duration: 22, ratingKey: "100",
            partKey: nil, container: "mp4", videoCodec: "h264", audioCodec: "aac", videoProfile: nil,
            bitrate: 2000, genres: [], rating: 0, userRating: 0, type: type, thumb: thumb, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: type == .episode ? .tv : .movie, serverID: nil)
        i.showKey = showKey
        i.parentRatingKey = parentRatingKey
        return i
    }

    func testAnEpisodeTriesTheSeasonThenTheSeriesThenItsOwnFrame() {
        let e = item(type: .episode, thumb: "/library/metadata/100/thumb/9", showKey: "10", parentRatingKey: "11")
        XCTAssertEqual(PlexPosterChain.paths(for: e), [
            "/library/metadata/11/thumb", "/library/metadata/10/thumb", "/library/metadata/100/thumb/9",
        ])
    }

    func testASeasonWithoutPosterArtSkipsToTheSeries() {
        let e = item(type: .episode, thumb: "/library/metadata/100/thumb/9", showKey: "10", parentRatingKey: nil)
        XCTAssertEqual(PlexPosterChain.paths(for: e), ["/library/metadata/10/thumb", "/library/metadata/100/thumb/9"])
    }

    /// An episode restored from a snapshot written before the keys: its own frame until the next rescan.
    func testAnOldSnapshotsEpisodeKeepsItsFrame() {
        let e = item(type: .episode, thumb: "/library/metadata/100/thumb/9")
        XCTAssertEqual(PlexPosterChain.paths(for: e), ["/library/metadata/100/thumb/9"])
    }

    func testAMovieIsJustItsPosterEvenWithKeysSet() {
        let m = item(type: .movie, thumb: "/library/metadata/100/thumb/5", showKey: "10", parentRatingKey: "11")
        XCTAssertEqual(PlexPosterChain.paths(for: m), ["/library/metadata/100/thumb/5"])
    }

    func testNothingToAskForGivesAnEmptyList() {
        XCTAssertEqual(PlexPosterChain.paths(for: item(type: .movie, thumb: nil)), [])
        XCTAssertEqual(PlexPosterChain.paths(for: item(type: .episode, thumb: "")), [])
    }

    func testAnEpisodeWhoseFrameIsTheSeriesPathIsNotAskedTwice() {
        let e = item(type: .episode, thumb: "/library/metadata/10/thumb", showKey: "10")
        XCTAssertEqual(PlexPosterChain.paths(for: e), ["/library/metadata/10/thumb"])
    }

    // MARK: - Snapshots

    func testAnItemWithTheKeyRoundTrips() throws {
        let e = item(type: .episode, thumb: "t", showKey: "10", parentRatingKey: "11")
        let back = try JSONDecoder().decode(PlexMediaItem.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.parentRatingKey, "11")
        XCTAssertEqual(back.showKey, "10")
    }

    /// A snapshot written before the field has no `parentRatingKey` at all; it must still decode.
    func testASnapshotWrittenBeforeTheFieldStillDecodes() throws {
        let e = item(type: .episode, thumb: "t", showKey: "10", parentRatingKey: "11")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "parentRatingKey"))
        let old = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONDecoder().decode(PlexMediaItem.self, from: old)
        XCTAssertNil(back.parentRatingKey)
        XCTAssertEqual(back.title, "Show")
        XCTAssertEqual(PlexPosterChain.paths(for: back), ["/library/metadata/10/thumb", "t"])
    }

    func testThePlexPayloadsSeasonFieldsDecodeAndAreOptional() throws {
        let with = #"{"ratingKey":"5","title":"Ep","parentRatingKey":"11","parentThumb":"/library/metadata/11/thumb/1","grandparentRatingKey":"10"}"#
        let without = #"{"ratingKey":"5","title":"Ep"}"#
        let a = try JSONDecoder().decode(PlexRawItem.self, from: Data(with.utf8))
        XCTAssertEqual(a.parentRatingKey, "11")
        XCTAssertEqual(a.parentThumb, "/library/metadata/11/thumb/1")
        let b = try JSONDecoder().decode(PlexRawItem.self, from: Data(without.utf8))
        XCTAssertNil(b.parentRatingKey)
        XCTAssertNil(b.parentThumb)
    }

    /// `withPartKey` copies the item for multi-disc playback; the season key must ride along.
    func testACopyForAnotherPartKeepsTheSeasonKey() {
        let e = item(type: .episode, thumb: "t", showKey: "10", parentRatingKey: "11")
        XCTAssertEqual(e.withPartKey("/part/2").parentRatingKey, "11")
    }
}
