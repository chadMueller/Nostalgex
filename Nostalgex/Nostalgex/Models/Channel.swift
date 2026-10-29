import Foundation
import SwiftUI

/// Keeps config-defined channels and runtime-created ones out of each other's way.
///
/// They used to share one small range: discovered collections were handed 220, 240 and 300
/// with fifty slots each, and `materializeCollectionChannels` cleared "everything from 220
/// up" before rebuilding. Any channel in channels.json at or above 220 was deleted and its
/// id handed to a Plex collection — HISTORY & BIO at 224 came back as Toy Story. The two
/// category ranges also overlapped each other at 240-269.
///
/// Static ids now stay below `dynamicBase` and runtime ids above it, so the lineup can grow
/// without ever reaching the collection space. `ChannelIDSpaceTests` fails the build if a
/// channels.json entry crosses the line.
enum ChannelIDSpace {
    /// Everything at or above this is created at runtime, never from channels.json.
    static let dynamicBase = 1_000_000
    /// Per-category room. Far more than any library produces, and no longer overlapping.
    static let categoryStride = 10_000

    static func isDynamic(_ id: Int) -> Bool { id >= dynamicBase }
    static func isStatic(_ id: Int) -> Bool { !isDynamic(id) }
}

// MARK: - Collection categories (auto-classified during scan)

/// NOTABLE STARS (`actors`) was removed with the franchise bundle: actor and director
/// sets now land in OTHER COLLECTIONS. A persisted `collections-actors` bundle id is
/// migrated by `AppState.migrateCollectionBundleIDs`, and a snapshot row whose category
/// reads "actors" resolves to `.custom` (see `StoredDiscoveredCollection.resolve`).
enum CollectionCategory: String, CaseIterable {
    case franchises, custom

    var displayName: String {
        switch self {
        case .franchises: return "FRANCHISES"
        case .custom:     return "OTHER COLLECTIONS"
        }
    }

    var bundleID: String { "collections-\(rawValue)" }

    var bundleDescription: String {
        switch self {
        case .franchises: return "Movie series and sequel collections"
        case .custom:     return "Actors, directors and your own themed sets"
        }
    }

    /// The block of ids and display numbers this category's channels use.
    var block: DynamicChannelBlock {
        switch self {
        case .franchises: return .collectionFranchises
        case .custom:     return .otherCollections
        }
    }

    var idBase: Int { block.idBase }
    var displayNumberBase: Int { block.displayNumberBase }
    var displayNumberEnd: Int { block.displayNumberEnd }
    var displayCapacity: Int { block.capacity }
}

// MARK: - Runtime channel blocks

/// Ids and display numbers for every runtime-created channel. Each kind owns a fixed block,
/// so switching one kind on or off never moves another kind's numbers or ids. They used to
/// share: found franchises and server franchise collections both numbered from CH 300 on one
/// id base, collections straight after the found ones, so toggling the FRANCHISES package or
/// any found franchise renumbered (and re-id'd) every franchise collection.
///
/// The two franchise blocks fill by `keptInDisplayOrder`. OTHER COLLECTIONS keeps the rule
/// the web tuner already mirrors (A to Z, the first 200 switched on), so it is unchanged.
enum DynamicChannelBlock: String, CaseIterable, Hashable {
    /// Franchises found from TMDB data (FRANCHISES package). Libraries seen so far: 64 and 86.
    case foundFranchises
    /// The server's own franchise collections. No real library has come near 50.
    case collectionFranchises
    /// Every other server collection (actors, directors, themed sets).
    case otherCollections

    /// Stride ordinals inside `ChannelIDSpace`. 1 belonged to the retired NOTABLE STARS
    /// category (1,010,000+). Nothing stores a channel id across launches except today's
    /// schedules (rebuilt from a pool fingerprint) and the snapshot, whose runtime rows are
    /// rebuilt on restore, so a NOTABLE STARS id can't come back pointing at a new channel.
    private var ordinal: Int {
        switch self {
        case .foundFranchises:      return 0
        case .collectionFranchises: return 1
        case .otherCollections:     return 2
        }
    }

    var idBase: Int { ChannelIDSpace.dynamicBase + ordinal * ChannelIDSpace.categoryStride }

    /// Clear of everything channels.json numbers (1-140, music videos 200-213).
    var displayNumberBase: Int {
        switch self {
        case .foundFranchises:      return 300
        case .collectionFranchises: return 450
        case .otherCollections:     return 500
        }
    }

    /// Hard cap: entries past it are not built rather than spilling into the next block.
    var displayNumberEnd: Int {
        switch self {
        case .foundFranchises:      return 449
        case .collectionFranchises: return 499
        case .otherCollections:     return 699
        }
    }

    /// 150, 50 and 200.
    var capacity: Int { displayNumberEnd - displayNumberBase + 1 }

    /// The switched-on entries a block keeps, in the order they are numbered.
    ///
    /// When more are on than fit, the ones with the most films stay; ties go to the name,
    /// then the stable id, so every platform drops the same ones. The kept entries are then
    /// numbered A to Z (name, then stable id), as they always were.
    static func keptInDisplayOrder<T>(_ enabled: [T], capacity: Int,
                                      name: (T) -> String, stableID: (T) -> String,
                                      films: (T) -> Int) -> (kept: [T], skipped: Int) {
        func alphabetical(_ a: T, _ b: T) -> Bool {
            name(a) != name(b) ? name(a) < name(b) : stableID(a) < stableID(b)
        }
        guard enabled.count > capacity else {
            return (enabled.sorted(by: alphabetical), 0)
        }
        let kept = enabled.sorted { a, b in
            films(a) != films(b) ? films(a) > films(b) : alphabetical(a, b)
        }.prefix(capacity)
        return (kept.sorted(by: alphabetical), enabled.count - capacity)
    }
}

// MARK: - Discovered collections (from Plex scan)

struct DiscoveredCollection: Identifiable {
    let id: String              // ratingKey or "trilogies"
    let title: String           // e.g. "BATMAN COLLECTION"
    /// Films only. A collection of shows has 0 here and its episodes in `items`.
    let movieCount: Int
    /// Films plus the episodes of every show in the collection (see CollectionMemberIndex).
    let items: [PlexMediaItem]
    var enabled: Bool
    var matchedChannel: String? // name-similarity match to a static channel
    var contentOverlap: ContentOverlap? // content-aware: most items already claimed by another channel
    var category: CollectionCategory = .custom
    /// Set when this server collection IS a franchise the FRANCHISES bundle already
    /// carries, either a stock channel ("CH 100 STAR WARS") or a found franchise
    /// ("JOHN WICK"). A folded collection is hidden from the collections list and never
    /// materialised, so the same films are not offered twice. See FranchiseCollectionFold.
    var foldedIntoFranchise: String? = nil

    var isFoldedIntoFranchise: Bool { foldedIntoFranchise != nil }

    /// Distinct shows among the episodes. Derived rather than stored, so snapshot rows
    /// keep their shape.
    var showCount: Int { items.collectionShowCount }

    /// The row's subtitle: "12 movies" exactly as before for a films-only collection,
    /// "3 shows · 47 episodes" for shows, "2 movies · 1 show" for a mix.
    var memberSummary: String {
        Self.memberSummary(movies: movieCount, shows: showCount,
                           episodes: items.count - items.collectionMovieCount)
    }

    static func memberSummary(movies: Int, shows: Int, episodes: Int) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        guard shows > 0 else { return "\(movies) movies" }
        if movies == 0 { return "\(plural(shows, "show", "shows")) · \(plural(episodes, "episode", "episodes"))" }
        return "\(plural(movies, "movie", "movies")) · \(plural(shows, "show", "shows"))"
    }
}

/// Content-aware duplicate signal: most of a discovered Plex collection's items
/// are already claimed by an existing channel via the membership manifest.
struct ContentOverlap: Equatable {
    let channelID: Int
    let channelName: String
    let overlapCount: Int    // items in the Plex collection that the manifest claims for channelID
    let totalCount: Int      // total items in the Plex collection
    var percent: Int { totalCount > 0 ? Int((Double(overlapCount) / Double(totalCount) * 100).rounded()) : 0 }
}

// MARK: - Rule types

struct GenreRules {
    var include: [String] = []
    var requireAll: [String] = []
    var exclude: [String] = []
}

struct YearRange {
    var min: Int?
    var max: Int?
}

struct DurationRange {
    var min: Int? // minutes
    var max: Int? // minutes
}

/// A stretch of the calendar as "MM-DD" bounds, inclusive. When `from` is later than
/// `to` it wraps the new year ("11-25" to "01-10").
struct AirWindow {
    var from: String?
    var to: String?

    /// "MM-DD" -> month * 100 + day.
    static func monthDay(_ s: String?) -> Int? {
        guard let s else { return nil }
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 2, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isASCII) }),
              let m = Int(parts[0]), let d = Int(parts[1]) else { return nil }
        return m * 100 + d
    }

    /// Month * 100 + day of a "YYYY-MM-DD..." date string.
    static func monthDay(ofDate s: String?) -> Int? {
        guard let s else { return nil }
        let chars = Array(s.utf8)
        guard chars.count >= 10, chars[4] == UInt8(ascii: "-"), chars[7] == UInt8(ascii: "-"),
              chars[0..<4].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let m = Int(String(decoding: chars[5..<7], as: UTF8.self)),
              let d = Int(String(decoding: chars[8..<10], as: UTF8.self)) else { return nil }
        return m * 100 + d
    }

    /// Whether a "YYYY-MM-DD" date falls inside the window. Mirrors `inAirWindow` in
    /// scripts/nostalgex-channel-filter.cjs.
    func contains(date: String?) -> Bool {
        guard let lo = Self.monthDay(from), let hi = Self.monthDay(to),
              let md = Self.monthDay(ofDate: date) else { return false }
        return lo <= hi ? (md >= lo && md <= hi) : (md >= lo || md <= hi)
    }
}

struct BlockRatings {
    var ratings: [String]
    var blockBefore: Int? // hour 0-23
    var blockAfter: Int?  // hour 0-23
}

struct TimeRestrictions {
    var blockRatings: BlockRatings?
    var tvOnlyBefore: Int?   // hour 0-23: only show episodes before this hour
    var onlyAfterHour: Int?  // hour 0-23: channel pool is empty before this hour (prime time gate)
}

struct ChannelRules {
    var type: MediaType?
    var source: LibrarySource? // restrict pool to items from a specific library type (e.g. .musicVideo)
    var genres: GenreRules?
    var studios: [String]?
    var yearRange: YearRange?
    var contentRatings: [String]?
    var allowUnrated: Bool = false
    var ratingMin: Double?
    var durationRange: DurationRange?
    var watchedOnly: Bool = false
    var unwatchedOnly: Bool = false
    var rewatched: Bool = false // viewCount >= 3 (must match scripts/nostalgex-channel-filter.cjs)
    var titleContains: [String]? // matches if title contains any of these (case-insensitive)
    /// Episode rules read an item's OWN title (the episode title for an episode, the title
    /// for anything else) and its summary, never the show name. The only way to find a
    /// Christmas special: the show is "Friends", the festive part is "The One with the
    /// Holiday Armadillo". `titleContains` sees show names only. A channel with any of
    /// the three include lists is episode-curated: an item must match one, and nothing
    /// else widens it. Mirrors scripts/nostalgex-channel-filter.cjs.
    var episodeTitleContains: [String]?
    /// Whole words in the item's summary.
    var episodeSummaryContains: [String]?
    /// Whole words in the own title that only count for an episode first aired inside
    /// `episodeAirWindow`. Films never take this path.
    var episodeSeasonalTitleContains: [String]?
    var episodeAirWindow: AirWindow?
    /// Whole words in the own title that veto the item.
    var episodeTitleExcludes: [String]?
    /// This channel's genre tests also read the item's TMDB genres (`MediaEnrichment.tmdbGenres`).
    /// A Plex listing carries two genres per film; TMDB has them all.
    var matchTmdbGenres: Bool = false
    var titleExcludes: [String]? // excludes if title contains any of these (case-insensitive)
    var editorialOverrides: [String]? // exact title matches always included regardless of other rules
    var addedWithinDays: Int? // only items added to library within this many days
    var releasedWithinMonths: Int? // only items released within this many months of today
    // TMDB enrichment rules
    var keywords: [String]?              // match if item has ANY of these TMDB keywords
    var keywordsRequireAll: [String]?    // match if item has ALL of these TMDB keywords
    var keywordsExclude: [String]?       // exclude if item has ANY of these TMDB keywords
    var keywordsRequireAnyGenre: [String]? // when set, keyword match only counts if item also has ANY of these genres (cross-reference)
    var keywordGatedGenres: [String]?    // when genre match is to one of these, a keyword match is also required
    var networks: [String]?              // match if TV show airs on ANY of these networks
    var productionCompanies: [String]?   // match if produced by ANY of these companies
    // OMDb enrichment rules
    var imdbRatingMin: Double?           // IMDb rating threshold (authoritative vs Plex ratingMin)
    var imdbVotesMin: Int?               // Minimum IMDb vote count — filters out obscure high-rated items
    var rtScoreMin: Int?                 // Rotten Tomatoes critic score 0-100
    var metacriticMin: Int?              // Metacritic score 0-100
    var wonOscar: Bool = false           // Awards string contains "won" + "oscar" (case-insensitive)
    var manifestOnly: Bool = false       // membership comes ONLY from the TMDB manifest, no genre/title fallback (for keyword-precise channels like ANIME, CRITERION)
    var manifestOnlyGenreFallback: Bool = false // opt-in, per channel: on a manifestOnly channel, also run the normal genre/keyword content-matching block below as a second, additive claim path. Only set this when the channel's own genres/keywords/keywordGatedGenres are reviewed to be tight, this flag does not itself guard against a catch-all; the channel's rules do. STAND-UP opts in (Comedy/Documentary stay keyword-gated via keywordGatedGenres; the narrower "Stand-Up" server genre tag is specific enough to stand alone). See AppState+Channels.swift.
}

// MARK: - Channel

struct Channel: Identifiable {
    let id: Int
    let number: Int
    let name: String
    let color: Color
    let category: String?
    let rules: ChannelRules?
    let timeRestrictions: TimeRestrictions?
    let minItems: Int
    /// Whether newly added titles premiere here at prime time.
    ///
    /// Exactly one channel should carry this. A new film usually sits in several pools,
    /// and when every one of them promoted it to the evening anchor it premiered on all
    /// of them at once: Point Break, added to five channels, aired on five channels
    /// simultaneously. A premiere is an event on one channel; everywhere else the title
    /// just enters the normal rotation.
    var isPremiereChannel: Bool = false
    var itemPool: [PlexMediaItem] = []
    var enabled: Bool = true

    /// Returns itemPool filtered for current time restrictions
    func filteredPool() -> [PlexMediaItem] {
        guard let tr = timeRestrictions else { return itemPool }
        let hour = Calendar.current.component(.hour, from: Date())
        var pool = itemPool

        // Block ratings (e.g. Late Night R-rated content before 8pm)
        if let br = tr.blockRatings {
            let isBlocked = (br.blockBefore.map { hour < $0 } ?? false)
                         || (br.blockAfter.map { hour >= $0 } ?? false)
            if isBlocked {
                // A rating from another country counts as its US label: GB-18 waits for 9 PM like R.
                let filtered = pool.filter { !br.ratings.contains(ContentRating.usLabel($0.contentRating, type: $0.type) ?? "") }
                if filtered.count >= 2 { pool = filtered }
            }
        }

        // TV-only before hour (e.g. only episodes before 11 AM)
        if let tvBefore = tr.tvOnlyBefore, hour < tvBefore {
            let episodesOnly = pool.filter { $0.type == .episode }
            if episodesOnly.count >= 2 { pool = episodesOnly }
        }

        // Prime time gate: channel is unavailable before this hour
        if let afterHour = tr.onlyAfterHour, hour < afterHour {
            return []
        }

        return pool
    }
}

// MARK: - JSON config (Codable)

// MARK: - Exclusive rules (channel ownership)

struct ExclusiveRule {
    /// Channels allowed to own this content. Content matching this rule is
    /// blocked from every channel NOT in this list (e.g. anime -> [32, 60]).
    let channelIDs: [Int]
    let genres: [String]
    let titleContains: [String]
    let editorialTitles: [String]
    /// When true, any item the manifest claims for one of `channelIDs` is also
    /// owned by this rule — so manifest-claimed anime is blocked from other
    /// channels even when Plex tags it "Animation" instead of "Anime".
    let manifestExclusive: Bool
    /// Optional scope: the lock only applies to items of this type and library source.
    /// The holiday lock is movie + movie library, so a show called Santa Clarita Diet and
    /// a Christmas song on a music video are no longer locked to movie channels that can
    /// never air them. Mirrors `exclusiveRuleApplies` in scripts/nostalgex-channel-filter.cjs.
    var type: MediaType? = nil
    var source: LibrarySource? = nil

    func applies(to item: PlexMediaItem) -> Bool {
        if let type, item.type != type { return false }
        if let source, (item.librarySource ?? .movie) != source { return false }
        return true
    }

    /// Mirrors `exclusiveRuleMatches` in scripts/nostalgex-channel-filter.cjs; both read
    /// scripts/filter-golden.json. A lock looks at the item's own title (the song for a
    /// music video, never the artist), year suffix ignored:
    /// - `editorialTitles`: the exact title
    /// - `titleContains`: whole words, the same boundary rule as a channel's
    ///   `titleContains` (`AppState.titleContainsWordLower`). It used to be a substring
    ///   test, so "Scream" locked Kicking & Screaming off every channel it belongs on and
    ///   "Santa" caught Santana.
    /// - `genres`: substring of a genre tag
    func matches(_ item: PlexMediaItem) -> Bool {
        guard applies(to: item) else { return false }
        let titleLower = item.title.lowercased()
        // Plex's TMDB agent routinely stores films as "Elf (2003)". Every other
        // title comparison in the app strips that suffix, but this exact match
        // did not, so an editorialTitles entry of "Elf" silently failed and the
        // title leaked onto channels the rule was meant to lock it out of.
        // The web filter (scripts/nostalgex-channel-filter.cjs) already stripped
        // it, so the two surfaces disagreed about what was exclusive.
        let strippedLower = MusicTitleParser.stripYearSuffix(item.title).lowercased()

        // Editorial title match (exact, case-insensitive, year suffix ignored)
        if editorialTitles.contains(where: {
            let candidate = $0.lowercased()
            return titleLower == candidate || strippedLower == candidate
        }) {
            return true
        }

        // Title words: whole words only, never a substring of a longer word
        if !titleContains.isEmpty && titleContains.contains(where: {
            AppState.titleContainsWordLower(strippedLower, $0.lowercased())
        }) {
            return true
        }

        // Genre match
        if !genres.isEmpty {
            let genreMatch = item.genres.contains { genre in
                genres.contains { g in genre.lowercased().contains(g.lowercased()) }
            }
            if genreMatch { return true }
        }

        return false
    }
}

struct ExclusiveRuleJSON: Codable {
    // Back-compat: older configs/snapshots use a single `channelID`; newer ones
    // use `channelIDs`. At least one is present.
    let channelID: Int?
    let channelIDs: [Int]?
    let genres: [String]?
    let titleContains: [String]?
    let editorialTitles: [String]?
    let manifestExclusive: Bool?
    let type: String?
    let source: String?

    func toExclusiveRule() -> ExclusiveRule {
        ExclusiveRule(
            channelIDs: channelIDs ?? channelID.map { [$0] } ?? [],
            genres: genres ?? [],
            titleContains: titleContains ?? [],
            editorialTitles: editorialTitles ?? [],
            manifestExclusive: manifestExclusive ?? false,
            type: type.flatMap { MediaType(rawValue: $0) },
            source: source.flatMap { LibrarySource(rawValue: $0) }
        )
    }
}

struct ChannelConfig: Codable {
    let version: Int
    let exclusiveRules: [ExclusiveRuleJSON]?
    let bundles: [ChannelBundleDefinition]?
    let channels: [ChannelDefinition]
}

struct ChannelDefinition: Codable {
    let id: Int
    let number: Int
    let name: String
    let colorHex: String
    let category: String?
    let minItems: Int?
    let isPremiereChannel: Bool?
    let rules: ChannelRulesJSON?
    let timeRestrictions: TimeRestrictionsJSON?

    func toChannel() -> Channel {
        Channel(
            id: id,
            number: number,
            name: name,
            color: Color(hex: colorHex),
            category: category,
            rules: rules?.toChannelRules(),
            timeRestrictions: timeRestrictions?.toTimeRestrictions(),
            minItems: minItems ?? 50,
            isPremiereChannel: isPremiereChannel ?? false
        )
    }
}

struct GenreRulesJSON: Codable {
    let include: [String]?
    let requireAll: [String]?
    let exclude: [String]?

    func toGenreRules() -> GenreRules {
        GenreRules(
            include: include ?? [],
            requireAll: requireAll ?? [],
            exclude: exclude ?? []
        )
    }
}

struct YearRangeJSON: Codable {
    let min: Int?
    let max: Int?

    func toYearRange() -> YearRange {
        YearRange(min: min, max: max)
    }
}

struct AirWindowJSON: Codable {
    let from: String?
    let to: String?

    func toAirWindow() -> AirWindow {
        AirWindow(from: from, to: to)
    }
}

struct DurationRangeJSON: Codable {
    let min: Int?
    let max: Int?

    func toDurationRange() -> DurationRange {
        DurationRange(min: min, max: max)
    }
}

struct ChannelRulesJSON: Codable {
    let type: String?
    let source: String?
    let genres: GenreRulesJSON?
    let studios: [String]?
    let yearRange: YearRangeJSON?
    let contentRatings: [String]?
    let allowUnrated: Bool?
    let ratingMin: Double?
    let durationRange: DurationRangeJSON?
    let watchedOnly: Bool?
    let unwatchedOnly: Bool?
    let rewatched: Bool?
    let titleContains: [String]?
    let episodeTitleContains: [String]?
    let episodeSummaryContains: [String]?
    let episodeSeasonalTitleContains: [String]?
    let episodeAirWindow: AirWindowJSON?
    let episodeTitleExcludes: [String]?
    let matchTmdbGenres: Bool?
    let titleExcludes: [String]?
    let editorialOverrides: [String]?
    let addedWithinDays: Int?
    let releasedWithinMonths: Int?
    // TMDB enrichment rules
    let keywords: [String]?
    let keywordsRequireAll: [String]?
    let keywordsExclude: [String]?
    let keywordsRequireAnyGenre: [String]?
    let keywordGatedGenres: [String]?
    let networks: [String]?
    let productionCompanies: [String]?
    // OMDb enrichment rules
    let imdbRatingMin: Double?
    let imdbVotesMin: Int?
    let rtScoreMin: Int?
    let metacriticMin: Int?
    let wonOscar: Bool?
    let manifestOnly: Bool?
    let manifestOnlyGenreFallback: Bool?

    func toChannelRules() -> ChannelRules {
        var mediaType: MediaType?
        if let t = type {
            mediaType = MediaType(rawValue: t)
        }
        return ChannelRules(
            type: mediaType,
            source: source.flatMap { LibrarySource(rawValue: $0) },
            genres: genres?.toGenreRules(),
            studios: studios,
            yearRange: yearRange?.toYearRange(),
            contentRatings: contentRatings,
            allowUnrated: allowUnrated ?? false,
            ratingMin: ratingMin,
            durationRange: durationRange?.toDurationRange(),
            watchedOnly: watchedOnly ?? false,
            unwatchedOnly: unwatchedOnly ?? false,
            rewatched: rewatched ?? false,
            titleContains: titleContains,
            episodeTitleContains: episodeTitleContains,
            episodeSummaryContains: episodeSummaryContains,
            episodeSeasonalTitleContains: episodeSeasonalTitleContains,
            episodeAirWindow: episodeAirWindow?.toAirWindow(),
            episodeTitleExcludes: episodeTitleExcludes,
            matchTmdbGenres: matchTmdbGenres ?? false,
            titleExcludes: titleExcludes,
            editorialOverrides: editorialOverrides,
            addedWithinDays: addedWithinDays,
            releasedWithinMonths: releasedWithinMonths,
            keywords: keywords,
            keywordsRequireAll: keywordsRequireAll,
            keywordsExclude: keywordsExclude,
            keywordsRequireAnyGenre: keywordsRequireAnyGenre,
            keywordGatedGenres: keywordGatedGenres,
            networks: networks,
            productionCompanies: productionCompanies,
            imdbRatingMin: imdbRatingMin,
            imdbVotesMin: imdbVotesMin,
            rtScoreMin: rtScoreMin,
            metacriticMin: metacriticMin,
            wonOscar: wonOscar ?? false,
            manifestOnly: manifestOnly ?? false,
            manifestOnlyGenreFallback: manifestOnlyGenreFallback ?? false
        )
    }
}

struct BlockRatingsJSON: Codable {
    let ratings: [String]
    let blockBefore: Int?
    let blockAfter: Int?

    func toBlockRatings() -> BlockRatings {
        BlockRatings(ratings: ratings, blockBefore: blockBefore, blockAfter: blockAfter)
    }
}

struct TimeRestrictionsJSON: Codable {
    let blockRatings: BlockRatingsJSON?
    let tvOnlyBefore: Int?
    let onlyAfterHour: Int?

    func toTimeRestrictions() -> TimeRestrictions {
        TimeRestrictions(
            blockRatings: blockRatings?.toBlockRatings(),
            tvOnlyBefore: tvOnlyBefore,
            onlyAfterHour: onlyAfterHour
        )
    }
}

// MARK: - Channel config loading

struct ChannelConfigResult {
    let channels: [Channel]
    let bundles: [ChannelBundleDefinition]
    let exclusiveRules: [ExclusiveRule]
}

enum ChannelConfigLoader {

    /// Load channels and bundles from JSON data
    static func loadConfig(from data: Data) -> ChannelConfigResult? {
        guard let config = try? JSONDecoder().decode(ChannelConfig.self, from: data) else {
            return nil
        }
        return ChannelConfigResult(
            channels: config.channels.map { $0.toChannel() },
            bundles: config.bundles ?? [],
            exclusiveRules: (config.exclusiveRules ?? []).map { $0.toExclusiveRule() }
        )
    }

    /// Load channels from JSON data (backward compat)
    static func loadChannels(from data: Data) -> [Channel]? {
        return loadConfig(from: data)?.channels
    }

    /// Load from bundled channels.json fallback
    static func loadBundled() -> ChannelConfigResult {
        guard let url = Bundle.main.url(forResource: "channels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = loadConfig(from: data) else {
            return ChannelConfigResult(channels: [], bundles: [], exclusiveRules: [])
        }
        return result
    }
}
