import Foundation

/// Unified enrichment record combining TMDB (keywords/networks/studios) and OMDb (ratings/awards).
/// Stored in the Supabase `media_enrichments` table. All OMDb fields are optional since older
/// rows created before the Phase 2 migration will have them as NULL until backfilled.
///
/// Uses a custom `init(from:)` decoder so that null/missing array fields default to `[]`
/// instead of crashing the entire decode batch.
struct MediaEnrichment: Codable, Sendable {
    // Primary identifiers
    let tmdbID: String
    let imdbID: String?
    let mediaType: String               // "movie" or "tv"

    // TMDB fields
    let keywords: [String]              // ["christmas", "dystopia", "superhero"]
    let networks: [String]              // TV only: ["Netflix", "HBO"]
    let productionCompanies: [String]   // ["Marvel Studios", "A24"]
    let tmdbGenres: [String]            // TMDB's genre list (may differ from Plex)

    // OMDb fields (nullable — populated after Phase 2 rollout)
    let imdbRating: Double?             // 0.0 – 10.0
    let imdbVotes: Int?                 // raw vote count
    let rottenTomatoesScore: Int?       // 0 – 100, nil if no RT rating
    let metacriticScore: Int?           // 0 – 100, nil if no MC rating
    let awards: String?                 // raw OMDb "Awards" string

    // Franchise fields (nullable — populated from TMDB belongs_to_collection on movies only.
    // TV has no collection, so both stay nil for tv rows and for any row cached before the
    // Phase 0 franchise migration was applied.)
    let franchiseID: Int?               // TMDB belongs_to_collection.id
    let franchiseName: String?          // TMDB belongs_to_collection.name

    let fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case tmdbID = "tmdb_id"
        case imdbID = "imdb_id"
        case mediaType = "media_type"
        case keywords
        case networks
        case productionCompanies = "production_companies"
        case tmdbGenres = "tmdb_genres"
        case imdbRating = "imdb_rating"
        case imdbVotes = "imdb_votes"
        case rottenTomatoesScore = "rt_score"
        case metacriticScore = "metacritic_score"
        case awards
        case franchiseID = "franchise_id"
        case franchiseName = "franchise_name"
        case fetchedAt = "fetched_at"
    }

    // MARK: - Resilient decoder (arrays default to [], optionals to nil)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbID = try c.decode(String.self, forKey: .tmdbID)
        imdbID = try c.decodeIfPresent(String.self, forKey: .imdbID)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        keywords = (try? c.decode([String].self, forKey: .keywords)) ?? []
        networks = (try? c.decode([String].self, forKey: .networks)) ?? []
        productionCompanies = (try? c.decode([String].self, forKey: .productionCompanies)) ?? []
        tmdbGenres = (try? c.decode([String].self, forKey: .tmdbGenres)) ?? []
        imdbRating = try c.decodeIfPresent(Double.self, forKey: .imdbRating)
        imdbVotes = try c.decodeIfPresent(Int.self, forKey: .imdbVotes)
        rottenTomatoesScore = try c.decodeIfPresent(Int.self, forKey: .rottenTomatoesScore)
        metacriticScore = try c.decodeIfPresent(Int.self, forKey: .metacriticScore)
        awards = try c.decodeIfPresent(String.self, forKey: .awards)
        franchiseID = try c.decodeIfPresent(Int.self, forKey: .franchiseID)
        franchiseName = try c.decodeIfPresent(String.self, forKey: .franchiseName)
        fetchedAt = (try? c.decode(Date.self, forKey: .fetchedAt)) ?? Date()
    }

    // MARK: - Memberwise init (used by TMDBService + merging)

    init(tmdbID: String, imdbID: String?, mediaType: String,
         keywords: [String], networks: [String], productionCompanies: [String], tmdbGenres: [String],
         imdbRating: Double?, imdbVotes: Int?, rottenTomatoesScore: Int?, metacriticScore: Int?, awards: String?,
         franchiseID: Int? = nil, franchiseName: String? = nil,
         fetchedAt: Date) {
        self.tmdbID = tmdbID
        self.imdbID = imdbID
        self.mediaType = mediaType
        self.keywords = keywords
        self.networks = networks
        self.productionCompanies = productionCompanies
        self.tmdbGenres = tmdbGenres
        self.imdbRating = imdbRating
        self.imdbVotes = imdbVotes
        self.rottenTomatoesScore = rottenTomatoesScore
        self.metacriticScore = metacriticScore
        self.awards = awards
        self.franchiseID = franchiseID
        self.franchiseName = franchiseName
        self.fetchedAt = fetchedAt
    }

    /// Returns a new enrichment with OMDb data merged in.
    func merging(omdb: OMDBResult) -> MediaEnrichment {
        MediaEnrichment(
            tmdbID: tmdbID,
            imdbID: imdbID ?? omdb.imdbID,
            mediaType: mediaType,
            keywords: keywords,
            networks: networks,
            productionCompanies: productionCompanies,
            tmdbGenres: tmdbGenres,
            imdbRating: omdb.imdbRating,
            imdbVotes: omdb.imdbVotes,
            rottenTomatoesScore: omdb.rottenTomatoesScore,
            metacriticScore: omdb.metacriticScore,
            awards: omdb.awards,
            franchiseID: franchiseID,
            franchiseName: franchiseName,
            fetchedAt: Date()
        )
    }
}

// MARK: - The key a row is kept and looked up by

extension MediaEnrichment {
    /// "movie:603" or "tv:603". TMDB numbers films and shows separately, so the number
    /// alone does not name a title, and the shared table's key is the number plus the type.
    static func cacheKey(mediaType: String, tmdbID: String) -> String { "\(mediaType):\(tmdbID)" }

    var cacheKey: String { Self.cacheKey(mediaType: mediaType, tmdbID: tmdbID) }
}

extension PlexMediaItem {
    /// The type TMDB files this item under: an episode's number is its show's.
    var enrichmentMediaType: String { type == .episode ? "tv" : "movie" }

    /// The key of this item's enrichment row, or nil with no TMDB number.
    var enrichmentKey: String? {
        tmdbID.map { MediaEnrichment.cacheKey(mediaType: enrichmentMediaType, tmdbID: $0) }
    }
}
