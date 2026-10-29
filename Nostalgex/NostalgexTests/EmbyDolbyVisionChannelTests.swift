import XCTest
@testable import Nostalgex

/// On Emby, a Dolby Vision profile 5 file goes on no channel (`ChannelEligibility`). It stays in
/// the library. Profile 8, 7, HDR10, SDR and an unknown profile stay on channels, and Plex and
/// Jellyfin are untouched. Same cases as scripts/nostalgex-emby-dolby-vision-smoke.mjs (web
/// tuner and Docker); scripts/filter-golden.json holds both engines to the rule.
///
/// Every "left off" check has a control: the same item on another backend, or with another
/// profile, reaching channels through the same build. Without it an item that simply matched no
/// channel would pass.
@MainActor
final class EmbyDolbyVisionChannelTests: XCTestCase {

    // MARK: - Emby's field

    func testEmbyExtendedVideoSubTypeNamesTheProfile() {
        let read = EmbyAPIService.doviProfile(extendedVideoSubType:)
        XCTAssertEqual(read("DoviProfile50"), 5)
        XCTAssertEqual(read("DoviProfile81"), 8)
        XCTAssertEqual(read("DoviProfile84"), 8)
        XCTAssertEqual(read("DoviProfile76"), 7)
        XCTAssertEqual(read("doviprofile50"), 5, "any case")
        XCTAssertEqual(read("DoviProfile100"), 10, "the profile is every digit but the last")
        for unknown in ["Hdr10", "None", "", "DoviProfile5", "DoviProfile", "DoviProfile5x", "Profile 5.0"] {
            XCTAssertNil(read(unknown), unknown)
        }
        XCTAssertNil(read(nil))
    }

    // MARK: - The scan's own parse

    private struct Page: Decodable { let Items: [JellyfinItem] }

    /// A film the way Emby 4.10.1.0 lists it (`/Items?...&Fields=...MediaSources...`), video
    /// stream fields copied from the lab server's answer for each kind of file.
    private func embyFilm(_ id: String, video: String) -> String {
        """
        { "Id": "\(id)", "Name": "Film \(id)", "RunTimeTicks": 60000000000, "Genres": ["Comedy"],
          "ProductionYear": 2003, "Type": "Movie",
          "MediaSources": [ { "Id": "src\(id)", "Container": "mkv", "Bitrate": 27621488,
            "MediaStreams": [ { "Type": "Video", "Codec": "hevc", "Profile": "Main 10", "BitDepth": 10,
                                "Height": 2160, "Width": 3840, \(video) },
                              { "Type": "Audio", "Codec": "aac", "Language": "eng" } ] } ] }
        """
    }

    private let embyVideo: [(id: String, video: String, profile: Int?)] = [
        ("1", #""VideoRange": "DolbyVision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubType": "DoviProfile50", "ExtendedVideoSubTypeDescription": "Profile 5.0""#, 5),
        ("2", #""VideoRange": "DolbyVision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubType": "DoviProfile81", "ExtendedVideoSubTypeDescription": "Profile 8.1 (HDR10 compatible)""#, 8),
        ("3", #""VideoRange": "DolbyVision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubType": "DoviProfile76", "ExtendedVideoSubTypeDescription": "Profile 7.6 (Bluray)""#, 7),
        ("4", #""VideoRange": "HDR 10", "ExtendedVideoType": "Hdr10", "ExtendedVideoSubType": "Hdr10""#, nil),
        ("5", #""VideoRange": "SDR", "ExtendedVideoType": "None", "ExtendedVideoSubType": "None""#, nil),
        ("6", #""VideoRange": "DolbyVision", "ExtendedVideoType": "DolbyVision""#, nil),   // profile not reported
    ]

    func testEmbyScanReadsTheProfileOffTheListCall() throws {
        let json = "{ \"Items\": [" + embyVideo.map { embyFilm($0.id, video: $0.video) }.joined(separator: ",") + "] }"
        let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
        let emby = EmbyAPIService(serverURL: "http://emby.local:8096", accessToken: "TKN", userId: "u1")
        let items = page.Items.compactMap { emby.parseMovieItem($0, isMusicSection: false) }
        XCTAssertEqual(items.map(\.ratingKey), embyVideo.map(\.id))
        XCTAssertEqual(items.map(\.doviProfile), embyVideo.map(\.profile))
    }

    /// Jellyfin names the profile `DvProfile` and has no `ExtendedVideoSubType`. Its scan is
    /// unchanged: no profile on the item, so the rule could never reach it.
    func testJellyfinScanIsUnchanged() throws {
        let json = """
        { "Items": [ { "Id": "j1", "Name": "Film", "RunTimeTicks": 60000000000, "Genres": ["Comedy"],
          "MediaSources": [ { "Id": "s1", "Container": "mkv",
            "MediaStreams": [ { "Type": "Video", "Codec": "hevc", "DvVersionMajor": 1, "DvProfile": 5,
                                "DvBlSignalCompatibilityId": 0, "VideoRange": "HDR", "VideoRangeType": "DOVI" } ] } ] } ] }
        """
        let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
        let jellyfin = JellyfinAPIService(serverURL: "http://jelly.local:8096", accessToken: "TKN", userId: "u1")
        let item = try XCTUnwrap(jellyfin.parseMovieItem(page.Items[0], isMusicSection: false))
        XCTAssertNil(item.doviProfile)
    }

    // MARK: - The rule

    func testRule() {
        let cases: [(MediaBackendKind, Int?, Bool)] = [
            (.emby, 5, true),
            (.emby, 8, false), (.emby, 7, false), (.emby, nil, false),
            (.jellyfin, 5, false), (.plex, 5, false),
        ]
        for (backend, profile, leftOff) in cases {
            let item = film("x", profile: profile)
            XCTAssertEqual(ChannelEligibility.isLeftOffChannels(item, backend: backend), leftOff,
                           "\(backend) profile \(profile.map(String.init) ?? "unknown")")
        }
        let items = [film("a", profile: 5), film("b", profile: 8), film("c", profile: nil), film("d", profile: 5)]
        XCTAssertEqual(ChannelEligibility.onChannels(items, backend: .emby).map(\.id), ["b", "c"])
        XCTAssertEqual(ChannelEligibility.leftOffCount(items, backend: .emby), 2)
        XCTAssertEqual(ChannelEligibility.onChannels(items, backend: .jellyfin).map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(ChannelEligibility.leftOffCount(items, backend: .plex), 0)
    }

    // MARK: - Pools

    private func film(_ id: String, profile: Int?, tmdbID: String? = nil, title: String? = nil) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: title ?? "Lab Film \(id)", artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 2003, originallyAvailableAt: nil, contentRating: "PG",
            duration: 100, ratingKey: id, partKey: "src\(id)", container: "mkv",
            videoCodec: "hevc", audioCodec: "aac", videoProfile: "Main 10", bitrate: 20_000,
            genres: ["Comedy", "Action"], rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: tmdbID, imdbID: nil, librarySource: .movie,
            videoBitDepth: 10, doviProfile: profile
        )
    }

    private func episode(_ id: String, profile: Int?) -> PlexMediaItem {
        PlexMediaItem(
            id: id, title: "Lab Show", artist: nil, episodeTitle: "Episode \(id)", seTag: "S01E01",
            summary: "", year: 2003, originallyAvailableAt: nil, contentRating: "TV-PG",
            duration: 25, ratingKey: id, partKey: "src\(id)", container: "mkv",
            videoCodec: "hevc", audioCodec: "aac", videoProfile: "Main 10", bitrate: 20_000,
            genres: ["Comedy", "Action"], rating: 0, userRating: 0, type: .episode, thumb: nil, art: nil,
            viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .tv,
            videoBitDepth: 10, doviProfile: profile, showKey: "show1"
        )
    }

    /// Channels holding `subject` after the app's stock pool build, with enough plain
    /// films and episodes beside it that channels clear their minimum.
    private func stockChannels(holding subject: PlexMediaItem, on backend: MediaBackendKind) async -> [Int] {
        let fill = (1...6).map { film("f\($0)", profile: nil) } + (1...6).map { episode("e\($0)", profile: nil) }
        let state = AppState()
        state.backendKind = backend
        state.allItems = fill + [subject]
        let config = ChannelConfigLoader.loadBundled()
        state.exclusiveRules = config.exclusiveRules
        let built = await state.rebuildStaticChannelPools(
            configChannels: config.channels, items: state.allItems, onlyChannelIDs: Set(config.channels.map(\.id)))
        XCTAssertEqual(state.allItems.count, fill.count + 1, "the build never drops library items")
        return built.filter { ch in ch.itemPool.contains { $0.id == subject.id } }.map(\.number).sorted()
    }

    func testStockChannelsOnEmbyLeaveProfile5OutAndKeepTheRest() async {
        let makers: [(Int?) -> PlexMediaItem] = [{ self.film("s", profile: $0) }, { self.episode("s", profile: $0) }]
        for make in makers {
            // Control: the same file from Plex. It must reach channels for the rest to mean anything.
            let control = await stockChannels(holding: make(5), on: .plex)
            XCTAssertFalse(control.isEmpty, "control: the test file reaches no channel at all")

            let embyDV5 = await stockChannels(holding: make(5), on: .emby)
            XCTAssertEqual(embyDV5, [], "Emby profile 5 is on a channel")

            for profile in [8, 7, nil] as [Int?] {
                let kept = await stockChannels(holding: make(profile), on: .emby)
                XCTAssertEqual(kept, control, "Emby profile \(profile.map(String.init) ?? "unknown")")
            }
            let jellyfinDV5 = await stockChannels(holding: make(5), on: .jellyfin)
            XCTAssertEqual(jellyfinDV5, control, "Jellyfin profile 5")
        }
    }

    func testAChannelWithoutRulesLeavesProfile5Out() {
        func cache(_ item: PlexMediaItem, leftOff: Bool) -> AppState.FilterCache {
            AppState.FilterCache(item: item, titleLower: item.title.lowercased(), episodeTitleLower: "",
                                 genresLowerSet: ["comedy"], enrichment: nil, itemStudioLower: "",
                                 leftOffChannels: leftOff)
        }
        let pool = AppState.filterItems(
            [cache(film("a", profile: 5), leftOff: true), cache(film("b", profile: 8), leftOff: false)],
            rules: nil, memberships: .empty, exclusiveRules: [])
        XCTAssertEqual(pool.map(\.id), ["b"])
    }

    func testFoundFranchiseOnEmbyLeavesProfile5Out() {
        let films = [film("k1", profile: nil, tmdbID: "k1", title: "Lab Kids"),
                     film("k2", profile: 8, tmdbID: "k2", title: "Lab Kids 2"),
                     film("k3", profile: nil, tmdbID: "k3", title: "Lab Kids 3"),
                     film("k4", profile: 5, tmdbID: "k4", title: "Lab Kids 4")]
        let lookup: (PlexMediaItem) -> MediaEnrichment? = { _ in
            MediaEnrichment(tmdbID: "0", imdbID: nil, mediaType: "movie", keywords: [], networks: [],
                            productionCompanies: [], tmdbGenres: [], imdbRating: nil, imdbVotes: nil,
                            rottenTomatoesScore: nil, metacriticScore: nil, awards: nil,
                            franchiseID: 99_991, franchiseName: "Lab Kids Collection", fetchedAt: Date())
        }
        func members(on backend: MediaBackendKind) -> [String] {
            let state = AppState()
            state.backendKind = backend
            state.allChannels = []
            state.discoveredCollections = []
            state.allItems = films
            state.rebuildFoundFranchises(enrichmentFor: lookup)
            XCTAssertEqual(state.allItems.count, 4)
            return state.foundFranchises.first { $0.name == "LAB KIDS" }?.movies.map(\.id).sorted() ?? []
        }
        XCTAssertEqual(members(on: .plex), ["k1", "k2", "k3", "k4"], "control")
        XCTAssertEqual(members(on: .jellyfin), ["k1", "k2", "k3", "k4"])
        XCTAssertEqual(members(on: .emby), ["k1", "k2", "k3"])
    }

    // MARK: - Server collections

    private final class CollectionServer: MediaBackend, @unchecked Sendable {
        let serverID = ""
        var authHeaders: [String: String] { [:] }
        func testConnection() async throws -> String { "lab" }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress?) async throws -> [PlexMediaItem] { [] }
        func loadSections() async throws -> [PlexSection] { [PlexSection(key: "1", title: "Movies", type: "movie")] }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] {
            [PlexCollection(ratingKey: "c-lab", title: "Lab Set", childCount: nil, thumb: nil)]
        }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { ["m1", "m2", "m3", "m4"] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { nil }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    func testServerCollectionOnEmbyLeavesProfile5Out() async {
        func members(on backend: MediaBackendKind) async -> [String] {
            let state = AppState()
            let server = CollectionServer()
            state.backendOverride = { _ in server }
            state.backendKind = backend
            state.allItems = [film("m1", profile: nil), film("m2", profile: 8), film("m3", profile: nil), film("m4", profile: 5)]
            state.enabledCollectionKeys = ["c-lab"]
            await state.scanCollections()
            XCTAssertEqual(state.allItems.count, 4)
            return state.discoveredCollections.first { $0.id == "c-lab" }?.items.map(\.id) ?? []
        }
        let control = await members(on: .jellyfin)
        XCTAssertEqual(control, ["m1", "m2", "m3", "m4"], "control")
        let plex = await members(on: .plex)
        XCTAssertEqual(plex, ["m1", "m2", "m3", "m4"])
        let emby = await members(on: .emby)
        XCTAssertEqual(emby, ["m1", "m2", "m3"])
    }
}
