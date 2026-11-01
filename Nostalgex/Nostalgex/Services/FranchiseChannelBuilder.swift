import Foundation

/// Turns a library plus its TMDB enrichment into the franchise channel list.
///
/// Pure and injectable on purpose: it takes the items and an enrichment lookup as
/// arguments and returns value types, so it unit-tests without a network, a server,
/// or `AppState`. Phase 2 feeds its output into Settings and the guide; this file only
/// decides WHAT the franchise channels are, never renders or schedules them.
///
/// Two sources feed a franchise:
///   1. Movies grouped by TMDB `franchiseID` (`belongs_to_collection`). 3+ owned films
///      in a group that has no stock channel make a dynamic channel. This is the
///      "found in your library" source. For DICTIONARY franchises, films that TMDB
///      leaves outside any collection (Rogue One, Bumblebee) also join by title: an
///      explicit `filmTitles` entry or a `nameMatchToken`. Auto-found franchises stay
///      franchiseID-only so a token cannot over-match.
///   2. TV shows, which have no `franchiseID`, joined by name-match against the
///      franchise name or by an explicit `FranchiseDictionary` entry.
///
/// The dictionary also merges several collections into one franchise and folds found
/// films/shows into a stock `channels.json` channel (ids 100-106, CH 300-306) instead of making a
/// duplicate.
///
/// The web tuner runs the same rules from `scripts/nostalgex-franchise-builder.js`.
/// Both read `franchises.json` and both must reproduce `scripts/franchise-golden.json`
/// (`FranchiseGoldenTests` here, `npm run test:franchises` there). Change a rule in
/// both files, then add a golden case.
enum FranchiseChannelBuilder {

    /// One resolved franchise: either a fold into an existing stock channel, or a new
    /// dynamic channel.
    struct FranchiseGrouping: Equatable {
        enum Placement: Equatable {
            /// Folds into this stock `channels.json` channel. No duplicate is made.
            case stock(channelID: Int)
            /// Its own runtime channel (like a discovered-collection channel).
            case dynamic
        }

        /// Channel-ready display name, upper-cased.
        let name: String
        let placement: Placement
        /// Movies claimed by `franchiseID`.
        let movies: [PlexMediaItem]
        /// TV items joined by name-match or dictionary.
        let tvItems: [PlexMediaItem]
        /// TMDB collection ids merged into this franchise (sorted, for diagnostics).
        let mergedFranchiseIDs: [Int]
        /// True when a `FranchiseDictionary` entry drove this grouping.
        let fromDictionary: Bool

        var allItems: [PlexMediaItem] { movies + tvItems }
        var itemCount: Int { movies.count + tvItems.count }

        /// Identity that survives a relaunch, a rescan and (later) an iCloud sync, so a
        /// per-franchise on/off choice can be stored as a plain string. A dictionary
        /// franchise is keyed by its canonical name; an auto-found one by the TMDB
        /// collection id that grouped it, which never changes for a given collection.
        var stableID: String {
            if fromDictionary { return "dict:\(name)" }
            return "tmdb:\(mergedFranchiseIDs.first ?? 0)"
        }

        static func == (lhs: FranchiseGrouping, rhs: FranchiseGrouping) -> Bool {
            lhs.name == rhs.name
                && lhs.placement == rhs.placement
                && lhs.movies.map(\.id) == rhs.movies.map(\.id)
                && lhs.tvItems.map(\.id) == rhs.tvItems.map(\.id)
                && lhs.mergedFranchiseIDs == rhs.mergedFranchiseIDs
                && lhs.fromDictionary == rhs.fromDictionary
        }
    }

    /// Build the franchise channel list.
    ///
    /// - Parameters:
    ///   - movies: library movie items (anything whose `type` is `.movie`).
    ///   - tvItems: library TV items (one per show is enough; episodes also work).
    ///   - enrichmentFor: resolves a TMDB enrichment for an item, or nil when the item
    ///     is not enriched yet. Injected so the builder stays pure.
    ///   - availableStockChannelIDs: which stock channels actually exist in the current
    ///     lineup. A franchise only folds into a stock channel that is present.
    ///   - definitions: the stock dictionary (overridable for tests).
    ///   - minimumFilms: films required for a dynamic channel. Stock folds are not gated.
    static func build(
        movies: [PlexMediaItem],
        tvItems: [PlexMediaItem] = [],
        enrichmentFor: (PlexMediaItem) -> MediaEnrichment?,
        availableStockChannelIDs: Set<Int> = [],
        definitions: [FranchiseDefinition] = FranchiseDictionary.all,
        minimumFilms: Int = 3
    ) -> [FranchiseGrouping] {

        let byCollectionID: [Int: FranchiseDefinition] = {
            var map: [Int: FranchiseDefinition] = [:]
            for def in definitions where !def.studioRuled {
                for id in def.tmdbCollectionIDs { map[id] = def }
            }
            return map
        }()

        // A working bucket keyed either by a dictionary franchise's canonical name or by
        // a found franchise's own id ("found:<fid>").
        struct Bucket {
            var name: String
            var definition: FranchiseDefinition?
            var movies: [PlexMediaItem] = []
            var tvItems: [PlexMediaItem] = []
            var franchiseIDs: Set<Int> = []
        }
        var buckets: [String: Bucket] = [:]
        // Remembers which key a given dictionary franchise lives under, so TV and extra
        // movie collections merge into the same bucket.
        func keyForDefinition(_ def: FranchiseDefinition) -> String { "dict:\(def.canonicalName)" }

        // MARK: 1. Movies, placed once each, in priority order

        // A film lands in exactly one bucket:
        //   a. its franchiseID is a dictionary collection  -> that dictionary franchise
        //   b. its title is in a dictionary `filmTitles` list, or contains a dictionary
        //      `nameMatchToken`                            -> that dictionary franchise
        //   c. it has some other franchiseID               -> an auto-found franchise
        //   d. otherwise it is not a franchise film.
        // (b) exists because TMDB leaves some franchise films outside any collection
        // (Rogue One, Solo, Bumblebee, Rise of the Beasts all have
        // belongs_to_collection: null). It applies to dictionary franchises only, so a
        // token can never over-match an auto-found franchise the dictionary does not
        // know about; those stay franchiseID-only.
        var autoFoundNames: [Int: String] = [:]   // fid -> cleaned franchiseName
        // Auto-found films wait until every collection has its name, then go into one
        // bucket per merge key (see `franchiseMergeKey`), in input order.
        var autoFoundFilms: [(movie: PlexMediaItem, fid: Int)] = []
        for movie in movies {
            let enrichment = enrichmentFor(movie)
            let fid = enrichment?.franchiseID

            // a. dictionary by collection id
            if let fid, let def = byCollectionID[fid] {
                let key = keyForDefinition(def)
                var bucket = buckets[key] ?? Bucket(name: def.canonicalName, definition: def)
                bucket.movies.append(movie)
                bucket.franchiseIDs.insert(fid)
                buckets[key] = bucket
                continue
            }

            // b. dictionary by title (explicit list beats token)
            if let def = Self.dictionaryMatch(forFilmTitle: movie.title, definitions: definitions) {
                let key = keyForDefinition(def)
                var bucket = buckets[key] ?? Bucket(name: def.canonicalName, definition: def)
                bucket.movies.append(movie)
                buckets[key] = bucket
                continue
            }

            // c. auto-found by collection id, named from the enrichment's franchiseName
            if let fid {
                if autoFoundNames[fid] == nil, let raw = enrichment?.franchiseName {
                    autoFoundNames[fid] = FranchiseDictionary.cleanFranchiseName(raw).uppercased()
                }
                autoFoundFilms.append((movie, fid))
            }
            // d. no franchise signal: skip
        }

        // A collection whose films never carried a franchiseName cannot be named, so it
        // cannot be a channel. Named ones whose names match after `franchiseMergeKey`
        // share one bucket: "Spider-Man" + "Spider-Man (MCU)", "American Pie" +
        // "American Pie (Spin-off)". TMDB splits those; viewers see one franchise.
        func foundKey(_ fid: Int) -> String? {
            guard let name = autoFoundNames[fid], !name.isEmpty else { return nil }
            let mergeKey = Self.franchiseMergeKey(name)
            return mergeKey.isEmpty ? "found:#\(fid)" : "found:\(mergeKey)"
        }
        for (movie, fid) in autoFoundFilms {
            guard let key = foundKey(fid) else { continue }
            var bucket = buckets[key] ?? Bucket(name: "", definition: nil)
            bucket.movies.append(movie)
            bucket.franchiseIDs.insert(fid)
            buckets[key] = bucket
        }
        // Named after the lowest collection id; a merged bucket drops its "(MCU)" suffix.
        for key in buckets.keys where buckets[key]?.definition == nil {
            guard let ids = buckets[key]?.franchiseIDs, let lowest = ids.min() else { continue }
            let name = autoFoundNames[lowest] ?? ""
            buckets[key]?.name = ids.count > 1 ? Self.stripParentheticalSuffix(name) : name
        }

        // Found buckets in ascending collection id, the fixed order TV tries them in.
        let foundKeys: [String] = buckets
            .compactMap { key, bucket in
                bucket.definition == nil ? bucket.franchiseIDs.min().map { (key, $0) } : nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        // MARK: 2. TV joined by dictionary entry, then by name-match

        for tv in tvItems {
            let titleLower = Self.normalizedTitle(tv.title)

            // Dictionary first: explicit titles, then name tokens. Explicit beats token.
            // A studio-ruled franchise (MARVEL) takes shows here by exact title only;
            // its films never reach a bucket, so the stock fold below carries just TV.
            if let def = Self.dictionaryMatch(title: tv.title, explicit: \.tvShowTitles,
                                              definitions: definitions, includeStudioRuled: true) {
                let key = keyForDefinition(def)
                var bucket = buckets[key] ?? Bucket(name: def.canonicalName, definition: def)
                bucket.tvItems.append(tv)
                buckets[key] = bucket
                continue
            }

            // No dictionary match: try to join a found (dynamic) franchise by its name.
            // Only found buckets with a non-empty name are candidates. Tried in
            // ascending collection id so a show that matches two found names always
            // lands in the same one (Swift dictionary order is not stable, and the web
            // port in scripts/nostalgex-franchise-builder.js must agree).
            for key in foundKeys {
                guard let bucket = buckets[key] else { continue }
                if Self.titleContainsToken(titleLower, bucket.name.lowercased()) {
                    buckets[key]?.tvItems.append(tv)
                    break
                }
            }
        }

        // MARK: 3. Resolve each bucket to a grouping

        var groupings: [FranchiseGrouping] = []
        for bucket in buckets.values {
            let mergedIDs = bucket.franchiseIDs.sorted()
            let fromDict = bucket.definition != nil

            if let def = bucket.definition,
               let stockID = def.stockChannelID,
               availableStockChannelIDs.contains(stockID) {
                // Fold into the stock channel. Not gated on film count: the stock
                // channel already exists; we are only recording that found content maps
                // to it so Phase 2 doesn't also build a duplicate. Needs at least one
                // found item to be worth recording.
                guard bucket.movies.count + bucket.tvItems.count >= 1 else { continue }
                groupings.append(FranchiseGrouping(
                    name: def.canonicalName,
                    placement: .stock(channelID: stockID),
                    movies: bucket.movies,
                    tvItems: bucket.tvItems,
                    mergedFranchiseIDs: mergedIDs,
                    fromDictionary: fromDict
                ))
            } else {
                // Dynamic channel. Gated on owned films, per "3+ owned films is a
                // candidate". TV augments the pool but does not by itself create a
                // channel here (a TV-only franchise has no franchiseID to group on).
                guard bucket.movies.count >= minimumFilms else { continue }
                groupings.append(FranchiseGrouping(
                    name: bucket.name,
                    placement: .dynamic,
                    movies: bucket.movies,
                    tvItems: bucket.tvItems,
                    mergedFranchiseIDs: mergedIDs,
                    fromDictionary: fromDict
                ))
            }
        }

        // Deterministic order: stock folds first (by channel), then dynamic by name, a
        // name tie (two collections both called "ALIEN") broken by stableID. The web
        // port sorts with the same three keys.
        return groupings.sorted { a, b in
            switch (a.placement, b.placement) {
            case let (.stock(l), .stock(r)): return l < r
            case (.stock, .dynamic): return true
            case (.dynamic, .stock): return false
            case (.dynamic, .dynamic):
                if a.name != b.name { return a.name < b.name }
                return a.stableID < b.stableID
            }
        }
    }

    /// The stock channel a Plex/Jellyfin server collection maps to, if any, decided by
    /// the TMDB franchiseIDs of its member items. Lets the scan path fold a server
    /// collection into a stock channel instead of showing it twice. Returns the stock
    /// channel id when 2+ members share a dictionary-mapped franchiseID (the lowest
    /// such channel if several qualify).
    static func stockChannel(
        forCollectionItems items: [PlexMediaItem],
        enrichmentFor: (PlexMediaItem) -> MediaEnrichment?,
        availableStockChannelIDs: Set<Int>,
        definitions: [FranchiseDefinition] = FranchiseDictionary.all
    ) -> Int? {
        let byCollectionID: [Int: FranchiseDefinition] = {
            var map: [Int: FranchiseDefinition] = [:]
            for def in definitions where !def.studioRuled {
                for id in def.tmdbCollectionIDs { map[id] = def }
            }
            return map
        }()

        var stockHits: [Int: Int] = [:]
        for item in items {
            guard let fid = enrichmentFor(item)?.franchiseID,
                  let def = byCollectionID[fid],
                  let stockID = def.stockChannelID,
                  availableStockChannelIDs.contains(stockID) else { continue }
            stockHits[stockID, default: 0] += 1
        }
        // Lowest qualifying channel, so a mixed collection always answers the same way
        // (dictionary order is not stable; the web port picks the same one).
        return stockHits.filter { $0.value >= 2 }.keys.min()
    }

    // MARK: - Helpers

    /// The dictionary franchise a film title belongs to, or nil. Explicit `filmTitles`
    /// beat `nameMatchTokens`. Never matches a studio-ruled franchise.
    static func dictionaryMatch(forFilmTitle title: String,
                                definitions: [FranchiseDefinition] = FranchiseDictionary.all) -> FranchiseDefinition? {
        dictionaryMatch(title: title, explicit: \.filmTitles, definitions: definitions)
    }

    /// Shared matcher for films and TV: an exact hit on the explicit list wins across
    /// every definition before any token is tried, so a show that is listed under one
    /// franchise cannot be stolen by another franchise's broad token.
    ///
    /// `includeStudioRuled` lets a studio-ruled franchise answer the EXACT-title pass
    /// (TV only). Its tokens are never tried, and films never pass it in, so CH101's
    /// films stay with its studio rule.
    private static func dictionaryMatch(title: String,
                                        explicit: KeyPath<FranchiseDefinition, [String]>,
                                        definitions: [FranchiseDefinition],
                                        includeStudioRuled: Bool = false) -> FranchiseDefinition? {
        let titleKey = explicitTitleKey(title)
        for def in definitions where includeStudioRuled || !def.studioRuled {
            if def[keyPath: explicit].contains(where: { explicitTitleKey($0) == titleKey }) {
                return def
            }
        }
        let titleLower = normalizedTitle(title)
        for def in definitions where !def.studioRuled {
            if def.nameMatchTokens.contains(where: { titleContainsToken(titleLower, $0) }) {
                return def
            }
        }
        return nil
    }

    /// "Spider-Man (MCU)" -> "Spider-Man". Drops trailing parenthetical suffixes, one or
    /// more, never the whole name. Mirrors `stripParentheticalSuffix` in the web port.
    static func stripParentheticalSuffix(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(")") {
            guard let open = s.lastIndex(of: "("), open != s.startIndex else { break }
            s = String(s[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Found franchises with the same merge key are one channel: drop " Collection" and
    /// any trailing parenthetical ("(MCU)", "(Spin-off)", "(Reboot)"), compare by
    /// `explicitTitleKey` (case and punctuation ignored), and ignore a leading "The".
    /// Pinned by `mergeKeys` in scripts/franchise-golden.json, same as the web port.
    static func franchiseMergeKey(_ raw: String) -> String {
        let base = FranchiseDictionary.cleanFranchiseName(
            stripParentheticalSuffix(FranchiseDictionary.cleanFranchiseName(raw)))
        let key = explicitTitleKey(base)
        return key.hasPrefix("the ") ? String(key.dropFirst(4)) : key
    }

    /// Lowercased, with any trailing " (YYYY)" suffix dropped (Plex's TMDB agent appends
    /// release year). Kept local so the builder stays nonisolated and pure; this mirrors
    /// the logic of `AppState.stripTrailingYearSuffix`.
    private static func normalizedTitle(_ raw: String) -> String {
        let s = raw.lowercased()
        guard s.count >= 7, s.hasSuffix(")") else { return s }
        let endIdx = s.index(s.endIndex, offsetBy: -7)
        let chars = Array(s[endIdx..<s.endIndex])
        guard chars[0] == " ", chars[1] == "(",
              chars[2].isNumber, chars[3].isNumber,
              chars[4].isNumber, chars[5].isNumber,
              chars[6] == ")" else { return s }
        return String(s[..<endIdx])
    }

    /// Key for EXACT title lists: `normalizedTitle`, then every run of punctuation and
    /// whitespace collapsed to one space. Servers disagree on punctuation, so "What
    /// If...?", "What If…?" and "What If" are one key, as are "Agents of S.H.I.E.L.D."
    /// and "Agents of S.H.I.E.L.D" or "She-Hulk: Attorney at Law" and "She Hulk
    /// Attorney at Law". Still whole-title equality, never containment.
    static func explicitTitleKey(_ raw: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in normalizedTitle(raw) {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                // "Marvel's" and "Marvel’s" read the same; an apostrophe never splits a word.
                continue
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Word-boundary, case-insensitive containment so "star wars" matches "Star Wars
    /// Rebels" but "men" does not match "Mentalist". Both inputs are already lowercased.
    /// Mirrors `AppState.titleContainsWordLower`.
    private static func titleContainsToken(_ titleLower: String, _ tokenLower: String) -> Bool {
        guard !tokenLower.isEmpty else { return false }
        var searchStart = titleLower.startIndex
        while let range = titleLower.range(of: tokenLower, range: searchStart..<titleLower.endIndex) {
            let leftOK: Bool
            if range.lowerBound == titleLower.startIndex {
                leftOK = true
            } else {
                let prev = titleLower[titleLower.index(before: range.lowerBound)]
                leftOK = !prev.isLetter && !prev.isNumber
            }
            let rightOK: Bool
            if range.upperBound == titleLower.endIndex {
                rightOK = true
            } else {
                let next = titleLower[range.upperBound]
                rightOK = !next.isLetter && !next.isNumber
            }
            if leftOK && rightOK { return true }
            searchStart = titleLower.index(after: range.lowerBound)
        }
        return false
    }
}
