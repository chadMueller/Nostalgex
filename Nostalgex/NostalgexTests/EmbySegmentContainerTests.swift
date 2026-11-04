import XCTest
@testable import Nostalgex

/// Emby HLS is MPEG-TS whenever the video can only come out as H.264, and fMP4 only when it
/// may come out as HEVC. Jellyfin is unchanged: always fMP4.
///
/// A mid-programme join on Emby restarts the encode at the join segment. With the video
/// copied and the audio transcoded, fMP4 stamps both tracks from zero and keeps the real
/// start gap only in an edit list AVPlayer does not apply, so the sound runs early by up to
/// a GOP until the programme ends. TS carries the source timestamps. Measured with AVPlayer
/// on a Mac against Emby 4.10.1.0 on 2026-10-16, joining at 247 s, sound minus picture:
///
///     H.264 + DTS, 2 s GOP          fMP4 -1720 ms     TS +35 ms
///     H.264 + FLAC, 5 s GOP         fMP4  -731 ms     TS +24 ms
///     H.264 + TrueHD, 10.4 s GOP    fMP4 about -6.2 s TS +24 ms
///     same files from the start     fMP4 +25 to +36 ms (the harness's in-sync reading)
final class EmbySegmentContainerTests: XCTestCase {

    private let emby = EmbyAPIService(serverURL: "http://emby.local:8096", accessToken: "TKN", userId: "u1")
    private let jellyfin = JellyfinAPIService(serverURL: "http://jelly.local:8096", accessToken: "TKN", userId: "u1")

    private func item(video: String?, container: String = "mkv", audio: String = "dts") -> PlexMediaItem {
        PlexMediaItem(
            id: "1666", title: "Test", artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2001, originallyAvailableAt: nil, contentRating: nil,
            duration: 100, ratingKey: "1666", partKey: "mediasource_1666", container: container,
            videoCodec: video, audioCodec: audio, videoProfile: nil, bitrate: 3_200,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: .movie
        )
    }

    private func query(_ url: URL?) throws -> [String: String] {
        let c = try XCTUnwrap(URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false))
        return Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// TranscodingProfiles[0] of a PlaybackInfo request, as the server receives it.
    private func transcodingProfile(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(try XCTUnwrap(request).httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        let transcoding = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]])
        XCTAssertEqual(transcoding.count, 1)
        return try XCTUnwrap(transcoding.first)
    }

    /// What the device's own HEVC support makes of an HEVC file: fMP4 if it can decode HEVC,
    /// otherwise the server re-encodes to H.264 and TS applies.
    private var hevcExpectation: (container: String, codecs: String) {
        EmbyAPIService.deviceSupportsHEVC ? ("mp4", "h264,hevc") : ("ts", "h264")
    }

    // MARK: - The decision

    func testTSWheneverTheVideoCanOnlyBeH264() {
        for codec in ["h264", "H264", "mpeg2video", "mpeg4", "msmpeg4v3", "vc1", "vp9", "av1"] {
            XCTAssertEqual(JellyfinPlaybackResolver.embySegmentContainer(videoCodec: codec, supportsHEVC: true), "ts", codec)
            XCTAssertEqual(JellyfinPlaybackResolver.embySegmentContainer(videoCodec: codec, supportsHEVC: false), "ts", codec)
        }
    }

    func testFMP4OnlyWhenTheVideoMayBeHEVC() {
        for codec in ["hevc", "HEVC", "h265"] {
            XCTAssertEqual(JellyfinPlaybackResolver.embySegmentContainer(videoCodec: codec, supportsHEVC: true), "mp4", codec)
            XCTAssertEqual(JellyfinPlaybackResolver.embySegmentContainer(videoCodec: codec, supportsHEVC: false), "ts",
                           "\(codec) on a device without HEVC is re-encoded to H.264")
        }
    }

    func testAnUnknownCodecKeepsWhatEveryStreamUsedBefore() {
        XCTAssertEqual(JellyfinPlaybackResolver.embySegmentContainer(videoCodec: nil, supportsHEVC: true), "mp4")
        XCTAssertEqual(JellyfinPlaybackResolver.embySegmentContainer(videoCodec: "", supportsHEVC: true), "mp4")
        XCTAssertEqual(JellyfinPlaybackResolver.embySegmentContainer(videoCodec: nil, supportsHEVC: false), "ts",
                       "no HEVC decoder, so the output is H.264 whatever the source is")
    }

    func testTSNeverOffersHEVC() {
        XCTAssertEqual(JellyfinPlaybackResolver.transcodeVideoCodecs(supportsHEVC: true, segmentContainer: "ts"), "h264",
                       "HEVC copied into TS plays as sound over a black picture")
        XCTAssertEqual(JellyfinPlaybackResolver.transcodeVideoCodecs(supportsHEVC: true, segmentContainer: "mp4"), "h264,hevc")
        XCTAssertEqual(JellyfinPlaybackResolver.transcodeVideoCodecs(supportsHEVC: false, segmentContainer: "mp4"), "h264")
    }

    // MARK: - Emby request shapes

    func testPlaybackInfoAsksForTSForAnH264File() throws {
        for serverStreamOnly in [false, true] {
            let profile = try transcodingProfile(emby.playbackInfoRequest(for: item(video: "h264"), serverStreamOnly: serverStreamOnly))
            XCTAssertEqual(profile["Container"] as? String, "ts")
            XCTAssertEqual(profile["VideoCodec"] as? String, "h264")
            XCTAssertEqual(profile["Protocol"] as? String, "hls")
            XCTAssertEqual(profile["AudioCodec"] as? String, "aac,ac3,eac3,mp3", "audio choice unchanged")
        }
    }

    func testPlaybackInfoKeepsFMP4ForHEVC() throws {
        let profile = try transcodingProfile(emby.playbackInfoRequest(for: item(video: "hevc"), serverStreamOnly: false))
        XCTAssertEqual(profile["Container"] as? String, hevcExpectation.container)
        XCTAssertEqual(profile["VideoCodec"] as? String, hevcExpectation.codecs)
    }

    func testDirectPlayIsUntouched() throws {
        let data = try XCTUnwrap(emby.playbackInfoRequest(for: item(video: "h264", container: "mp4", audio: "aac"),
                                                           serverStreamOnly: false)?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let direct = try XCTUnwrap((body["DeviceProfile"] as? [String: Any])?["DirectPlayProfiles"] as? [[String: Any]])
        XCTAssertEqual(direct.first?["Container"] as? String, "mp4,m4v,mov")
        XCTAssertEqual(direct.first?["VideoCodec"] as? String, EmbyAPIService.deviceSupportsHEVC ? "h264,hevc" : "h264")
        XCTAssertNotNil(emby.buildDirectPlayURL(for: item(video: "h264", container: "mp4", audio: "aac")),
                        "an MP4 the device decodes still plays as the file")
    }

    func testTheFallbackAndTheCappedRungUseTheSameFormat() throws {
        for url in [emby.buildTranscodeURL(for: item(video: "h264"), sessionID: "s"),
                    emby.cappedTranscodeURL(for: item(video: "h264"), offsetSeconds: 2_851, sessionID: "s")] {
            let q = try query(url)
            XCTAssertEqual(q["SegmentContainer"], "ts")
            XCTAssertEqual(q["VideoCodec"], "h264")
            XCTAssertEqual(q["PlaySessionId"], "s", "Emby refuses every segment without it")
            XCTAssertNil(q["StartTimeTicks"])
        }
        for url in [emby.buildTranscodeURL(for: item(video: "hevc"), sessionID: "s"),
                    emby.cappedTranscodeURL(for: item(video: "hevc"), offsetSeconds: 2_851, sessionID: "s")] {
            let q = try query(url)
            XCTAssertEqual(q["SegmentContainer"], hevcExpectation.container)
            XCTAssertEqual(q["VideoCodec"], hevcExpectation.codecs)
        }
    }

    /// The join is still a client seek: the format changes, the timeline does not.
    func testAnOffsetTuneStillSeeksOnTheClient() async throws {
        let offline = EmbyAPIService(serverURL: "http://127.0.0.1:9", accessToken: "k", userId: "u")
        let result = await offline.resolveTranscodePlayback(for: item(video: "h264"), offsetSeconds: 1_234)
        let resolved = try XCTUnwrap(result)
        XCTAssertFalse(resolved.startsAtOffset)
        let q = try query(resolved.resolution.url)
        XCTAssertEqual(q["SegmentContainer"], "ts")
        XCTAssertNil(q["StartTimeTicks"])
        XCTAssertFalse(offline.cappedStreamStartsAtOffset)
    }

    // MARK: - With the subtitle and Dolby Vision fields

    private func canonical(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// A PlaybackInfo body without its transcoding profile, as sorted JSON, and that profile.
    private func split(_ body: [String: Any]) throws -> (rest: String, transcoding: [String: Any]) {
        var body = body
        var profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        let transcoding = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
        profile["TranscodingProfiles"] = nil
        body["DeviceProfile"] = profile
        return (try canonical(body), transcoding)
    }

    /// TS changes the transcoding profile's container and codec list and nothing else. The
    /// subtitle fields (`SubtitleStreamIndex`, `SubtitleProfiles`, External or Encode), the
    /// codec profiles with the Dolby Vision range list, and direct play are byte for byte the
    /// fMP4 body, with no subtitle and when burning a forced track.
    func testTSChangesOnlyTheTranscodingProfile() throws {
        for burning in [nil, 5] as [Int?] {
            let data = try XCTUnwrap(emby.playbackInfoRequest(
                for: item(video: "h264"), serverStreamOnly: false, burningSubtitle: burning)?.httpBody)
            let ts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let mp4Data = try JSONEncoder().encode(JellyfinPlaybackResolver.playbackInfoBody(
                mediaSourceId: "mediasource_1666", supportsHEVC: EmbyAPIService.deviceSupportsHEVC,
                serverStreamOnly: false, burningSubtitle: burning))
            let mp4 = try XCTUnwrap(JSONSerialization.jsonObject(with: mp4Data) as? [String: Any])
            let (tsRest, tsProfile) = try split(ts)
            let (mp4Rest, mp4Profile) = try split(mp4)
            let label = "burning=\(String(describing: burning))"
            XCTAssertEqual(tsRest, mp4Rest, label)
            XCTAssertEqual(ts["SubtitleStreamIndex"] as? Int, burning ?? JellyfinPlaybackResolver.noSubtitleStream, label)
            XCTAssertEqual(tsProfile["Container"] as? String, "ts", label)
            XCTAssertEqual(tsProfile["VideoCodec"] as? String, "h264", label)
            XCTAssertEqual(mp4Profile["Container"] as? String, "mp4", label)
            for key in ["AudioCodec", "Context", "MaxAudioChannels", "Protocol", "Type"] {
                XCTAssertEqual(tsProfile[key] as? String, mp4Profile[key] as? String, "\(key), \(label)")
            }
        }
    }

    /// Answers PlaybackInfo like Emby: the usual request gets session "plain" and lists a
    /// forced English track, the request burning it gets session "burned".
    private final class RecordingServer: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String: Any]] = []
        var bodies: [[String: Any]] { lock.withLock { recorded } }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            // A GET is the check of the burned stream's playlists; an empty playlist passes.
            guard let httpBody = request.httpBody else {
                return (Data("#EXTM3U\n".utf8), try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
            lock.withLock { recorded.append(body) }
            let session = (body["SubtitleStreamIndex"] as? Int) == JellyfinPlaybackResolver.noSubtitleStream ? "plain" : "burned"
            let json = """
            { "PlaySessionId": "\(session)",
              "MediaSources": [ { "Id": "mediasource_1666", "SupportsDirectPlay": false, "SupportsTranscoding": true,
                "TranscodingUrl": "/videos/1666/master.m3u8?MediaSourceId=mediasource_1666&PlaySessionId=\(session)",
                "MediaStreams": [ { "Index": 0, "Type": "Video" }, { "Index": 1, "Type": "Audio", "Language": "eng" },
                  { "Index": 5, "Type": "Subtitle", "Language": "eng", "IsForced": true } ] } ] }
            """
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        }
    }

    /// A forced track in the viewer's language makes a second PlaybackInfo request. It asks
    /// for the same segment format as the first, so a burned-in stream joins in sync too.
    func testTheForcedSubtitleRequestUsesTheSameFormat() async throws {
        let cases: [(video: String, container: String, codecs: String)] = [
            ("h264", "ts", "h264"),
            ("hevc", hevcExpectation.container, hevcExpectation.codecs),
        ]
        for c in cases {
            let server = RecordingServer()
            let send: JellyfinPlaybackResolver.PlaybackInfoSend = { try await server.send($0) }
            let resolution = await emby.negotiatePlayback(
                for: item(video: c.video), serverStreamOnly: false, preferredSubtitleLanguage: "en", send: send)
            XCTAssertEqual(resolution?.playSessionId, "burned", c.video)
            let bodies = server.bodies
            XCTAssertEqual(bodies.map { $0["SubtitleStreamIndex"] as? Int }, [JellyfinPlaybackResolver.noSubtitleStream, 5], c.video)
            for body in bodies {
                let profile = (body["DeviceProfile"] as? [String: Any])?["TranscodingProfiles"] as? [[String: Any]]
                XCTAssertEqual(profile?.first?["Container"] as? String, c.container, c.video)
                XCTAssertEqual(profile?.first?["VideoCodec"] as? String, c.codecs, c.video)
            }
        }
    }

    // MARK: - Jellyfin is unchanged

    func testJellyfinStillAsksForFMP4() throws {
        let profile = try transcodingProfile(jellyfin.playbackInfoRequest(for: item(video: "h264"), serverStreamOnly: false))
        XCTAssertEqual(profile["Container"] as? String, "mp4")
        XCTAssertEqual(profile["VideoCodec"] as? String, JellyfinAPIService.deviceSupportsHEVC ? "h264,hevc" : "h264")
        XCTAssertEqual(try query(jellyfin.cappedTranscodeURL(for: item(video: "h264"), offsetSeconds: 0, sessionID: "s"))["SegmentContainer"], "mp4")
        XCTAssertEqual(try query(jellyfin.buildTranscodeURL(for: item(video: "h264")))["SegmentContainer"], "mp4")
    }
}
