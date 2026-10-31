import Foundation

/// Decides which server collections are the same franchise the FRANCHISES package
/// already carries, so a franchise is never offered twice: once as a stock channel or a
/// found franchise under CHANNEL PACKAGES, and again as a row under MY COLLECTIONS.
///
/// Pure and nonisolated, like `FranchiseChannelBuilder`: it takes plain inputs and
/// returns a map, so it unit-tests without `AppState`. The signals it reuses are the
/// ones the collection scan already computes (`matchedChannel`, `contentOverlap`) plus
/// the dictionary (by enrichment franchiseID, then by title) and a plain item overlap
/// against each franchise's own pool, at the same 60% threshold the scan uses for
/// "already on CH N".
enum FranchiseCollectionFold {

    /// A franchise a collection can fold into: one stock channel (ids 100-106, CH 300-306) or one found
    /// franchise.
    struct Target: Equatable {
        /// What the collection row would have said: "CH 100 STAR WARS" or "JOHN WICK".
        let label: String
        /// Item ids the franchise already holds (stock pool, or found movies + shows).
        let itemIDs: Set<String>
        /// Canonical dictionary name when this target is dictionary-backed, so a
        /// collection can match it by title alone.
        let dictionaryName: String?
        /// The stock channel id when this target is a stock channel.
        let stockChannelID: Int?

        init(label: String, itemIDs: Set<String>, dictionaryName: String? = nil, stockChannelID: Int? = nil) {
            self.label = label
            self.itemIDs = itemIDs
            self.dictionaryName = dictionaryName
            self.stockChannelID = stockChannelID
        }
    }

    /// collection id -> target label, for every collection that folds. Collections not in
    /// the result stay listed under MY COLLECTIONS as before.
    static func folds(
        collections: [DiscoveredCollection],
        targets: [Target],
        enrichmentFor: (PlexMediaItem) -> MediaEnrichment?,
        definitions: [FranchiseDefinition] = FranchiseDictionary.all,
        overlapThresholdPercent: Int = 60
    ) -> [String: String] {
        guard !targets.isEmpty else { return [:] }

        var stockByID: [Int: Target] = [:]
        for t in targets {
            if let sid = t.stockChannelID { stockByID[sid] = t }
        }
        let availableStock = Set(stockByID.keys)

        var result: [String: String] = [:]
        for collection in collections {
            if let target = fold(collection,
                                 targets: targets,
                                 stockByID: stockByID,
                                 availableStock: availableStock,
                                 enrichmentFor: enrichmentFor,
                                 definitions: definitions,
                                 threshold: overlapThresholdPercent),
               carriesEveryShow(of: collection, target) {
                result[collection.id] = target.label
            }
        }
        return result
    }

    /// A folded collection is hidden and never built, so folding is only safe when the
    /// franchise already airs everything in it. Films were the whole story while the scan
    /// kept only films. A collection that holds shows folds only into a franchise whose
    /// pool has at least one episode of each of them; otherwise it stays its own channel
    /// rather than losing the shows (a "Star Trek" set of films and series must not
    /// vanish into a films-only STAR TREK). Films-only collections pass untouched.
    static func carriesEveryShow(of collection: DiscoveredCollection, _ target: Target) -> Bool {
        var covered: [String: Bool] = [:]
        for item in collection.items where item.type == .episode {
            let show = CollectionMemberIndex.showIdentity(of: item)
            if covered[show] == true { continue }
            covered[show] = target.itemIDs.contains(item.id)
        }
        return covered.values.allSatisfy { $0 }
    }

    private static func fold(
        _ collection: DiscoveredCollection,
        targets: [Target],
        stockByID: [Int: Target],
        availableStock: Set<Int>,
        enrichmentFor: (PlexMediaItem) -> MediaEnrichment?,
        definitions: [FranchiseDefinition],
        threshold: Int
    ) -> Target? {
        // 1. Dictionary truth from enrichment: 2+ members share a franchiseID that the
        //    dictionary maps to a stock channel present in the lineup.
        if let sid = FranchiseChannelBuilder.stockChannel(
            forCollectionItems: collection.items,
            enrichmentFor: enrichmentFor,
            availableStockChannelIDs: availableStock,
            definitions: definitions
        ), let target = stockByID[sid] {
            return target
        }

        // 2. Dictionary by title: "Star Wars Collection" carries the "star wars" token,
        //    "Bourne Films" carries "bourne". Folds into the stock channel when it exists,
        //    else into the found franchise that the same dictionary entry produced.
        if let def = FranchiseChannelBuilder.dictionaryMatch(forFilmTitle: collection.title, definitions: definitions) {
            if let sid = def.stockChannelID, let target = stockByID[sid] {
                return target
            }
            if let target = targets.first(where: { $0.dictionaryName == def.canonicalName }) {
                return target
            }
        }

        // 3. The scan's own duplicate signals, when they point at a stock franchise
        //    channel: a name match ("CH 101 MARVEL") or a manifest overlap on CH 101.
        if let matched = collection.matchedChannel,
           let target = targets.first(where: { $0.stockChannelID != nil && $0.label == matched }) {
            return target
        }
        if let overlap = collection.contentOverlap, let target = stockByID[overlap.channelID] {
            return target
        }

        // 4. Plain item overlap: most of this collection is already in one franchise's
        //    pool. Catches an auto-found franchise (no dictionary entry) whose server
        //    collection has a name TMDB would never guess.
        let total = collection.items.count
        guard total > 0 else { return nil }
        let collectionIDs = Set(collection.items.map(\.id))
        var best: (target: Target, count: Int)?
        for target in targets {
            let count = collectionIDs.intersection(target.itemIDs).count
            if count > (best?.count ?? 0) { best = (target, count) }
        }
        if let best {
            let percent = Int((Double(best.count) / Double(total) * 100).rounded())
            if percent >= threshold { return best.target }
        }
        return nil
    }
}
