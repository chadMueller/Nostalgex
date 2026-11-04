import Foundation
import Observation

/// Small actor-isolated flag so background tasks can coordinate OMDb rate-limit state
/// without touching MainActor-isolated EnrichmentService state.
private actor OMDBRateLimitFlag {
    var limited: Bool = false
    var quota: Bool = false
    /// Stop asking for this load. `quota` means OMDb said the day's limit is gone.
    func mark(quota: Bool = false) {
        limited = true
        if quota { self.quota = true }
    }
    func isLimited() -> Bool { limited }
    func wasQuota() -> Bool { quota }
}

/// One TMDB id's worth of library items, as the enrichment pass sees them.
struct OMDBWorkItem {
    let tmdbID: String
    var imdbID: String?
    let mediaType: String
    /// The server's genres for the title, merged across its items.
    var genres: [String]
}

/// An OMDb lookup: the IMDb id to ask about and the TMDB row its answer merges into.
struct OMDBLookup {
    let tmdbID: String
    let imdbID: String
    let existing: MediaEnrichment
}

@Observable
@MainActor
class EnrichmentService {

    // In-memory cache: tmdbID -> MediaEnrichment (TMDB + optional OMDb merged)
    private(set) var cache: [String: MediaEnrichment] = [:]

    // Progress tracking
    var isEnriching: Bool = false
    var statusMessage: String = ""
    var progress: Double = 0 // 0.0 to 1.0
    var enrichedCount: Int = 0
    var totalToEnrich: Int = 0

    // Read when a pass starts, not when the service is made, so a DEBUG harness that sets
    // `TMDBConfig.harnessEndpoints` reaches its stand-ins. In the app the values never change.
    private var tmdb: TMDBService { TMDBService(apiKey: TMDBConfig.tmdbAPIKey) }
    private var omdb: OMDBService { OMDBService(apiKey: TMDBConfig.omdbAPIKey) }
    private var supabase: SupabaseService {
        SupabaseService(projectURL: TMDBConfig.supabaseURL, anonKey: TMDBConfig.supabaseAnonKey)
    }

    // MARK: - Public API

    /// Look up enrichment data for a media item
    func enrichment(for item: PlexMediaItem) -> MediaEnrichment? {
        guard let tmdbID = item.tmdbID else { return nil }
        return cache[tmdbID]
    }

    /// Rows saved by the last pass, inside their 7-day TTL, merged under what is already in
    /// memory. Called by a snapshot restore before any pool is rebuilt (I-073), so a package
    /// build after a restore sees the same networks, keywords and scores the first load did.
    /// Returns how many rows came off disk.
    @discardableResult
    func loadDiskCache() -> Int {
        let rows = EnrichmentCacheStore.load()
        guard !rows.isEmpty else { return 0 }
        for (id, row) in rows where cache[id] == nil { cache[id] = row }
        print("[Enrichment] Loaded \(rows.count) cached rows from disk (\(cache.count) in memory)")
        return rows.count
    }

    /// Writes the in-memory cache to disk in the background. Called when a pass ends.
    func saveDiskCache() {
        guard !cache.isEmpty else { return }
        EnrichmentCacheStore.saveInBackground(cache) { bytes in
            print("[Enrichment] Saved \(bytes / 1024) KB enrichment cache to disk")
        }
    }

    /// Fixture seam: puts ready-made rows in the in-memory cache without Supabase or
    /// TMDB. Used by the `-uiTestFranchiseFixture` demo so the franchise fields can be
    /// exercised on a simulator before the shared table carries them. Nothing is written
    /// back to Supabase from here.
    func seedCache(_ entries: [MediaEnrichment]) {
        for entry in entries {
            cache[entry.tmdbID] = entry
        }
    }

    /// What keeps enrichment off, in the order the skip log names it. TMDB needs either
    /// a key (dev builds, direct) or the site proxy (App Store builds). Supabase is
    /// required either way: the shared cache is the point, and without it every Apple TV
    /// would fetch the same titles from TMDB on every scan.
    nonisolated static func missingConfiguration(
        tmdbAPIKey: String,
        tmdbProxyURL: String,
        supabaseURL: String,
        supabaseAnonKey: String
    ) -> [String] {
        var missing: [String] = []
        if tmdbAPIKey.isEmpty && tmdbProxyURL.isEmpty { missing.append("tmdb proxy/key") }
        if supabaseURL.isEmpty { missing.append("supabase url") }
        if supabaseAnonKey.isEmpty { missing.append("anon key") }
        return missing
    }

    /// The titles worth an OMDb lookup: a TMDB row with no IMDb rating yet, a usable
    /// IMDb id (the server's, else the one TMDB gave), and a gate that admits the row's
    /// media type plus its TMDB keywords, TMDB genres or server genres.
    nonisolated static func omdbCandidates(
        work: [OMDBWorkItem],
        enrichments: [String: MediaEnrichment],
        gates: [OMDBGate]
    ) -> [OMDBLookup] {
        guard !gates.isEmpty else { return [] }
        var out: [OMDBLookup] = []
        for w in work {
            guard let e = enrichments[w.tmdbID], e.imdbRating == nil else { continue }
            guard let imdbID = w.imdbID ?? e.imdbID, OMDBService.isValidIMDbID(imdbID) else { continue }
            guard OMDBQuota.isCandidate(
                mediaType: e.mediaType, keywords: e.keywords, genres: e.tmdbGenres + w.genres, gates: gates
            ) else { continue }
            out.append(OMDBLookup(tmdbID: w.tmdbID, imdbID: imdbID, existing: e))
        }
        return out
    }

    /// Enrich all items in the library. Runs in background, updates progress.
    ///
    /// `omdbGates` decides which titles are worth an OMDb lookup (see `OMDBGate`). The
    /// library load passes the gates from the channel config it just loaded; nil reads
    /// them from the bundled channels.json.
    func enrichItems(_ items: [PlexMediaItem], omdbGates: [OMDBGate]? = nil) async {
        let missing = Self.missingConfiguration(
            tmdbAPIKey: TMDBConfig.tmdbAPIKey,
            tmdbProxyURL: TMDBConfig.tmdbProxyURL,
            supabaseURL: TMDBConfig.supabaseURL,
            supabaseAnonKey: TMDBConfig.supabaseAnonKey
        )
        guard missing.isEmpty else {
            print("[Enrichment] Skipping: missing \(missing.joined(separator: ", "))")
            return
        }
        print("[Enrichment] TMDB via \(tmdb.usesProxy ? "site proxy" : "direct key")")

        isEnriching = true
        statusMessage = "Preparing..."
        progress = 0

        // Step 1: Deduplicate TMDB IDs
        // TV episodes share a show-level TMDB ID, so group by ID
        // Track an IMDb ID per TMDB ID when available (first one wins)
        var workItemsByTMDB: [String: OMDBWorkItem] = [:]
        for item in items {
            guard let tmdbID = item.tmdbID else { continue }
            let mediaType = item.type == .episode ? "tv" : "movie"
            if var existing = workItemsByTMDB[tmdbID] {
                // Fill in missing IMDb ID if a later item has one
                if existing.imdbID == nil, let imdb = item.imdbID {
                    existing.imdbID = imdb
                }
                for g in item.genres where !existing.genres.contains(g) {
                    existing.genres.append(g)
                }
                workItemsByTMDB[tmdbID] = existing
            } else {
                workItemsByTMDB[tmdbID] = OMDBWorkItem(
                    tmdbID: tmdbID, imdbID: item.imdbID, mediaType: mediaType, genres: item.genres
                )
            }
        }

        let total = workItemsByTMDB.count
        let backoff = OMDBBackoff()
        let omdbBlocked = backoff.isBlocked()
        let omdbEnabled = omdb.isConfigured && !omdbBlocked
        let withIMDB = workItemsByTMDB.values.filter { $0.imdbID != nil }.count
        let omdbState = omdbBlocked
            ? "paused until UTC midnight (daily limit)"
            : (omdb.isConfigured ? "via \(omdb.usesProxy ? "site proxy" : "direct key")" : "disabled")
        print("[Enrichment] \(total) unique TMDB IDs from \(items.count) items, \(withIMDB) with IMDb IDs, OMDb \(omdbState)")

        guard total > 0 else {
            statusMessage = "No TMDB IDs found"
            isEnriching = false
            return
        }

        // Step 2: Check Supabase cache
        statusMessage = "Checking metadata cache"
        let allIDs = Array(workItemsByTMDB.keys)
        var cached: [MediaEnrichment] = []
        do {
            cached = try await supabase.fetchEnrichments(tmdbIDs: allIDs) { done, total in
                guard total > 1 else { return }
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Checking metadata cache \(done)/\(total)"
                }
            }
            for enrichment in cached {
                cache[enrichment.tmdbID] = enrichment
            }
            let withOMDBCached = cached.filter { $0.imdbRating != nil }.count
            print("[Enrichment] \(cached.count)/\(total) cached in Supabase (\(withOMDBCached) with OMDb)")
        } catch {
            print("[Enrichment] Supabase cache check failed: \(error)")
        }
        // A cancelled pass (a load started while a restore's refill ran) stops here: a
        // cancelled Supabase fetch throws, and carrying on would ask TMDB for every id.
        if Task.isCancelled {
            print("[Enrichment] Pass cancelled after the cache check")
            statusMessage = ""
            isEnriching = false
            return
        }

        // Step 3: TMDB for every id with no cache row. OMDb is decided afterwards, once
        // the keywords that say whether a title could land on a gated channel are known.
        let cachedIDs = Set(cached.map(\.tmdbID))
        let needsTMDB = workItemsByTMDB.values.filter { !cachedIDs.contains($0.tmdbID) }

        totalToEnrich = needsTMDB.count
        enrichedCount = 0

        var newByID: [String: MediaEnrichment] = [:]
        let rateLimitFlag = OMDBRateLimitFlag()
        let tmdbService = tmdb
        let omdbService = omdb
        let maxConcurrency = 10

        if !needsTMDB.isEmpty {
            print("[Enrichment] Fetching \(needsTMDB.count) new from TMDB")
            statusMessage = "Fetching metadata 0/\(totalToEnrich)"
            await withTaskGroup(of: MediaEnrichment?.self) { group in
                var index = 0

                func launch(_ work: OMDBWorkItem) {
                    group.addTask {
                        do {
                            return try await tmdbService.fetchEnrichment(
                                tmdbID: work.tmdbID,
                                imdbID: work.imdbID,
                                mediaType: work.mediaType
                            )
                        } catch TMDBService.TMDBError.rateLimited {
                            print("[Enrichment] TMDB rate limited on \(work.tmdbID)")
                            return nil
                        } catch {
                            print("[Enrichment] TMDB failed \(work.tmdbID): \(error)")
                            return nil
                        }
                    }
                }

                while index < maxConcurrency && index < needsTMDB.count {
                    launch(needsTMDB[index])
                    index += 1
                }

                // Drain + refill (throttle UI updates to every 5 items to prevent SwiftUI lag)
                var pendingCount = 0
                for await result in group {
                    if let enrichment = result {
                        newByID[enrichment.tmdbID] = enrichment
                        cache[enrichment.tmdbID] = enrichment
                    }
                    pendingCount += 1
                    if pendingCount >= 5 || (enrichedCount + pendingCount) >= totalToEnrich {
                        enrichedCount += pendingCount
                        progress = Double(enrichedCount) / Double(max(totalToEnrich, 1))
                        statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
                        pendingCount = 0
                    }
                    if index < needsTMDB.count {
                        launch(needsTMDB[index])
                        index += 1
                    }
                }
                if pendingCount > 0 {
                    enrichedCount += pendingCount
                    progress = Double(enrichedCount) / Double(max(totalToEnrich, 1))
                    statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
                }
            }
        }

        // Step 4: OMDb, only for titles that could land on an IMDb-gated channel, at most
        // OMDBQuota.perLoadLimit per load, in random order.
        if omdbEnabled {
            let gates = omdbGates ?? OMDBGate.bundledGates()
            let candidates = Self.omdbCandidates(
                work: Array(workItemsByTMDB.values), enrichments: cache, gates: gates
            )
            let picked = OMDBQuota.pick(candidates)
            print("[Enrichment] OMDb: \(gates.count) gated channels, \(candidates.count) candidates, looking up \(picked.count)")

            if !picked.isEmpty {
                totalToEnrich += picked.count
                let omdbConcurrency = 5
                await withTaskGroup(of: MediaEnrichment?.self) { group in
                    var index = 0

                    func launch(_ work: OMDBLookup) {
                        group.addTask {
                            if await rateLimitFlag.isLimited() { return nil }
                            do {
                                let result = try await omdbService.fetch(imdbID: work.imdbID)
                                return work.existing.merging(omdb: result)
                            } catch OMDBService.OMDBError.rateLimited {
                                await rateLimitFlag.mark(quota: true)
                                return nil
                            } catch OMDBService.OMDBError.notFound {
                                return nil
                            } catch OMDBService.OMDBError.httpError(let code) {
                                // 401/403 = bad key, 5xx = relay or OMDb down: stop for this load.
                                if code == 401 || code == 403 || code >= 500 {
                                    print("[Enrichment] OMDb disabled for this load (HTTP \(code))")
                                    await rateLimitFlag.mark()
                                }
                                return nil
                            } catch {
                                return nil
                            }
                        }
                    }

                    while index < omdbConcurrency && index < picked.count {
                        launch(picked[index])
                        index += 1
                    }

                    var pendingCount = 0
                    for await result in group {
                        if let enrichment = result {
                            newByID[enrichment.tmdbID] = enrichment
                            cache[enrichment.tmdbID] = enrichment
                        }
                        pendingCount += 1
                        if pendingCount >= 5 || (enrichedCount + pendingCount) >= totalToEnrich {
                            enrichedCount += pendingCount
                            progress = Double(enrichedCount) / Double(max(totalToEnrich, 1))
                            statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
                            pendingCount = 0
                        }
                        if index < picked.count {
                            launch(picked[index])
                            index += 1
                        }
                    }
                    if pendingCount > 0 {
                        enrichedCount += pendingCount
                        progress = Double(enrichedCount) / Double(max(totalToEnrich, 1))
                        statusMessage = "Fetching metadata \(enrichedCount)/\(totalToEnrich)"
                    }
                }
            }
        }

        if await rateLimitFlag.wasQuota() {
            backoff.markRateLimited()
            print("[Enrichment] OMDb daily limit reached; no more OMDb lookups until UTC midnight")
        }

        let newEnrichments = Array(newByID.values)

        // Step 5: Persist to Supabase
        if !newEnrichments.isEmpty {
            statusMessage = "Saving metadata cache"
            do {
                try await supabase.upsertEnrichments(newEnrichments)
                print("[Enrichment] Saved \(newEnrichments.count) enrichments to Supabase")
            } catch {
                print("[Enrichment] Supabase save failed: \(error)")
            }
        }

        let totalCached = cache.count
        let totalWithOMDB = cache.values.filter { $0.imdbRating != nil }.count
        print("[Enrichment] Complete: \(totalCached) cached total, \(totalWithOMDB) with OMDb data, \(newEnrichments.count) new this session")
        saveDiskCache()
        statusMessage = ""
        progress = 1
        isEnriching = false
    }
}
