import Foundation

struct PlexAPIService: MediaBackend {
    let serverURL: String
    let token: String
    /// Machine identifier of this server. Stamped onto every parsed item so playback,
    /// images, and lookups can be routed back to the correct server when multiple are
    /// connected. Empty for the demo/no-server case.
    var serverID: String = ""
    /// Carries playback reports (timeline, scrobble, Continue Watching cleanup). Tests
    /// replace it with a recorder.
    var reportTransport: any ReportTransport = URLSessionReportTransport.shared

    /// URLSession with timeout configured for Plex API calls
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        // Large TV libraries hammer many endpoints; tight totals surface as flaky "connection failed"
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static var clientID: String {
        if let id = UserDefaults.standard.string(forKey: "plex90_client_id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "plex90_client_id")
        return id
    }

    private var clientID: String { PlexAPIService.clientID }

    private var baseHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": "Nostalgex",
            "X-Plex-Platform": "tvOS",
            "X-Plex-Device": "Apple TV",
            "X-Plex-Device-Name": "Nostalgex",
        ]
    }

    /// HTTP headers with Plex auth token — used by AVURLAsset for direct play
    var authHeaders: [String: String] { baseHeaders }

    private func request(path: String) -> URLRequest? {
        guard let url = URL(string: "\(serverURL)\(path)") else { return nil }
        var req = URLRequest(url: url)
        baseHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return req
    }

    // MARK: - Resilient transport

    /// Transport failures worth a retry. A weak or congested connection produces these
    /// constantly; without a retry a single blip aborts a scan that may already be
    /// minutes deep, and the user is sent back to square one.
    private static let retryableURLErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorResourceUnavailable,
    ]

    private static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return retryableURLErrorCodes.contains(ns.code)
    }

    /// HTTP statuses that mean "try again shortly" rather than "this request is wrong".
    ///
    /// A reverse proxy in front of Plex returns 502/503/504 when the upstream is slow to
    /// respond, which is common on a large library over a thin connection. These arrive as
    /// *successful* responses carrying a bad status, so without this they bypass the
    /// transport retry above and abort the entire scan on the first blip.
    static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408,          // request timeout
             429,          // rate limited
             502, 503, 504: // gateway errors from a proxy in front of Plex
            return true
        default:
            return false
        }
    }

    /// Performs a request, retrying transient transport failures with exponential backoff.
    /// Cancellation and non-transport errors (auth, bad status, malformed payload) propagate
    /// immediately — only connection blips are worth waiting on.
    private func dataWithRetry(_ req: URLRequest, attempts: Int = 3) async throws -> (Data, URLResponse) {
        var lastError: Error = APIError.invalidResponse
        for attempt in 0 ..< attempts {
            do {
                let (data, response) = try await Self.session.data(for: req)

                // Retry gateway/overload statuses. On the final attempt fall through and
                // return the response so the decoder surfaces the real status code to the
                // user rather than a generic failure.
                if let http = response as? HTTPURLResponse,
                   Self.isRetryableHTTPStatus(http.statusCode),
                   attempt < attempts - 1 {
                    print("[Plex90] RETRY \(attempt + 1)/\(attempts - 1) (HTTP \(http.statusCode)) \(req.url?.path ?? "?")")
                    // Gateway errors usually mean the upstream is still working, so back
                    // off harder than for a dropped connection.
                    try await Task.sleep(nanoseconds: 1_000_000_000 << UInt64(attempt))
                    continue
                }

                return (data, response)
            } catch {
                try Task.checkCancellation()
                guard Self.isRetryable(error), attempt < attempts - 1 else { throw error }
                lastError = error
                print("[Plex90] RETRY \(attempt + 1)/\(attempts - 1) (\((error as NSError).code)) \(req.url?.path ?? "?")")
                // 0.5s, then 1s. Long enough to ride out a brief dropout, short enough
                // that a healthy link never notices.
                try await Task.sleep(nanoseconds: 500_000_000 << UInt64(attempt))
            }
        }
        throw lastError
    }

    /// Round-trip time above which the connection is treated as slow, measured on the
    /// first (tiny) request of a scan. Slow links get smaller pages so each individual
    /// request stays well inside the timeout instead of dying near the end of a big one.
    private static let slowLinkThresholdSeconds: Double = 0.8

    /// Plex (or a proxy in front of it) must return JSON. HTML/XML usually means a gateway error page, captive portal, or wrong host/port.
    private static func decodePlexJSONResponse<T: Decodable>(
        _: T.Type,
        data: Data,
        response: URLResponse?
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            print("[Plex90] Plex HTTP \(http.statusCode), expected JSON. Prefix: \(String(data: data.prefix(240), encoding: .utf8) ?? "?")")
            throw APIError.httpFailure(statusCode: http.statusCode)
        }
        if data.looksLikeMarkupOrNonJSONPayload() {
            print("[Plex90] Plex returned markup/XML instead of JSON (HTTP \(http.statusCode)). Prefix: \(String(data: data.prefix(240), encoding: .utf8) ?? "?")")
            throw APIError.receivedMarkupInsteadOfJSON(statusCode: http.statusCode)
        }
        let report = PlexDecodeReport()
        let decoded = try decodeRepaired(T.self, from: data, report: report)
        for line in report.logLines(context: Self.logContext(http.url)) {
            InstallDiagnostics.note(line)
        }
        return decoded
    }

    /// Bytes that are not UTF-8 (a Latin-1 file name Plex copied into a title) fail the
    /// whole document, so they are repaired first (PlexUTF8Repair). A valid response skips
    /// the repair and decodes exactly as before.
    static func decodeRepaired<T: Decodable>(_: T.Type, from data: Data, report: PlexDecodeReport) throws -> T {
        var data = data
        if let fixed = PlexUTF8Repair.repair(data) {
            data = fixed.data
            report.repairedBytes = fixed.repairedBytes
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.plexDecodeReport] = report
        return try decoder.decode(T.self, from: data)
    }

    /// A section page and the sections list, decoded exactly as a scan decodes them.
    /// Internal so tests can feed fixture JSON through the real models.
    static func decodeSectionPage(_ data: Data, report: PlexDecodeReport = PlexDecodeReport()) throws -> (totalSize: Int?, items: [PlexRawItem]) {
        let page = try decodeRepaired(SectionItemsResponse.self, from: data, report: report).MediaContainer
        return (page.totalSize, page.Metadata ?? [])
    }

    static func decodeSections(_ data: Data, report: PlexDecodeReport = PlexDecodeReport()) throws -> [PlexSection] {
        try decodeRepaired(SectionsResponse.self, from: data, report: report).MediaContainer.Directory ?? []
    }

    /// Path and paging query for a log line. Plex auth rides in headers, but a token in the
    /// query is stripped all the same.
    private static func logContext(_ url: URL?) -> String {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "?" }
        c.queryItems = c.queryItems?.filter { !$0.name.lowercased().contains("token") }
        let query = c.percentEncodedQuery.map { "?\($0)" } ?? ""
        return c.path + query
    }

    // MARK: - Connection test

    func testConnection() async throws -> String {
        guard let req = request(path: "/identity") else { throw APIError.invalidResponse }
        let (data, response) = try await Self.session.data(for: req)
        let decoded = try Self.decodePlexJSONResponse(IdentityResponse.self, data: data, response: response)
        return decoded.MediaContainer.friendlyName ?? "Plex Server"
    }

    // MARK: - Library loading
    // `LoadProgressEvent` / `LoadProgress` now live in MediaBackend.swift (shared by all backends).

    func loadLibrary(progress: LoadProgress? = nil) async throws -> [PlexMediaItem] {
        guard let req = request(path: "/library/sections") else { throw APIError.invalidResponse }
        // Time the first request to size every page that follows. This call returns a
        // handful of rows, so its duration is essentially pure round-trip latency.
        let probeStart = Date()
        let (sectionsData, response) = try await dataWithRetry(req)
        let probeSeconds = Date().timeIntervalSince(probeStart)
        let sections = try Self.decodePlexJSONResponse(SectionsResponse.self, data: sectionsData, response: response)
            .MediaContainer.Directory ?? []

        let isSlowLink = probeSeconds > Self.slowLinkThresholdSeconds
        let pageSize = isSlowLink ? Self.slowLinkPageSize : Self.sectionPageSize
        print("[Plex90] LINK: probe \(String(format: "%.2f", probeSeconds))s -> \(isSlowLink ? "slow" : "normal"), page size \(pageSize)")

        var allItems: [PlexMediaItem] = []
        for (i, section) in sections.enumerated() {
            progress?(LoadProgressEvent(
                sectionIndex: i,
                totalSections: sections.count,
                sectionTitle: section.title,
                sectionType: section.type,
                itemsLoadedSoFar: allItems.count,
                showsCompleted: nil,
                totalShows: nil
            ))
            let baseItemCount = allItems.count
            let items: [PlexMediaItem]
            do {
                items = try await fetchSection(section, pageSize: pageSize) { showsDone, totalShows, episodesSoFar in
                    progress?(LoadProgressEvent(
                        sectionIndex: i,
                        totalSections: sections.count,
                        sectionTitle: section.title,
                        sectionType: section.type,
                        itemsLoadedSoFar: baseItemCount + episodesSoFar,
                        showsCompleted: showsDone,
                        totalShows: totalShows
                    ))
                }
            } catch {
                // Cancelled (stall watchdog, or the user leaving) with sections already
                // read: hand those back so the caller can build a reduced guide instead of
                // throwing the whole scan away.
                if Task.isCancelled, !allItems.isEmpty {
                    throw LibraryScanInterrupted(partialItems: allItems)
                }
                throw error
            }
            allItems.append(contentsOf: items)

            // A cancelled section now returns the rows it managed to read rather than
            // throwing, so surface the partial scan here instead of looping into the
            // next section and letting a bare cancellation replace it.
            if Task.isCancelled, !allItems.isEmpty {
                throw LibraryScanInterrupted(partialItems: allItems)
            }
        }
        return allItems
    }

    /// Page size for library section fetches. Plex serializes the entire requested
    /// window server-side before sending a byte, so a bounded page keeps every request
    /// comfortably under the request timeout — even for a huge section over a slow
    /// remote/relay connection. Sections used to load in a single un-paginated request,
    /// which timed out (NSURLErrorDomain -1001) once a section outgrew what the server
    /// could serialize within `timeoutIntervalForRequest`.
    private static let sectionPageSize = 500

    /// Page size used once the link measures as slow. Smaller pages mean more requests,
    /// but each one completes well inside the timeout — far better than a large page
    /// that dies at 90% and takes the whole scan with it.
    private static let slowLinkPageSize = 150

    /// Fetch every raw item in a section, paging through Plex's container window
    /// (`X-Plex-Container-Start` / `X-Plex-Container-Size`) so no single request has to
    /// return the whole section. `onPage` reports cumulative progress after each page.
    /// `typeFilter` selects the Plex metadata type (4 = episode) when sweeping a section
    /// for something other than its top-level items.
    private func fetchSectionItemsPaged(
        _ section: PlexSection,
        pageSize: Int,
        typeFilter: Int? = nil,
        onPage: (@Sendable (_ page: [PlexRawItem], _ loadedSoFar: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [PlexRawItem] {
        var all: [PlexRawItem] = []
        var start = 0
        while true {
            var path = "/library/sections/\(section.key)/all?includeGuids=1"
            if let typeFilter { path += "&type=\(typeFilter)" }
            path += "&X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(pageSize)"
            guard let req = request(path: path) else { throw APIError.invalidResponse }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await dataWithRetry(req)
            } catch {
                // Same reasoning as the check below, for a cancellation that lands
                // while a page request is in flight rather than between pages.
                if Task.isCancelled, !all.isEmpty { break }
                throw error
            }
            let container = try Self.decodePlexJSONResponse(SectionItemsResponse.self, data: data, response: response)
                .MediaContainer
            let page = container.Metadata ?? []
            all.append(contentsOf: page)
            onPage?(page, all.count, container.totalSize ?? all.count)

            // Cancelled part-way through a section (stall watchdog, or the user
            // leaving): stop paging and hand back the pages already read instead of
            // letting the next request throw and take them with it. The caller turns
            // this into a LibraryScanInterrupted carrying every completed section plus
            // this partial one. Without it, a stall inside the FIRST section discarded
            // the entire scan, because the caller's partial list was still empty.
            if Task.isCancelled { break }

            if page.isEmpty { break }
            if let total = container.totalSize, all.count >= total { break }
            // Servers that omit totalSize: stop on the first short page.
            if container.totalSize == nil, page.count < pageSize { break }
            start += pageSize
        }
        return all
    }

    private func fetchSection(_ section: PlexSection, pageSize: Int, onShowBatch: ShowProgress? = nil) async throws -> [PlexMediaItem] {
        if section.type == "show" {
            // Show list pages are small (one entry per show); episodes come from a single
            // bulk sweep below.
            let shows = try await fetchSectionItemsPaged(section, pageSize: pageSize)
            let bulk = try await fetchEpisodesBulk(
                section: section,
                shows: shows,
                pageSize: pageSize,
                onBatch: onShowBatch
            )
            // A server that doesn't honour `type=4` returns nothing. Fall back to the
            // per-show crawl rather than silently reporting an empty TV library.
            if bulk.isEmpty, !shows.isEmpty {
                print("[Plex90] BULK EPISODES: section '\(section.title)' returned 0 — falling back to per-show fetch")
                return try await fetchEpisodesPerShow(from: shows, onBatch: onShowBatch)
            }
            return bulk
        } else {
            let isMusicSection = section.title.range(
                of: #"music.?video|^music$|^mv[s]?$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            // Report page progress so a large movie/music section doesn't look frozen
            // while it streams in. These sections have no "shows", so the item count
            // rides the same progress channel used for shows.
            let rawItems = try await fetchSectionItemsPaged(section, pageSize: pageSize) { _, loaded, total in
                onShowBatch?(loaded, total, loaded)
            }
            return rawItems.compactMap { parseMovieItem($0, isMusicSection: isMusicSection) }
        }
    }

    /// Reports progress fetching episodes within a TV section.
    /// - showsCompleted: number of shows whose episodes have been fetched
    /// - totalShows: total shows in this section
    /// - episodesSoFar: cumulative episode count
    typealias ShowProgress = @Sendable (_ showsCompleted: Int, _ totalShows: Int, _ episodesSoFar: Int) -> Void

    /// Fetches every episode in a TV section with one paged sweep (`type=4`) rather than
    /// one request per show.
    ///
    /// The per-show crawl issued a round trip for each series, so a 300-show library cost
    /// 300+ requests. On a high-latency connection that is minutes of pure waiting before
    /// any useful work, and any one of those requests failing quietly dropped a whole show
    /// from the lineup. The bulk sweep collapses it to a handful of paged requests.
    ///
    /// Episode payloads don't carry show-level metadata (genres, studio, GUIDs, rating), so
    /// each episode is joined back to its show through `grandparentRatingKey`.
    private func fetchEpisodesBulk(
        section: PlexSection,
        shows: [PlexRawItem],
        pageSize: Int,
        onBatch: ShowProgress? = nil
    ) async throws -> [PlexMediaItem] {
        guard !shows.isEmpty else { return [] }
        let showsByKey = Dictionary(shows.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })

        var results: [PlexMediaItem] = []
        var seenShowKeys = Set<String>()
        var orphanCount = 0

        _ = try await fetchSectionItemsPaged(section, pageSize: pageSize, typeFilter: 4) { page, _, _ in
            for ep in page {
                guard let showKey = ep.grandparentRatingKey, let show = showsByKey[showKey] else {
                    orphanCount += 1
                    continue
                }
                seenShowKeys.insert(showKey)
                if let item = makeEpisodeItem(ep, show: show) { results.append(item) }
            }
            onBatch?(seenShowKeys.count, shows.count, results.count)
        }

        if orphanCount > 0 {
            print("[Plex90] BULK EPISODES: \(orphanCount) episodes had no matching show in '\(section.title)'")
        }
        print("[Plex90] BULK EPISODES: '\(section.title)' -> \(results.count) episodes across \(seenShowKeys.count)/\(shows.count) shows")
        return results
    }

    /// Legacy per-show episode crawl. Retained only as a fallback for servers that ignore
    /// the `type=4` filter — it is one request per show and should not be the normal path.
    private func fetchEpisodesPerShow(from shows: [PlexRawItem], onBatch: ShowProgress? = nil) async throws -> [PlexMediaItem] {
        var results: [PlexMediaItem] = []
        // Kept modest: a wide fan-out on a thin connection makes every request slower and
        // more likely to time out.
        let batchSize = 5
        for batchStart in stride(from: 0, to: shows.count, by: batchSize) {
            let batch = Array(shows[batchStart ..< min(batchStart + batchSize, shows.count)])
            let batchResults = try await withThrowingTaskGroup(of: [PlexMediaItem].self) { group in
                for show in batch {
                    group.addTask { try await fetchShowEpisodes(show) }
                }
                var merged: [PlexMediaItem] = []
                for try await eps in group { merged.append(contentsOf: eps) }
                return merged
            }
            results.append(contentsOf: batchResults)
            onBatch?(min(batchStart + batchSize, shows.count), shows.count, results.count)
        }
        return results
    }

    /// Builds an episode item from the episode payload plus its show's metadata.
    /// Shared by the bulk sweep and the per-show fallback so both produce identical items.
    private func makeEpisodeItem(_ ep: PlexRawItem, show: PlexRawItem) -> PlexMediaItem? {
        let durationMin = (ep.duration ?? 0) / 60000
        guard durationMin > 0 else { return nil }
        let s = ep.parentIndex.map { "S\(String(format: "%02d", $0))" } ?? ""
        let e = ep.index.map { "E\(String(format: "%02d", $0))" } ?? ""
        let media = ep.bestMedia
        return PlexMediaItem(
            id: Self.compositeID(serverID: serverID, ratingKey: ep.ratingKey),
            title: show.title,
            artist: nil,
            episodeTitle: ep.title,
            seTag: (s + e).isEmpty ? nil : s + e,
            summary: ep.summary ?? show.summary ?? "",
            year: show.year,
            originallyAvailableAt: ep.originallyAvailableAt ?? show.originallyAvailableAt,
            contentRating: show.contentRating ?? ep.contentRating,
            duration: durationMin,
            ratingKey: ep.ratingKey,
            partKey: media?.Part?.first?.key,
            container: media?.container,
            videoCodec: media?.videoCodec,
            audioCodec: media?.audioStream?.codec ?? media?.audioCodec,
            videoProfile: media?.videoProfile,
            bitrate: media?.bitrate,
            genres: (show.Genre ?? []).map(\.tag),
            rating: show.rating ?? 0,
            userRating: show.userRating ?? 0,
            type: .episode,
            thumb: ep.thumb ?? show.thumb,
            art: show.art,
            viewCount: ep.viewCount ?? 0,
            addedAt: ep.addedAt ?? 0,
            studio: show.studio,
            tmdbID: show.tmdbID,
            imdbID: show.imdbID,
            librarySource: .tv,
            serverID: serverID.isEmpty ? nil : serverID,
            additionalPartKeys: {
                let extra = (media?.Part ?? []).dropFirst().compactMap { $0.key }
                return extra.isEmpty ? nil : Array(extra)
            }(),
            videoBitDepth: media?.videoStream?.bitDepth,
            doviProfile: media?.videoStream?.DOVIProfile,
            videoWidth: media?.width,
            videoHeight: media?.height,
            mediaIndex: ep.bestMediaIndex ?? 0,
            playbackParts: media?.playbackParts,
            exactDurationSeconds: ep.duration.map { Double($0) / 1000 },
            showKey: show.ratingKey,
            audioChannelCount: media?.audioStream?.channels,
            doviCompatibilityID: media?.videoStream?.DOVIBLCompatID,
            audioStreamID: media?.audioStream?.id,
            hasHDR10ColorMetadata: media?.videoStream?.hasHDR10ColorMetadata
        )
    }

    private func fetchShowEpisodes(_ show: PlexRawItem) async throws -> [PlexMediaItem] {
        do {
            guard let req = request(path: "/library/metadata/\(show.ratingKey)/allLeaves") else { return [] }
            let (data, response) = try await dataWithRetry(req)
            let episodes = try Self.decodePlexJSONResponse(SectionItemsResponse.self, data: data, response: response)
                .MediaContainer.Metadata ?? []
            return episodes.compactMap { makeEpisodeItem($0, show: show) }
        } catch {
            return [] // skip shows that fail individually
        }
    }

    func parseMovieItem(_ item: PlexRawItem, isMusicSection: Bool) -> PlexMediaItem? {
        let durationMin = (item.duration ?? 0) / 60000
        guard durationMin > 0 else { return nil }
        var genres = (item.Genre ?? []).map(\.tag)
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
        let media = item.bestMedia
        // "Artist - Song" parsing is for music videos only. Run on films it turned
        // "Star Wars: Episode I - The Phantom Menace" into "The Phantom Menace",
        // "Breaking Dawn - Part 1" into "Part 1" and "Spider-Man" into "Man", which
        // also hid those titles from title-matched channels and collection checks.
        let parsed: (artist: String?, song: String) = isMusicVideo
            ? MusicTitleParser.parse(item.title)
            : (nil, item.title)
        let artist = isMusicVideo
            ? ([item.parentTitle, item.grandparentTitle]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                ?? parsed.artist)
            : nil
        let displayTitle = parsed.song
        return PlexMediaItem(
            id: Self.compositeID(serverID: serverID, ratingKey: item.ratingKey),
            title: displayTitle,
            artist: artist,
            episodeTitle: nil,
            seTag: nil,
            summary: item.summary ?? "",
            year: item.year,
            originallyAvailableAt: item.originallyAvailableAt,
            contentRating: item.contentRating,
            duration: durationMin,
            ratingKey: item.ratingKey,
            partKey: media?.Part?.first?.key,
            container: media?.container,
            videoCodec: media?.videoCodec,
            audioCodec: media?.audioStream?.codec ?? media?.audioCodec,
            videoProfile: media?.videoProfile,
            bitrate: media?.bitrate,
            genres: genres,
            rating: item.rating ?? 0,
            userRating: item.userRating ?? 0,
            type: .movie,
            thumb: item.thumb,
            art: item.art,
            viewCount: item.viewCount ?? 0,
            addedAt: item.addedAt ?? 0,
            studio: item.studio,
            tmdbID: item.tmdbID,
            imdbID: item.imdbID,
            librarySource: isMusicVideo ? .musicVideo : .movie,
            serverID: serverID.isEmpty ? nil : serverID,
            additionalPartKeys: {
                let extra = (media?.Part ?? []).dropFirst().compactMap { $0.key }
                return extra.isEmpty ? nil : Array(extra)
            }(),
            videoBitDepth: media?.videoStream?.bitDepth,
            doviProfile: media?.videoStream?.DOVIProfile,
            videoWidth: media?.width,
            videoHeight: media?.height,
            mediaIndex: item.bestMediaIndex ?? 0,
            playbackParts: media?.playbackParts,
            exactDurationSeconds: item.duration.map { Double($0) / 1000 },
            audioChannelCount: media?.audioStream?.channels,
            doviCompatibilityID: media?.videoStream?.DOVIBLCompatID,
            audioStreamID: media?.audioStream?.id,
            hasHDR10ColorMetadata: media?.videoStream?.hasHDR10ColorMetadata
        )
    }

    /// Unique item id across servers. ratingKeys are only unique within one server,
    /// so prefix with the server id to avoid collisions in pools and lookups. With no
    /// server id (demo) the raw ratingKey is used, matching pre-multi-server snapshots.
    static func compositeID(serverID: String, ratingKey: String) -> String {
        serverID.isEmpty ? ratingKey : "\(serverID):\(ratingKey)"
    }

    // MARK: - Library sections

    func loadSections() async throws -> [PlexSection] {
        guard let req = request(path: "/library/sections") else { throw APIError.invalidResponse }
        let (data, response) = try await Self.session.data(for: req)
        return try Self.decodePlexJSONResponse(SectionsResponse.self, data: data, response: response)
            .MediaContainer.Directory ?? []
    }

    // MARK: - Collections

    /// Fetch all collections for a given library section
    func loadCollections(sectionKey: String) async throws -> [PlexCollection] {
        guard let req = request(path: "/library/sections/\(sectionKey)/collections") else {
            throw APIError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: req)
        let collections = try Self.decodePlexJSONResponse(CollectionsResponse.self, data: data, response: response)
            .MediaContainer.Metadata ?? []
        return collections
    }

    /// Fetch item ratingKeys belonging to a collection
    func loadCollectionItems(collectionKey: String) async throws -> [String] {
        guard let req = request(path: "/library/collections/\(collectionKey)/children") else {
            throw APIError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: req)
        let items = try Self.decodePlexJSONResponse(SectionItemsResponse.self, data: data, response: response)
            .MediaContainer.Metadata ?? []
        return items.map(\.ratingKey)
    }

    // MARK: - Stream URLs

    // Codecs AVPlayer on tvOS can handle natively
    private static let supportedVideoCodecs: Set<String> = CodecSupport.directPlayVideoCodecs(hevcCapable: CodecSupport.deviceSupportsHEVC)
    private static let supportedAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]
    // Containers AVPlayer can open as a raw file. Matroska (mkv), avi, etc. are NOT
    // playable directly even when their codecs are supported, so they must transcode.
    private static let directPlayContainers: Set<String> = ["mp4", "mov", "m4v"]

    /// Whether the server looks like it's on the same network.
    ///
    /// Plex hands out `plex.direct` hostnames that encode the address, so a LAN connection
    /// still shows a private address in the host. A private/link-local address means there
    /// is effectively unlimited bandwidth and no reason to cap direct play; anything else
    /// (public address or relay) is treated as remote.
    var isLikelyLocalServer: Bool {
        guard let host = URL(string: serverURL)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        // plex.direct encodes the address with dashes: 192-168-1-50.abc.plex.direct
        let normalized = host.replacingOccurrences(of: "-", with: ".")
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count >= 4 else { return false }
        let (a, b) = (octets[0], octets[1])
        if a == 10 { return true }                        // 10.0.0.0/8
        if a == 192, b == 168 { return true }             // 192.168.0.0/16
        if a == 172, (16 ... 31).contains(b) { return true } // 172.16.0.0/12
        if a == 127 { return true }                       // loopback
        if a == 169, b == 254 { return true }             // link-local
        return false
    }

    /// Direct play URL — serves the raw file from Plex.
    /// Only used when both the container and the video/audio codecs are natively
    /// supported by tvOS AVPlayer.
    func buildDirectPlayURL(for item: PlexMediaItem) -> URL? {
        guard let partKey = item.partKey else { return nil }

        // Direct play sends the original file at its original bitrate with no ability to
        // adapt. Over a remote connection a high-bitrate file will simply stall, so hand it
        // to the transcoder instead, where adaptive HLS can step it down. On a LAN this
        // never trips, so local playback keeps direct-playing everything as before.
        if !isLikelyLocalServer {
            let ceiling = StreamQuality.current.remoteDirectPlayCeilingKbps
            if let bitrate = item.bitrate, bitrate > ceiling {
                print("[Plex90] SKIP direct play: \(bitrate)kbps exceeds remote ceiling \(ceiling)kbps for \"\(item.title)\" — transcoding")
                return nil
            }
        }

        // Container must be one AVPlayer can open as a raw file. An mkv with h264/aac
        // passes the codec checks below but AVPlayer can't open the container — that
        // path used to fail and only then fall back to transcode. Skip it up front.
        if let container = item.container?.lowercased(),
           !Self.directPlayContainers.contains(container) {
            print("[Plex90] SKIP direct play: unsupported container '\(container)' for \"\(item.title)\"")
            return nil
        }

        // If we know the codecs, check compatibility before attempting direct play
        if let videoCodec = item.videoCodec?.lowercased(),
           !Self.supportedVideoCodecs.contains(videoCodec) {
            print("[Plex90] SKIP direct play: unsupported video codec '\(videoCodec)' for \"\(item.title)\"")
            return nil
        }
        if Self.needsServerRemux(container: item.container, videoCodec: item.videoCodec) {
            print("[Plex90] SKIP direct play: HEVC in MP4 for \"\(item.title)\" — remuxing on the server (hev1 tag risk)")
            return nil
        }
        if let reason = Self.undecodableVideoReason(for: item, hevcCapable: CodecSupport.deviceSupportsHEVC) {
            print("[Plex90] SKIP direct play: \(reason) for \"\(item.title)\" — transcoding")
            return nil
        }
        if let audioCodec = item.audioCodec?.lowercased(),
           !Self.supportedAudioCodecs.contains(audioCodec) {
            print("[Plex90] SKIP direct play: unsupported audio codec '\(audioCodec)' for \"\(item.title)\"")
            return nil
        }

        return URL(string: "\(serverURL)\(partKey)")
    }

    /// HLS transcode URL — used when direct play isn't possible.
    /// Tells Plex to transcode video/audio into AVPlayer-compatible formats.
    /// A supported codec name is not the whole question; see CodecSupport.canDecodeVideo.
    /// AVPlayer opens HEVC in MP4 only when the sample entry is `hvc1`. Most x265 rips
    /// carry `hev1` instead, and Plex metadata does not say which; the file plays audio over
    /// a black screen. A server remux writes a playable stream and copies video, so it
    /// costs a session, not an encode. `.mov` is Apple's own container and always `hvc1`.
    static func needsServerRemux(container: String?, videoCodec: String?) -> Bool {
        guard let container = container?.lowercased(), let codec = videoCodec?.lowercased() else { return false }
        return codec == "hevc" && (container == "mp4" || container == "m4v")
    }

    static func undecodableVideoReason(for item: PlexMediaItem, hevcCapable: Bool) -> String? {
        let codec = item.videoCodec?.lowercased()
        if !CodecSupport.canDecodeVideo(codec: codec, bitDepth: item.videoBitDepth, hevcCapable: hevcCapable) {
            return "\(item.videoBitDepth ?? 10)-bit \(codec?.uppercased() ?? "video") has no decoder on this device"
        }
        if item.doviProfile == 7 { return "Dolby Vision profile 7 is not renderable by AVPlayer" }
        return nil
    }

    /// Client profile for the transcoder. This is Marquee's profile, the one that plays on
    /// Chad's Apple TVs every day, carried over verbatim except for the audio list.
    ///
    /// - Two targets and no `replace`: MPEG-TS for H.264, fMP4 for HEVC (AVPlayer cannot
    ///   render HEVC in MPEG-TS). A single fMP4 target with `replace=true` looked right on
    ///   the decision endpoint and was wrong on the wire: the transcoder wrote empty init
    ///   and first segments, so an H.264 MKV that had started in a second took twenty, and
    ///   most files never reached ready at all. Measured on both TVs, 20% pass rate.
    /// - Width, height and HEVC bit depth raised. Plex's base profile assumes 8-bit and 1080
    ///   lines, so a 4K HEVC Main 10 file was re-encoded to 1080p H.264 on an Apple TV 4K that
    ///   decodes it natively.
    /// - No HEVC for Dolby Vision profile 7 (AVPlayer cannot render it; the server then makes
    ///   H.264). Profile 8 in an MKV is re-encoded by the server regardless; that is Plex.
    /// - Lossy audio targets only. Offering ALAC made the server turn TrueHD into ALAC at
    ///   negative speed: picture, no sound, then nothing.
    /// - EAC3 capped at 6 channels (`eac3ChannelCap`).
    static func clientProfileExtra(hevcCapable: Bool, offersHEVC: Bool) -> String {
        let hevc = hevcCapable && offersHEVC
        let video = CodecSupport.directPlayVideoCodecs(hevcCapable: hevc)
        let tsVideo = video.subtracting(["hevc"]).sorted().joined(separator: ",")
        let mp4Video = video.sorted().joined(separator: ",")
        let audio = CodecSupport.transcodeAudioCodecs.sorted().joined(separator: ",")
        var profile = "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=\(tsVideo)&audioCodec=\(audio))"
            + "+add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=fmp4&videoCodec=\(mp4Video)&audioCodec=\(audio))"
            + "+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width&value=3840&replace=true)"
            + "+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height&value=2160&replace=true)"
            + eac3ChannelCap
        if hevc {
            profile += "+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.width&value=3840&replace=true)"
                + "+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.height&value=2160&replace=true)"
                + "+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.bitDepth&value=10&replace=true)"
        }
        return profile
    }

    /// Blu-ray "DD+ 7.1" is an AC-3 5.1 core with E-AC-3 extension frames, and AVPlayer
    /// refuses it (CoreMedia -12979) about a second after Plex starts copying it: The Wild
    /// Robot, Bob Marley: One Love and ten more in one library. True E-AC-3 7.1 plays, so the
    /// channel count is not the problem, but the label can't tell the two apart. Capped at 6,
    /// Plex re-encodes just that audio to AC-3 5.1 and still copies the video. Must be scope
    /// `videoAudioCodec`: `audioCodec` is silently ignored. Measured 2026-10-18.
    static let eac3ChannelCap = "+add-limitation(scope=videoAudioCodec&scopeName=eac3&type=upperBound&name=audio.channels&value=6)"

    /// Query for `/video/:/transcode/universal/start.m3u8`. No `videoDecision=transcode`:
    /// that flag forced a full video re-encode on every file that could not direct play,
    /// which for an MKV remux is exactly the transcode a remux would have avoided. With
    /// directStream on and the profile above, the server copies compatible video and
    /// rewraps it, and only re-encodes what it truly has to.
    static func transcodeQueryItems(for item: PlexMediaItem, sessionID: String, offsetSeconds: Int,
                                    isLocal: Bool, quality: StreamQuality, token: String, clientID: String,
                                    hevcCapable: Bool) -> [URLQueryItem] {
        let offersHEVC = CodecSupport.offersHEVC(doviProfile: item.doviProfile, deviceCapable: hevcCapable)
        let items: [URLQueryItem] = [
            .init(name: "path",                      value: "/library/metadata/\(item.ratingKey)"),
            .init(name: "mediaIndex",                value: String(item.mediaIndex)),
            .init(name: "partIndex",                 value: String(item.partIndex)),
            .init(name: "protocol",                  value: "hls"),
            .init(name: "session",                   value: sessionID),
            .init(name: "offset",                    value: String(offsetSeconds)),
            .init(name: "fastSeek",                  value: "1"),
            .init(name: "directPlay",                value: "0"),
            .init(name: "directStream",              value: "1"),
            .init(name: "directStreamAudio",         value: "1"),
            // copyts=0, measured on tvOS 26. With copyts=1 a re-encoded stream came back as
            // 1-second segments whose timestamps sat ten seconds ahead of the playlist, and
            // tvOS 26 refused them (CoreMedia -15628) after the first segment: picture for
            // a moment, then nothing. Copied streams lined up and played either way. With
            // copyts=0 the same files started in under three seconds on the same Apple TV.
            // The player's clock then starts at zero; hlsBaseOffset adds the offset back.
            .init(name: "copyts",                    value: "0"),
            .init(name: "subtitles",                 value: "auto"),
            .init(name: "subtitleSize",              value: "100"),
            .init(name: "audioBoost",                value: "100"),
            .init(name: "hasMDE",                    value: "1"),
            .init(name: "location",                  value: isLocal ? "lan" : "wan"),
            .init(name: "maxVideoBitrate",           value: "\(quality.maxBitrateKbps)"),
            .init(name: "videoQuality",              value: "\(quality.videoQualityIndex)"),
            .init(name: "videoResolution",           value: quality.resolutionString),
            .init(name: "autoAdjustQuality",         value: quality.allowsAutoAdjust ? "1" : "0"),
            .init(name: "addDebugOverlay",           value: "0"),
            .init(name: "X-Plex-Client-Profile-Extra", value: clientProfileExtra(hevcCapable: hevcCapable, offersHEVC: offersHEVC)),
            .init(name: "X-Plex-Session-Identifier", value: sessionID),
            .init(name: "X-Plex-Token",              value: token),
            .init(name: "X-Plex-Client-Identifier",  value: clientID),
            .init(name: "X-Plex-Product",            value: "Nostalgex"),
            .init(name: "X-Plex-Platform",           value: "tvOS"),
            .init(name: "X-Plex-Device",             value: "Apple TV"),
            .init(name: "X-Plex-Device-Name",        value: "Nostalgex"),
        ]
        let overrides = PlaybackSoak.queryOverrides
        guard !overrides.isEmpty else { return items }
        return items.compactMap { q in
            guard let v = overrides[q.name] else { return q }
            return v == "UNSET" ? nil : URLQueryItem(name: q.name, value: v)
        }
    }

    func transcodeURL(for item: PlexMediaItem, sessionID: String, offsetSeconds: Int = 0, quality: StreamQuality = StreamQuality.current) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/video/:/transcode/universal/start.m3u8") else { return nil }
        components.queryItems = Self.transcodeQueryItems(
            for: item, sessionID: sessionID, offsetSeconds: offsetSeconds, isLocal: isLikelyLocalServer,
            quality: quality, token: token, clientID: clientID,
            hevcCapable: CodecSupport.deviceSupportsHEVC)
        return components.url
    }

    func buildTranscodeURL(for item: PlexMediaItem) -> URL? {
        transcodeURL(for: item, sessionID: UUID().uuidString)
    }

    /// Every HLS playback gets its own session id, so stopping it cannot tear down a
    /// transcode that a faster channel change already started under a shared key.
    func resolveTranscodePlayback(for item: PlexMediaItem) async -> PlaybackResolution? {
        let sessionID = UUID().uuidString
        guard let url = transcodeURL(for: item, sessionID: sessionID) else { return nil }
        return PlaybackResolution(url: url, playSessionId: sessionID, isDirectPlay: false)
    }

    /// The server starts the transcode at the offset. Channel tuning always lands
    /// mid-program, and a client-side seek into a transcode that began at zero never
    /// completes, so this is the difference between picture and a black screen.
    func resolveTranscodePlayback(for item: PlexMediaItem, offsetSeconds: Int) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        let item = await itemWithPlaybackStreamFacts(item)
        guard !Task.isCancelled else { return nil }
        let originalLocal = LocalPlexOriginalQuality.enabled
        let sessionID = UUID().uuidString
        guard let url = transcodeURL(for: item, sessionID: sessionID, offsetSeconds: max(0, offsetSeconds)) else { return nil }
        if Self.shouldPreferOriginalVideo(item, quality: .current,
                                          isLocal: isLikelyLocalServer,
                                          hevcCapable: CodecSupport.deviceSupportsHEVC,
                                          originalLocal: originalLocal) {
            if let candidate = Self.preferredOriginalVideoURL(from: url, item: item, quality: .current,
                isLocal: isLikelyLocalServer, hevcCapable: CodecSupport.deviceSupportsHEVC,
                originalLocal: originalLocal) {
                return await Self.resolveOriginalVideoCandidate(url: candidate, sessionID: sessionID,
                    offsetSeconds: offsetSeconds, requiresOriginalVideo: originalLocal,
                    allowAC3Conversion: item.audioChannelCount == 8,
                    prepare: { await prepareTranscodeSession(startURL: $0) },
                    stop: { await stopTranscode(playSessionId: $0) },
                    fallback: { await resolveNormalTranscodePlayback(for: item, offsetSeconds: offsetSeconds) })
            }
            if originalLocal { return nil }
        }
        return await resolveNormalTranscodePlayback(for: item, offsetSeconds: offsetSeconds)
    }

    /// A rejected automatic candidate has already retired its session. Normal playback
    /// gets a fresh one, retaining the selected quality, media and schedule position.
    private func resolveNormalTranscodePlayback(for item: PlexMediaItem, offsetSeconds: Int) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        guard !Task.isCancelled else { return nil }
        let sessionID = UUID().uuidString
        guard let url = transcodeURL(for: item, sessionID: sessionID, offsetSeconds: max(0, offsetSeconds)) else { return nil }
        let decision = await prepareTranscodeSession(startURL: url)
        if Self.isDolbyVisionRefusal(decision),
           let remux = Self.dolbyVisionRemuxURL(from: url) {
            // The server will not re-encode this file but will copy it into fMP4 for a
            // client it treats as Generic; see dolbyVisionRemuxURL. Ask once that way.
            let second = await prepareTranscodeSession(startURL: remux)
            if second.code.hasPrefix("1") {
                print("[Plex90] DECISION: Dolby Vision remux accepted for \"\(item.title)\"")
                return (PlaybackResolution(url: remux, playSessionId: sessionID, isDirectPlay: false), offsetSeconds > 0)
            }
            PlaybackDiagnostics.record(outcome: "server refused", title: item.title, detail: "decision \(decision.code): \(decision.text); remux retry \(second.code): \(second.text)")
        } else if decision.code.hasPrefix("2") {
            PlaybackDiagnostics.record(outcome: "server refused", title: item.title, detail: "decision \(decision.code): \(decision.text)")
        }
        return (PlaybackResolution(url: url, playSessionId: sessionID, isDirectPlay: false), offsetSeconds > 0)
    }

    struct TranscodeDecision: Sendable, Equatable {
        let code: String
        let text: String
        var preservesOriginalVideo: Bool = false
        var preservesOriginalAudio: Bool = false
        var convertsAudioToAC3Surround: Bool = false
        static let unknown = TranscodeDecision(code: "?", text: "")
    }

    /// Plex's transcoder cannot tone-map Dolby Vision profile 5 (no HDR10 base layer),
    /// so a decision 2003 naming DoVi means every re-encode request will be refused.
    static func isDolbyVisionRefusal(_ d: TranscodeDecision) -> Bool {
        d.code == "2003" && d.text.localizedCaseInsensitiveContains("dovi")
    }

    /// The same request, resolved against the server's Generic profile with one hls/mp4
    /// target that admits HEVC.
    ///
    /// Measured 2026-10-07 against Chad's server with a 4K DV profile 5 MKV: with
    /// `X-Plex-Platform=tvOS` the server applies its built-in tvOS profile, picks mpegts
    /// for HLS, finds "no remuxable profile" for HEVC there and tries to transcode, which
    /// DV5 cannot survive (2003). Plex's own Apple TV app resolves to the Generic profile
    /// and gets `container=mp4, video=copy hevc DOVI 5, audio=copy eac3`: an fMP4 HLS
    /// remux carrying the dvh1 Dolby Vision record and VIDEO-RANGE=PQ, which Apple TV 4K
    /// decodes natively. Sending Platform=Generic with an hls/mp4 target gets us the same.
    /// Only used after a DoVi refusal; the everyday request is unchanged.
    static func dolbyVisionRemuxURL(from startURL: URL, convertSurroundAudio: Bool = false) -> URL? {
        guard var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "X-Plex-Platform" && $0.name != "X-Plex-Client-Profile-Extra" }
        let audio = convertSurroundAudio ? "ac3,eac3" : CodecSupport.transcodeAudioCodecs.sorted().joined(separator: ",")
        let profile = "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264,hevc&audioCodec=\(audio))"
            + "+add-limitation(scope=videoTranscodeTarget&scopeName=hevc&scopeType=videoCodec&context=all&protocol=hls&type=upperBound&name=video.bitDepth&value=10)"
            + eac3ChannelCap
        items.append(.init(name: "X-Plex-Platform", value: "Generic"))
        items.append(.init(name: "X-Plex-Client-Profile-Extra", value: profile))
        components.queryItems = items
        return components.url
    }

    /// Bulk Plex listings omit Stream records. Enrich just the selected item when
    /// its broad format could use the automatic path; never rescan or change the catalog.
    func itemWithPlaybackStreamFacts(_ item: PlexMediaItem) async -> PlexMediaItem {
        guard Self.needsOriginalVideoFacts(item, quality: .current, isLocal: isLikelyLocalServer,
                                          hevcCapable: CodecSupport.deviceSupportsHEVC, originalLocal: LocalPlexOriginalQuality.enabled),
              var req = request(path: "/library/metadata/\(item.ratingKey)") else { return item }
        req.timeoutInterval = 5
        do {
            let (data, response) = try await Self.session.data(for: req)
            guard !Task.isCancelled, let status = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status) else { return item }
            let raw = try Self.decodePlexJSONResponse(SectionItemsResponse.self, data: data, response: response)
                .MediaContainer.Metadata?.first { $0.ratingKey == item.ratingKey }
            guard let raw else { return item }
            return Self.applyingPlaybackStreamFacts(raw, to: item)
        } catch { return item } // Unavailable facts do not invent codec support.
    }

    static func needsOriginalVideoFacts(_ item: PlexMediaItem, quality: StreamQuality,
                                       isLocal: Bool, hevcCapable: Bool, originalLocal: Bool = false) -> Bool {
        isLocal && hevcCapable && (originalLocal || [.auto, .maximum].contains(quality))
            && item.container?.lowercased() == "mkv" && item.videoCodec?.lowercased() == "hevc"
            && item.audioCodec?.lowercased() == "eac3" && (item.videoWidth ?? 0) > 1920
            && (item.videoHeight ?? 0) > 1080
            && (item.audioChannelCount == nil || item.doviCompatibilityID == nil
                || item.audioStreamID == nil || item.doviProfile == nil || item.videoBitDepth == nil)
    }

    static func applyingPlaybackStreamFacts(_ raw: PlexRawItem, to item: PlexMediaItem) -> PlexMediaItem {
        guard raw.ratingKey == item.ratingKey, let media = raw.Media,
              media.indices.contains(item.mediaIndex), let parts = media[item.mediaIndex].Part,
              parts.indices.contains(item.partIndex) else { return item }
        let part = parts[item.partIndex]
        guard let currentKey = part.key, let cachedKey = item.partKey,
              Self.samePlexPart(currentKey, cachedKey) else { return item }
        let video = part.Stream?.first { $0.streamType == 1 }
        let audio = part.Stream?.first { $0.streamType == 2 && $0.selected == 1 }
            ?? part.Stream?.first { $0.streamType == 2 }
        guard video?.codec == item.videoCodec, audio?.codec == item.audioCodec else { return item }
        var enriched = currentKey == cachedKey ? item : item.withPartKey(currentKey)
        if currentKey != cachedKey, let cachedParts = enriched.playbackParts {
            let freshPart = PlexPartPlaybackInfo(key: currentKey,
                container: part.container ?? media[item.mediaIndex].container,
                videoCodec: video?.codec, audioCodec: audio?.codec,
                bitDepth: video?.bitDepth, doviProfile: video?.DOVIProfile,
                durationSeconds: part.duration.map { Double($0) / 1000 },
                audioChannelCount: audio?.channels, doviCompatibilityID: video?.DOVIBLCompatID,
                audioStreamID: audio?.id, hasHDR10ColorMetadata: video?.hasHDR10ColorMetadata)
            enriched.playbackParts = cachedParts.map { $0.key == cachedKey ? freshPart : $0 }
        }
        enriched.videoBitDepth = video?.bitDepth
        enriched.doviProfile = video?.DOVIProfile
        enriched.doviCompatibilityID = video?.DOVIBLCompatID
        enriched.audioChannelCount = audio?.channels
        enriched.audioStreamID = audio?.id
        enriched.hasHDR10ColorMetadata = video?.hasHDR10ColorMetadata
        return enriched
    }

    /// A replacement can change the URL's timestamp without changing the selected part.
    /// Never accept another part ID, arbitrary path, or filename as the cached selection.
    static func samePlexPart(_ current: String, _ cached: String) -> Bool {
        if current == cached { return true }
        func identity(_ key: String) -> (String, String)? {
            let pieces = key.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 6, pieces[0].isEmpty, pieces[1] == "library", pieces[2] == "parts",
                  !pieces[3].isEmpty, pieces[3].allSatisfy(\.isNumber),
                  !pieces[4].isEmpty, pieces[4].allSatisfy(\.isNumber),
                  ["file.mkv", "file.mp4", "file.m4v"].contains(String(pieces[5])) else { return nil }
            return (String(pieces[3]), String(pieces[5]))
        }
        guard let a = identity(current), let b = identity(cached) else { return false }
        return a == b
    }

    /// Local DV8.1 / EAC3 5.1 or explicitly identified HDR10 / EAC3 surround.
    /// HDR10 7.1 keeps the existing audio compatibility cap but must copy HEVC. Missing facts,
    /// remote playback, lower quality selections and over-budget files keep their old path.
    static func shouldPreferOriginalVideo(_ item: PlexMediaItem, quality: StreamQuality,
                                          isLocal: Bool, hevcCapable: Bool, originalLocal: Bool = false) -> Bool {
        guard isLocal, hevcCapable, originalLocal || [.auto, .maximum].contains(quality),
              item.container?.lowercased() == "mkv", item.videoCodec?.lowercased() == "hevc",
              item.videoBitDepth == 10,
              item.audioCodec?.lowercased() == "eac3",
              item.audioStreamID != nil, let bitrate = item.bitrate, bitrate > 0,
              bitrate <= (originalLocal ? LocalPlexOriginalQuality.requestCeilingKbps : quality.maxBitrateKbps),
              let width = item.videoWidth, let height = item.videoHeight else { return false }
        let validatedDV = item.doviProfile == 8 && item.doviCompatibilityID == 1 && item.audioChannelCount == 6
        let hdr10 = originalLocal && item.doviProfile == nil && item.hasHDR10ColorMetadata == true
            && [6, 8].contains(item.audioChannelCount ?? 0)
        return (validatedDV || hdr10) && width > 1920 && width <= (originalLocal ? 3840 : quality.width)
            && height > 1080 && height <= (originalLocal ? 2160 : quality.height)
    }

    static func preferredOriginalVideoURL(from url: URL, item: PlexMediaItem, quality: StreamQuality,
                                          isLocal: Bool, hevcCapable: Bool, originalLocal: Bool) -> URL? {
        guard shouldPreferOriginalVideo(item, quality: quality, isLocal: isLocal,
                                        hevcCapable: hevcCapable, originalLocal: originalLocal) else { return nil }
        if originalLocal {
            return preservationRetryURL(from: url, audioStreamID: item.audioStreamID,
                                        convertSurroundAudio: item.audioChannelCount == 8)
        }
        return automaticOriginalVideoURL(from: url, audioStreamID: item.audioStreamID,
                                         convertSurroundAudio: item.audioChannelCount == 8)
    }

    /// Unlike the explicit retry, automation never raises the bitrate/resolution ceiling
    /// or disables the selected adaptive-quality setting. The 7.1 path limits audio to AC3/EAC3.
    static func automaticOriginalVideoURL(from original: URL, audioStreamID: Int?,
                                          convertSurroundAudio: Bool = false) -> URL? {
        guard let id = audioStreamID, let remux = dolbyVisionRemuxURL(from: original, convertSurroundAudio: convertSurroundAudio),
              var c = URLComponents(url: remux, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "audioStreamID" }
            + [URLQueryItem(name: "audioStreamID", value: String(id))]
        return c.url
    }

    static func prepareOriginalVideoCandidate(url: URL, sessionID: String, offsetSeconds: Int,
        allowAC3Conversion: Bool = false, requiresOriginalVideo: Bool = true,
        prepare: (URL) async -> TranscodeDecision, stop: (String) async -> Void
    ) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        let decision = await prepare(url)
        let audioAccepted = allowAC3Conversion ? decision.convertsAudioToAC3Surround : decision.preservesOriginalAudio
        guard !Task.isCancelled, decision.code.hasPrefix("1"), decision.preservesOriginalVideo, audioAccepted else {
            await stop(sessionID)
            return nil // The caller chooses normal recovery or explicit Original failure.
        }
        return (PlaybackResolution(url: url, playSessionId: sessionID, isDirectPlay: false,
                                   requiresOriginalVideo: requiresOriginalVideo), offsetSeconds > 0)
    }

    /// Auto/Maximum prefer a copy, but playback and capped recovery still take priority.
    /// Explicit Original alone requires the accepted stream to stay at original quality.
    static func resolveOriginalVideoCandidate(url: URL, sessionID: String, offsetSeconds: Int,
        requiresOriginalVideo: Bool, allowAC3Conversion: Bool = false,
        prepare: (URL) async -> TranscodeDecision, stop: (String) async -> Void,
        fallback: () async -> (resolution: PlaybackResolution, startsAtOffset: Bool)?
    ) async -> (resolution: PlaybackResolution, startsAtOffset: Bool)? {
        let candidate = await prepareOriginalVideoCandidate(url: url, sessionID: sessionID,
            offsetSeconds: offsetSeconds, allowAC3Conversion: allowAC3Conversion,
            requiresOriginalVideo: requiresOriginalVideo, prepare: prepare, stop: stop)
        if let candidate { return candidate }
        guard !requiresOriginalVideo, !Task.isCancelled else { return nil }
        return await fallback()
    }

    static func canRetryOriginalVideo(_ item: PlexMediaItem, isLocal: Bool, hevcCapable: Bool) -> Bool {
        guard isLocal, hevcCapable, item.videoCodec?.lowercased() == "hevc",
              let width = item.videoWidth, let height = item.videoHeight else { return false }
        return width > 1920 && width <= 3840 && height > 1080 && height <= 2160
    }

    /// Opt-in remux request. Never changes persisted quality settings or normal tuning.
    /// The caller must inspect the decision before replacing the current player.
    static func preservationRetryURL(from startURL: URL, audioStreamID: Int? = nil,
                                     convertSurroundAudio: Bool = false) -> URL? {
        guard let remux = dolbyVisionRemuxURL(from: startURL, convertSurroundAudio: convertSurroundAudio),
              var components = URLComponents(url: remux, resolvingAgainstBaseURL: false) else { return nil }
        var overrides = ["directPlay": "0", "directStream": "1", "directStreamAudio": "1",
                         "maxVideoBitrate": String(LocalPlexOriginalQuality.requestCeilingKbps), "videoResolution": "3840x2160",
                         "videoQuality": "100", "autoAdjustQuality": "0"]
        if let audioStreamID { overrides["audioStreamID"] = String(audioStreamID) }
        components.queryItems = (components.queryItems ?? []).filter { overrides[$0.name] == nil }
            + overrides.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    /// Fail closed: an accepted decision is not enough; require exactly one copied HEVC
    /// video stream in fMP4. Malformed/partial responses never authorize a player swap.
    static func decisionPreservesOriginalVideo(_ data: Data, requireAudioCopy: Bool = false,
                                               requireAC3Conversion: Bool = false) -> Bool {
        final class Reader: NSObject, XMLParserDelegate {
            var videos: [(String, String)] = []
            var containers: [String] = []
            var audio: [[String: String]] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                if name == "Stream", attributes["streamType"] == "2" { audio.append(attributes) }
                if name == "Part" { containers.append(attributes["container"] ?? "") }
                if name == "Stream", attributes["streamType"] == "1" {
                    videos.append((attributes["codec"] ?? "", attributes["decision"] ?? ""))
                }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.videos.count == 1, reader.containers.count == 1 else { return false }
        if requireAudioCopy && requireAC3Conversion { return false }
        if requireAC3Conversion {
            guard reader.audio.count == 1, let a = reader.audio.first,
                  a["codec"] == "ac3", a["decision"] == "transcode", a["channels"] == "6" else { return false }
        }
        if requireAudioCopy {
            guard reader.audio.count == 1, let a = reader.audio.first,
                  a["codec"] == "eac3", a["decision"] == "copy", a["channels"] == "6" else { return false }
        }
        return reader.videos[0].0 == "hevc" && reader.videos[0].1 == "copy"
            && ["mp4", "fmp4"].contains(reader.containers[0])
    }

    /// The `decision` call Plex's own players make before `start.m3u8`, with the same
    /// session and query. Without it the server answers `start.m3u8` with 400 (surfaced as
    /// "resource unavailable") whenever it is not idle, which on a channel-flipping app is
    /// nearly always. Measured against a real server: plain start 400 on three fresh
    /// clients in a row, decision-then-start 200 every time, including right after a stop.
    /// Never throws: a failed decision still falls through to start.m3u8.
    @discardableResult
    func prepareTranscodeSession(startURL: URL) async -> TranscodeDecision {
        guard let decisionURL = Self.decisionURL(from: startURL) else { return .unknown }
        var request = URLRequest(url: decisionURL)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            let code = Self.attribute("transcodeDecisionCode", in: body) ?? Self.attribute("generalDecisionCode", in: body) ?? "?"
            let text = Self.attribute("transcodeDecisionText", in: body) ?? Self.attribute("generalDecisionText", in: body) ?? ""
            print("[Plex90] DECISION: HTTP \(status) code=\(code) \(text)")
            return TranscodeDecision(code: code, text: text, preservesOriginalVideo: (200..<300).contains(status) && Self.decisionPreservesOriginalVideo(data), preservesOriginalAudio: (200..<300).contains(status) && Self.decisionPreservesOriginalVideo(data, requireAudioCopy: true),
                convertsAudioToAC3Surround: (200..<300).contains(status) && Self.decisionPreservesOriginalVideo(data, requireAC3Conversion: true))
        } catch {
            print("[Plex90] DECISION: failed (\(error.localizedDescription)), starting anyway")
            return .unknown
        }
    }

    static func decisionURL(from startURL: URL) -> URL? {
        guard var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/start.m3u8") else { return nil }
        components.path = String(components.path.dropLast("start.m3u8".count)) + "decision"
        return components.url
    }

    private static func attribute(_ name: String, in xml: String) -> String? {
        guard let range = xml.range(of: "\(name)=\"") else { return nil }
        let rest = xml[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// 1080p / 12 Mbps forces the server to re-encode, which is the point: the first attempt
    /// copied video the device could not render.
    func cappedTranscodeURL(for item: PlexMediaItem, offsetSeconds: Int, sessionID: String) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/video/:/transcode/universal/start.m3u8") else { return nil }
        components.queryItems = Self.transcodeQueryItems(
            for: item, sessionID: sessionID, offsetSeconds: max(0, offsetSeconds), isLocal: isLikelyLocalServer,
            quality: .high, token: token, clientID: clientID, hevcCapable: false)
        return components.url
    }

    func stopTranscode(playSessionId: String?) async {
        guard let sessionID = playSessionId, !sessionID.isEmpty else { return }
        guard var components = URLComponents(string: "\(serverURL)/video/:/transcode/universal/stop") else { return }
        components.queryItems = [.init(name: "session", value: sessionID), .init(name: "X-Plex-Token", value: token)]
        guard let url = components.url else { return }
        _ = try? await Self.session.data(for: URLRequest(url: url))
    }

    /// Convenience — tries direct play first, falls back to transcode.
    func buildStreamURL(for item: PlexMediaItem) -> URL? {
        buildDirectPlayURL(for: item) ?? buildTranscodeURL(for: item)
    }

    // NOTE: Plex transcode-session cleanup is intentionally left to Plex's own handling
    // (inactivity timeout + implicit replace when a new transcode starts). An explicit
    // /transcode/universal/stop keyed off a shared client-id session risked a stop-then-start
    // race that could tear down a freshly-started transcode on rapid channel changes. Revisit
    // with a per-load session id if Plex sessions are observed piling up in practice.
    // (MediaBackend's default no-op stopTranscode applies.)

    /// Returns an image URL for Plex server-side thumbnail transcoding
    func thumbnailURL(for item: PlexMediaItem, width: Int = 400) -> URL? {
        guard let thumb = item.thumb,
              var components = URLComponents(string: "\(serverURL)/photo/:/transcode") else { return nil }
        components.queryItems = [
            .init(name: "url", value: thumb),
            .init(name: "width", value: "\(width)"),
            .init(name: "height", value: "\(width * 3 / 2)"),
            .init(name: "X-Plex-Token", value: token),
        ]
        return components.url
    }

    // MARK: - PIN Auth

    static func requestPIN() async throws -> (id: Int, code: String) {
        guard var components = URLComponents(string: "https://plex.tv/api/v2/pins") else {
            throw APIError.invalidResponse
        }
        components.queryItems = []
        guard let url = components.url else { throw APIError.invalidResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        pinHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 201 else { throw APIError.httpFailure(statusCode: http.statusCode) }
        let decoded = try JSONDecoder().decode(PINResponse.self, from: data)
        return (decoded.id, decoded.code)
    }

    static func checkPIN(id: Int) async throws -> String? {
        guard let url = URL(string: "https://plex.tv/api/v2/pins/\(id)") else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        pinHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, _) = try await Self.session.data(for: req)
        let decoded = try JSONDecoder().decode(PINStatusResponse.self, from: data)
        return decoded.authToken
    }

    /// Result of a discovery pass: the servers we could reach, plus how many servers the
    /// account has at all (so callers can tell "no server" from "server found, unreachable").
    struct DiscoveryResult: Sendable {
        let reachable: [DiscoveredServer]
        let totalServers: Int
        /// How many of the account's servers the user actually owns. Zero with
        /// `totalServers > 0` means the account only has access to *shared* libraries —
        /// the unreachable-server advice ("enable Remote Access") doesn't apply to them.
        let ownedServers: Int
    }

    /// A Plex server the account can reach, with the best connection URI we could verify.
    struct DiscoveredServer: Identifiable, Hashable, Sendable {
        let machineIdentifier: String
        let name: String
        let bestReachableURI: String
        let owned: Bool
        /// Token to use for this specific server (account token for owned servers,
        /// the share-specific access token for servers owned by someone else).
        let token: String
        var id: String { machineIdentifier }
    }

    /// Best connection for a single server. Probes every connection concurrently and
    /// returns the highest-priority reachable one (local → remote HTTPS → remote HTTP →
    /// relay). Concurrent so one unreachable/slow connection can't stall the whole login —
    /// total time is bounded by the slowest single probe, not the sum of all of them.
    private static func bestReachableURI(for server: PlexResource, token: String) async -> String? {
        let ordered: [PlexConnection] =
            server.connections.filter { $0.local && !$0.relay }
            + server.connections.filter { !$0.local && !$0.relay && $0.uri.hasPrefix("https://") }
            + server.connections.filter { !$0.local && !$0.relay && !$0.uri.hasPrefix("https://") }
            + server.connections.filter { $0.relay }
        guard !ordered.isEmpty else { return nil }

        let reachableIndices = await withTaskGroup(of: Int?.self) { group -> [Int] in
            for (idx, candidate) in ordered.enumerated() {
                group.addTask {
                    // Local connections answer fast or not at all; remote/relay paths
                    // (the only paths a shared-library-only user has) are slow to
                    // establish cold, so they get a longer budget and one retry.
                    let patient = !candidate.local || candidate.relay
                    return await testReachable(uri: candidate.uri, token: token, patient: patient) ? idx : nil
                }
            }
            var hits: [Int] = []
            for await result in group {
                if let result { hits.append(result) }
            }
            return hits
        }
        guard let best = reachableIndices.min() else { return nil }
        return ordered[best].uri
    }

    /// Asks plex.tv — the account's identity authority — whether a token is still live.
    ///
    /// Deliberately separate from any call to the media server: a reverse proxy, a cold relay
    /// tunnel, or a server still waking from sleep will answer 401 while the account token is
    /// perfectly good, and only plex.tv can tell those two apart. Never throws; anything other
    /// than a clear accept/reject is reported as `.unknown` so the caller can't mistake a
    /// network problem for a dead session.
    static func validateAccountToken(_ token: String) async -> TokenValidity {
        guard !token.isEmpty, let url = URL(string: "https://plex.tv/api/v2/user") else {
            return .unknown
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        var headers = pinHeaders
        headers["X-Plex-Token"] = token
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        do {
            let (_, response) = try await Self.session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            switch http.statusCode {
            case 200...299: return .valid
            case 401, 403:  return .invalid
            default:        return .unknown
            }
        } catch {
            print("[Plex90] TOKEN CHECK: plex.tv unreachable (\(error.localizedDescription)) — validity unknown")
            return .unknown
        }
    }

    /// Discovers reachable Plex servers (owned first) and reports the total server count
    /// on the account. Empty `reachable` with `totalServers == 0` means no server exists;
    /// empty `reachable` with `totalServers > 0` means servers exist but none were reachable.
    /// Throws only on a transport failure. Servers are probed concurrently so total time is
    /// bounded by the slowest single server rather than the sum across all of them.
    static func discoverServers(token: String) async throws -> DiscoveryResult {
        guard var components = URLComponents(string: "https://plex.tv/api/v2/resources") else {
            throw APIError.invalidResponse
        }
        components.queryItems = [
            .init(name: "includeHttps", value: "1"),
            .init(name: "includeRelay", value: "1"),
        ]
        guard let url = components.url else { throw APIError.invalidResponse }

        var req = URLRequest(url: url)
        var headers = pinHeaders
        headers["X-Plex-Token"] = token
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, _) = try await Self.session.data(for: req)
        let resources = try JSONDecoder().decode([PlexResource].self, from: PlexUTF8Repair.prepared(data, context: "plex.tv /api/v2/resources"))
        let servers = resources.filter { $0.provides.contains("server") }

        let discovered = await withTaskGroup(of: DiscoveredServer?.self) { group -> [DiscoveredServer] in
            for server in servers {
                group.addTask {
                    // Shared servers reject the account token; use their per-server access token.
                    let serverToken = server.accessToken ?? token
                    guard let uri = await bestReachableURI(for: server, token: serverToken) else {
                        print("[Plex90] DISCOVERY: '\(server.name ?? server.clientIdentifier ?? "?")' unreachable")
                        return nil
                    }
                    print("[Plex90] DISCOVERY: '\(server.name ?? "?")' -> \(uri) (owned=\(server.owned ?? false))")
                    return DiscoveredServer(
                        machineIdentifier: server.clientIdentifier ?? uri,
                        name: server.name ?? "Plex Server",
                        bestReachableURI: uri,
                        owned: server.owned ?? false,
                        token: serverToken
                    )
                }
            }
            var result: [DiscoveredServer] = []
            for await server in group {
                if let server { result.append(server) }
            }
            return result
        }

        let reachable = discovered.sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) }
        let ownedServers = servers.filter { $0.owned ?? false }.count
        return DiscoveryResult(reachable: reachable, totalServers: servers.count, ownedServers: ownedServers)
    }

    /// Tests a Plex connection URI by hitting `/identity` AND an authenticated endpoint
    /// (`/library/sections`) with a short timeout each.
    ///
    /// `/identity` alone is insufficient: it's unauthenticated, so it returns 200 even if the
    /// token will later be rejected by the real server. Validating the token here prevents
    /// "discovery succeeded but loadLibrary 401s" — the exact pattern that surfaces as a
    /// misleading "Session expired" message on a brand-new login (App Store rejection cause).
    ///
    /// `patient` connections (remote-direct and relay) get a longer timeout and one retry —
    /// cold relay tunnels through plex.tv routinely take 10–20s to establish, and relay is
    /// often the ONLY path for a user who only has access to a shared remote library. Local
    /// connections stay snappy: on a LAN they answer fast, and waiting on a dead LAN IP only
    /// slows login.
    private static func testReachable(uri: String, token: String, patient: Bool) async -> Bool {
        let timeout: TimeInterval = patient ? 25 : 12
        let attempts = patient ? 2 : 1
        for attempt in 0..<attempts {
            // Step 1: identity probe — server is reachable at all
            guard await probe(uri: "\(uri)/identity", token: token, requireAuth: false, timeout: timeout) else {
                if attempt < attempts - 1 { continue }
                return false
            }
            // Step 2: authenticated probe — the token actually works on this connection
            return await probe(uri: "\(uri)/library/sections", token: token, requireAuth: true, timeout: timeout)
        }
        return false
    }

    /// One HTTP GET with timeout. `requireAuth=true` requires a 2xx response and rejects 401/403.
    private static func probe(uri: String, token: String, requireAuth: Bool, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: uri) else { return false }
        var req = URLRequest(url: url)
        // Probes run concurrently across servers and connections, so a generous timeout no
        // longer stacks — total discovery time is bounded by the single slowest server.
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        do {
            let (_, response) = try await Self.session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            if requireAuth {
                return (200...299).contains(http.statusCode)
            }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    private static var pinHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": "Nostalgex",
            "X-Plex-Platform": "tvOS",
            "X-Plex-Device": "Apple TV",
            "X-Plex-Device-Name": "Nostalgex",
        ]
    }

    // MARK: - Session reporting (Now Playing + Scrobble)

    /// Builds the Continue Watching cleanup and scrobble requests. Shares this service's
    /// server, token and transport.
    var watchStateGuard: PlexWatchStateGuard {
        PlexWatchStateGuard(serverURL: serverURL, headers: baseHeaders, transport: reportTransport)
    }

    /// Position-free Now Playing report (from PR #18, w6trp). No `time` or `duration`, so
    /// Plex lists the session in Now Playing at offset 0 and writes no resume point: the
    /// item never reaches Continue Watching. `stopped` takes it out of Now Playing. Both
    /// measured on a real server 2026-10-13. Kept separate from the scrobble so no default
    /// can add a position to it.
    func heartbeatRequest(ratingKey: String, state: String, sessionID: String) -> URLRequest? {
        guard ["playing", "paused", "buffering", "stopped"].contains(state),
              !ratingKey.isEmpty, ratingKey.allSatisfy(\.isNumber), !sessionID.isEmpty,
              var components = URLComponents(string: serverURL + "/:/timeline") else { return nil }
        components.queryItems = [
            .init(name: "ratingKey", value: ratingKey),
            .init(name: "key", value: "/library/metadata/\(ratingKey)"),
            .init(name: "state", value: state)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        baseHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        return request
    }

    /// True when Plex answered 2xx. A failure only slows the next pulses (`PulseBackoff`).
    @discardableResult
    func reportHeartbeat(ratingKey: String, state: String, sessionID: String) async -> Bool {
        guard let request = heartbeatRequest(ratingKey: ratingKey, state: state, sessionID: sessionID),
              let status = await reportTransport.send(request)?.status else { return false }
        return (200..<300).contains(status)
    }

    /// Mark an item as watched in Plex (scrobble). Fires once per session when the hybrid
    /// watch rule passes (entry gate ≤ 15% + active time ≥ 75% of runtime).
    func scrobble(ratingKey: String) async {
        guard let req = watchStateGuard.scrobbleRequest(ratingKey: ratingKey) else { return }
        if let status = await reportTransport.send(req)?.status {
            print("[Plex90] Scrobble \(ratingKey): HTTP \(status)")
        } else {
            print("[Plex90] Scrobble \(ratingKey) failed silently")
        }
    }

    // MARK: - Error

    enum APIError: Error, Equatable {
        case unauthorized
        case invalidResponse
        /// plex.tv listed servers, but none of them passed reachability + token validation
        /// within the timeout. Distinct from `.unauthorized` so the UI can show an accurate
        /// "couldn't reach any server" message instead of "session expired".
        case noReachableServer
        /// Non-2xx from Plex or an intermediate proxy (body is often HTML).
        case httpFailure(statusCode: Int)
        /// Plex usually returns JSON; `<` typically means HTML error page or `<?xml` from Plex XML mode.
        case receivedMarkupInsteadOfJSON(statusCode: Int)
    }
}

// MARK: - Response body sniffing

private extension Data {
    /// First non-whitespace UTF-8 byte is `<` (HTML, XML, SGML-ish error pages).
    func looksLikeMarkupOrNonJSONPayload() -> Bool {
        for byte in self {
            if byte == 9 || byte == 10 || byte == 13 || byte == 32 { continue }
            return byte == UInt8(ascii: "<")
        }
        return false
    }
}

// MARK: - PIN auth models

private struct PINResponse: Decodable {
    let id: Int
    let code: String
}

private struct PINStatusResponse: Decodable {
    let authToken: String?
}

private struct PlexResource: Decodable {
    let name: String?
    let clientIdentifier: String?
    let owned: Bool?
    /// Per-server access token. For servers you don't own this differs from the account
    /// token and is REQUIRED — the account token is rejected by other people's servers.
    let accessToken: String?
    let provides: String
    let connections: [PlexConnection]
}

private struct PlexConnection: Decodable {
    let uri: String
    let local: Bool
    let relay: Bool
}

// MARK: - Decodable response models

private struct IdentityResponse: Decodable {
    let MediaContainer: Container
    struct Container: Decodable { let friendlyName: String? }
}

private struct SectionsResponse: Decodable {
    let MediaContainer: Container
    struct Container: Decodable { let Directory: [PlexSection]? }
}

struct PlexSection: Decodable {
    let key: String
    let title: String
    let type: String
    var scannedAt: Int? = nil
    var updatedAt: Int? = nil
    var contentChangedAt: Int? = nil
}

private struct SectionItemsResponse: Decodable {
    let MediaContainer: Container
    struct Container: Decodable {
        /// Total items in the section across all pages (Plex sets this on paged
        /// responses). Absent on endpoints that don't paginate (e.g. `/allLeaves`).
        let totalSize: Int?
        let Metadata: [PlexRawItem]?

        private enum CodingKeys: String, CodingKey { case totalSize, Metadata }

        /// An item that fails to decode is skipped and logged; the page still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalSize = try c.decodeIfPresent(Int.self, forKey: .totalSize)
            Metadata = try c.decodeIfPresent([PlexSkippableItem<PlexRawItem>].self, forKey: .Metadata)?.compactMap(\.value)
        }
    }
}

private struct CollectionsResponse: Decodable {
    let MediaContainer: Container
    struct Container: Decodable { let Metadata: [PlexCollection]? }
}

struct PlexCollection: Decodable {
    let ratingKey: String
    let title: String
    let childCount: Int?
    let thumb: String?
}

struct PlexRawItem: Decodable {
    let ratingKey: String
    let title: String
    let parentTitle: String?
    let grandparentTitle: String?
    let originalTitle: String?
    let summary: String?
    let year: Int?
    let originallyAvailableAt: String?
    let contentRating: String?
    let duration: Int?
    let rating: Double?
    let userRating: Double?
    let thumb: String?
    let art: String?
    let viewCount: Int?
    let addedAt: Int?
    let studio: String?
    let Genre: [Tagged]?
    let Director: [Tagged]?
    let Media: [PlexMedia]?
    let Guid: [GuidTag]?
    // Episode fields
    let parentIndex: Int?
    let index: Int?
    /// Rating key of the episode's show. Present on episode payloads returned by the
    /// bulk section sweep (`type=4`), which is how those episodes are joined back to
    /// their show's metadata (genres, studio, GUIDs) — none of which rides along on
    /// the episode itself.
    let grandparentRatingKey: String?

    struct Tagged: Decodable { let tag: String }
    struct GuidTag: Decodable { let id: String }

    /// Extract TMDB ID from Plex GUIDs (format: "tmdb://12345")
    var tmdbID: String? {
        Guid?.first(where: { $0.id.hasPrefix("tmdb://") })
            .map { String($0.id.dropFirst("tmdb://".count)) }
    }

    /// Extract IMDb ID from Plex GUIDs (format: "imdb://tt1234567")
    var imdbID: String? {
        Guid?.first(where: { $0.id.hasPrefix("imdb://") })
            .map { String($0.id.dropFirst("imdb://".count)) }
    }
    /// Highest-quality version: max bitrate, tie-broken on vertical resolution. Falls back to
    /// the first version when none report a bitrate, so libraries without that metadata behave
    /// exactly as before.
    var bestMediaIndex: Int? {
        guard let medias = Media, !medias.isEmpty else { return nil }
        guard medias.contains(where: { $0.bitrate != nil }) else { return 0 }
        return medias.indices.max { a, b in
            let ba = medias[a].bitrate ?? Int.min, bb = medias[b].bitrate ?? Int.min
            if ba != bb { return ba < bb }
            return PlexRawItem.resolutionHeight(medias[a].videoResolution) < PlexRawItem.resolutionHeight(medias[b].videoResolution)
        }
    }

    var bestMedia: PlexMedia? {
        guard let index = bestMediaIndex else { return nil }
        return Media?[index]
    }

    /// Vertical resolution from a "WIDTHxHEIGHT" string (or a label like "4k"); 0 if unknown.
    static func resolutionHeight(_ res: String?) -> Int {
        guard let res = res?.lowercased() else { return 0 }
        if let h = res.split(separator: "x").last.flatMap({ Int($0) }) { return h }
        if res.contains("4k") { return 2160 }
        if res.contains("1080") { return 1080 }
        if res.contains("720") { return 720 }
        return 0
    }

    struct PlexMedia: Decodable {
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let videoProfile: String?
        let videoResolution: String?
        let bitrate: Int?
        let width: Int?
        let height: Int?
        let Part: [PlexPart]?
        struct PlexPart: Decodable {
            let key: String?
            let container: String?
            let duration: Int?
            let Stream: [PlexStream]?
        }
        struct PlexStream: Decodable {
            let streamType: Int?   // 1 video, 2 audio, 3 subtitle
            let codec: String?
            let bitDepth: Int?
            let DOVIProfile: Int?
            var DOVIBLCompatID: Int? = nil
            var channels: Int? = nil
            var id: Int? = nil
            var selected: Int? = nil
            let colorTrc: String?
            let colorPrimaries: String?
            let colorSpace: String?
            var hasHDR10ColorMetadata: Bool {
                colorTrc == "smpte2084" && colorPrimaries == "bt2020" && colorSpace == "bt2020nc"
            }
            private enum CodingKeys: String, CodingKey {
                case streamType, codec, bitDepth, DOVIProfile, DOVIBLCompatID, channels, id, selected
                case colorTrc, colorPrimaries, colorSpace
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                streamType = try c.decodeIfPresent(Int.self, forKey: .streamType)
                codec = try c.decodeIfPresent(String.self, forKey: .codec)
                bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth)
                DOVIProfile = try c.decodeIfPresent(Int.self, forKey: .DOVIProfile)
                DOVIBLCompatID = try c.decodeIfPresent(Int.self, forKey: .DOVIBLCompatID)
                colorTrc = try c.decodeIfPresent(String.self, forKey: .colorTrc)
                colorPrimaries = try c.decodeIfPresent(String.self, forKey: .colorPrimaries)
                colorSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace)
                channels = try c.decodeIfPresent(Int.self, forKey: .channels)
                id = try c.decodeIfPresent(Int.self, forKey: .id)
                selected = (try? c.decode(Bool.self, forKey: .selected)).map { $0 ? 1 : 0 }
                    ?? (try? c.decode(Int.self, forKey: .selected))
            }
        }
        var playbackParts: [PlexPartPlaybackInfo] {
            (Part ?? []).compactMap { part in
                guard let key = part.key else { return nil }
                let video = part.Stream?.first { $0.streamType == 1 }
                let audio = part.Stream?.first { $0.streamType == 2 && $0.selected == 1 }
                    ?? part.Stream?.first { $0.streamType == 2 }
                return PlexPartPlaybackInfo(key: key, container: part.container ?? container,
                    videoCodec: video?.codec ?? videoCodec, audioCodec: audio?.codec ?? audioCodec,
                    bitDepth: video?.bitDepth, doviProfile: video?.DOVIProfile,
                    durationSeconds: part.duration.map { Double($0) / 1000 },
                    audioChannelCount: audio?.channels, doviCompatibilityID: video?.DOVIBLCompatID, audioStreamID: audio?.id, hasHDR10ColorMetadata: video?.hasHDR10ColorMetadata)
            }
        }
        var audioStream: PlexStream? {
            Part?.first?.Stream?.first { $0.streamType == 2 && $0.selected == 1 }
                ?? Part?.first?.Stream?.first { $0.streamType == 2 }
        }
        var videoStream: PlexStream? {
            Part?.first?.Stream?.first { $0.streamType == 1 }
        }
    }
}

