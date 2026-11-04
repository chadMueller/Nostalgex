import Foundation

/// Which titles are worth an OMDb lookup, and how many.
///
/// OMDb's free tier is 1,000 requests a day for the relay as a whole, so every Apple TV
/// and browser shares it. The only thing OMDb feeds is the IMDb-gated channels
/// (FOREIGN FILMS, CULT CLASSICS: any channel with an imdb/RT/Metacritic/Oscar rule),
/// so a title is only looked up when it could land on one of them: same media type and
/// at least one of that channel's keywords or genres. Everything else would fail the
/// channel's content rule no matter what IMDb says.
///
/// Mirrored on the web in `scripts/nostalgex-enrichment.js` (`omdbGates`,
/// `isOMDbCandidate`, `pickOMDbLookups`, the UTC-midnight backoff).
struct OMDBGate: Equatable {
    /// "movie" or "tv" (the MediaEnrichment media type); nil when the channel takes both.
    let mediaType: String?
    /// Lowercased TMDB keywords from the channel's `keywords` and `keywordsRequireAll`.
    let keywords: Set<String>
    /// Lowercased `genres.include`, matched as substrings the way the channel filter does.
    let genres: [String]

    static func needsOMDb(_ rules: ChannelRules) -> Bool {
        rules.imdbRatingMin != nil || rules.imdbVotesMin != nil
            || rules.rtScoreMin != nil || rules.metacriticMin != nil || rules.wonOscar
    }

    /// One gate per OMDb-gated channel in the config.
    static func gates(from rules: [ChannelRules]) -> [OMDBGate] {
        rules.filter(needsOMDb).map { r in
            let mediaType: String?
            switch r.type {
            case .movie: mediaType = "movie"
            case .episode: mediaType = "tv"
            case nil: mediaType = nil
            }
            let kw = (r.keywords ?? []) + (r.keywordsRequireAll ?? [])
            return OMDBGate(
                mediaType: mediaType,
                keywords: Set(kw.map { $0.lowercased() }),
                genres: (r.genres?.include ?? []).map { $0.lowercased() }
            )
        }
    }

    /// Gates from the bundled channels.json, for callers that have no loaded config.
    static func bundledGates() -> [OMDBGate] {
        gates(from: ChannelConfigLoader.loadBundled().channels.compactMap(\.rules))
    }

    func admits(mediaType: String, keywords: [String], genres: [String]) -> Bool {
        if let want = self.mediaType, want != mediaType { return false }
        // A gated channel with no content rule takes any title of its type.
        if self.keywords.isEmpty && self.genres.isEmpty { return true }
        if keywords.contains(where: { self.keywords.contains($0.lowercased()) }) { return true }
        let lowered = genres.map { $0.lowercased() }
        return self.genres.contains { g in lowered.contains { $0.contains(g) } }
    }
}

enum OMDBQuota {
    /// Lookups one library load may spend. A library with thousands of candidate titles
    /// fills in over several loads (and across every device sharing the cache) instead of
    /// one Apple TV draining the day's quota.
    static let perLoadLimit = 50

    /// True when any gate admits the title. `genres` is TMDB genres plus the server's.
    static func isCandidate(mediaType: String, keywords: [String], genres: [String], gates: [OMDBGate]) -> Bool {
        gates.contains { $0.admits(mediaType: mediaType, keywords: keywords, genres: genres) }
    }

    /// At most `limit` items in random order, so repeated loads of the same library walk
    /// through different titles rather than retrying the same first fifty.
    static func pick<T>(_ items: [T], limit: Int = perLoadLimit) -> [T] {
        var rng = SystemRandomNumberGenerator()
        return pick(items, limit: limit, using: &rng)
    }

    static func pick<T, R: RandomNumberGenerator>(_ items: [T], limit: Int, using rng: inout R) -> [T] {
        guard limit > 0 else { return [] }
        return Array(items.shuffled(using: &rng).prefix(limit))
    }

    /// OMDb's daily quota resets at midnight UTC.
    static func nextUTCMidnight(after date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: startOfDay)!
    }
}

/// After OMDb says the day's quota is gone (a 429 from the relay, or its "Request limit
/// reached!"), this device stops asking until the next UTC midnight. Asking again
/// sooner only burns requests that fail.
struct OMDBBackoff {
    static let defaultsKey = "omdbBlockedUntil"
    let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
    }

    var blockedUntil: Date? {
        defaults.object(forKey: Self.defaultsKey) as? Date
    }

    func isBlocked(now: Date = Date()) -> Bool {
        guard let until = blockedUntil else { return false }
        return now < until
    }

    func markRateLimited(now: Date = Date()) {
        defaults.set(OMDBQuota.nextUTCMidnight(after: now), forKey: Self.defaultsKey)
    }
}
