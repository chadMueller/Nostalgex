import Foundation
import VideoToolbox

/// Jellyfin backend. Hand-rolled REST (matches the Plex service pattern) over the
/// `MediaBackend` protocol. Jellyfin has no central account: the user points us at a
/// server URL and authenticates locally, yielding an `AccessToken` + `userId` we send
/// on every request via the `MediaBrowser` Authorization header.
///
/// The big reuse win is `ProviderIds`: Jellyfin items carry `{"Tmdb":"…","Imdb":"…"}`
/// natively, so mapping those into `PlexMediaItem.tmdbID/imdbID` lets Jellyfin content
/// flow through the exact same channel-building + enrichment pipeline as Plex.
struct JellyfinAPIService: MediaBackend, WatchActivityReporting {
    let serverURL: String
    let accessToken: String
    let userId: String
    var serverID: String = ""

    /// Stable per-install device id. Reuses the same UUID Plex uses so the value is
    /// consistent across backends on a device.
    private var deviceID: String { PlexAPIService.clientID }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - Auth header

    /// `MediaBrowser` authorization scheme. `Token` is omitted when empty (initial auth).
    static func authorizationHeader(deviceID: String, token: String) -> String {
        var fields = [
            "Client=\"Nostalgex\"",
            "Device=\"Apple TV\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"1.0\"",
        ]
        if !token.isEmpty { fields.append("Token=\"\(token)\"") }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    private var baseHeaders: [String: String] {
        [
            "Accept": "application/json",
            "Authorization": Self.authorizationHeader(deviceID: deviceID, token: accessToken),
        ]
    }

    /// Direct play streams the raw file; AVPlayer needs the token, but the Jellyfin
    /// stream URL already carries `api_key`, so headers are just the Accept/auth pair.
    var authHeaders: [String: String] { baseHeaders }

    private func request(path: String, queryItems: [URLQueryItem] = []) -> URLRequest? {
        guard var components = URLComponents(string: "\(serverURL)\(path)") else { return nil }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        baseHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return req
    }

    private static func decode<T: Decodable>(_: T.Type, data: Data, response: URLResponse?) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw PlexAPIService.APIError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw PlexAPIService.APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            print("[Jellyfin] HTTP \(http.statusCode). Prefix: \(String(data: data.prefix(240), encoding: .utf8) ?? "?")")
            throw PlexAPIService.APIError.httpFailure(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// `decode` for sign-in calls: a 2xx web page becomes `.receivedMarkupInsteadOfJSON`
    /// so a wrong path or proxy page isn't reported as a generic failure.
    private static func decodeSignIn<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse?) throws -> T {
        if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           SignInRequest.looksLikeMarkup(data) {
            throw PlexAPIService.APIError.receivedMarkupInsteadOfJSON(statusCode: http.statusCode)
        }
        return try decode(type, data: data, response: response)
    }

    // MARK: - Connection test

    func testConnection() async throws -> String {
        guard let url = URL(string: "\(serverURL)/System/Info/Public") else {
            throw PlexAPIService.APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: req)
        let info = try Self.decode(PublicSystemInfo.self, data: data, response: response)
        return info.ServerName ?? "Jellyfin Server"
    }

    // MARK: - Library sections (views)

    func loadSections() async throws -> [PlexSection] {
        guard let req = request(path: "/UserViews", queryItems: [.init(name: "userId", value: userId)]) else {
            throw PlexAPIService.APIError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: req)
        let views = try Self.decode(ItemsResponse.self, data: data, response: response).Items ?? []
        return views.map { PlexSection(key: $0.Id, title: $0.Name ?? "Library", type: Self.sectionType(for: $0.CollectionType)) }
    }

    /// Maps a Jellyfin `CollectionType` to the section type strings the loader branches on.
    static func sectionType(for collectionType: String?) -> String {
        switch collectionType?.lowercased() {
        case "tvshows": return "show"
        case "musicvideos": return "musicvideo"
        default: return "movie"   // movies + anything else treated as flat item lists
        }
    }

    // MARK: - Library loading

    private static let pageSize = 200

    func loadLibrary(progress: LoadProgress? = nil) async throws -> [PlexMediaItem] {
        let sections = try await loadSections()
        var allItems: [PlexMediaItem] = []
        for (i, section) in sections.enumerated() {
            progress?(LoadProgressEvent(
                sectionIndex: i, totalSections: sections.count,
                sectionTitle: section.title, sectionType: section.type,
                itemsLoadedSoFar: allItems.count, showsCompleted: nil, totalShows: nil
            ))
            let baseItemCount = allItems.count
            let items: [PlexMediaItem]
            do {
                if section.type == "show" {
                    items = try await fetchShowsSection(section) { showsDone, totalShows, episodesSoFar in
                        progress?(LoadProgressEvent(
                            sectionIndex: i, totalSections: sections.count,
                            sectionTitle: section.title, sectionType: section.type,
                            itemsLoadedSoFar: baseItemCount + episodesSoFar,
                            showsCompleted: showsDone, totalShows: totalShows
                        ))
                    }
                } else {
                    let isMusicSection = section.type == "musicvideo"
                    let raw = try await fetchAllItems(parentId: section.key, includeItemTypes: "Movie")
                    items = raw.compactMap { parseMovieItem($0, isMusicSection: isMusicSection) }
                }
            } catch {
                // Cancelled with sections already read: hand those back rather than losing
                // the whole scan. See LibraryScanInterrupted.
                if Task.isCancelled, !allItems.isEmpty {
                    throw LibraryScanInterrupted(partialItems: allItems)
                }
                throw error
            }
            allItems.append(contentsOf: items)

            // A cancelled section now returns the rows it managed to read rather than
            // throwing, so surface the partial scan here instead of issuing another
            // request that is only going to fail.
            if Task.isCancelled, !allItems.isEmpty {
                throw LibraryScanInterrupted(partialItems: allItems)
            }
        }

        // TMDB-manifest channels (franchises, anime, stand-up) only match when items carry
        // tmdbID. Log coverage so a low number flags a server whose metadata isn't scraped yet.
        let withTmdb = allItems.filter { $0.tmdbID != nil }.count
        print("[Jellyfin] LIBRARY: \(allItems.count) items, \(withTmdb) with tmdbID (\(allItems.isEmpty ? 0 : withTmdb * 100 / allItems.count)%)")

        return allItems
    }

    /// Pages through `/Items` for a parent until `TotalRecordCount` is reached.
    private func fetchAllItems(parentId: String, includeItemTypes: String) async throws -> [JellyfinItem] {
        var collected: [JellyfinItem] = []
        var start = 0
        while true {
            let queryItems: [URLQueryItem] = [
                .init(name: "userId", value: userId),
                .init(name: "ParentId", value: parentId),
                .init(name: "Recursive", value: "true"),
                .init(name: "IncludeItemTypes", value: includeItemTypes),
                .init(name: "Fields", value: "ProviderIds,Overview,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData"),
                .init(name: "StartIndex", value: "\(start)"),
                .init(name: "Limit", value: "\(Self.pageSize)"),
                .init(name: "SortBy", value: "SortName"),
            ]
            guard let req = request(path: "/Items", queryItems: queryItems) else {
                throw PlexAPIService.APIError.invalidResponse
            }
            let (data, response) = try await Self.session.data(for: req)
            let page = try Self.decode(ItemsResponse.self, data: data, response: response)
            let items = page.Items ?? []
            collected.append(contentsOf: items)
            let total = page.TotalRecordCount ?? collected.count
            start += items.count
            // Cancelled part-way through a section (stall watchdog, or the user
            // leaving): stop paging and keep the pages already read. The caller turns
            // this into a LibraryScanInterrupted. Without it, a stall inside the FIRST
            // section discarded the whole scan, because the caller only preserved
            // partials once at least one section had completed.
            if Task.isCancelled { break }
            if items.isEmpty || collected.count >= total { break }
        }
        return collected
    }

    /// Mirrors the Plex TV path: list series, then fetch each series' episodes in
    /// batches, stamping the series' provider IDs/genres onto every episode (episodes
    /// rarely carry their own TMDB id, and channel rules key off the series).
    private func fetchShowsSection(_ section: PlexSection, onBatch: PlexAPIService.ShowProgress? = nil) async throws -> [PlexMediaItem] {
        let series = try await fetchAllItems(parentId: section.key, includeItemTypes: "Series")
        var results: [PlexMediaItem] = []
        let batchSize = 10
        for batchStart in stride(from: 0, to: series.count, by: batchSize) {
            let batch = Array(series[batchStart ..< min(batchStart + batchSize, series.count)])
            let batchResults = try await withThrowingTaskGroup(of: [PlexMediaItem].self) { group in
                for show in batch {
                    group.addTask { try await self.fetchEpisodes(for: show) }
                }
                var merged: [PlexMediaItem] = []
                for try await eps in group { merged.append(contentsOf: eps) }
                return merged
            }
            results.append(contentsOf: batchResults)
            onBatch?(min(batchStart + batchSize, series.count), series.count, results.count)
        }
        return results
    }

    private func fetchEpisodes(for show: JellyfinItem) async throws -> [PlexMediaItem] {
        do {
            let episodes = try await fetchAllItems(parentId: show.Id, includeItemTypes: "Episode")
            let showGenres = show.Genres ?? []
            return episodes.compactMap { ep -> PlexMediaItem? in
                let durationMin = Self.minutes(fromTicks: ep.RunTimeTicks)
                guard durationMin > 0 else { return nil }
                let s = ep.ParentIndexNumber.map { "S\(String(format: "%02d", $0))" } ?? ""
                let e = ep.IndexNumber.map { "E\(String(format: "%02d", $0))" } ?? ""
                let source = JellyfinItem.bestMediaSource(ep.MediaSources)
                return PlexMediaItem(
                    id: PlexAPIService.compositeID(serverID: serverID, ratingKey: ep.Id),
                    title: show.Name ?? ep.SeriesName ?? "",
                    artist: nil,
                    episodeTitle: ep.Name,
                    seTag: (s + e).isEmpty ? nil : s + e,
                    summary: ep.Overview ?? show.Overview ?? "",
                    year: show.ProductionYear,
                    originallyAvailableAt: Self.dateOnly(ep.PremiereDate ?? show.PremiereDate),
                    contentRating: show.OfficialRating ?? ep.OfficialRating,
                    duration: durationMin,
                    ratingKey: ep.Id,
                    partKey: source?.Id ?? ep.Id,      // stash MediaSourceId for URL builders
                    container: source?.Container,
                    videoCodec: source?.videoCodec,
                    audioCodec: source?.audioCodec,
                    videoProfile: source?.videoProfile,
                    bitrate: source?.Bitrate.map { $0 / 1000 },
                    genres: showGenres,
                    rating: show.CommunityRating ?? 0,
                    userRating: 0,
                    type: .episode,
                    thumb: ep.ImageTags?["Primary"] ?? show.ImageTags?["Primary"],
                    art: show.ImageTags?["Backdrop"],
                    viewCount: ServerWatchCount.viewCount(playCount: ep.UserData?.PlayCount, played: ep.UserData?.Played),
                    addedAt: Self.unixSeconds(fromISO: ep.DateCreated),
                    studio: show.Studios?.first?.Name,
                    tmdbID: show.tmdbID,
                    imdbID: show.imdbID,
                    librarySource: .tv,
                    serverID: serverID.isEmpty ? nil : serverID,
                    videoBitDepth: source?.videoBitDepth
                )
            }
        } catch {
            return []   // skip shows that fail individually, matching the Plex path
        }
    }

    func parseMovieItem(_ item: JellyfinItem, isMusicSection: Bool) -> PlexMediaItem? {
        let durationMin = Self.minutes(fromTicks: item.RunTimeTicks)
        guard durationMin > 0 else { return nil }
        var genres = item.Genres ?? []
        if isMusicSection && !genres.contains(where: { $0.lowercased().contains("music") }) {
            genres.append("Music Video")
        }
        // A dedicated music-video library is the primary path. As a fallback, a
        // short item tagged with a Music genre inside a regular Movies/TV library
        // is treated as a music video too — lets users route videos into HIGH
        // ROTATION without a separate library. The 10-min cap keeps musicals,
        // biopics, and concert films (90+ min) out.
        let isMusicVideo = isMusicSection
            || (durationMin <= 10 && genres.contains { $0.lowercased().contains("music") })
        let source = JellyfinItem.bestMediaSource(item.MediaSources)
        // Disc-stacked rips (Titanic part 1 + part 2 grouped by the server into one movie)
        // arrive as multiple MediaSources. Detect them so disc 2 plays after disc 1 through
        // the same advance machinery Plex multi-part movies already use, and so the
        // schedule blocks out the full runtime instead of disc 1's.
        let stack = MultiPartStack.detect(
            sources: (item.MediaSources ?? []).map { ($0.Id, $0.Name ?? $0.Path, $0.RunTimeTicks) }
        )
        let stackDurationMin = stack?.totalRunTimeTicks.map { Self.minutes(fromTicks: $0) }
        let parsed = MusicTitleParser.parse(item.Name ?? "")
        let title = isMusicVideo ? parsed.song : (item.Name ?? "")
        let artist = isMusicVideo ? parsed.artist : nil
        var built = PlexMediaItem(
            id: PlexAPIService.compositeID(serverID: serverID, ratingKey: item.Id),
            title: title,
            artist: artist,
            episodeTitle: nil,
            seTag: nil,
            summary: item.Overview ?? "",
            year: item.ProductionYear,
            originallyAvailableAt: Self.dateOnly(item.PremiereDate),
            contentRating: item.OfficialRating,
            duration: stackDurationMin ?? durationMin,
            ratingKey: item.Id,
            partKey: stack?.parts.first?.id ?? source?.Id ?? item.Id,
            container: source?.Container,
            videoCodec: source?.videoCodec,
            audioCodec: source?.audioCodec,
            videoProfile: source?.videoProfile,
            bitrate: source?.Bitrate.map { $0 / 1000 },
            genres: genres,
            rating: item.CommunityRating ?? 0,
            userRating: 0,
            type: .movie,
            thumb: item.ImageTags?["Primary"],
            art: item.ImageTags?["Backdrop"],
            viewCount: ServerWatchCount.viewCount(playCount: item.UserData?.PlayCount, played: item.UserData?.Played),
            addedAt: Self.unixSeconds(fromISO: item.DateCreated),
            studio: item.Studios?.first?.Name,
            tmdbID: item.tmdbID,
            imdbID: item.imdbID,
            librarySource: isMusicVideo ? .musicVideo : .movie,
            serverID: serverID.isEmpty ? nil : serverID,
            videoBitDepth: source?.videoBitDepth
        )
        if let stack, stack.parts.count > 1 {
            built.additionalPartKeys = Array(stack.parts.dropFirst().map(\.id))
        }
        return built
    }

    /// Jellyfin runtimes are in 100-ns ticks. 600,000,000 ticks == 1 minute.
    static func minutes(fromTicks ticks: Int64?) -> Int {
        guard let ticks else { return 0 }
        return Int(ticks / 600_000_000)
    }

    /// Trims a Jellyfin ISO-8601 datetime down to the `YYYY-MM-DD` Plex used.
    /// Unix seconds from Jellyfin's ISO 8601 DateCreated — feeds the premiere scheduling
    /// window, which is why 0 (not "now") is the failure value: an unparseable date must
    /// read as "not recent", never as "added this second".
    static func unixSeconds(fromISO value: String?) -> Int {
        guard let value else { return 0 }
        if let date = ISO8601DateFormatter().date(from: value) { return Int(date.timeIntervalSince1970) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value).map { Int($0.timeIntervalSince1970) } ?? 0
    }

    static func dateOnly(_ value: String?) -> String? {
        guard let value, value.count >= 10 else { return value }
        return String(value.prefix(10))
    }

    // MARK: - Collections
    // collection-discovery path is Plex-specific; for Jellyfin we return empty so the
    // app falls back to rule-based channels (which is the primary membership source).

    func loadCollections(sectionKey: String) async throws -> [PlexCollection] {
        // Jellyfin models collections as BoxSet items living in their own virtual folder
        // rather than as children of a library, so unlike Plex they cannot be fetched
        // per-section. Every movie section therefore receives the same global list and the
        // caller dedupes by id — the alternative, guessing which library a BoxSet "belongs"
        // to from its members, would drop any collection that spans two libraries.
        let queryItems: [URLQueryItem] = [
            .init(name: "userId", value: userId),
            .init(name: "IncludeItemTypes", value: "BoxSet"),
            .init(name: "Recursive", value: "true"),
            .init(name: "Fields", value: "ChildCount"),
            .init(name: "SortBy", value: "SortName"),
        ]
        guard let req = request(path: "/Items", queryItems: queryItems) else {
            throw PlexAPIService.APIError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: req)
        let page = try Self.decode(ItemsResponse.self, data: data, response: response)
        let boxSets = (page.Items ?? []).map {
            PlexCollection(
                ratingKey: $0.Id,
                title: $0.Name ?? "Untitled",
                childCount: $0.ChildCount,
                thumb: $0.ImageTags?["Primary"]
            )
        }
        print("[Jellyfin] COLLECTIONS: \(boxSets.count) BoxSets")
        return boxSets
    }

    /// Movie ids inside a BoxSet. Ids match the ratingKeys parsed in `parseMovieItem`,
    /// which is what lets the shared collection matcher pair them with library items.
    func loadCollectionItems(collectionKey: String) async throws -> [String] {
        try await fetchAllItems(parentId: collectionKey, includeItemTypes: "Movie").map(\.Id)
    }

    // MARK: - Stream URLs

    // Mirror the AVPlayer-native capability sets used by PlexAPIService.
    private static let supportedAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]
    private static let directPlayContainers: Set<String> = ["mp4", "mov", "m4v"]

    // Apple TV 4K decodes HEVC in hardware; Apple TV HD (4th gen) does not. Used to gate
    // HEVC passthrough on the transcode path so we never hand an incapable device HEVC.
    static let deviceSupportsHEVC: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)

    func buildDirectPlayURL(for item: PlexMediaItem) -> URL? {
        if let container = item.container?.lowercased(), !Self.directPlayContainers.contains(container) {
            return nil
        }
        // Codec and bit depth: 10-bit H.264 opens fine and plays as sound over a black picture.
        if !CodecSupport.canDecodeVideo(codec: item.videoCodec?.lowercased(), bitDepth: item.videoBitDepth,
                                        hevcCapable: CodecSupport.deviceSupportsHEVC) {
            return nil
        }
        // HEVC in MP4 renders only when tagged hvc1, and most encodes are hev1 (ffmpeg's
        // default): sound over a black picture. The library listing does not carry the tag,
        // so let PlaybackInfo decide. Its profile requires hvc1: the server direct-plays what
        // it knows is hvc1 and remuxes the rest (video copied) into HLS tagged hvc1.
        if PlexAPIService.needsServerRemux(container: item.container, videoCodec: item.videoCodec) {
            return nil
        }
        if let audioCodec = item.audioCodec?.lowercased(), !Self.supportedAudioCodecs.contains(audioCodec) {
            return nil
        }
        guard var components = URLComponents(string: "\(serverURL)/Videos/\(item.ratingKey)/stream") else { return nil }
        components.queryItems = [
            .init(name: "Static", value: "true"),
            .init(name: "MediaSourceId", value: item.partKey ?? item.ratingKey),
            .init(name: "api_key", value: accessToken),
        ]
        return components.url
    }

    func buildTranscodeURL(for item: PlexMediaItem) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/Videos/\(item.ratingKey)/master.m3u8") else { return nil }
        // CRITICAL: AVPlayer only renders HEVC from fMP4 HLS segments. The old code shipped
        // MPEG-TS ("ts") AND told Jellyfin HEVC was acceptable, so an h265 source was copied
        // straight into a TS segment — which plays the audio but shows a black screen. Fix:
        // request fMP4 segments, and only accept HEVC when the device can decode it (otherwise
        // Jellyfin transcodes to H.264, which plays on every Apple TV). Audio drops the lossless
        // codecs (alac/flac) that can produce silent HLS playback.
        let videoCodecs = Self.deviceSupportsHEVC ? "h264,hevc" : "h264"
        let audioCodecs = "aac,ac3,eac3,mp3"
        components.queryItems = [
            .init(name: "MediaSourceId", value: item.partKey ?? item.ratingKey),
            .init(name: "api_key", value: accessToken),
            .init(name: "DeviceId", value: deviceID),
            .init(name: "VideoCodec", value: videoCodecs),
            .init(name: "AudioCodec", value: audioCodecs),
            .init(name: "VideoBitrate", value: "\(StreamQuality.current.maxBitrateBps)"),
            .init(name: "MaxWidth", value: "\(StreamQuality.current.width)"),
            .init(name: "TranscodingMaxAudioChannels", value: "6"),
            .init(name: "SegmentContainer", value: "mp4"),
        ]
        return components.url
    }

    // MARK: - Playback negotiation (PlaybackInfo) + session lifecycle

    private struct PlaybackInfoBody: Encodable {
        let DeviceProfile: JellyfinDeviceProfile
        let MediaSourceId: String
        let MaxStreamingBitrate: Int
    }

    /// Asks Jellyfin how to play a transcode-bound item. Sending a DeviceProfile lets the
    /// server decide direct-stream/remux vs transcode and hand back a TranscodingUrl with a
    /// real PlaySessionId. Falls back to the hand-built `buildTranscodeURL` on any failure.
    /// NOTE: we deliberately do NOT send StartTimeTicks — the app seeks client-side after
    /// readyToPlay, so a server-side offset would double-apply.
    func resolveTranscodePlayback(for item: PlexMediaItem) async -> PlaybackResolution? {
        let msid = item.partKey ?? item.ratingKey
        do {
            guard var components = URLComponents(string: "\(serverURL)/Items/\(item.ratingKey)/PlaybackInfo") else {
                return fallbackResolution(for: item)
            }
            components.queryItems = [.init(name: "userId", value: userId)]
            guard let url = components.url else { return fallbackResolution(for: item) }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            // Short timeout: this is a quick negotiation, not a stream. If it hangs we must
            // fall through fast (to the hand-built URL) rather than hold the tuning screen.
            req.timeoutInterval = 12
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(Self.authorizationHeader(deviceID: deviceID, token: accessToken), forHTTPHeaderField: "Authorization")
            let body = PlaybackInfoBody(
                DeviceProfile: JellyfinPlaybackResolver.deviceProfile(supportsHEVC: Self.deviceSupportsHEVC),
                MediaSourceId: msid,
                MaxStreamingBitrate: StreamQuality.current.maxBitrateBps
            )
            req.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await Self.session.data(for: req)
            let info = try Self.decode(JellyfinPlaybackResolver.PlaybackInfoResponse.self, data: data, response: response)
            return JellyfinPlaybackResolver.resolve(
                info, serverURL: serverURL, apiKey: accessToken, itemId: item.ratingKey, mediaSourceId: msid
            ) ?? fallbackResolution(for: item)
        } catch {
            print("[Plex90] PlaybackInfo failed for \(item.ratingKey): \(error) — falling back to hand-built URL")
            return fallbackResolution(for: item)
        }
    }

    /// The client seeks to the offset itself. Jellyfin rejects `StartTimeTicks` on HLS
    /// segment requests and its playlist always runs from zero; see
    /// `JellyfinPlaybackResolver.offsetPlayback` for the measurements.
    func resolveTranscodePlayback(for item: PlexMediaItem, offsetSeconds: Int) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        guard let r = await resolveTranscodePlayback(for: item) else { return nil }
        return JellyfinPlaybackResolver.offsetPlayback(r, offsetSeconds: offsetSeconds)
    }

    private func fallbackResolution(for item: PlexMediaItem) -> PlaybackResolution? {
        guard let url = buildTranscodeURL(for: item) else { return nil }
        return PlaybackResolution(url: url, playSessionId: nil, isDirectPlay: false)
    }

    func reportWatchActivity(
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionTicks: Int,
        event: MediaServerPlaybackReport.Event
    ) async {
        await MediaServerPlaybackReport.post(
            serverURL: serverURL,
            authorization: Self.authorizationHeader(deviceID: deviceID, token: accessToken),
            event: event,
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks
        )
    }

    func markWatched(itemId: String) async {
        await MediaServerPlaybackReport.markPlayed(
            serverURL: serverURL,
            authorization: Self.authorizationHeader(deviceID: deviceID, token: accessToken),
            userId: userId,
            itemId: itemId
        )
    }

    /// Frees a server-side transcode session immediately rather than waiting on Jellyfin's
    /// inactivity timeout. Fire-and-forget; failures are ignored.
    func stopTranscode(playSessionId: String?) async {
        guard let psid = playSessionId, !psid.isEmpty else { return }
        if var c = URLComponents(string: "\(serverURL)/Videos/ActiveEncodings") {
            c.queryItems = [
                .init(name: "deviceId", value: deviceID),
                .init(name: "playSessionId", value: psid),
                .init(name: "api_key", value: accessToken),
            ]
            if let url = c.url {
                var r = URLRequest(url: url)
                r.httpMethod = "DELETE"
                baseHeaders.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                _ = try? await Self.session.data(for: r)
            }
        }
        if let url = URL(string: "\(serverURL)/Sessions/Playing/Stopped") {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(Self.authorizationHeader(deviceID: deviceID, token: accessToken), forHTTPHeaderField: "Authorization")
            r.httpBody = try? JSONEncoder().encode(["PlaySessionId": psid])
            _ = try? await Self.session.data(for: r)
        }
    }

    func thumbnailURL(for item: PlexMediaItem, width: Int = 400) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/Items/\(item.ratingKey)/Images/Primary") else { return nil }
        var query: [URLQueryItem] = [.init(name: "maxWidth", value: "\(width)")]
        if let tag = item.thumb { query.append(.init(name: "tag", value: tag)) }
        components.queryItems = query
        return components.url
    }

    // MARK: - Authentication (static — called from onboarding)

    /// Result of a successful login, ready to persist + construct a service from.
    struct AuthResult: Sendable {
        let accessToken: String
        let userId: String
        let serverID: String
        let serverName: String
    }

    /// Username/password auth against a specific server URL.
    static func authenticate(serverURL: String, username: String, password: String) async throws -> AuthResult {
        guard let url = URL(string: "\(serverURL)/Users/AuthenticateByName") else {
            throw PlexAPIService.APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = SignInRequest.timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(deviceID: PlexAPIService.clientID, token: ""), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])

        let (data, response) = try await session.data(for: req)
        let result = try decodeSignIn(AuthenticationResult.self, data: data, response: response)
        guard let token = result.AccessToken, let uid = result.User?.Id else {
            throw PlexAPIService.APIError.unauthorized
        }
        return AuthResult(accessToken: token, userId: uid,
                          serverID: result.ServerId ?? "", serverName: result.User?.ServerName ?? "Jellyfin Server")
    }

    // MARK: - Quick Connect

    struct QuickConnectInit: Sendable { let code: String; let secret: String }

    /// Starts a Quick Connect session; user approves `code` in their Jellyfin dashboard.
    static func quickConnectInitiate(serverURL: String) async throws -> QuickConnectInit {
        guard let url = URL(string: "\(serverURL)/QuickConnect/Initiate") else {
            throw PlexAPIService.APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = SignInRequest.timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authorizationHeader(deviceID: PlexAPIService.clientID, token: ""), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let decoded = try decodeSignIn(QuickConnectResult.self, data: data, response: response)
        guard let code = decoded.Code, let secret = decoded.Secret else {
            throw PlexAPIService.APIError.invalidResponse
        }
        return QuickConnectInit(code: code, secret: secret)
    }

    /// Polls once; returns true when the user has approved the code.
    static func quickConnectCheck(serverURL: String, secret: String) async throws -> Bool {
        guard var components = URLComponents(string: "\(serverURL)/QuickConnect/Connect") else {
            throw PlexAPIService.APIError.invalidResponse
        }
        components.queryItems = [.init(name: "Secret", value: secret)]
        guard let url = components.url else { throw PlexAPIService.APIError.invalidResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = SignInRequest.timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authorizationHeader(deviceID: PlexAPIService.clientID, token: ""), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        return (try decodeSignIn(QuickConnectResult.self, data: data, response: response).Authenticated) ?? false
    }

    /// Exchanges an approved Quick Connect secret for an access token.
    static func quickConnectAuthenticate(serverURL: String, secret: String) async throws -> AuthResult {
        guard let url = URL(string: "\(serverURL)/Users/AuthenticateWithQuickConnect") else {
            throw PlexAPIService.APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = SignInRequest.timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(deviceID: PlexAPIService.clientID, token: ""), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["Secret": secret])
        let (data, response) = try await session.data(for: req)
        let result = try decodeSignIn(AuthenticationResult.self, data: data, response: response)
        guard let token = result.AccessToken, let uid = result.User?.Id else {
            throw PlexAPIService.APIError.unauthorized
        }
        return AuthResult(accessToken: token, userId: uid,
                          serverID: result.ServerId ?? "", serverName: result.User?.ServerName ?? "Jellyfin Server")
    }
}

// MARK: - Decodable response models

private struct PublicSystemInfo: Decodable {
    let ServerName: String?
    let Version: String?
    let Id: String?
}

private struct AuthenticationResult: Decodable {
    let AccessToken: String?
    let ServerId: String?
    let User: JellyfinUser?
    struct JellyfinUser: Decodable {
        let Id: String?
        let Name: String?
        let ServerName: String?
    }
}

private struct QuickConnectResult: Decodable {
    let Code: String?
    let Secret: String?
    let Authenticated: Bool?
}

private struct ItemsResponse: Decodable {
    let Items: [JellyfinItem]?
    let TotalRecordCount: Int?
}

struct JellyfinItem: Decodable {
    let Id: String
    let Name: String?
    let SeriesName: String?
    let Overview: String?
    let ProductionYear: Int?
    let PremiereDate: String?
    let DateCreated: String?
    /// BoxSet member count. Only requested when listing collections.
    let ChildCount: Int?
    let OfficialRating: String?
    let CommunityRating: Double?
    let RunTimeTicks: Int64?
    let Genres: [String]?
    let CollectionType: String?
    let ParentIndexNumber: Int?
    let IndexNumber: Int?
    let ProviderIds: [String: String]?
    let Studios: [Studio]?
    let MediaSources: [MediaSource]?
    let ImageTags: [String: String]?
    let UserData: UserData?

    struct Studio: Decodable { let Name: String? }
    struct UserData: Decodable {
        let Played: Bool?
        let PlayCount: Int?
    }

    struct MediaSource: Decodable {
        let Id: String?
        let Name: String?
        let Path: String?
        let RunTimeTicks: Int64?
        let Container: String?
        let Bitrate: Int?
        let MediaStreams: [MediaStream]?

        struct MediaStream: Decodable {
            let streamType: String?
            let Codec: String?
            let Profile: String?
            let Width: Int?
            let Height: Int?
            let BitDepth: Int?

            enum CodingKeys: String, CodingKey {
                case streamType = "Type"
                case Codec, Profile, Width, Height, BitDepth
            }
        }

        var videoCodec: String? { MediaStreams?.first(where: { $0.streamType == "Video" })?.Codec }
        var audioCodec: String? { MediaStreams?.first(where: { $0.streamType == "Audio" })?.Codec }
        var videoProfile: String? { MediaStreams?.first(where: { $0.streamType == "Video" })?.Profile }
        var videoHeight: Int? { MediaStreams?.first(where: { $0.streamType == "Video" })?.Height }
        var videoBitDepth: Int? { MediaStreams?.first(where: { $0.streamType == "Video" })?.BitDepth }
    }

    /// Highest-quality source: max bitrate, tie-broken on video height. Falls back to the first
    /// when none report a bitrate, preserving prior behavior for libraries without that metadata.
    static func bestMediaSource(_ sources: [MediaSource]?) -> MediaSource? {
        guard let sources, !sources.isEmpty else { return nil }
        guard sources.contains(where: { $0.Bitrate != nil }) else { return sources.first }
        return sources.max { a, b in
            let ba = a.Bitrate ?? Int.min, bb = b.Bitrate ?? Int.min
            if ba != bb { return ba < bb }
            return (a.videoHeight ?? 0) < (b.videoHeight ?? 0)
        }
    }

    /// Provider IDs are case-sensitive keys in Jellyfin ("Tmdb", "Imdb"); match leniently.
    private func providerID(_ name: String) -> String? {
        guard let ids = ProviderIds else { return nil }
        if let exact = ids[name] { return exact }
        return ids.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    var tmdbID: String? { providerID("Tmdb") }
    var imdbID: String? { providerID("Imdb") }
}
