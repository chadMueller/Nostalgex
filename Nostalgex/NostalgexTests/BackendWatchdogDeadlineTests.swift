import XCTest
@testable import Nostalgex

/// The playback watchdog gives a 4K source the server has to transcode 40 s before it falls
/// back, and any other 20 s. It reads the frame size off the item, and only the Plex loader
/// used to fill it in, so on Jellyfin and Emby a slow 4K start got the 20 s deadline
/// (found 2026-11-03, N-035). Both scans now read Width and Height off the same media source
/// they read the codec and bit depth from.
@MainActor
final class BackendWatchdogDeadlineTests: XCTestCase {

    private struct Page: Decodable { let Items: [JellyfinItem] }

    private func film(_ id: String, width: Int, height: Int) -> String {
        """
        { "Id": "\(id)", "Name": "Film \(id)", "RunTimeTicks": 60000000000, "Genres": ["Comedy"],
          "ProductionYear": 2003, "Type": "Movie",
          "MediaSources": [ { "Id": "src\(id)", "Container": "mkv", "Bitrate": 27621488,
            "MediaStreams": [ { "Type": "Audio", "Codec": "aac", "Language": "eng" },
                              { "Type": "Video", "Codec": "hevc", "Profile": "Main 10", "BitDepth": 10,
                                "Height": \(height), "Width": \(width) } ] } ] }
        """
    }

    private let sizes: [(id: String, width: Int, height: Int, transcodeDeadline: Int)] = [
        ("uhd", 3840, 2160, 40),
        ("scope", 3840, 1606, 40),     // a 2.39:1 UHD frame is wide, not tall
        ("hd", 1920, 1080, 20),
        ("sd", 720, 480, 20),
    ]

    private func items(using parse: (JellyfinItem) -> PlexMediaItem?) throws -> [PlexMediaItem] {
        let json = "{ \"Items\": [" + sizes.map { film($0.id, width: $0.width, height: $0.height) }.joined(separator: ",") + "] }"
        let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
        return page.Items.compactMap(parse)
    }

    private func check(_ items: [PlexMediaItem], _ backend: String) {
        XCTAssertEqual(items.map(\.ratingKey), sizes.map(\.id), backend)
        XCTAssertEqual(items.map(\.videoWidth), sizes.map { $0.width }, "\(backend): width comes off the video stream")
        XCTAssertEqual(items.map(\.videoHeight), sizes.map { $0.height }, "\(backend): height comes off the video stream")
        for (item, size) in zip(items, sizes) {
            XCTAssertEqual(
                PlaybackWatchdog.deadlineSeconds(isDirectPlay: false, videoWidth: item.videoWidth, videoHeight: item.videoHeight),
                size.transcodeDeadline, "\(backend) \(size.id): transcode deadline")
            XCTAssertEqual(
                PlaybackWatchdog.deadlineSeconds(isDirectPlay: true, videoWidth: item.videoWidth, videoHeight: item.videoHeight),
                15, "\(backend) \(size.id): direct play is 15 s at any size")
        }
    }

    func testJellyfinFilmsCarryTheirFrameSize() throws {
        let jf = JellyfinAPIService(serverURL: "http://jf.local:8096", accessToken: "TKN", userId: "u1")
        check(try items { jf.parseMovieItem($0, isMusicSection: false) }, "Jellyfin")
    }

    func testEmbyFilmsCarryTheirFrameSize() throws {
        let emby = EmbyAPIService(serverURL: "http://emby.local:8096", accessToken: "TKN", userId: "u1")
        check(try items { emby.parseMovieItem($0, isMusicSection: false) }, "Emby")
    }

    /// An item scanned before this change has no frame size; it keeps the 20 s deadline until
    /// the library is scanned again, and it still decodes.
    func testAnOldSnapshotItemWithNoSizeKeepsTheShortDeadline() {
        XCTAssertEqual(PlaybackWatchdog.deadlineSeconds(isDirectPlay: false, videoWidth: nil, videoHeight: nil), 20)
    }
}
