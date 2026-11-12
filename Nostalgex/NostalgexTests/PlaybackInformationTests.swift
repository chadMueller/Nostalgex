import AVFoundation
import XCTest
@testable import Nostalgex

final class PlaybackInformationTests: XCTestCase {
    private func information(generation: Int = 1, quality: StreamQuality = .low,
                             video: String? = "hevc", audio: String? = "dts") -> PlaybackInformation {
        PlaybackInformation(generation: generation, backend: .plex, qualityAtTune: quality,
                            source: .init(videoCodec: video, audioCodec: audio))
    }

    private func value(_ id: String, in information: PlaybackInformation,
                       width: Double? = 1920, height: Double? = 1080) -> String? {
        information.rows(presentationWidth: width, presentationHeight: height).first { $0.id == id }?.value
    }

    func testServerStreamDoesNotClaimTranscodingOrCopySourceCodecsIntoOutput() {
        var info = information()
        let attempt = info.beginAttempt(generation: 1, delivery: .serverStream)
        XCTAssertTrue(info.markReady(generation: 1, attemptID: attempt))
        XCTAssertEqual(value("delivery", in: info), "Server stream")
        XCTAssertEqual(value("source", in: info), "Video: HEVC · Audio: DTS")
        XCTAssertNil(value("delivered", in: info))
        XCTAssertNil(value("bitrate", in: info))
        XCTAssertEqual(info.rows().map(\.id), ["backend", "delivery", "quality", "presentation", "source", "reason"])
        XCTAssertTrue(info.evidenceNote.contains("stays Server stream"), "the note says when the row can be more specific")
    }

    func testDirectPlayRequiresAReadyAttempt() {
        var info = information()
        let attempt = info.beginAttempt(generation: 1, delivery: .directPlay)
        XCTAssertEqual(value("delivery", in: info), "Loading")
        XCTAssertEqual(value("presentation", in: info), "Unknown")
        XCTAssertTrue(info.markReady(generation: 1, attemptID: attempt))
        XCTAssertEqual(value("delivery", in: info), "Direct Play")
        XCTAssertEqual(value("presentation", in: info), "1920 × 1080")
    }

    func testReplacedAttemptCannotPublishReadyIntoRecovery() {
        var info = information()
        let first = info.beginAttempt(generation: 1, delivery: .directPlay)
        let replacement = info.beginAttempt(generation: 1, delivery: .serverStream, reason: .directPlayFailed)
        XCTAssertFalse(info.markReady(generation: 1, attemptID: first))
        XCTAssertFalse(info.isReady)
        XCTAssertEqual(info.reason, .directPlayFailed)
        XCTAssertTrue(info.markReady(generation: 1, attemptID: replacement))
        XCTAssertEqual(value("delivery", in: info), "Server stream")
    }

    func testSupersededGenerationCannotMutateNewProgram() {
        var info = information(generation: 2, quality: .medium, video: "h264", audio: "aac")
        XCTAssertNil(info.beginAttempt(generation: 1, delivery: .directPlay, reason: .playerRetry))
        XCTAssertFalse(info.markReady(generation: 1, attemptID: UUID()))
        XCTAssertEqual(info.delivery, .unknown)
        XCTAssertEqual(info.reason, .none)
        XCTAssertNil(info.attemptID)
        XCTAssertEqual(value("source", in: info), "Video: H.264 · Audio: AAC")
    }

    func testQualitySelectionAndRecoveryRequestStaySeparateFromMeasuredOutput() {
        var info = information(quality: .low)
        let attempt = info.beginAttempt(generation: 1, delivery: .serverStream,
                                        reason: .startupNoPicture, recoveryRequest: .compatibility1080p)
        XCTAssertTrue(info.markReady(generation: 1, attemptID: attempt))
        XCTAssertEqual(value("quality", in: info), "Low")
        XCTAssertEqual(value("recovery", in: info), "Compatibility retry, up to 1080p")
        XCTAssertEqual(value("presentation", in: info, width: 854, height: 480), "854 × 480")
        XCTAssertNil(value("delivered", in: info))
        let retry = info.beginAttempt(generation: 1, delivery: .serverStream, reason: .playerRetry)
        XCTAssertTrue(info.markReady(generation: 1, attemptID: retry))
        XCTAssertEqual(value("recovery", in: info), "Compatibility retry, up to 1080p")
    }

    func testInvalidOrUnavailablePlayerMeasurementsRemainUnknown() {
        var info = information()
        let attempt = info.beginAttempt(generation: 1, delivery: .serverStream)
        info.markReady(generation: 1, attemptID: attempt)
        for width in [Double.nan, .infinity, -1, 0, 65_537] {
            XCTAssertEqual(value("presentation", in: info, width: width), "Unknown")
        }
        XCTAssertEqual(value("presentation", in: info, width: nil), "Unknown")
        XCTAssertEqual(value("presentation", in: info, height: nil), "Unknown")
    }

    func testRetiringAnAttemptDropsReadinessUntilItsReplacementIsReady() {
        var info = information()
        let old = info.beginAttempt(generation: 1, delivery: .serverStream,
                                    reason: .streamStalled, recoveryRequest: .compatibility1080p)
        XCTAssertTrue(info.markReady(generation: 1, attemptID: old))
        info.invalidateAttempt()
        XCTAssertNil(info.attemptID)
        XCTAssertFalse(info.markReady(generation: 1, attemptID: old))
        XCTAssertEqual(value("delivery", in: info), "Loading")
        XCTAssertEqual(value("presentation", in: info), "Unknown")
        let replacement = info.beginAttempt(generation: 1, delivery: .serverStream, reason: .playerRetry)
        XCTAssertTrue(info.markReady(generation: 1, attemptID: replacement))
        XCTAssertEqual(value("recovery", in: info), "Compatibility retry, up to 1080p")
    }

    func testArbitraryMetadataCannotRetainOrDisplayCredentialsOrAddresses() {
        let privateText = "https://example.invalid/private?X-Plex-Token=FAKE_PRIVATE_MARKER"
        var info = information(video: privateText, audio: "Authorization: Bearer FAKE_PRIVATE_MARKER")
        let attempt = info.beginAttempt(generation: 1, delivery: .serverStream, reason: .streamStalled)
        info.markReady(generation: 1, attemptID: attempt)
        let strings = info.rows().map { $0.label + " " + $0.value }.joined(separator: " ")
        XCTAssertEqual(info.source.videoCodec, "Unknown")
        XCTAssertEqual(info.source.audioCodec, "Unknown")
        for forbidden in ["example.invalid", "https://", "FAKE_PRIVATE_MARKER", "Authorization", "X-Plex-Token"] {
            XCTAssertFalse(strings.contains(forbidden))
            XCTAssertFalse(String(reflecting: info).contains(forbidden), "the model must not merely hide raw values")
        }
    }

    // MARK: - I-059: Remux or Transcode, only when the server said

    /// A decision reply in the shape Plex sends for an HLS start: the container is rewritten
    /// (Part), and each stream says whether it is copied or transcoded. The subtitle stream and
    /// an audio track nobody chose are present and must not change the answer.
    private func decision(video: String, audio: String, extra: String = "") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <MediaContainer size="1" generalDecisionCode="1000" transcodeDecisionCode="1001" transcodeDecisionText="Direct play not allowed">
          <Video type="movie" title="Heat">
            <Media container="mkv">
              <Part container="mpegts" decision="transcode">
                <Stream streamType="1" codec="h264" decision="\(video)" location="direct"/>
                <Stream streamType="2" codec="ac3" decision="\(audio)" channels="6" selected="1"/>
                <Stream streamType="3" codec="srt" decision="ignore"/>
                \(extra)
              </Part>
            </Media>
          </Video>
        </MediaContainer>
        """.utf8)
    }

    func testTheDecisionNamesRemuxAndTheThreeTranscodes() {
        let cases: [(String, String, PlaybackInformation.ServerStream)] = [
            ("copy", "copy", .remux), ("copy", "transcode", .transcodeAudio),
            ("transcode", "copy", .transcodeVideo), ("transcode", "transcode", .transcodeVideoAndAudio),
        ]
        for (v, a, want) in cases {
            XCTAssertEqual(PlexAPIService.serverStream(fromDecision: decision(video: v, audio: a)), want, "\(v)/\(a)")
        }
        XCTAssertEqual(PlaybackInformation.ServerStream.allLabels,
                       ["Remux", "Transcode (audio)", "Transcode (video)", "Transcode (video and audio)"])
    }

    func testAnAudioTrackTheServerDidNotChooseDoesNotChangeTheAnswer() {
        let other = #"<Stream streamType="2" codec="aac" channels="2"/><Stream streamType="2" codec="dts" decision="ignore"/>"#
        XCTAssertEqual(PlexAPIService.serverStream(fromDecision: decision(video: "copy", audio: "copy", extra: other)), .remux)
    }

    func testAnythingUncertainIsNoAnswer() {
        XCTAssertNil(PlexAPIService.serverStream(fromDecision: decision(video: "copy", audio: "directplay")), "an unknown word")
        XCTAssertNil(PlexAPIService.serverStream(fromDecision: decision(video: "burn", audio: "copy")))
        let second = #"<Stream streamType="2" codec="eac3" decision="transcode"/>"#
        XCTAssertNil(PlexAPIService.serverStream(fromDecision: decision(video: "copy", audio: "copy", extra: second)), "two audio tracks both decided")
        let secondVideo = #"<Stream streamType="1" codec="hevc" decision="copy"/>"#
        XCTAssertNil(PlexAPIService.serverStream(fromDecision: decision(video: "copy", audio: "copy", extra: secondVideo)))
        XCTAssertNil(PlexAPIService.serverStream(fromDecision: Data()))
        XCTAssertNil(PlexAPIService.serverStream(fromDecision: Data("<html>502 Bad Gateway</html>".utf8)))
        XCTAssertNil(PlexAPIService.serverStream(fromDecision: Data("<MediaContainer><Stream streamType=\"1\" decision=\"copy\"".utf8)), "cut off")
    }

    func testTheRowSaysRemuxOrTranscodeOnlyOnceTheServerSaidAndTheStreamIsReady() {
        var info = information()
        let attempt = info.beginAttempt(generation: 1, delivery: .serverStream, serverStream: .remux)
        XCTAssertEqual(value("delivery", in: info), "Loading", "not before the player is ready")
        XCTAssertTrue(info.markReady(generation: 1, attemptID: attempt))
        XCTAssertEqual(value("delivery", in: info), "Remux")

        var transcode = information()
        let t = transcode.beginAttempt(generation: 1, delivery: .serverStream, serverStream: .transcodeVideo)
        transcode.markReady(generation: 1, attemptID: t)
        XCTAssertEqual(value("delivery", in: transcode), "Transcode (video)")
    }

    func testWithoutAnAnswerTheRowStaysAsItWas() {
        var info = information()
        let attempt = info.beginAttempt(generation: 1, delivery: .serverStream)
        info.markReady(generation: 1, attemptID: attempt)
        XCTAssertEqual(value("delivery", in: info), "Server stream")
        // Direct play never carries one, even if one is passed.
        var direct = information()
        let d = direct.beginAttempt(generation: 1, delivery: .directPlay, serverStream: .remux)
        direct.markReady(generation: 1, attemptID: d)
        XCTAssertEqual(value("delivery", in: direct), "Direct Play")
        XCTAssertNil(direct.serverStream)
    }

    func testANewAttemptDoesNotInheritTheLastStreamsAnswer() {
        var info = information()
        let first = info.beginAttempt(generation: 1, delivery: .serverStream, serverStream: .remux)
        info.markReady(generation: 1, attemptID: first)
        let capped = info.beginAttempt(generation: 1, delivery: .serverStream, reason: .startupNoPicture)
        info.markReady(generation: 1, attemptID: capped)
        XCTAssertEqual(value("delivery", in: info), "Server stream", "a different stream, and the server has not said what it does to it")
    }

    func testTheFallbackAndAcceptedAnswersFromTheDecisionCallCarryTheKind() {
        let accepted = PlexAPIService.TranscodeDecision(code: "1001", text: "ok", serverStream: .transcodeAudio)
        let resolution = PlaybackResolution(url: URL(string: "http://example.test/start.m3u8")!, playSessionId: "s",
                                            isDirectPlay: false, serverStream: accepted.serverStream)
        XCTAssertEqual(resolution.serverStream, .transcodeAudio)
        XCTAssertNil(PlexAPIService.TranscodeDecision.unknown.serverStream)
    }
}

@MainActor
final class PlaybackInformationOwnershipTests: XCTestCase {
    private struct NoCredentials: Nostalgex.CredentialStoring {
        func save(key: String, value: String) -> Bool { false }
        func load(key: String) -> String? { nil }
        func delete(key: String) {}
    }

    func testAppStateRejectsReadyFromAReplacedPlayerItem() {
        let state = AppState(credentialStore: NoCredentials())
        state.loadGeneration = 5
        state.playbackInformation = PlaybackInformation(generation: 5, backend: .jellyfin, qualityAtTune: .high,
                                                        source: .init(videoCodec: "h264", audioCodec: "aac"))
        let oldItem = AVPlayerItem(asset: AVMutableComposition())
        let currentItem = AVPlayerItem(asset: AVMutableComposition())
        state.player = AVPlayer(playerItem: currentItem)
        let owner = state.playbackAttemptGeneration
        let attempt = state.beginPlaybackInformationAttempt(generation: 5, attempt: owner, isDirectPlay: true)
        state.markPlaybackInformationReady(for: oldItem, generation: 5, attempt: owner, attemptID: attempt)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        state.markPlaybackInformationReady(for: currentItem, generation: 5, attempt: owner, attemptID: attempt)
        XCTAssertEqual(state.playbackInformation?.isReady, true)
        state.player?.replaceCurrentItem(with: nil)
        state.player = nil
    }

    func testClearingTheCurrentProgramDropsInformation() {
        let state = AppState(credentialStore: NoCredentials())
        state.playbackInformation = PlaybackInformation(generation: 1, backend: .emby, qualityAtTune: .auto,
                                                        source: .init(videoCodec: "hevc", audioCodec: "aac"))
        state.currentItem = nil
        XCTAssertNil(state.playbackInformation)
        XCTAssertTrue(state.playbackInformationRows.isEmpty)
    }

    func testRetiredPlaybackOwnerCannotPublishReadyWhileItsOldPlayerIsStillInstalled() {
        let state = AppState(credentialStore: NoCredentials())
        state.loadGeneration = 5
        state.playbackInformation = PlaybackInformation(generation: 5, backend: .plex, qualityAtTune: .high,
                                                        source: .init(videoCodec: "h264", audioCodec: "aac"))
        let playerItem = AVPlayerItem(asset: AVMutableComposition())
        state.player = AVPlayer(playerItem: playerItem)
        let oldOwner = state.playbackAttemptGeneration
        let oldInformation = state.beginPlaybackInformationAttempt(generation: 5, attempt: oldOwner, isDirectPlay: true)
        state.markPlaybackInformationReady(for: playerItem, generation: 5, attempt: oldOwner, attemptID: oldInformation)
        XCTAssertEqual(state.playbackInformation?.isReady, true)
        state.invalidatePlaybackAttempt()
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        state.markPlaybackInformationReady(for: playerItem, generation: 5, attempt: oldOwner, attemptID: oldInformation)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        XCTAssertNil(state.beginPlaybackInformationAttempt(generation: 5, attempt: oldOwner, isDirectPlay: true))
        state.player = nil
    }
}
