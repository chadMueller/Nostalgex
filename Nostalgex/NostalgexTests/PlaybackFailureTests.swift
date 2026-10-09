import XCTest
@testable import Nostalgex

/// The app has to be able to tell the user whose problem it is.
///
/// These lock the one distinction that matters from the couch: the server refused the job,
/// versus the device could not render what arrived. Getting that backwards sends someone
/// to re-encode a file when their server is broken, or to restart a server when the file
/// is the problem.
final class PlaybackFailureTests: XCTestCase {

    private func classify(_ backend: MediaBackendKind = .emby,
                          _ build: (inout PlaybackFailure.Evidence) -> Void) -> PlaybackFailure {
        var e = PlaybackFailure.Evidence()
        build(&e)
        return PlaybackFailure.classify(backend: backend, evidence: e)
    }

    /// The case this was written for. Emby answered HTTP 500 in 0.12s for every transcode
    /// of two 4K HDR10 files, at every resolution and codec, while ordinary files on the
    /// same server ran at 3x real time.
    func testAServerThatAnswers500IsReportedAsTheServerNotTheFile() {
        let f = classify { $0.httpStatuses = [500]; $0.coreMediaStatuses = [-12889] }
        XCTAssertEqual(f, .serverRefused(server: "Emby", status: 500))
        XCTAssertTrue(f.isServerSide)
        XCTAssertTrue(f.detail.contains("HTTP 500"))
        XCTAssertTrue(f.detail.lowercased().contains("not this file"),
                      "the user's first assumption is the file or the app; say otherwise")
    }

    /// A 500 arrives alongside CoreMedia noise, because the player logs its own failure to
    /// decode a body it never got. The HTTP status is the real signal and must win.
    func testAnHTTPFailureOutranksTheDecodeNoiseItCauses() {
        let f = classify {
            $0.httpStatuses = [500]
            $0.coreMediaStatuses = [-15628, -12889]
            $0.everShowedPicture = false
            $0.sourceCodec = "hevc"
        }
        guard case .serverRefused = f else { return XCTFail("got \(f)") }
    }

    func testDecodeFailureIsOnlyClaimedWhenNoHTTPErrorAndNoPictureEverAppeared() {
        let f = classify { $0.coreMediaStatuses = [-12909]; $0.sourceCodec = "hevc" }
        XCTAssertEqual(f, .deviceCannotRender(codec: "hevc"))
        XCTAssertFalse(f.isServerSide)
        XCTAssertTrue(f.detail.contains("HEVC"))
    }

    /// A film that played for an hour and then broke is not an undecodable file.
    func testAFailureAfterThePictureAppearedIsNotBlamedOnTheDevice() {
        let f = classify { $0.coreMediaStatuses = [-12909]; $0.everShowedPicture = true }
        guard case .unknown = f else { return XCTFail("got \(f)") }
    }

    /// The exact shape seen on an Apple TV HD on 2026-10-08: a frame decoded, the playhead
    /// never moved, and CoreMedia reported -12889 (no response in 3s) and -15628 (segment
    /// abandoned). The server was measured at 1.07x for that request, so it was late, not
    /// undecodable. Calling it a decode failure blames the wrong machine.
    func testLateMediaIsTheServerBeingSlowNotTheDeviceFailingToDecode() {
        let f = classify {
            $0.coreMediaStatuses = [-15628, -12889]
            $0.decodedAFrame = true
            $0.everShowedPicture = false
            $0.sourceCodec = "hevc"
            $0.serverDeliveredBytes = true
        }
        XCTAssertEqual(f, .serverTooSlow(server: "Emby"))
        XCTAssertFalse(f.detail.lowercased().contains("apple tv"),
                       "a late stream is not the device's fault")
    }

    /// A frame reaching the screen is proof the device can decode the stream.
    func testADecodedFrameVetoesTheDeviceCannotRenderVerdict() {
        let f = classify { $0.coreMediaStatuses = [-12909]; $0.decodedAFrame = true }
        guard case .deviceCannotRender = f else { return }
        XCTFail("a decoded frame must rule out deviceCannotRender, got \(f)")
    }

    /// And the genuine case still works: no frame ever, a decode error, nothing late.
    func testATrulyUndecodableStreamIsStillBlamedOnTheDevice() {
        let f = classify {
            $0.coreMediaStatuses = [-12909]
            $0.decodedAFrame = false
            $0.sourceCodec = "hevc"
        }
        XCTAssertEqual(f, .deviceCannotRender(codec: "hevc"))
    }

    func testStarvationOutranksEverythingBecauseTheServerAnsweredCorrectly() {
        let f = classify {
            $0.starvedAfterCappedRetry = true
            $0.httpStatuses = [500]
            $0.coreMediaStatuses = [-15628]
        }
        XCTAssertEqual(f, .serverTooSlow(server: "Emby"))
        XCTAssertTrue(f.detail.contains("1080p"))
    }

    func test404IsAMissingFileNotAGenericRefusal() {
        let f = classify { $0.httpStatuses = [404] }
        XCTAssertEqual(f, .fileMissing(server: "Emby"))
        XCTAssertTrue(f.detail.lowercased().contains("scan"))
    }

    func testAuthFailuresSendThePersonToSettings() {
        for code in [401, 403] {
            let f = classify { $0.httpStatuses = [code] }
            XCTAssertEqual(f, .notAuthorised(server: "Emby"), "status \(code)")
            XCTAssertTrue(f.detail.contains("Settings"))
        }
    }

    func testUnreachableBeatsUnknownWhenTheNetworkSaidSo() {
        let f = classify { $0.urlErrorCode = URLError.cannotConnectToHost.rawValue }
        XCTAssertEqual(f, .serverUnreachable(server: "Emby"))
    }

    /// `httpStatusCode` is -1 on error-log events that are not HTTP failures. Letting that
    /// through would classify every decode error as a refusal.
    func testNonHTTPErrorLogEventsAreIgnored() {
        let f = classify { $0.httpStatuses = [-1, -1]; $0.coreMediaStatuses = [-12909] }
        guard case .deviceCannotRender = f else { return XCTFail("got \(f)") }
    }

    func testTheMessageNamesTheServerTheUserActuallyUses() {
        for (backend, name) in [(MediaBackendKind.plex, "Plex"),
                                (.jellyfin, "Jellyfin"),
                                (.emby, "Emby")] {
            let f = classify(backend) { $0.httpStatuses = [500] }
            XCTAssertTrue(f.detail.hasPrefix(name), "\(backend): \(f.detail)")
        }
    }

    /// Chad's copy rules, which an error screen is no excuse to break.
    func testCopyHasNoEmDashesAndNoEmoji() {
        let all: [PlaybackFailure] = [
            .serverRefused(server: "Emby", status: 500), .fileMissing(server: "Emby"),
            .notAuthorised(server: "Emby"), .serverTooSlow(server: "Emby"),
            .serverUnreachable(server: "Emby"), .deviceCannotRender(codec: "hevc"),
            .unknown(server: "Emby"),
        ]
        for f in all {
            for text in [f.headline, f.detail, f.diagnosticSummary] {
                XCTAssertFalse(text.contains("—"), "em dash in: \(text)")
                XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C },
                               "emoji in: \(text)")
            }
            XCTAssertFalse(f.headline.isEmpty)
            XCTAssertFalse(f.detail.isEmpty)
        }
    }
}
