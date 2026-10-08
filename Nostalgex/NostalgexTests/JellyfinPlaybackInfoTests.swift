import XCTest
@testable import Nostalgex

/// Pure unit tests for the Jellyfin PlaybackInfo flow — DeviceProfile construction and the
/// response→URL selection. The live PlaybackInfo POST itself isn't tested (no network mock
/// infra, matching the existing JellyfinAPITests), but every pure piece around it is.
final class JellyfinPlaybackInfoTests: XCTestCase {

    private func decodeInfo(_ json: String) throws -> JellyfinPlaybackResolver.PlaybackInfoResponse {
        try JSONDecoder().decode(JellyfinPlaybackResolver.PlaybackInfoResponse.self, from: Data(json.utf8))
    }

    private func profileJSON(supportsHEVC: Bool) throws -> String {
        let data = try JSONEncoder().encode(JellyfinPlaybackResolver.deviceProfile(supportsHEVC: supportsHEVC))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - DeviceProfile

    func testDeviceProfileExcludesHEVCWhenUnsupported() throws {
        let json = try profileJSON(supportsHEVC: false)
        XCTAssertFalse(json.contains("hevc"), "HEVC must not be offered when the device can't decode it")
        XCTAssertTrue(json.contains("\"Protocol\":\"hls\""))
        // Transcode container is always fMP4, never MPEG-TS.
        XCTAssertTrue(json.contains("\"Container\":\"mp4\""))
        XCTAssertFalse(json.contains("\"Container\":\"ts\""))
    }

    func testDeviceProfileIncludesHEVCWhenSupported() throws {
        let json = try profileJSON(supportsHEVC: true)
        XCTAssertTrue(json.contains("hevc"))
        XCTAssertTrue(json.contains("h264"))
        XCTAssertTrue(json.contains("\"Container\":\"mp4\""))
    }

    func testDeviceProfileEncodesExpectedShape() throws {
        let json = try profileJSON(supportsHEVC: true)
        XCTAssertTrue(json.contains("DirectPlayProfiles"))
        XCTAssertTrue(json.contains("TranscodingProfiles"))
        XCTAssertTrue(json.contains("Streaming"))
    }

    func testDeviceProfileNamesTheBlackPictureCases() throws {
        let json = try profileJSON(supportsHEVC: true)
        XCTAssertTrue(json.contains("CodecProfiles"))
        XCTAssertTrue(json.contains("\"Property\":\"VideoCodecTag\""), "hev1 HEVC must be remuxed, not direct played")
        XCTAssertTrue(json.contains("hvc1|dvh1"))
        XCTAssertTrue(json.contains("\"Property\":\"VideoBitDepth\""), "10-bit H.264 has no decoder on Apple TV")
        XCTAssertFalse(try profileJSON(supportsHEVC: false).contains("VideoCodecTag"), "no HEVC rule when HEVC is not offered")
    }

    // MARK: - resolve()

    func testResolveSelectsTranscodingUrlAndSession() throws {
        let info = try decodeInfo("""
        { "PlaySessionId": "PS123",
          "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        XCTAssertFalse(res.isDirectPlay)
        XCTAssertEqual(res.playSessionId, "PS123")
        XCTAssertTrue(res.url.absoluteString.hasPrefix("http://jelly.local:8096"))
        XCTAssertTrue(res.url.absoluteString.contains("/Videos/m1/master.m3u8"))
        XCTAssertTrue(res.url.absoluteString.contains("api_key=TKN"))
    }

    func testResolveAppendsApiKeyWhenMissing() throws {
        let info = try decodeInfo("""
        { "PlaySessionId": "PS1",
          "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        let occurrences = res.url.absoluteString.components(separatedBy: "api_key=").count - 1
        XCTAssertEqual(occurrences, 1, "api_key must be appended exactly once")
    }

    func testResolveDoesNotDuplicateApiKey() throws {
        let info = try decodeInfo("""
        { "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?api_key=TKN" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        let occurrences = res.url.absoluteString.components(separatedBy: "api_key=").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testResolveFallsBackToDirectStream() throws {
        let info = try decodeInfo("""
        { "PlaySessionId": "PS9",
          "MediaSources": [ { "Id": "src1", "SupportsDirectPlay": true } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        XCTAssertTrue(res.isDirectPlay)
        XCTAssertTrue(res.url.absoluteString.contains("/Videos/m1/stream"))
        XCTAssertTrue(res.url.absoluteString.contains("Static=true"))
        XCTAssertEqual(res.playSessionId, "PS9")
    }

    func testResolveReturnsNilWhenNoPlayableSource() throws {
        let info = try decodeInfo("""
        { "MediaSources": [ { "Id": "src1", "SupportsDirectPlay": false, "SupportsTranscoding": false } ] }
        """)
        XCTAssertNil(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
    }

    func testResolvePicksMatchingMediaSourceId() throws {
        let info = try decodeInfo("""
        { "MediaSources": [
            { "Id": "other", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=other&api_key=TKN" },
            { "Id": "src1",  "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        XCTAssertTrue(res.url.absoluteString.contains("MediaSourceId=src1"))
    }

    // MARK: - Tuning in at a schedule offset

    /// Tuning into a channel mid-programme on Jellyfin: the HLS URL must be the server's
    /// TranscodingUrl untouched and the client must do the seeking. Jellyfin's segment
    /// handler answers 400 "StartTimeTicks is not allowed." to any segment URL carrying
    /// StartTimeTicks, and its playlist copies the master's query string onto every
    /// segment, so an offset smuggled into the URL made every tuned-in transcode fail and
    /// auto-skip to the next title (measured against Jellyfin 12.2.0, 2026-10-06; same
    /// check in 10.10.7 and 10.11.0). Recorded PlaybackInfo response, trimmed.
    func testOffsetTuneLeavesTranscodingUrlVerbatimAndSeeksClientSide() throws {
        let info = try decodeInfo("""
        { "PlaySessionId": "040049f188504bd2a104ce71f6987ef7",
          "MediaSources": [ { "Id": "c7851b0aa9ae4ac34456de4d4392a853",
            "SupportsDirectPlay": false, "SupportsDirectStream": false, "SupportsTranscoding": true,
            "TranscodingUrl": "/videos/c7851b0a-a9ae-4ac3-4456-de4d4392a853/master.m3u8?DeviceId=atv&MediaSourceId=c7851b0aa9ae4ac34456de4d4392a853&VideoCodec=h264,hevc&AudioCodec=aac,ac3,eac3,mp3&SegmentContainer=mp4&PlaySessionId=040049f188504bd2a104ce71f6987ef7&ApiKey=TKN&TranscodeReasons=ContainerNotSupported,AudioCodecNotSupported" } ] }
        """)
        let base = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://127.0.0.1:8096", apiKey: "TKN",
            itemId: "c7851b0aa9ae4ac34456de4d4392a853", mediaSourceId: "c7851b0aa9ae4ac34456de4d4392a853"))

        let tuned = JellyfinPlaybackResolver.offsetPlayback(base, offsetSeconds: 1483)

        XCTAssertFalse(tuned.startsAtOffset, "the client seeks; Jellyfin's HLS timeline always starts at zero")
        XCTAssertEqual(tuned.resolution.url, base.url, "the TranscodingUrl must go to AVPlayer exactly as the server built it")
        XCTAssertFalse(tuned.resolution.url.absoluteString.contains("StartTimeTicks"),
                       "StartTimeTicks on a Jellyfin HLS URL is inherited by every segment request and rejected with 400")
        XCTAssertEqual(tuned.resolution.playSessionId, "040049f188504bd2a104ce71f6987ef7")
        XCTAssertFalse(tuned.resolution.isDirectPlay)
    }

    /// Zero offset (tuning in exactly at a programme start) has nothing to seek either way.
    func testZeroOffsetTuneIsUnchanged() throws {
        let base = PlaybackResolution(url: URL(string: "http://127.0.0.1:8096/videos/x/master.m3u8?ApiKey=TKN")!,
                                      playSessionId: "PS1", isDirectPlay: false)
        let tuned = JellyfinPlaybackResolver.offsetPlayback(base, offsetSeconds: 0)
        XCTAssertFalse(tuned.startsAtOffset)
        XCTAssertEqual(tuned.resolution.url, base.url)
    }
}
