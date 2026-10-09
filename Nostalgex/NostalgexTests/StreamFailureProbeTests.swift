import XCTest
@testable import Nostalgex

/// The probe exists because tvOS will not tell us the HTTP status of a failed HLS request.
/// These pin the two things the failure card depends on: that a refusal is recognised, and
/// that a server which is serving the URL happily is never reported as a refusal.
final class StreamFailureProbeTests: XCTestCase {

    func testOnlyFourAndFiveHundredsCountAsTheServerSayingNo() {
        for ok in [200, 206, 301, 302, 399] {
            XCTAssertFalse(StreamFailureProbe.isRefusal(ok), "\(ok) is not a refusal")
        }
        for no in [400, 401, 403, 404, 500, 502, 503] {
            XCTAssertTrue(StreamFailureProbe.isRefusal(no), "\(no) is a refusal")
        }
    }

    /// 206 is the expected answer to the ranged request the probe makes. Treating it as a
    /// refusal would blame the server for every failure that is actually on this side.
    func testAPartialContentAnswerIsTheHealthyCase() {
        XCTAssertFalse(StreamFailureProbe.isRefusal(206))
    }

    func testNothingAnsweringYieldsNoStatusRatherThanAGuess() async {
        // Reserved, per RFC 6761, so this resolves nowhere and the probe must simply
        // give up instead of inventing a status.
        let url = URL(string: "http://localhost:1/does-not-exist.m3u8")!
        let status = await StreamFailureProbe.status(of: url, timeout: 2)
        XCTAssertNil(status)
    }

    // MARK: - Walking the playlist down to real media

    /// The whole reason the walk exists: Emby serves the master and the variant and only
    /// refuses when the first segment is demanded. Stopping at the master reported "no
    /// reason came back" for a server that was refusing everything.
    func testTheFirstMediaLineOfAMasterPlaylistIsTheNextHop() throws {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=9600000,CODECS="avc1.640029,mp4a.40.2"
        main.m3u8?MediaSourceId=mediasource_2770&api_key=abc
        """
        let base = URL(string: "http://host:8096/Videos/2770/master.m3u8?api_key=abc")!
        let next = try XCTUnwrap(StreamFailureProbe.firstMediaURL(inPlaylist: master, relativeTo: base))
        XCTAssertEqual(next.path, "/Videos/2770/main.m3u8")
        XCTAssertTrue(next.query?.contains("MediaSourceId=mediasource_2770") == true,
                      "the playlist's own query must survive: Emby repeats it on every hop")
    }

    /// Segment URIs are relative to the playlist, not to the server root.
    func testSegmentURIsResolveAgainstThePlaylistNotTheHost() throws {
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:3
        #EXT-X-MAP:URI="hls1/main/init.mp4"
        #EXTINF:3.0000, nodesc
        hls1/main/0.mp4?PlaySessionId=xyz
        """
        let base = URL(string: "http://host:8096/videos/2770/main.m3u8?api_key=abc")!
        let seg = try XCTUnwrap(StreamFailureProbe.firstMediaURL(inPlaylist: media, relativeTo: base))
        XCTAssertEqual(seg.path, "/videos/2770/hls1/main/0.mp4")
    }

    /// `#EXT-X-MAP` is a comment line carrying a URI. Treating it as the next hop would
    /// probe the init segment instead of the first media segment.
    func testCommentLinesAreSkippedEvenWhenTheyContainAURI() throws {
        let media = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:3.0000, nodesc
        0.mp4
        """
        let base = URL(string: "http://host:8096/videos/1/main.m3u8")!
        let seg = try XCTUnwrap(StreamFailureProbe.firstMediaURL(inPlaylist: media, relativeTo: base))
        XCTAssertEqual(seg.lastPathComponent, "0.mp4")
    }

    func testAPlaylistWithNoMediaLinesEndsTheWalk() {
        let empty = "#EXTM3U\n#EXT-X-VERSION:7\n"
        let base = URL(string: "http://host:8096/v/master.m3u8")!
        XCTAssertNil(StreamFailureProbe.firstMediaURL(inPlaylist: empty, relativeTo: base))
    }

    /// A probe that answers 500 has to reach the card as a server refusal, which is the
    /// whole chain this feature rests on.
    func testARefusalFromTheProbeClassifiesAsServerRefused() {
        var e = PlaybackFailure.Evidence()
        e.httpStatuses = [500]
        XCTAssertEqual(PlaybackFailure.classify(backend: .emby, evidence: e),
                       .serverRefused(server: "Emby", status: 500))
    }
}
