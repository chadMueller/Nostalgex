import XCTest
@testable import Nostalgex

final class OriginalVideoCompatibilityTests: XCTestCase {
    func testRetryPreservesSourceSessionOffsetAndSurround() throws {
        let original = try XCTUnwrap(URL(string: "http://example.test/video/:/transcode/universal/start.m3u8?path=/library/metadata/1692&mediaIndex=2&partIndex=1&session=unique&offset=1792&copyts=0&directStreamAudio=0&videoResolution=1920x1080&X-Plex-Token=test&X-Plex-Platform=tvOS"))
        let retry = try XCTUnwrap(PlexAPIService.preservationRetryURL(from: original))
        let items = try XCTUnwrap(URLComponents(url: retry, resolvingAgainstBaseURL: false)?.queryItems)
        func values(_ key: String) -> [String] { items.filter { $0.name == key }.compactMap(\.value) }
        for (key, value) in ["path": "/library/metadata/1692", "mediaIndex": "2", "partIndex": "1", "session": "unique", "offset": "1792", "copyts": "0", "X-Plex-Token": "test", "X-Plex-Platform": "Generic", "directStream": "1", "directStreamAudio": "1", "videoResolution": "3840x2160", "maxVideoBitrate": "100000"] {
            XCTAssertEqual(values(key), [value], key)
        }
        XCTAssertTrue(values("X-Plex-Client-Profile-Extra")[0].contains("container=mp4"))
        XCTAssertTrue(values("X-Plex-Client-Profile-Extra")[0].contains(PlexAPIService.eac3ChannelCap))
        XCTAssertFalse(items.contains { $0.name == "audioChannels" || $0.name == "maxAudioChannels" })
        XCTAssertTrue(original.absoluteString.contains("videoResolution=1920x1080"))
    }

    private func decision(_ streams: String, container: String = "mp4") -> Data {
        Data("<MediaContainer><Video><Media><Part container=\"\(container)\">\(streams)</Part></Media></Video></MediaContainer>".utf8)
    }

    func testCopiedHEVCInFMP4IsAccepted() {
        let streams = "<Stream streamType=\"1\" codec=\"hevc\" decision=\"copy\"/><Stream streamType=\"2\" codec=\"eac3\" decision=\"copy\" channels=\"6\"/>"
        XCTAssertTrue(PlexAPIService.decisionPreservesOriginalVideo(decision(streams)))
        XCTAssertFalse(PlexAPIService.decisionPreservesOriginalVideo(decision(streams, container: "mpegts")))
    }

    func testReencodedUnknownAndAmbiguousVideoAreRejected() {
        for streams in ["", "<Stream streamType=\"1\" codec=\"h264\" decision=\"transcode\"/>", "<Stream streamType=\"1\" codec=\"hevc\" decision=\"transcode\"/>", "<Stream streamType=\"1\" codec=\"hevc\"/>", "<Stream streamType=\"1\" codec=\"hevc\" decision=\"copy\"/><Stream streamType=\"1\" codec=\"hevc\" decision=\"copy\"/>"] {
            XCTAssertFalse(PlexAPIService.decisionPreservesOriginalVideo(decision(streams)))
        }
        XCTAssertFalse(PlexAPIService.decisionPreservesOriginalVideo(Data("<MediaContainer>".utf8)))
        XCTAssertFalse(PlexAPIService.TranscodeDecision.unknown.preservesOriginalVideo)
    }
}
