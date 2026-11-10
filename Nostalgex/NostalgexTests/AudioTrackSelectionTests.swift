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

    // MARK: - Commentary tracks (I-075, #153)

    private func titled(_ index: Int, lang: String?, isDefault: Bool = false, channels: Int? = nil,
                        title: String? = nil, displayTitle: String? = nil) -> Stream {
        let json = """
        {"Index": \(index), "Type": "Audio", \(lang.map { "\"Language\": \"\($0)\"," } ?? "")
         "IsDefault": \(isDefault), \(channels.map { "\"Channels\": \($0)," } ?? "")
         \(title.map { "\"Title\": \"\($0)\"," } ?? "") \(displayTitle.map { "\"DisplayTitle\": \"\($0)\"," } ?? "") "x": 0}
        """
        return try! JSONDecoder().decode(Stream.self, from: Data(json.utf8))
    }

    func testTheWordIsMatchedInAnyCase() {
        for title in ["Commentary", "commentary", "COMMENTARY", "Director's Commentary", "Audio Commentary with the cast",
                      "English - Commentary - AC3 - Stereo - Default"] {
            XCTAssertTrue(AudioTrackCommentary.isCommentary(title), title)
        }
        for title in ["English - Dolby Digital - 5.1", "Surround 5.1", "Comment", "", "Descriptive"] {
            XCTAssertFalse(AudioTrackCommentary.isCommentary(title), title)
        }
        XCTAssertFalse(AudioTrackCommentary.isCommentary(nil))
        XCTAssertTrue(AudioTrackCommentary.isCommentary(nil, "Director's commentary"), "either title can say it")
    }

    /// The default-flagged English commentary has the viewer's language and, being the file's
    /// default, was what the server sent. The real track is not the default.
    func testACommentaryTheFileMarksDefaultIsPassedOver() {
        let streams = [
            stream(0, "Video", lang: nil),
            titled(1, lang: "eng", isDefault: true, channels: 2, title: "Director's Commentary"),
            titled(2, lang: "eng", isDefault: false, channels: 2, title: "English"),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en-US"]), 2)
    }

    /// More channels does not make a commentary the pick: a 5.1 commentary beside a stereo
    /// feature track.
    func testAMoreChannelCommentaryDoesNotWin() {
        let streams = [
            titled(1, lang: "eng", channels: 6, displayTitle: "English - Commentary - Dolby Digital - 5.1"),
            titled(2, lang: "eng", channels: 2, displayTitle: "English - AAC - Stereo"),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en"]), 2)
    }

    /// Two tracks, one a commentary: that is a choice now, so the real one is pinned (before,
    /// the answer for the same file with a one-line Title was whichever the language rules gave).
    func testOneRealTrackBesideACommentaryIsPinned() {
        let streams = [
            titled(1, lang: "eng", isDefault: true, title: "commentary"),
            titled(2, lang: "eng"),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en"]), 2)
    }

    /// The viewer's chosen language rules still apply among the tracks that are left.
    func testTheAudioLanguageSettingStillPicksAmongTheRest() {
        let streams = [
            titled(1, lang: "eng", isDefault: true, channels: 6, title: "Commentary"),
            titled(2, lang: "eng", channels: 2),
            titled(3, lang: "fre", channels: 6),
            titled(4, lang: "fre", channels: 2, title: "Commentaire audio / Commentary"),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, audioLanguage: "fr", preferredLanguages: ["en"]), 3)
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, audioLanguage: "en", preferredLanguages: ["fr"]), 2)
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en-GB"]), 2)
    }

    /// A commentary is only skipped when another track exists. All tracks commentary: the
    /// language rules run over all of them. One track, commentary or not: left to the server.
    func testACommentaryIsKeptWhenItIsAllThereIs() {
        let both = [
            titled(1, lang: "eng", channels: 2, title: "Commentary"),
            titled(2, lang: "eng", channels: 6, title: "Cast commentary"),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: both, preferredLanguages: ["en"]), 2)
        XCTAssertNil(JellyfinPlaybackResolver.preferredAudioIndex(in: [titled(1, lang: "eng", title: "Commentary")], preferredLanguages: ["en"]))
    }

    /// No commentary anywhere: every earlier answer holds.
    func testFilesWithoutACommentaryAreUntouched() {
        let streams = [
            titled(1, lang: "spa", isDefault: true, channels: 2, title: "Spanish [Latinoamericano]"),
            titled(2, lang: "eng", channels: 6, title: "English [US]"),
        ]
        XCTAssertEqual(JellyfinPlaybackResolver.preferredAudioIndex(in: streams, preferredLanguages: ["en-US"]), 2)
    }

    // MARK: Plex

    private func plexAudio(_ streams: String) throws -> PlexRawItem.PlexMedia.PlexStream? {
        let json = #"{"ratingKey":"1","type":"movie","title":"T","Media":[{"Part":[{"key":"/p","Stream":[{"streamType":1,"codec":"hevc"},\#(streams)]}]}]}"#
        let raw = try JSONDecoder().decode(PlexRawItem.self, from: Data(json.utf8))
        return raw.Media?.first?.audioStream
    }

    func testPlexSkipsASelectedCommentary() throws {
        let pick = try plexAudio(#"{"streamType":2,"id":21,"codec":"ac3","channels":2,"selected":true,"displayTitle":"English (AC3 Stereo)","title":"Director's Commentary"},{"streamType":2,"id":22,"codec":"eac3","channels":6,"displayTitle":"English (EAC3 5.1)"}"#)
        XCTAssertEqual(pick?.id, 22)
    }

    func testPlexKeepsTheSelectedTrackWhenItIsNotACommentary() throws {
        let pick = try plexAudio(#"{"streamType":2,"id":21,"codec":"ac3","channels":2,"displayTitle":"English (AC3 Stereo)","title":"Commentary"},{"streamType":2,"id":22,"codec":"eac3","channels":6,"selected":true,"displayTitle":"English (EAC3 5.1)"},{"streamType":2,"id":23,"codec":"dts","channels":6,"displayTitle":"French (DTS 5.1)"}"#)
        XCTAssertEqual(pick?.id, 22)
        let none = try plexAudio(#"{"streamType":2,"id":21,"codec":"ac3","displayTitle":"English"},{"streamType":2,"id":23,"codec":"dts","displayTitle":"French"}"#)
        XCTAssertEqual(none?.id, 21, "no selected track: the first, as before")
    }

    func testPlexKeepsALoneCommentary() throws {
        let pick = try plexAudio(#"{"streamType":2,"id":21,"codec":"ac3","selected":true,"title":"Commentary"}"#)
        XCTAssertEqual(pick?.id, 21)
    }

    // MARK: Tracks the player itself offers

    func testPlayerOptionsPassOverACommentary() {
        let tags: [String?] = ["en", "en", "fr"]
        let titles: [[String?]] = [["Commentary"], ["English"], ["French"]]
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: tags, titles: titles, preferredLowercased: "en"), 1)
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: tags, titles: titles, preferredLowercased: "fr"), 2)
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: ["en", "en"], titles: [["Commentary"], ["Audio commentary"]], preferredLowercased: "en"), 0,
                       "all commentary: the old rule")
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: ["de", "en"], titles: [["Commentary"], ["x"]], preferredLowercased: "de"), 1,
                       "the commentary is the only German track; a real track still beats it")
        XCTAssertEqual(SubtitleSelectionLogic.preferredTrackIndex(tags: ["en", "en"], titles: [["English"]], preferredLowercased: "en"), 0,
                       "mismatched title list falls back to the tag rule")
    }
}
