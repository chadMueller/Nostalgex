import Foundation
import VideoToolbox

/// Emby backend. Mirrors `JellyfinAPIService` — Emby and Jellyfin forked from the same
/// codebase in 2018 so their REST APIs are ~90% identical. Key difference: Emby does not
/// support Quick Connect, so username/password is the only login path.
struct EmbyAPIService: MediaBackend, WatchActivityReporting {
    let serverURL: String
    let accessToken: String
    let userId: String
    var serverID: String = ""

    private var deviceID: String { PlexAPIService.clientID }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - Auth header

    /// `MediaBrowser` authorization scheme shared with Jellyfin. `Token` is omitted on initial auth.
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
            print("[Emby] HTTP \(http.statusCode). Prefix: \(String(data: data.prefix(240), encoding: .utf8) ?? "?")")
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
        let info = try Self.decode(EmbyPublicSystemInfo.self, data: data, response: response)
        return info.ServerName ?? "Emby Server"
    }

    // MARK: - Library sections (views)

    /// Emby serves a user's libraries at `/Users/{id}/Views`. `/UserViews?userId=` is
    /// Jellyfin's spelling and does not exist on Emby, which is what this used to call:
    /// measured against Emby 4.10.1.0, `/UserViews` answers 404 while `/Users/{id}/Views`
    /// answers 200. It was the first request after sign-in, so every Emby user got a 404
    /// the moment the library scan started, whatever their libraries were called or how
    /// big they were (issue #6).
    /// Path for a user's libraries. Static so it can be asserted on without a server.
    static func userViewsPath(userId: String) -> String? {
        guard let escaped = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !escaped.isEmpty else { return nil }
        return "/Users/\(escaped)/Views"
    }

    func loadSections() async throws -> [PlexSection] {
        guard let path = Self.userViewsPath(userId: userId), let req = request(path: path) else {
            throw PlexAPIService.APIError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: req)
        let views = try Self.decode(EmbyItemsResponse.self, data: data, response: response).Items ?? []
        return views.map { PlexSection(key: $0.Id, title: $0.Name ?? "Library", type: JellyfinAPIService.sectionType(for: $0.CollectionType)) }
    }

    // MARK: - Library loading

    private static let pageSize = 200

    /// The Dolby Vision profile from Emby's `ExtendedVideoSubType` on the video stream, or nil.
    ///
    /// Emby has no `DvProfile` field (that is Jellyfin's). It names the profile and the base
    /// layer's compatibility id together: "DoviProfile50" is profile 5, "DoviProfile81" 8.1,
    /// "DoviProfile76" 7.6. The last digit is the compatibility id, the digits before it the
    /// profile. Anything else ("Hdr10", "None", missing, one digit) is nil, an unknown profile,
    /// which keeps the item on channels. Measured 2026-10-19 on Emby 4.10.1.0: the list call the
    /// scan already makes (`Fields=...MediaSources...`) carries it on `MediaSources[].MediaStreams`
    /// for every film and episode, so the scan asks for nothing new.
    static func doviProfile(extendedVideoSubType value: String?) -> Int? {
        guard let value else { return nil }
        let prefix = "doviprofile"
        let lower = value.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        let digits = lower.dropFirst(prefix.count)
        guard digits.count >= 2, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits.dropLast())
    }

    func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress? = nil) async throws -> [PlexMediaItem] {
        let allSections = try await loadSections()
        // A section the viewer turned off in library selection (I-054) is dropped here,
        // before a single item request for it is made — never fetched, not fetched
        // and discarded.
        let sections = excludedSectionKeys.isEmpty ? allSections : allSections.filter { !excludedSectionKeys.contains($0.key) }
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

        let withTmdb = allItems.filter { $0.tmdbID != nil }.count
        print("[Emby] LIBRARY: \(allItems.count) items, \(withTmdb) with tmdbID (\(allItems.isEmpty ? 0 : withTmdb * 100 / allItems.count)%)")

        return allItems
    }

    private func fetchAllItems(parentId: String, includeItemTypes: String) async throws -> [JellyfinItem] {
        var collected: [JellyfinItem] = []
        var start = 0
        while true {
            let queryItems: [URLQueryItem] = [
                .init(name: "userId", value: userId),
                .init(name: "ParentId", value: parentId),
                .init(name: "Recursive", value: "true"),
                .init(name: "IncludeItemTypes", value: includeItemTypes),
                // DateCreated is what parseMovieItem reads for addedAt. Without it in
                // this list Emby items all came back with addedAt 0, so the schedule's
                // premiere promotion could never fire on an Emby server.
                .init(name: "Fields", value: "ProviderIds,Overview,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData"),
                .init(name: "StartIndex", value: "\(start)"),
                .init(name: "Limit", value: "\(Self.pageSize)"),
                .init(name: "SortBy", value: "SortName"),
            ]
            guard let req = request(path: "/Items", queryItems: queryItems) else {
                throw PlexAPIService.APIError.invalidResponse
            }
            let (data, response) = try await Self.session.data(for: req)
            let page = try Self.decode(EmbyItemsResponse.self, data: data, response: response)
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
                let durationMin = JellyfinAPIService.minutes(fromTicks: ep.RunTimeTicks)
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
                    originallyAvailableAt: JellyfinAPIService.dateOnly(ep.PremiereDate ?? show.PremiereDate),
                    contentRating: show.OfficialRating ?? ep.OfficialRating,
                    duration: durationMin,
                    ratingKey: ep.Id,
                    partKey: source?.Id ?? ep.Id,
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
                    addedAt: JellyfinAPIService.unixSeconds(fromISO: ep.DateCreated),
                    studio: show.Studios?.first?.Name,
                    tmdbID: show.tmdbID,
                    imdbID: show.imdbID,
                    librarySource: .tv,
                    serverID: serverID.isEmpty ? nil : serverID,
                    videoBitDepth: source?.videoBitDepth,
                    doviProfile: Self.doviProfile(extendedVideoSubType: source?.videoExtendedSubType),
                    showKey: show.Id
                )
            }
        } catch {
            return []
        }
    }

    func parseMovieItem(_ item: JellyfinItem, isMusicSection: Bool) -> PlexMediaItem? {
        let durationMin = JellyfinAPIService.minutes(fromTicks: item.RunTimeTicks)
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
        let stackDurationMin = stack?.totalRunTimeTicks.map { JellyfinAPIService.minutes(fromTicks: $0) }
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
            originallyAvailableAt: JellyfinAPIService.dateOnly(item.PremiereDate),
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
            addedAt: JellyfinAPIService.unixSeconds(fromISO: item.DateCreated),
            studio: item.Studios?.first?.Name,
            tmdbID: item.tmdbID,
            imdbID: item.imdbID,
            librarySource: isMusicVideo ? .musicVideo : .movie,
            serverID: serverID.isEmpty ? nil : serverID,
            videoBitDepth: source?.videoBitDepth,
            doviProfile: Self.doviProfile(extendedVideoSubType: source?.videoExtendedSubType)
        )
        if let stack, stack.parts.count > 1 {
            built.additionalPartKeys = Array(stack.parts.dropFirst().map(\.id))
        }
        return built
    }

    // MARK: - Collections

    /// Emby's collection model matches Jellyfin's: BoxSet items in a virtual folder, so
    /// the same global-list-plus-caller-dedupe approach applies.
    func loadCollections(sectionKey: String) async throws -> [PlexCollection] {
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
        let page = try Self.decode(EmbyItemsResponse.self, data: data, response: response)
        let boxSets = (page.Items ?? []).map {
            PlexCollection(
                ratingKey: $0.Id,
                title: $0.Name ?? "Untitled",
                childCount: $0.ChildCount,
                thumb: $0.ImageTags?["Primary"]
            )
        }
        print("[Emby] COLLECTIONS: \(boxSets.count) BoxSets")
        return boxSets
    }

    /// Same query as Jellyfin, different answer: with `Recursive=true` Emby 4.10 hands
    /// back a series' episodes rather than the series itself (measured on a lab server).
    /// The collection matcher takes episode ids as well as series ids, so either works.
    func loadCollectionItems(collectionKey: String) async throws -> [String] {
        try await fetchAllItems(parentId: collectionKey, includeItemTypes: "Movie,Series").map(\.Id)
    }

    // MARK: - Stream URLs

    private static let supportedAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]
    private static let directPlayContainers: Set<String> = ["mp4", "mov", "m4v"]

    static let deviceSupportsHEVC: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)

    func buildDirectPlayURL(for item: PlexMediaItem) -> URL? {
        if let container = item.container?.lowercased(), !Self.directPlayContainers.contains(container) {
            return nil
        }
        // Same two black-picture cases as Jellyfin: 10-bit H.264, and HEVC in MP4 whose tag
        // only the server knows. See JellyfinAPIService.buildDirectPlayURL.
        if !CodecSupport.canDecodeVideo(codec: item.videoCodec?.lowercased(), bitDepth: item.videoBitDepth,
                                        hevcCapable: CodecSupport.deviceSupportsHEVC) {
            return nil
        }
        if PlexAPIService.needsServerRemux(container: item.container, videoCodec: item.videoCodec) {
            return nil
        }
        if let audioCodec = item.audioCodec?.lowercased(), !Self.supportedAudioCodecs.contains(audioCodec) {
            return nil
        }
        // `stream.mp4`, not `stream`: see JellyfinPlaybackResolver.staticStreamURL.
        return JellyfinPlaybackResolver.staticStreamURL(
            serverURL: serverURL, itemId: item.ratingKey,
            mediaSourceId: item.partKey ?? item.ratingKey, apiKey: accessToken
        )
    }

    func buildTranscodeURL(for item: PlexMediaItem) -> URL? {
        buildTranscodeURL(for: item, sessionID: UUID().uuidString)
    }

    /// The hand-built HLS stream: the runtime fallback after a failed direct play, and the
    /// fallback when PlaybackInfo hands back no TranscodingUrl.
    ///
    /// `PlaySessionId` is load-bearing on Emby. Emby does not copy the master's query string
    /// onto segment URLs the way Jellyfin does; it writes `hls1/main/0.mp4?PlaySessionId=<id>`
    /// and nothing else, so a master without one gets segments asking for `PlaySessionId=`
    /// with no value, and every one of them comes back HTTP 400 "Value cannot be null.
    /// (Parameter 'key')". Master and variant playlists still answer 200, which is why it
    /// looked like a stream that would not start rather than a refused request. Measured
    /// against Emby 4.10.1.0 on 2026-10-13 on 8-bit H.264 MKV and MP4 sources: without the
    /// id, init and segments 0 to 2 all 400; with a client-made UUID, all 200. Emby takes an
    /// id the client mints, as the capped rung has always done, and the id lets
    /// `stopTranscode` end this encode on the next channel change.
    func buildTranscodeURL(for item: PlexMediaItem, sessionID: String) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/Videos/\(item.ratingKey)/master.m3u8") else { return nil }
        let segments = segmentContainer(for: item)
        let videoCodecs = JellyfinPlaybackResolver.transcodeVideoCodecs(supportsHEVC: Self.deviceSupportsHEVC, segmentContainer: segments)
        let audioCodecs = "aac,ac3,eac3,mp3"
        components.queryItems = [
            .init(name: "MediaSourceId", value: item.partKey ?? item.ratingKey),
            .init(name: "api_key", value: accessToken),
            .init(name: "DeviceId", value: deviceID),
            .init(name: "PlaySessionId", value: sessionID),
            .init(name: "VideoCodec", value: videoCodecs),
            .init(name: "AudioCodec", value: audioCodecs),
            .init(name: "VideoBitrate", value: "\(StreamQuality.current.maxBitrateBps)"),
            .init(name: "MaxWidth", value: "\(StreamQuality.current.width)"),
            .init(name: "TranscodingMaxAudioChannels", value: "6"),
            .init(name: "SegmentContainer", value: segments),
        ]
        return components.url
    }

    /// TS unless the stream may be HEVC, so a mid-programme join stays in sync. The one
    /// decision for every Emby HLS request; see `JellyfinPlaybackResolver.embySegmentContainer`.
    private func segmentContainer(for item: PlexMediaItem) -> String {
        JellyfinPlaybackResolver.embySegmentContainer(videoCodec: item.videoCodec, supportsHEVC: Self.deviceSupportsHEVC)
    }

    // MARK: - Playback negotiation (PlaybackInfo) + session lifecycle

    /// The PlaybackInfo POST. `serverStreamOnly` is the retry after a direct play failed;
    /// see `JellyfinPlaybackResolver.playbackInfoBody`. Emby needs `EnableDirectStream`
    /// off as well as direct play before it hands back a TranscodingUrl.
    func playbackInfoRequest(for item: PlexMediaItem, serverStreamOnly: Bool) -> URLRequest? {
        playbackInfoRequest(for: item, serverStreamOnly: serverStreamOnly, burningSubtitle: nil)
    }

    /// `burningSubtitle`: the forced track to burn in; see `JellyfinPlaybackResolver.forcedSubtitleToBurn`.
    func playbackInfoRequest(for item: PlexMediaItem, serverStreamOnly: Bool, burningSubtitle: Int?) -> URLRequest? {
        guard var components = URLComponents(string: "\(serverURL)/Items/\(item.ratingKey)/PlaybackInfo") else {
            return nil
        }
        components.queryItems = [.init(name: "userId", value: userId)]
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.authorizationHeader(deviceID: deviceID, token: accessToken), forHTTPHeaderField: "Authorization")
        let body = JellyfinPlaybackResolver.playbackInfoBody(
            mediaSourceId: item.partKey ?? item.ratingKey,
            supportsHEVC: Self.deviceSupportsHEVC,
            serverStreamOnly: serverStreamOnly,
            burningSubtitle: burningSubtitle,
            segmentContainer: segmentContainer(for: item)
        )
        guard let encoded = try? JSONEncoder().encode(body) else { return nil }
        req.httpBody = encoded
        return req
    }

    func resolveTranscodePlayback(for item: PlexMediaItem) async -> PlaybackResolution? {
        await negotiatePlayback(for: item, serverStreamOnly: false)
    }

    private func negotiatePlayback(for item: PlexMediaItem, serverStreamOnly: Bool) async -> PlaybackResolution? {
        await negotiatePlayback(
            for: item, serverStreamOnly: serverStreamOnly,
            preferredSubtitleLanguage: SubtitleSelectionLogic.currentSubtitleLanguage(),
            send: { try await Self.session.data(for: $0) }
        )
    }

    /// The PlaybackInfo exchange, with how requests are sent as a parameter so tests can
    /// answer them. A second request burns a forced subtitle track; see
    /// `JellyfinPlaybackResolver.negotiate`.
    func negotiatePlayback(
        for item: PlexMediaItem,
        serverStreamOnly: Bool,
        preferredSubtitleLanguage: String,
        send: JellyfinPlaybackResolver.PlaybackInfoSend
    ) async -> PlaybackResolution? {
        let msid = item.partKey ?? item.ratingKey
        do {
            return try await JellyfinPlaybackResolver.negotiate(
                request: { playbackInfoRequest(for: item, serverStreamOnly: serverStreamOnly, burningSubtitle: $0) },
                serverURL: serverURL, apiKey: accessToken, itemId: item.ratingKey, mediaSourceId: msid,
                serverStreamOnly: serverStreamOnly, preferredSubtitleLanguage: preferredSubtitleLanguage, send: send
            ) ?? fallbackResolution(for: item)
        } catch {
            print("[Emby] PlaybackInfo failed for \(item.ratingKey): \(error) — falling back to hand-built URL")
            return fallbackResolution(for: item)
        }
    }

    /// The server stream after a direct play gave no picture or starved; never the static
    /// file. Same as Jellyfin's, and the client seeks.
    func resolveServerStream(for item: PlexMediaItem, offsetSeconds: Int) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        guard let r = await negotiatePlayback(for: item, serverStreamOnly: true) else { return nil }
        return JellyfinPlaybackResolver.offsetPlayback(r, offsetSeconds: offsetSeconds)
    }

    /// The client seeks to the offset itself, same as Jellyfin; see
    /// `JellyfinPlaybackResolver.offsetPlayback`.
    func resolveTranscodePlayback(for item: PlexMediaItem, offsetSeconds: Int) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        guard let r = await resolveTranscodePlayback(for: item) else { return nil }
        return JellyfinPlaybackResolver.offsetPlayback(r, offsetSeconds: offsetSeconds)
    }

    func cappedTranscodeURL(for item: PlexMediaItem, offsetSeconds: Int, sessionID: String) -> URL? {
        JellyfinPlaybackResolver.cappedTranscodeURL(
            serverURL: serverURL, item: item, accessToken: accessToken,
            deviceID: deviceID, sessionID: sessionID, supportsHEVC: Self.deviceSupportsHEVC,
            segmentContainer: segmentContainer(for: item)
        )
    }

    /// The capped stream starts at zero and the caller seeks, same as the first attempt. A
    /// start time on the URL would not keep the sound in sync; see
    /// `JellyfinPlaybackResolver.offsetPlayback`.
    var cappedStreamStartsAtOffset: Bool { false }

    /// Hand the session id back so the transcode it starts is stopped on the next channel
    /// change, the same as a PlaybackInfo session.
    private func fallbackResolution(for item: PlexMediaItem) -> PlaybackResolution? {
        let sessionID = UUID().uuidString
        guard let url = buildTranscodeURL(for: item, sessionID: sessionID) else { return nil }
        return PlaybackResolution(url: url, playSessionId: sessionID, isDirectPlay: false)
    }

    func reportWatchActivity(
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        positionTicks: Int,
        event: MediaServerPlaybackReport.Event
    ) async -> Bool {
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

    var watchStateGuard: any WatchStateGuarding {
        MediaServerWatchStateGuard(
            serverURL: serverURL,
            authorization: Self.authorizationHeader(deviceID: deviceID, token: accessToken),
            userId: userId,
            transport: URLSessionReportTransport.shared
        )
    }

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

    struct AuthResult: Sendable {
        let accessToken: String
        let userId: String
        let serverID: String
        let serverName: String
    }

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
        let result = try decodeSignIn(EmbyAuthenticationResult.self, data: data, response: response)
        guard let token = result.AccessToken, let uid = result.User?.Id else {
            throw PlexAPIService.APIError.unauthorized
        }
        return AuthResult(accessToken: token, userId: uid,
                          serverID: result.ServerId ?? "", serverName: result.User?.ServerName ?? "Emby Server")
    }
}

// MARK: - Decodable response models

private struct EmbyPublicSystemInfo: Decodable {
    let ServerName: String?
    let Version: String?
    let Id: String?
}

private struct EmbyAuthenticationResult: Decodable {
    let AccessToken: String?
    let ServerId: String?
    let User: EmbyUser?
    struct EmbyUser: Decodable {
        let Id: String?
        let Name: String?
        let ServerName: String?
    }
}

private struct EmbyItemsResponse: Decodable {
    let Items: [JellyfinItem]?
    let TotalRecordCount: Int?
}
