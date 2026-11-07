import Foundation

/// One line a tester can read off the screen and send back.
///
/// A Jellyfin user reported 349 movies and 2,252 episodes on his server producing a
/// single channel. Ruling that out took days, because nothing in the app ever said how
/// much of his library it actually held — and no rules failure explains it. Stripping
/// every metadata field from a library that size still builds eleven channels, so a
/// lineup of one means the items never arrived. That is a different bug in a different
/// place, and the count is what tells the two apart in one screenshot.
enum LibraryDiagnostics {

    static func summary(_ items: [PlexMediaItem]) -> String {
        guard !items.isEmpty else { return "No titles loaded. The scan came back empty." }
        let movies = items.filter { $0.type == .movie }.count
        let episodes = items.filter { $0.type == .episode }.count
        let shows = Set(items.filter { $0.type == .episode }.map(\.title)).count
        let tmdb = items.filter { $0.tmdbID != nil }.count
        let genres = items.filter { !$0.genres.isEmpty }.count

        var parts = ["\(fmt(items.count)) titles"]
        if movies > 0 { parts.append("\(fmt(movies)) movies") }
        if episodes > 0 { parts.append("\(fmt(episodes)) episodes from \(fmt(shows)) shows") }
        parts.append("\(pct(genres, items.count))% with genres")
        parts.append("\(pct(tmdb, items.count))% matched to TMDB")
        return parts.joined(separator: " · ")
    }

    /// How many distinct titles the given channels hold between them: every item that is in
    /// at least one channel's pool, counted once however many channels take it. Pools hold
    /// the library's own items, so an item is told apart by its id.
    nonisolated static func titlesOnChannels(in channels: [Channel]) -> Int {
        var seen = Set<String>()
        seen.reserveCapacity(channels.reduce(0) { max($0, $1.itemPool.count) })
        for channel in channels {
            for item in channel.itemPool { seen.insert(item.id) }
        }
        return seen.count
    }

    /// The three kinds of title the library holds, as the summary line tells them apart.
    enum Kind: String, CaseIterable, Sendable {
        case movie, episode, musicVideo

        init(_ item: PlexMediaItem) {
            if item.type == .episode { self = .episode }
            else if item.librarySource == .musicVideo { self = .musicVideo }
            else { self = .movie }
        }

        var label: String {
            switch self {
            case .movie: return "MOVIES"
            case .episode: return "EPISODES"
            case .musicVideo: return "MUSIC VIDEOS"
            }
        }
    }

    /// Where the loaded titles land, with every package switched on.
    ///
    /// A title is **on a channel** when it is in the pool of at least one channel that would
    /// show if its package were on: a static channel whose pool reaches its `minItems`, or a
    /// collection or franchise channel the app has built. Whether that channel's package is
    /// on right now does not matter. A title on none is **on no channel**: nothing in
    /// channels.json takes it, so switching packages on would not bring it back.
    struct Coverage: Equatable, Sendable {
        var loaded: [Kind: Int] = [:]
        var onChannels: [Kind: Int] = [:]
        /// The first few titles on no channel, by title, with the fields the rules read.
        var orphanSample: [PlexMediaItem] = []

        var totalLoaded: Int { loaded.values.reduce(0, +) }
        var totalOnChannels: Int { onChannels.values.reduce(0, +) }
        var totalOnNoChannel: Int { totalLoaded - totalOnChannels }
        func orphans(_ kind: Kind) -> Int { (loaded[kind] ?? 0) - (onChannels[kind] ?? 0) }
    }

    /// Runs every static channel's rules over the library (the same `filterItems` the guide
    /// is built with) and counts what lands. `cache` is the library as `makeFilterCache`
    /// reads it; `dynamicPools` are the pools of the collection and franchise channels
    /// already built. Pure, so it runs off the main actor and a test can drive it.
    nonisolated static func coverage(
        items: [PlexMediaItem],
        cache: [AppState.FilterCache],
        staticChannels: [Channel],
        dynamicPools: [[PlexMediaItem]],
        memberships: ChannelMemberships,
        exclusiveRules: [ExclusiveRule],
        sampleSize: Int = 25
    ) -> Coverage {
        var covered = Set<String>()
        covered.reserveCapacity(items.count)
        for channel in staticChannels where channel.rules != nil {
            let pool = AppState.filterItems(cache, rules: channel.rules, forChannelID: channel.id,
                                            category: channel.category, memberships: memberships,
                                            exclusiveRules: exclusiveRules)
            guard pool.count >= channel.minItems else { continue }
            for item in pool { covered.insert(item.id) }
        }
        for pool in dynamicPools { for item in pool { covered.insert(item.id) } }

        var result = Coverage()
        var orphans: [PlexMediaItem] = []
        for item in items {
            let kind = Kind(item)
            result.loaded[kind, default: 0] += 1
            if covered.contains(item.id) {
                result.onChannels[kind, default: 0] += 1
            } else {
                orphans.append(item)
            }
        }
        result.orphanSample = Array(orphans.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(sampleSize))
        return result
    }

    /// One log line for the titles on no channel, so a support report can show why: the first
    /// few, each with the fields the channel rules read (year, rating, genres, studio, whether
    /// it has a TMDB id and a runtime).
    static func orphanReport(_ coverage: Coverage, onEnabledChannels: Int?) -> String {
        let counts = Kind.allCases.map { kind in
            "\(kind.rawValue) \((coverage.onChannels[kind] ?? 0))/\((coverage.loaded[kind] ?? 0))"
        }.joined(separator: ", ")
        var line = "COVERAGE: \(coverage.totalOnChannels) of \(coverage.totalLoaded) on a channel with every package on, "
            + "\(coverage.totalOnNoChannel) on none; \(onEnabledChannels.map(String.init) ?? "?") on the channels in the guide now (\(counts))"
        guard !coverage.orphanSample.isEmpty else { return line }
        let rows = coverage.orphanSample.map { item -> String in
            let year = item.year.map(String.init) ?? "no year"
            let rating = item.rating > 0 ? String(format: "%.1f", item.rating) : "no rating"
            let genres = item.genres.isEmpty ? "no genre" : item.genres.joined(separator: "|")
            let studio = item.studio ?? "no studio"
            let cert = item.contentRating ?? "unrated"
            let tmdb = item.tmdbID == nil ? "no TMDB" : "TMDB"
            let name = item.type == .episode ? "\(item.title) \(item.seTag ?? "")" : item.title
            return "\"\(name)\" (\(year), \(cert), \(rating), \(genres), \(studio), \(item.duration)m, \(tmdb))"
        }
        line += ". Not on any channel (first \(rows.count)): " + rows.joined(separator: "; ")
        return line
    }

    /// The line under the library summary in RESCAN LIBRARY:
    ///
    ///     1,788 OF 1,792 ON CHANNELS · 4 ON NO CHANNEL · 12 SKIPPED (NO RUNTIME)
    ///
    /// "ON CHANNELS" counts the loaded titles that sit on a channel with every package on;
    /// "ON NO CHANNEL" the ones that sit on none, split by kind when more than one kind has
    /// some, and left out at zero; "SKIPPED (NO RUNTIME)" the movies and episodes the scan
    /// dropped for having no runtime, left out at zero. The first two wait until counted.
    /// Nil when there is nothing to say.
    static func coverageLine(_ coverage: Coverage?, skippedNoRuntime: Int) -> String? {
        var parts: [String] = []
        if let coverage, coverage.totalLoaded > 0 {
            parts.append("\(fmt(coverage.totalOnChannels)) OF \(fmt(coverage.totalLoaded)) ON CHANNELS")
            if coverage.totalOnNoChannel > 0 {
                var orphans = "\(fmt(coverage.totalOnNoChannel)) ON NO CHANNEL"
                let byKind = Kind.allCases.compactMap { kind -> String? in
                    let n = coverage.orphans(kind)
                    return n > 0 ? "\(fmt(n)) \(kind.label)" : nil
                }
                if byKind.count > 1 { orphans += " (\(byKind.joined(separator: ", ")))" }
                parts.append(orphans)
            }
        }
        if skippedNoRuntime > 0 {
            parts.append("\(fmt(skippedNoRuntime)) SKIPPED (NO RUNTIME)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Percentages read better than raw counts for the metadata coverage, and 0% is the
    /// signal worth spotting — it means the server has the files but never scraped them.
    static func pct(_ n: Int, _ total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(n) / Double(total) * 100).rounded())
    }

    static func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
