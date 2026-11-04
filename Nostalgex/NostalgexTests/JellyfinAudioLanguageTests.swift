import XCTest
@testable import Nostalgex

/// AUDIO LANGUAGE on Jellyfin and Emby when the server transcodes (I-070, GitHub #177).
///
/// The transcode URL carries `AudioStreamIndex`, the track the server mixes into the stream.
/// The app chose it from the Apple TV's own languages plus English and never read the
/// AUDIO LANGUAGE setting, so a viewer who picked German on an English Apple TV still got
/// the English track. Direct play was fine: there the player switches tracks itself.
///
/// These go through each service's real PlaybackInfo exchange with the setting stored where
/// Settings stores it, and read the track off the URL the player would be given.
final class JellyfinAudioLanguageTests: XCTestCase {

    private static let key = "nostalgex_audio_language"
    private var saved: String?

    // Through `AppDefaults.standard`, the same store AppState writes and
    // `currentAudioLanguage()` reads, so on a device run under `HarnessIsolation` these
    // never touch the TV's real AUDIO LANGUAGE setting. Elsewhere, setUp/tearDown restore it.
    override func setUp() {
        super.setUp()
        saved = AppDefaults.standard.string(forKey: Self.key)
    }

    override func tearDown() {
        if let saved { AppDefaults.standard.set(saved, forKey: Self.key) } else { AppDefaults.standard.removeObject(forKey: Self.key) }
        super.tearDown()
    }

    /// English 5.1 marked default, then German and French stereo.
    private static let answer = """
    { "PlaySessionId": "s1",
      "MediaSources": [ { "Id": "src_77", "SupportsDirectPlay": false, "SupportsTranscoding": true,
        "TranscodingUrl": "/videos/77/master.m3u8?MediaSourceId=src_77&PlaySessionId=s1&ApiKey=TKN",
        "MediaStreams": [ { "Index": 0, "Type": "Video" },
          { "Index": 1, "Type": "Audio", "Language": "eng", "IsDefault": true, "Channels": 6 },
          { "Index": 2, "Type": "Audio", "Language": "ger", "Channels": 2 },
          { "Index": 3, "Type": "Audio", "Language": "fre", "Channels": 2 } ] } ] }
    """

    private func item() -> PlexMediaItem {
        PlexMediaItem(
            id: "77", title: "Film", artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2001, originallyAvailableAt: nil, contentRating: nil,
            duration: 100, ratingKey: "77", partKey: "src_77", container: "mkv",
            videoCodec: "h264", audioCodec: "ac3", videoProfile: nil, bitrate: 8_000,
            genres: [], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: .movie
        )
    }

    /// The `AudioStreamIndex` each service puts on the stream URL with `setting` stored.
    private func askedTrack(setting: String) async throws -> [String: String?] {
        AppDefaults.standard.set(setting, forKey: Self.key)
        let send: JellyfinPlaybackResolver.PlaybackInfoSend = { request in
            (Data(Self.answer.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let jellyfin = await JellyfinAPIService(serverURL: "http://jelly.invalid:8096", accessToken: "TKN", userId: "u1")
            .negotiatePlayback(for: item(), serverStreamOnly: false, preferredSubtitleLanguage: "en", send: send)
        let emby = await EmbyAPIService(serverURL: "http://emby.invalid:8096", accessToken: "TKN", userId: "u1")
            .negotiatePlayback(for: item(), serverStreamOnly: false, preferredSubtitleLanguage: "en", send: send)
        var out: [String: String?] = [:]
        for (name, r) in [("Jellyfin", jellyfin), ("Emby", emby)] {
            let url = try XCTUnwrap(r?.url, name)
            XCTAssertFalse(r?.isDirectPlay ?? true, name)
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            out[name] = q.first { $0.name == "AudioStreamIndex" }?.value
        }
        return out
    }

    func testAUDIOLANGUAGEGermanAsksForTheGermanTrack() async throws {
        for (name, index) in try await askedTrack(setting: "de") {
            XCTAssertEqual(index, "2", "\(name): AUDIO LANGUAGE German, on a file whose default is English 5.1")
        }
    }

    func testAUDIOLANGUAGEFrenchAsksForTheFrenchTrack() async throws {
        for (name, index) in try await askedTrack(setting: "fr") {
            XCTAssertEqual(index, "3", name)
        }
    }

    /// A language the file doesn't have changes nothing: the same track as before the fix.
    func testALanguageTheFileLacksKeepsTheUsualChoice() async throws {
        let usual = JellyfinPlaybackResolver.preferredAudioIndex(in: try streams()).map(String.init)
        for (name, index) in try await askedTrack(setting: "ja") {
            XCTAssertEqual(index, usual, name)
        }
    }

    /// AUTO follows the Apple TV, exactly as before the fix.
    func testAutoKeepsTheUsualChoice() async throws {
        let usual = JellyfinPlaybackResolver.preferredAudioIndex(in: try streams()).map(String.init)
        for (name, index) in try await askedTrack(setting: "__system__") {
            XCTAssertEqual(index, usual, name)
        }
    }

    private func streams() throws -> [JellyfinPlaybackResolver.PlaybackInfoResponse.MediaStream] {
        let info = try JSONDecoder().decode(JellyfinPlaybackResolver.PlaybackInfoResponse.self, from: Data(Self.answer.utf8))
        return try XCTUnwrap(info.MediaSources?.first?.MediaStreams)
    }
}
