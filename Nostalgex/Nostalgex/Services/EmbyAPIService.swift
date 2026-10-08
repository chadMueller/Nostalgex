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

    func loadSections() async throws -> [PlexSection] {
        guard let req = request(path: "/UserViews", queryItems: [.init(name: "userId", value: userId)]) else {
            throw PlexAPIService.APIError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: req)
        let views = try Self.decode(EmbyItemsResponse.self, data: data, response: response).Items ?? []
        return views.map { PlexSection(key: $0.Id, title: $0.Name ?? "Library", type: JellyfinAPIService.sectionType(for: $0.CollectionType)) }
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
                    serverID: serverID.isEmpty ? nil : serverID
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
            serverID: serverID.isEmpty ? nil : serverID
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

    func loadCollectionItems(collectionKey: String) async throws -> [String] {
        try await fetchAllItems(parentId: collectionKey, includeItemTypes: "Movie").map(\.Id)
    }

    // MARK: - Stream URLs

    private static let supportedVideoCodecs: Set<String> = CodecSupport.directPlayVideoCodecs(hevcCapable: CodecSupport.deviceSupportsHEVC)
    private static let supportedAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]
    private static let directPlayContainers: Set<String> = ["mp4", "mov", "m4v"]

    static let deviceSupportsHEVC: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)

    func buildDirectPlayURL(for item: PlexMediaItem) -> URL? {
        if let container = item.container?.lowercased(), !Self.directPlayContainers.contains(container) {
            return nil
        }
        if let videoCodec = item.videoCodec?.lowercased(), !Self.supportedVideoCodecs.contains(videoCodec) {
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
            print("[Emby] PlaybackInfo failed for \(item.ratingKey): \(error) — falling back to hand-built URL")
            return fallbackResolution(for: item)
        }
    }

    /// The client seeks to the offset itself, same as Jellyfin; see
    /// `JellyfinPlaybackResolver.offsetPlayback`.
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
