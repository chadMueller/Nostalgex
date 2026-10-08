import XCTest
@testable import Nostalgex

/// What Marquee's playback work established on real hardware, now enforced for Nostalgex.
final class PlaybackDecisionTests: XCTestCase {
    private func item(container: String = "mkv", video: String = "hevc", audio: String = "aac",
                      bitDepth: Int? = nil, dovi: Int? = nil, width: Int? = nil, height: Int? = nil) -> PlexMediaItem {
        PlexMediaItem(id: "1", title: "T", artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: 2020,
                      originallyAvailableAt: nil, contentRating: nil, duration: 100, ratingKey: "1", partKey: "/library/parts/1/file.mkv",
                      container: container, videoCodec: video, audioCodec: audio, videoProfile: nil, bitrate: 6000,
                      genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0,
                      studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie, serverID: nil, additionalPartKeys: nil,
                      videoBitDepth: bitDepth, doviProfile: dovi, videoWidth: width, videoHeight: height)
    }

    // MARK: - Direct play refuses what the decoder cannot render

    func testTenBitH264IsNotDecodable() {
        XCTAssertFalse(CodecSupport.canDecodeVideo(codec: "h264", bitDepth: 10, hevcCapable: true))
        XCTAssertTrue(CodecSupport.canDecodeVideo(codec: "h264", bitDepth: 8, hevcCapable: true))
        XCTAssertTrue(CodecSupport.canDecodeVideo(codec: "hevc", bitDepth: 10, hevcCapable: true), "HEVC Main 10 is fine on an Apple TV 4K")
        XCTAssertFalse(CodecSupport.canDecodeVideo(codec: "hevc", bitDepth: 10, hevcCapable: false))
    }

    func testUndecodableReasonsNameTheCause() {
        XCTAssertNotNil(PlexAPIService.undecodableVideoReason(for: item(video: "h264", bitDepth: 10), hevcCapable: true))
        XCTAssertNotNil(PlexAPIService.undecodableVideoReason(for: item(video: "hevc", dovi: 7), hevcCapable: true))
        XCTAssertNil(PlexAPIService.undecodableVideoReason(for: item(video: "hevc", bitDepth: 10, dovi: 8), hevcCapable: true))
        XCTAssertNil(PlexAPIService.undecodableVideoReason(for: item(video: "h264", bitDepth: 8), hevcCapable: true))
    }

    // MARK: - Transcode profile

    // Marquee's profile, which plays daily on real Apple TVs. The single fMP4 target with
    // replace=true that preceded it produced empty segments on the wire (20% pass on device).
    func testProfileIsMarqueesTwoTargetShape() {
        let profile = PlexAPIService.clientProfileExtra(hevcCapable: true, offersHEVC: true)
        let targets = profile.components(separatedBy: "+add-").filter { $0.contains("type=videoProfile") }
        XCTAssertEqual(targets.count, 2, "MPEG-TS for H.264 and fMP4 for HEVC")
        XCTAssertTrue(targets[0].contains("container=mpegts"))
        XCTAssertFalse(targets[0].contains("hevc"), "AVPlayer cannot render HEVC delivered in MPEG-TS")
        XCTAssertTrue(targets[1].contains("container=fmp4"))
        XCTAssertTrue(targets[1].contains("hevc"))
        XCTAssertFalse(targets[0].contains("replace=true"))
        XCTAssertFalse(targets[1].contains("replace=true"))
        XCTAssertFalse(profile.contains("type=subtitleProfile"))
    }

    func testProfileRaisesThePerCodecCeilings() {
        let profile = PlexAPIService.clientProfileExtra(hevcCapable: true, offersHEVC: true)
        XCTAssertTrue(profile.contains("scopeName=hevc&type=upperBound&name=video.width&value=3840"))
        XCTAssertTrue(profile.contains("scopeName=hevc&type=upperBound&name=video.height&value=2160"))
        XCTAssertTrue(profile.contains("scopeName=hevc&type=upperBound&name=video.bitDepth&value=10"), "without this Plex assumes 8-bit and re-encodes 4K HEVC Main 10 to 1080p H.264")
    }

    func testDolbyVision7NeverOffersHEVC() {
        XCTAssertFalse(CodecSupport.offersHEVC(doviProfile: 7, deviceCapable: true))
        XCTAssertTrue(CodecSupport.offersHEVC(doviProfile: 8, deviceCapable: true))
        let profile = PlexAPIService.clientProfileExtra(hevcCapable: true, offersHEVC: false)
        XCTAssertFalse(profile.contains("hevc"))
        XCTAssertFalse(profile.contains("scopeName=hevc"))
    }

    func testTranscodeRequestRemuxesInsteadOfForcingAReencode() {
        let q = PlexAPIService.transcodeQueryItems(for: item(), sessionID: "abc", offsetSeconds: 0, isLocal: true,
                                                   quality: .auto, token: "t", clientID: "c", hevcCapable: true)
        let names = q.map(\.name)
        XCTAssertFalse(names.contains("videoDecision"), "videoDecision=transcode forced a full re-encode on every non-direct-play file")
        XCTAssertFalse(names.contains("audioDecision"))
        func value(_ n: String) -> String? { q.first { $0.name == n }?.value }
        XCTAssertEqual(value("directStream"), "1")
        XCTAssertEqual(value("session"), "abc")
        XCTAssertEqual(value("X-Plex-Session-Identifier"), "abc")
        XCTAssertEqual(value("location"), "lan")
        XCTAssertEqual(value("hasMDE"), "1")
        XCTAssertEqual(value("autoAdjustQuality"), "0", "Plex's adaptive mode throttles to one 3s segment per 6s after the eighth; tvOS 26 dies at 24s")
        XCTAssertNotNil(value("X-Plex-Client-Profile-Extra"))
    }

    func testRemoteServerIsToldSo() {
        let q = PlexAPIService.transcodeQueryItems(for: item(), sessionID: "s", offsetSeconds: 0, isLocal: false,
                                                   quality: .auto, token: "t", clientID: "c", hevcCapable: true)
        XCTAssertEqual(q.first { $0.name == "location" }?.value, "wan")
    }

    // MARK: - Watchdog

    func testDeadlinesScaleWithTheWork() {
        XCTAssertEqual(PlaybackWatchdog.deadlineSeconds(isDirectPlay: true, videoWidth: 3840, videoHeight: 2160), 15)
        XCTAssertEqual(PlaybackWatchdog.deadlineSeconds(isDirectPlay: false, videoWidth: 1920, videoHeight: 1080), 20)
        XCTAssertEqual(PlaybackWatchdog.deadlineSeconds(isDirectPlay: false, videoWidth: 3840, videoHeight: 2160), 40)
        XCTAssertEqual(PlaybackWatchdog.deadlineSeconds(isDirectPlay: false, videoWidth: 3840, videoHeight: 1606), 40, "scope films are wide, not tall")
        XCTAssertEqual(PlaybackWatchdog.deadlineSeconds(isDirectPlay: false, videoWidth: nil, videoHeight: nil), 20)
    }

    func testSkipIsDecidedByThePlayheadNotBufferFlags() {
        XCTAssertTrue(PlaybackWatchdog.shouldSkip(reachedReady: false, progressedSeconds: 0))
        XCTAssertTrue(PlaybackWatchdog.shouldSkip(reachedReady: true, progressedSeconds: 0), "ready but nothing decoding: the Good Burger case")
        XCTAssertTrue(PlaybackWatchdog.shouldSkip(reachedReady: true, progressedSeconds: .nan))
        XCTAssertFalse(PlaybackWatchdog.shouldSkip(reachedReady: true, progressedSeconds: 1.9), "a healthy stream whose buffer momentarily reads empty must not be skipped")
        XCTAssertFalse(PlaybackWatchdog.shouldSkip(reachedReady: true, progressedSeconds: 0.3), "buffering for most of the window but decoding is alive, not dead")
        XCTAssertTrue(PlaybackWatchdog.shouldSkip(reachedReady: true, progressedSeconds: 0.1))
    }

    // MARK: - Tuning in mid-program

    func testTranscodeRequestCarriesTheOffsetSoTheServerStartsThere() {
        let q = PlexAPIService.transcodeQueryItems(for: item(), sessionID: "s", offsetSeconds: 2000, isLocal: true,
                                                   quality: .auto, token: "t", clientID: "c", hevcCapable: true)
        XCTAssertEqual(q.first { $0.name == "offset" }?.value, "2000", "a client-side seek into a transcode that began at zero never completes")
    }

    func testHLSBaseOffsetFollowsWhereTheClockStarts() {
        XCTAssertEqual(PlaybackWatchdog.hlsBaseOffset(requested: 2000, observedStart: 0.4), 2000, "clock rebased to zero: add the offset back")
        XCTAssertEqual(PlaybackWatchdog.hlsBaseOffset(requested: 2000, observedStart: 2000.3), 0, "copyts kept source time: nothing to add")
        XCTAssertEqual(PlaybackWatchdog.hlsBaseOffset(requested: 0, observedStart: 0), 0)
        XCTAssertEqual(PlaybackWatchdog.hlsBaseOffset(requested: 2000, observedStart: .nan), 0)
    }

    func testCappedRetryForcesA1080pReencodeAtTheSameOffset() {
        let svc = PlexAPIService(serverURL: "https://plex.local:32400", token: "t", serverID: "m")
        let url = svc.cappedTranscodeURL(for: item(width: 3840, height: 2160), offsetSeconds: 2480, sessionID: "s2")!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        XCTAssertEqual(v("videoResolution"), "1920x1080")
        XCTAssertEqual(v("maxVideoBitrate"), "12000")
        XCTAssertEqual(v("offset"), "2480")
        XCTAssertEqual(v("session"), "s2")
    }

    func testJellyfinAndEmbyLeaveTheOffsetToAClientSeek() async throws {
        // Loopback port 9 refuses the PlaybackInfo POST at once, so this runs the hand-built
        // fallback URL without a server. The offset rule is the same on either path.
        let backends: [any MediaBackend] = [
            JellyfinAPIService(serverURL: "http://127.0.0.1:9", accessToken: "k", userId: "u"),
            EmbyAPIService(serverURL: "http://127.0.0.1:9", accessToken: "k", userId: "u"),
        ]
        for backend in backends {
            let result = await backend.resolveTranscodePlayback(for: item(), offsetSeconds: 1234)
            let resolved = try XCTUnwrap(result)
            XCTAssertFalse(resolved.startsAtOffset, "the HLS playlist starts at zero, so the player has to seek")
            let q = URLComponents(url: resolved.resolution.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertNil(q.first { $0.name == "StartTimeTicks" }, "Jellyfin 10.10+ rejects every segment of an HLS URL that carries StartTimeTicks")
        }
    }

    func testTranscodeAudioTargetIsLossyOnly() {
        let profile = PlexAPIService.clientProfileExtra(hevcCapable: true, offersHEVC: true)
        let target = profile.components(separatedBy: "+add-transcode-target").filter { $0.contains("type=videoProfile") }.joined()
        XCTAssertFalse(target.contains("alac"), "TrueHD was being converted to ALAC inside HLS, which the player could not use")
        XCTAssertFalse(target.contains("flac"))
        XCTAssertTrue(target.contains("eac3"))
    }

    func testCappedRetryFallsBackToH264() {
        let svc = PlexAPIService(serverURL: "https://plex.local:32400", token: "t", serverID: "m")
        let url = svc.cappedTranscodeURL(for: item(width: 3840, height: 2160), offsetSeconds: 10, sessionID: "s")!
        let profile = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "X-Plex-Client-Profile-Extra" }!.value!
        XCTAssertFalse(profile.contains("hevc"), "the retry exists because the first attempt copied video the device did not decode; H.264 1080p is the one thing every Apple TV plays")
    }

    func testAudioOverBlackIsNotPicture() {
        XCTAssertFalse(PlaybackWatchdog.hasPicture(reachedReady: true, progressedSeconds: 1.9, decodedFrame: false), "playhead moving with no decoded frame is a black screen with sound")
        XCTAssertTrue(PlaybackWatchdog.hasPicture(reachedReady: true, progressedSeconds: 1.9, decodedFrame: true))
        XCTAssertFalse(PlaybackWatchdog.hasPicture(reachedReady: true, progressedSeconds: 0, decodedFrame: true))
    }

    // MARK: - Snapshot compatibility

    func testItemsWithoutTheNewFieldsStillDecode() throws {
        let legacy = """
        {"id":"1","title":"T","summary":"","duration":100,"ratingKey":"1","genres":[],"rating":0,"userRating":0,"type":"movie","viewCount":0,"addedAt":0}
        """
        let decoded = try JSONDecoder().decode(PlexMediaItem.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.videoBitDepth)
        XCTAssertNil(decoded.doviProfile)
        let round = try JSONDecoder().decode(PlexMediaItem.self, from: JSONEncoder().encode(item(bitDepth: 10, dovi: 8, width: 3840, height: 2160)))
        XCTAssertEqual(round.videoBitDepth, 10); XCTAssertEqual(round.doviProfile, 8); XCTAssertEqual(round.videoHeight, 2160)
    }
}

// Plex rejects start.m3u8 (HTTP 400, "resource unavailable" in AVFoundation) unless the
// same session was registered through the decision endpoint first. The decision URL must
// be the start URL with only the path changed, so the server sees identical parameters.
final class PlexDecisionHandshakeTests: XCTestCase {
    func testDecisionURLKeepsEveryQueryItemAndSwapsOnlyThePath() {
        let start = URL(string: "https://192-168-4-79.abc.plex.direct:32400/video/:/transcode/universal/start.m3u8?path=/library/metadata/19475&session=S1&offset=1920&X-Plex-Client-Profile-Extra=add-transcode-target(type%3DvideoProfile%26replace%3Dtrue)&X-Plex-Token=t")!
        let decision = PlexAPIService.decisionURL(from: start)
        XCTAssertEqual(decision?.path, "/video/:/transcode/universal/decision")
        XCTAssertEqual(decision?.query, start.query)
        XCTAssertEqual(decision?.host, start.host)
        XCTAssertEqual(decision?.port, 32400)
    }

    func testDecisionURLRefusesAnythingThatIsNotAStartPlaylist() {
        XCTAssertNil(PlexAPIService.decisionURL(from: URL(string: "https://x/video/:/transcode/universal/stop?session=S1")!))
        XCTAssertNil(PlexAPIService.decisionURL(from: URL(string: "https://x/library/parts/1/file.mkv")!))
    }
}

// x265 MP4 rips are usually tagged hev1, which AVPlayer opens as audio over black. They go
// through the server remux; everything else keeps direct play.
final class HEVCInMP4RemuxTests: XCTestCase {
    func testHEVCInMP4GoesToTheServer() {
        XCTAssertTrue(PlexAPIService.needsServerRemux(container: "mp4", videoCodec: "hevc"))
        XCTAssertTrue(PlexAPIService.needsServerRemux(container: "M4V", videoCodec: "HEVC"))
    }

    func testEverythingElseStaysDirect() {
        XCTAssertFalse(PlexAPIService.needsServerRemux(container: "mov", videoCodec: "hevc"))
        XCTAssertFalse(PlexAPIService.needsServerRemux(container: "mp4", videoCodec: "h264"))
        XCTAssertFalse(PlexAPIService.needsServerRemux(container: "mkv", videoCodec: "hevc"))
        XCTAssertFalse(PlexAPIService.needsServerRemux(container: nil, videoCodec: "hevc"))
    }
}

// tvOS 26 rejects re-encoded segments carried with copyts=1 (timestamps ten seconds ahead
// of the playlist, CoreMedia -15628). Verified on the living room Apple TV: two re-encode
// files 0/2 with copyts=1, 2/2 with copyts=0.
final class TranscodeTimestampTests: XCTestCase {
    func testTranscodeRequestDoesNotCopyTimestamps() {
        let item = PlexMediaItem(id: "m:1", title: "t", artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: nil,
                                 originallyAvailableAt: nil, contentRating: nil, duration: 60, ratingKey: "1", partKey: "/library/parts/1/x.mkv",
                                 container: "mkv", videoCodec: "vc1", audioCodec: "truehd", videoProfile: nil, bitrate: nil, genres: [], rating: 0,
                                 userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
                                 librarySource: .movie)
        let q = PlexAPIService.transcodeQueryItems(for: item, sessionID: "s", offsetSeconds: 100, isLocal: true, quality: .auto, token: "t", clientID: "c", hevcCapable: true)
        XCTAssertEqual(q.first { $0.name == "copyts" }?.value, "0")
        XCTAssertEqual(q.first { $0.name == "offset" }?.value, "100", "the server still starts at the offset")
    }
}

/// Dolby Vision profile 5 over Plex, measured 2026-10-07 (CH 48 FRESH on the living room):
/// the everyday request is refused with 2003 and the app auto-skipped to the next film
/// from 0:00; the Plex app got a remux because it resolves to the Generic profile.
final class DolbyVisionRemuxTests: XCTestCase {
    func testOnlyADoViRefusalTriggersTheRetry() {
        XCTAssertTrue(PlexAPIService.isDolbyVisionRefusal(.init(code: "2003", text: "File is unplayable. DoVi (Profile 5) color space is not supported.")))
        XCTAssertFalse(PlexAPIService.isDolbyVisionRefusal(.init(code: "2003", text: "File is unplayable. Something else.")))
        XCTAssertFalse(PlexAPIService.isDolbyVisionRefusal(.init(code: "1001", text: "Direct play not available; Conversion OK.")))
        XCTAssertFalse(PlexAPIService.isDolbyVisionRefusal(.unknown))
    }

    func testRemuxRequestKeepsTheSessionAndOffsetAndSwapsOnlyTheProfile() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.4.79:32400/video/:/transcode/universal/start.m3u8?path=/library/metadata/55615&session=S1&offset=5449&copyts=0&X-Plex-Platform=tvOS&X-Plex-Client-Profile-Extra=old&X-Plex-Token=t"))
        let remux = try XCTUnwrap(PlexAPIService.dolbyVisionRemuxURL(from: url))
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: remux, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["session"], "S1")
        XCTAssertEqual(q["offset"], "5449")
        XCTAssertEqual(q["copyts"], "0")
        XCTAssertEqual(q["X-Plex-Platform"], "Generic", "the built-in tvOS profile forces mpegts, which cannot carry HEVC")
        let profile = try XCTUnwrap(q["X-Plex-Client-Profile-Extra"])
        XCTAssertTrue(profile.contains("container=mp4"), profile)
        XCTAssertTrue(profile.contains("videoCodec=h264,hevc"), profile)
        XCTAssertFalse(profile.contains("mpegts"), "one target only, so the server cannot pick mpegts again")
        XCTAssertTrue(remux.path.hasSuffix("/start.m3u8"))
    }
}
