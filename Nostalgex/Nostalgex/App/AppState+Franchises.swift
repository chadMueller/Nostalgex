import Foundation
import SwiftUI

// Franchises: the stock classics and the ones found in the library, one Settings list.
//
// `FranchiseChannelBuilder` decides WHAT the franchises are from the library plus its
// TMDB enrichment. This file owns everything around that: when the list is rebuilt, how
// a viewer's on/off choices persist, how an enabled franchise becomes a runtime channel,
// and how a server collection that is really one of these franchises gets folded away so
// it is not offered twice. The schedule engine and playback are untouched: a found
// franchise channel is a dynamic channel (rules == nil) exactly like a collection channel.

/// One franchise the builder found in the viewer's library, as Settings lists it.
struct FoundFranchise: Identifiable, Equatable {
    /// `FranchiseGrouping.stableID`: survives relaunch, rescan and a later iCloud sync.
    let id: String
    /// Channel-ready name, upper-cased ("JOHN WICK").
    let name: String
    let movies: [PlexMediaItem]
    /// Episodes of the shows that joined (the show title is `PlexMediaItem.title`).
    let tvItems: [PlexMediaItem]
    /// The stock channel (CH100-106) this franchise folds into, when one exists. Such a
    /// franchise is listed (and switched) as that classic's row, see `franchiseListRows`.
    let coveredByChannelID: Int?
    let fromDictionary: Bool
    var enabled: Bool

    var isCoveredByStock: Bool { coveredByChannelID != nil }
    var items: [PlexMediaItem] { movies + tvItems }
    var showCount: Int { Set(tvItems.map(\.title)).count }

    /// "3 movies", "1 movie", "5 movies, 2 shows".
    var countLabel: String {
        var parts: [String] = []
        if !movies.isEmpty { parts.append(movies.count == 1 ? "1 movie" : "\(movies.count) movies") }
        let shows = showCount
        if shows > 0 { parts.append(shows == 1 ? "1 show" : "\(shows) shows") }
        return parts.joined(separator: ", ")
    }

    /// Settings line for a franchise a classic carries: "3 movies, 2 shows on CH 100".
    /// Those items are in that channel's pool (see `foldCoveredFranchisesIntoStockPools`).
    var coveredLabel: String {
        guard let channelID = coveredByChannelID else { return countLabel }
        return "\(countLabel) on CH \(channelID)"
    }

    static func == (lhs: FoundFranchise, rhs: FoundFranchise) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.movies.map(\.id) == rhs.movies.map(\.id)
            && lhs.tvItems.map(\.id) == rhs.tvItems.map(\.id)
            && lhs.coveredByChannelID == rhs.coveredByChannelID
            && lhs.fromDictionary == rhs.fromDictionary
            && lhs.enabled == rhs.enabled
    }
}

/// One row of the single franchise list in Settings: a stock classic (CH100-106,
/// channels.json) or a franchise found in the library. Both have a switch and share one
/// on/off store (`enabledFranchiseIDs` / `disabledFranchiseIDs`), keyed by stable id.
struct FranchiseListRow: Identifiable, Equatable {
    /// `FranchiseGrouping.stableID`: "dict:STAR WARS", "tmdb:2806".
    let id: String
    let name: String
    /// "12 movies, 1 show". A stock row counts its channel's pool.
    let countLabel: String
    /// The stock channel this row switches, nil for a found franchise.
    let stockChannelID: Int?
    /// The number Settings shows for a stock row ("CH 100").
    let channelNumber: Int?
    let enabled: Bool

    var isStock: Bool { stockChannelID != nil }

    /// "3 movies", "1 movie", "5 movies, 2 shows"; never empty.
    static func countLabel(movies: Int, shows: Int) -> String {
        var parts: [String] = []
        if movies > 0 { parts.append(movies == 1 ? "1 movie" : "\(movies) movies") }
        if shows > 0 { parts.append(shows == 1 ? "1 show" : "\(shows) shows") }
        return parts.isEmpty ? "None in your library yet" : parts.joined(separator: ", ")
    }
}

extension AppState {

    static let enabledFranchisesKey = PreferenceSync.enabledFranchisesKey
    static let disabledFranchisesKey = PreferenceSync.disabledFranchisesKey
    /// The stock FRANCHISES bundle in channels.json (CH100-106). Found franchise channels
    /// ride on this switch.
    static let franchisesBundleID = "franchises"

    // MARK: - What Settings reads

    var isFranchisesBundleOn: Bool { enabledBundleIDs.contains(Self.franchisesBundleID) }

    /// Found franchises that get a switch: not folded into a stock channel.
    var listedFoundFranchises: [FoundFranchise] {
        foundFranchises.filter { !$0.isCoveredByStock }
    }

    /// Found franchises already carried by a stock channel. Settings lists the classic
    /// itself instead (`franchiseListRows`); these feed its pool and the collection fold.
    var coveredFoundFranchises: [FoundFranchise] {
        foundFranchises.filter(\.isCoveredByStock)
    }

    // MARK: - The one franchise list

    /// Every franchise Settings lists under the FRANCHISES package, stock classics and
    /// found ones together, alphabetical, each with its own switch. MARVEL is here even
    /// though the builder groups none of its films (its studio rule owns them).
    var franchiseListRows: [FranchiseListRow] {
        var rows: [FranchiseListRow] = []
        var seen = Set<String>()

        // A film a non-stock dictionary franchise owns (SPIDER-MAN's MCU films) also
        // passes CH101's studio rule. It is counted once, on its own franchise.
        let claimed = Set(foundFranchises
            .filter { $0.fromDictionary && !$0.isCoveredByStock }
            .flatMap { $0.items.map(\.id) })
        let stockChannelIDs = bundles.first(where: { $0.id == Self.franchisesBundleID })?.channelIDs ?? []
        for channelID in stockChannelIDs {
            guard let def = FranchiseDictionary.byStockChannelID[channelID] else { continue }
            let channel = allChannels.first { $0.id == channelID }
            let pool = (channel?.itemPool ?? []).filter { !claimed.contains($0.id) }
            let movies = pool.filter { $0.type == .movie }.count
            let shows = Set(pool.filter { $0.type == .episode }.map(\.title)).count
            rows.append(FranchiseListRow(
                id: def.stableID,
                name: def.canonicalName,
                countLabel: FranchiseListRow.countLabel(movies: movies, shows: shows),
                stockChannelID: channelID,
                channelNumber: channel?.number ?? channelID,
                enabled: isStockFranchiseOn(def.stableID)
            ))
            seen.insert(def.stableID)
        }
        for franchise in listedFoundFranchises where !seen.contains(franchise.id) {
            rows.append(FranchiseListRow(
                id: franchise.id,
                name: franchise.name,
                countLabel: franchise.countLabel,
                stockChannelID: nil,
                channelNumber: nil,
                enabled: franchise.enabled
            ))
        }
        return rows.sorted { a, b in
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }

    /// A stock classic is on unless the viewer switched it off.
    func isStockFranchiseOn(_ id: String) -> Bool {
        FranchiseDictionary.isOn(id, enabledIDs: enabledFranchiseIDs,
                                 disabledIDs: disabledFranchiseIDs, defaultOn: true)
    }

    /// Stock channels the viewer switched off in the franchise list. `applyBundleFilter`
    /// keeps them out of the guide while the FRANCHISES package is on.
    var switchedOffStockFranchiseChannelIDs: Set<Int> {
        Set(FranchiseDictionary.byStockChannelID.compactMap { channelID, def in
            isStockFranchiseOn(def.stableID) ? nil : channelID
        })
    }

    /// Server collections that still belong under MY COLLECTIONS: everything the fold
    /// did not credit to a franchise.
    var visibleDiscoveredCollections: [DiscoveredCollection] {
        discoveredCollections.filter { !$0.isFoldedIntoFranchise }
    }

    /// Stock franchise channels present in the current lineup, by id.
    private var availableStockFranchiseChannelIDs: Set<Int> {
        let bundleIDs = Set(bundles.first(where: { $0.id == Self.franchisesBundleID })?.channelIDs ?? [])
        return Set(allChannels.filter { bundleIDs.contains($0.id) }.map(\.id))
    }

    // MARK: - Rebuild

    /// Runs the builder over the library and the enrichment cache, then re-folds the
    /// server collections against the result. Called after every enrichment pass (first
    /// load, RESCAN, background refresh) and after the FRANCHISES bundle's own pools are
    /// built, since a fold only targets a stock channel that is actually in the lineup.
    ///
    /// - Parameter enrichmentFor: injectable lookup for tests and fixtures; defaults to a
    ///   snapshot of the enrichment service's cache so the builder stays off the actor.
    func rebuildFoundFranchises(enrichmentFor: ((PlexMediaItem) -> MediaEnrichment?)? = nil) {
        let lookup: (PlexMediaItem) -> MediaEnrichment? = enrichmentFor ?? { [cache = enrichmentService.cache] item in
            guard let tmdbID = item.tmdbID else { return nil }
            return cache[tmdbID]
        }
        // Music videos live in a movie-typed library; they are never franchise films. Items no
        // channel may take (Emby Dolby Vision profile 5) are not franchise members either.
        let channelItems = ChannelEligibility.onChannels(allItems, backend: backendKind)
        let movies = channelItems.filter { $0.type == .movie && ($0.librarySource ?? .movie) == .movie }
        let tv = channelItems.filter { $0.type == .episode }

        let groupings = FranchiseChannelBuilder.build(
            movies: movies,
            tvItems: tv,
            enrichmentFor: lookup,
            availableStockChannelIDs: availableStockFranchiseChannelIDs
        )

        foundFranchises = groupings.map { g in
            let covered: Int? = {
                if case let .stock(channelID) = g.placement { return channelID }
                return nil
            }()
            return FoundFranchise(
                id: g.stableID,
                name: g.name,
                movies: g.movies,
                tvItems: g.tvItems,
                coveredByChannelID: covered,
                fromDictionary: g.fromDictionary,
                enabled: covered == nil && FranchiseDictionary.isOn(
                    g.stableID, enabledIDs: enabledFranchiseIDs, disabledIDs: disabledFranchiseIDs)
            )
        }

        // Before the collection fold, so a server collection is matched against the
        // classic's full pool (films plus the shows the dictionary put on it).
        foldCoveredFranchisesIntoStockPools()
        applyFranchiseFolds(enrichmentFor: lookup)

        let listed = listedFoundFranchises
        let folded = discoveredCollections.filter(\.isFoldedIntoFranchise).count
        print("[Plex90] FRANCHISES: \(listed.count) found (\(listed.filter(\.enabled).count) on), \(coveredFoundFranchises.count) covered by stock channels, \(folded) collection(s) folded")
        for f in foundFranchises {
            let where_ = f.coveredByChannelID.map { "on CH \($0)" } ?? (f.enabled ? "ON" : "off")
            print("[Plex90] FRANCHISES:   \(f.name) \(f.countLabel) [\(where_)]")
        }
    }

    // MARK: - Stock pools

    /// A stock franchise channel's pool is what its channels.json rule passes UNION the
    /// items the builder placed on it. Six of the seven rules say `type: movie`, so
    /// without this The Mandalorian or Rings of Power were labelled "on CH 100/104" in
    /// Settings but never aired there. Swift only: the web tuner has no dictionary and
    /// keeps the rule-only pool. Only while the FRANCHISES package is on.
    ///
    /// Idempotent (deduped by item id), so it is safe after every rebuild. Every path
    /// that rebuilds a stock pool from its rule reaches `rebuildFoundFranchises` after.
    func foldCoveredFranchisesIntoStockPools() {
        guard isFranchisesBundleOn else { return }
        allChannels = Self.stockPools(
            allChannels,
            unionedWith: foundFranchises,
            memberships: channelMemberships,
            exclusiveRules: exclusiveRules
        )
    }

    /// Pure core of `foldCoveredFranchisesIntoStockPools`. Appends each covered
    /// franchise's movies and shows to its stock channel's pool, skipping anything
    /// already in the pool and anything another channel owns: a manifest lock
    /// (`exclusive`) or an exclusive rule that does not list this channel. Those are the
    /// same two locks `filterItems` honours, so an item it would refuse is refused here.
    nonisolated static func stockPools(
        _ channels: [Channel],
        unionedWith franchises: [FoundFranchise],
        memberships: ChannelMemberships,
        exclusiveRules: [ExclusiveRule]
    ) -> [Channel] {
        var extras: [Int: [PlexMediaItem]] = [:]
        for franchise in franchises {
            guard let channelID = franchise.coveredByChannelID else { continue }
            extras[channelID, default: []].append(contentsOf: franchise.items)
        }
        guard !extras.isEmpty else { return channels }

        return channels.map { channel in
            // Rule-built (stock) channels only; a runtime channel already owns its list.
            guard channel.rules != nil, let additions = extras[channel.id] else { return channel }
            var out = channel
            var seen = Set(out.itemPool.map(\.id))
            for item in additions where !seen.contains(item.id) {
                guard !isLockedElsewhere(item, channelID: channel.id,
                                         memberships: memberships,
                                         exclusiveRules: exclusiveRules) else { continue }
                out.itemPool.append(item)
                seen.insert(item.id)
            }
            return out
        }
    }

    /// True when `item` belongs to a channel other than `channelID` by a manifest lock
    /// or an exclusive rule. Mirrors the exclusivity checks in `filterItems`.
    nonisolated private static func isLockedElsewhere(
        _ item: PlexMediaItem,
        channelID: Int,
        memberships: ChannelMemberships,
        exclusiveRules: [ExclusiveRule]
    ) -> Bool {
        let mediaType = item.type == .episode ? "tv" : "movie"
        if let tmdbID = item.tmdbID,
           let locked = memberships.exclusive(forMediaType: mediaType, tmdbID: tmdbID),
           locked != channelID {
            return true
        }
        for rule in exclusiveRules where !rule.channelIDs.contains(channelID) && rule.applies(to: item) {
            if rule.matches(item) { return true }
            if rule.manifestExclusive, let tmdbID = item.tmdbID,
               let claimed = memberships.channels(forMediaType: mediaType, tmdbID: tmdbID),
               claimed.contains(where: { rule.channelIDs.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Marks every discovered collection that IS a franchise the package already carries.
    /// Safe to call whenever either side changes: after a collection scan and after a
    /// franchise rebuild.
    func applyFranchiseFolds(enrichmentFor: ((PlexMediaItem) -> MediaEnrichment?)? = nil) {
        guard !discoveredCollections.isEmpty else { return }
        let lookup: (PlexMediaItem) -> MediaEnrichment? = enrichmentFor ?? { [cache = enrichmentService.cache] item in
            guard let tmdbID = item.tmdbID else { return nil }
            return cache[tmdbID]
        }

        var targets: [FranchiseCollectionFold.Target] = []
        let stockIDs = availableStockFranchiseChannelIDs
        for channel in allChannels where stockIDs.contains(channel.id) {
            let dictName = FranchiseDictionary.all.first(where: { $0.stockChannelID == channel.id })?.canonicalName
            targets.append(FranchiseCollectionFold.Target(
                label: "CH \(channel.number) \(channel.name)",
                itemIDs: Set(channel.itemPool.map(\.id)),
                dictionaryName: dictName,
                stockChannelID: channel.id
            ))
        }
        for franchise in foundFranchises where !franchise.isCoveredByStock {
            targets.append(FranchiseCollectionFold.Target(
                label: franchise.name,
                itemIDs: Set(franchise.items.map(\.id)),
                dictionaryName: franchise.fromDictionary ? franchise.name : nil
            ))
        }

        let folds = FranchiseCollectionFold.folds(
            collections: discoveredCollections,
            targets: targets,
            enrichmentFor: lookup
        )
        for i in discoveredCollections.indices {
            let label = folds[discoveredCollections[i].id]
            if discoveredCollections[i].foldedIntoFranchise != label {
                discoveredCollections[i].foldedIntoFranchise = label
                if let label {
                    print("[Plex90] FRANCHISES: collection '\(discoveredCollections[i].title)' folds into \(label)")
                }
            }
        }
    }

    // MARK: - Switches

    /// Flips one found franchise and rebuilds the lineup, the same path `toggleCollection`
    /// takes so the guide never shows a stale row.
    func toggleFranchise(_ franchise: FoundFranchise) {
        guard let idx = foundFranchises.firstIndex(where: { $0.id == franchise.id }),
              !foundFranchises[idx].isCoveredByStock else { return }
        foundFranchises[idx].enabled.toggle()
        let nowEnabled = foundFranchises[idx].enabled
        recordFranchiseChoice(franchise.id, on: nowEnabled)
        // No id in the event: a franchise id says which films the viewer owns.
        Analytics.track(.settingChanged(key: "franchise", value: nowEnabled ? "true" : "false"))
        saveFranchisePreferences()
        materializeDynamicChannels()
        applyBundleFilter()
        reselectIfCurrentChannelLeft()
    }

    /// One row's switch in the franchise list. A stock row takes its channel in or out
    /// of the guide; a found row builds or drops its runtime channel.
    func toggleFranchiseRow(_ row: FranchiseListRow) {
        guard row.isStock else {
            if let franchise = foundFranchises.first(where: { $0.id == row.id }) {
                toggleFranchise(franchise)
            }
            return
        }
        let nowOn = !isStockFranchiseOn(row.id)
        recordFranchiseChoice(row.id, on: nowOn)
        Analytics.track(.settingChanged(key: "franchise", value: nowOn ? "true" : "false"))
        saveFranchisePreferences()
        applyBundleFilter()
        reselectIfCurrentChannelLeft()
    }

    /// ADD ALL / REMOVE ALL over the whole franchise list, stock classics included.
    func setAllFranchises(enabled: Bool) {
        let stockOffBefore = switchedOffStockFranchiseChannelIDs
        for row in franchiseListRows where row.isStock {
            recordFranchiseChoice(row.id, on: enabled)
        }
        let stockChanged = stockOffBefore != switchedOffStockFranchiseChannelIDs
        let foundChanged = foundFranchises.contains { !$0.isCoveredByStock && $0.enabled != enabled }
        if foundChanged {
            // Records the found choices, saves, rebuilds and refilters.
            setAllFoundFranchises(enabled: enabled)
        } else {
            for i in foundFranchises.indices where !foundFranchises[i].isCoveredByStock {
                recordFranchiseChoice(foundFranchises[i].id, on: enabled)
            }
            saveFranchisePreferences()
        }
        guard stockChanged else { return }
        if !foundChanged {
            Analytics.track(.settingChanged(key: "franchise:all", value: enabled ? "true" : "false"))
        }
        applyBundleFilter()
        reselectIfCurrentChannelLeft()
    }

    /// ADD ALL / REMOVE ALL over the listed (non-covered) found franchises.
    func setAllFoundFranchises(enabled: Bool) {
        var changed = false
        for i in foundFranchises.indices where !foundFranchises[i].isCoveredByStock {
            if foundFranchises[i].enabled != enabled {
                foundFranchises[i].enabled = enabled
                changed = true
            }
            recordFranchiseChoice(foundFranchises[i].id, on: enabled)
        }
        guard changed else { return }
        Analytics.track(.settingChanged(key: "franchise:all", value: enabled ? "true" : "false"))
        saveFranchisePreferences()
        materializeDynamicChannels()
        applyBundleFilter()
        reselectIfCurrentChannelLeft()
    }

    /// An explicit on or off. Both sets are kept so a default-on franchise the viewer
    /// switched off is not switched back on by the next rebuild (`FranchiseDictionary.isOn`).
    private func recordFranchiseChoice(_ id: String, on: Bool) {
        if on {
            enabledFranchiseIDs.insert(id)
            disabledFranchiseIDs.remove(id)
        } else {
            enabledFranchiseIDs.remove(id)
            disabledFranchiseIDs.insert(id)
        }
    }

    func saveFranchisePreferences() {
        let ids = Array(enabledFranchiseIDs).sorted()
        UserDefaults.standard.set(ids, forKey: Self.enabledFranchisesKey)
        preferenceSync.record(PreferenceSync.enabledFranchisesKey, value: ids)
        let offIDs = Array(disabledFranchiseIDs).sorted()
        UserDefaults.standard.set(offIDs, forKey: Self.disabledFranchisesKey)
        preferenceSync.record(PreferenceSync.disabledFranchisesKey, value: offIDs)
    }

    /// Replaces the switched-on franchise ids (an iCloud arrival) and rebuilds the lineup
    /// the way `toggleFranchise` does. Ids for franchises this library does not have are
    /// kept so they survive a round trip and simply match nothing here. `disabled` is
    /// the explicit-off set when it arrived too; nil keeps this TV's.
    func applyEnabledFranchiseIDs(_ ids: Set<String>, disabled: Set<String>? = nil) {
        let stockOffBefore = switchedOffStockFranchiseChannelIDs
        enabledFranchiseIDs = ids
        if let disabled { disabledFranchiseIDs = disabled }
        // A stock classic switched on or off on another TV changes the guide too.
        var changed = stockOffBefore != switchedOffStockFranchiseChannelIDs
        for i in foundFranchises.indices where !foundFranchises[i].isCoveredByStock {
            let on = FranchiseDictionary.isOn(
                foundFranchises[i].id, enabledIDs: enabledFranchiseIDs, disabledIDs: disabledFranchiseIDs)
            if foundFranchises[i].enabled != on {
                foundFranchises[i].enabled = on
                changed = true
            }
        }
        saveFranchisePreferences()
        guard changed else { return }
        materializeDynamicChannels()
        applyBundleFilter()
        reselectIfCurrentChannelLeft()
    }

    /// Removing the channel the viewer is on must not leave the player pointed at a row
    /// the guide no longer shows. Same rule `toggleBundle` applies.
    private func reselectIfCurrentChannelLeft() {
        if let current = currentChannel, !channels.contains(where: { $0.id == current.id }) {
            if let first = channels.first {
                selectChannel(first)
            } else {
                currentChannel = nil
                currentItem = nil
            }
        }
    }

    // MARK: - Demo fixture

    /// `-uiTestFranchiseFixture`: layers a small enriched library over demo mode so the
    /// franchise list and a found-franchise channel can be seen on a
    /// simulator with no server and no Supabase franchise columns. Never runs without the
    /// launch argument. See `DemoData.franchiseFixture`.
    func installFranchiseFixture() async {
        let fixture = DemoData.franchiseFixture()
        let demoChannelIDs = allChannels.map(\.id)
        allItems.append(contentsOf: fixture.items)
        enrichmentService.seedCache(fixture.enrichment)

        let config = ChannelConfigLoader.loadBundled()
        channelConfigChannels = config.channels
        exclusiveRules = config.exclusiveRules
        // Plus one ARTHOUSE channel the sample library cannot fill, so the DEMO row has a
        // channel short of content, as a real package often does.
        let shortChannel = config.bundles.first(where: { $0.id == "arthouse" })?.channelIDs.first
        let demoBundle = ChannelBundle(
            id: "demo", name: "DEMO", description: "Sample channels",
            channelIDs: demoChannelIDs + (shortChannel.map { [$0] } ?? []), activeMonths: nil, enabled: true
        )
        let franchisesBundle = config.bundles
            .first(where: { $0.id == Self.franchisesBundleID })?
            .toChannelBundle(enabled: true)
        bundles = [demoBundle] + (franchisesBundle.map { [$0] } ?? [])
        enabledBundleIDs = Set(bundles.map(\.id))

        let stockIDs = Set(franchisesBundle?.channelIDs ?? [])
        let built = await rebuildStaticChannelPools(
            configChannels: config.channels, items: allItems, onlyChannelIDs: stockIDs
        )
        allChannels = (allChannels.filter { !stockIDs.contains($0.id) } + built)
            .sorted { $0.number < $1.number }

        discoveredCollections = fixture.collections
        rebuildFoundFranchises()
        materializeDynamicChannels()
        applyBundleFilter()
        print("[Plex90] FRANCHISES: fixture installed, \(channels.count) channels in the guide")
    }
}
