import XCTest
@testable import Nostalgex

/// A retro TV guide has no audio picker, so it has to pick the right track itself.
///
/// Jellyfin and Emby hand over whichever track the file marks default, and plenty of
/// files mark a dubbed one. Measured 2026-10-08: Joe Dirt played in Spanish on a channel
/// with no way to change it, because the file's default is
/// `spa 2ch "Spanish [Latinoamericano]"` and its English 5.1 track is not the default.
final class AudioTrackSelectionTests: XCTestCase {

    private typealias Stream = JellyfinPlaybackResolver.PlaybackInfoResponse.MediaStream

    private func stream(_ index: Int, _ type: String, lang: String?, isDefault: Bool = false,
                        channels: Int? = nil) -> Stream {
        // Decoding through JSON exercises the real coding keys, including the "Type"
        // key Swift will not let a property be named after.
        let json = """
        {"Index": \(index), "Type": "\(type)", \(lang.map { "\"Language\": \"\($0)\"," } ?? "")
         "IsDefault": \(isDefault), \(channels.map { "\"Channels\": \($0)," } ?? "") "x": 0}
        """
        return try! JSONDecoder().decode(Stream.self, from: Data(json.utf8))
    }

    /// The exact Joe Dirt layout.
    func testEnglishBeatsADefaultFlaggedSpanishTrack() {
        let streams = [
            stream(0, "Video", lang: nil),
            stream(1, "Audio", lang: "spa", isDefault: true, channels: 2),
            stream(2, "Audio", lang: "eng", isDefault: false, channels: 6),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en-US"]), 2)
    }

    func testMoreChannelsWinsAmongTracksInTheViewersLanguage() {
        let streams = [
            stream(1, "Audio", lang: "eng", isDefault: true, channels: 2),
            stream(2, "Audio", lang: "eng", channels: 6),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en"]), 2,
                       "a 5.1 English mix beats a stereo English default")
    }

    /// "en-GB" must match a track tagged "eng"; three-letter and two-letter codes both occur.
    func testLocaleIdentifiersMatchThreeLetterTags() {
        let streams = [
            stream(1, "Audio", lang: "fre", isDefault: true),
            stream(2, "Audio", lang: "eng"),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en-GB"]), 2)
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["fr-CA"]), 1,
                       "a French viewer keeps the French track")
    }

    func testFallsBackToTheFilesDefaultWhenNoTrackIsInTheViewersLanguage() {
        let streams = [
            stream(1, "Audio", lang: "jpn"),
            stream(2, "Audio", lang: "kor", isDefault: true),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["de"]), 2)
    }

    /// One track is not a choice. Leaving the index nil keeps the server's URL untouched,
    /// which matters: most files have one track and must not get a needless parameter.
    func testASingleAudioTrackIsLeftToTheServer() {
        let streams = [stream(0, "Video", lang: nil), stream(1, "Audio", lang: "eng")]
        XCTAssertNil(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en"]))
        XCTAssertNil(JellyfinPlaybackResolver.preferredAudioIndex(in: nil))
    }

    func testPinningReplacesAnyIndexTheServerAlreadyChose() throws {
        let url = URL(string: "http://h:8096/videos/1/master.m3u8?MediaSourceId=m&AudioStreamIndex=1&api_key=k")!
        let pinned = JellyfinPlaybackResolver.pinningAudioStream(url, index: 2)
        let q = try XCTUnwrap(URLComponents(url: pinned, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(q.filter { $0.name == "AudioStreamIndex" }.map(\.value), ["2"])
        XCTAssertTrue(q.contains { $0.name == "api_key" && $0.value == "k" }, "other params survive")
    }

    func testPinningWithNoIndexLeavesTheURLAlone() {
        let url = URL(string: "http://h:8096/videos/1/master.m3u8?api_key=k")!
        XCTAssertEqual(JellyfinPlaybackResolver.pinningAudioStream(url, index: nil), url)
    }
}
