import Foundation
import Observation
import SwiftUI
import AVFoundation
import Combine
import UIKit

// Channel config, bundles, collection discovery, audit and rule filtering.
// Split out of AppState.swift; behavior unchanged.
extension AppState {
    // MARK: - Channel config loading

    func loadChannelConfig() async -> ChannelConfigResult {
        // Try fetching channels.json from same server
        if !serverURL.isEmpty,
           let baseURL = URL(string: serverURL) {
            let configURL = baseURL.appendingPathComponent("channels.json")
            do {
                // Short timeout: this is an optional override with a bundled fallback, so a
                // sleeping or unreachable server must not hold the first step of onboarding
                // for the URLSession default of 60s with nothing on screen but "PREPARING".
                var req = URLRequest(url: configURL)
                req.timeoutInterval = 10
                let (data, _) = try await URLSession.shared.data(for: req)
                if let result = ChannelConfigLoader.loadConfig(from: data),
                   !result.channels.isEmpty {
                    print("[Plex90] CONFIG: server \(configURL.absoluteString) — \(Self.configDiagnostic(from: data))")
                    return result
                } else {
                    print("[Plex90] CONFIG: Server config parsed but empty or invalid, using bundled")
                }
            } catch {
                print("[Plex90] CONFIG: Server config load failed: \(error.localizedDescription), using bundled")
            }
        }

        // Fallback: bundled channels.json (copied from repo root on each Xcode build)
        let bundled = ChannelConfigLoader.loadBundled()
        if let url = Bundle.main.url(forResource: "channels", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            print("[Plex90] CONFIG: bundled — \(Self.configDiagnostic(from: data))")
        } else {
            print("[Plex90] CONFIG: bundled channels.json MISSING from app — channel rules will be empty")
        }
        return bundled
    }

    /// Quick sanity check in console: CH122 name and CH74 title-rule count change when config updates land.
    private static func configDiagnostic(from data: Data) -> String {
        guard let config = try? JSONDecoder().decode(ChannelConfig.self, from: data) else {
            return "unparseable"
        }
        let ch122 = config.channels.first(where: { $0.id == 122 })?.name ?? "?"
        let ch65Titles = config.channels.first(where: { $0.id == 65 })?.rules?.titleContains?.count ?? 0
        return "v\(config.version), \(config.channels.count) ch, CH132=\(ch122), CH65 title rules=\(ch65Titles)"
    }

    // MARK: - Bundle management

    func toggleBundle(_ bundle: ChannelBundle) {
        print("[Plex90] TOGGLE: '\(bundle.id)' (\(bundle.name)) - currently \(enabledBundleIDs.contains(bundle.id) ? "ON" : "OFF")")

        if enabledBundleIDs.contains(bundle.id) {
            // Prevent disabling the last enabled bundle
            guard enabledBundleIDs.count > 1 else { return }
            enabledBundleIDs.remove(bundle.id)
        } else {
            enabledBundleIDs.insert(bundle.id)
        }
        let nowEnabled = enabledBundleIDs.contains(bundle.id)
        print("[Plex90] TOGGLE: '\(bundle.id)' now \(nowEnabled ? "ON" : "OFF")")
        // Bundle IDs are static (`essentials`, `high-rotation`, `collections-franchises`,
        // …); safe to include as-is. Nothing here reveals library or user identity.
        Analytics.track(.settingChanged(key: "bundle:\(bundle.id)", value: nowEnabled ? "true" : "false"))

        rebuildLineupAfterBundleChange(newlyEnabled: nowEnabled ? [bundle] : [], byViewer: true)
    }

    /// Rebuilds the lineup after `enabledBundleIDs` changed. A toggle in Settings and a
    /// lineup arriving from another Apple TV through iCloud both come through here, so
    /// the guide is rebuilt the same way either way. Only the viewer's own toggle goes
    /// back out to iCloud.
    func rebuildLineupAfterBundleChange(newlyEnabled: [ChannelBundle], byViewer: Bool) {
        // Update runtime bundle state
        for i in bundles.indices {
            bundles[i].enabled = enabledBundleIDs.contains(bundles[i].id)
        }

        saveBundlePreferences(byViewer: byViewer)

        // Collection category bundles: scan if enabling and no collections discovered yet
        let needsCollectionScan = discoveredCollections.isEmpty
            && newlyEnabled.contains { $0.id.hasPrefix("collections-") }
        let staticBundles = newlyEnabled.filter { !$0.id.hasPrefix("collections-") }

        // A package switched off needs no build, and stops waiting for one.
        let switchedOff = Set(bundles.filter { !$0.enabled }.map(\.id))
        pendingBundleBuildIDs.subtract(switchedOff)
        buildingBundleIDs.subtract(switchedOff)

        if !staticBundles.isEmpty {
            buildingBundleIDs.formUnion(staticBundles.map(\.id))
            scheduleBundleBuild(staticBundles.map(\.id))
        }
        if needsCollectionScan {
            let previous = collectionScanTask
            collectionScanTask = Task {
                await previous?.value
                if !Task.isCancelled { await self.scanCollections() }
            }
        }
        // The scan applies the bundle filter itself when it finishes.
        if needsCollectionScan && staticBundles.isEmpty { return }

        applyBundleFilter()
        reselectIfCurrentChannelFilteredOut()
    }

    /// If the current channel got filtered out, select the first available.
    func reselectIfCurrentChannelFilteredOut() {
        if let current = currentChannel, !channels.contains(where: { $0.id == current.id }) {
            if let first = channels.first {
                selectChannel(first)
            } else {
                currentChannel = nil
                currentItem = nil
            }
        }
    }

    /// Enables every in-season bundle that has at least one qualifying channel, so a
    /// new user whose library doesn't match the default bundle still lands in a populated
    /// guide instead of the "no channels" dead end. Only meaningful when the full lineup
    /// has been built (first load), since `allChannels` is what determines availability.
    /// Returns true if any bundle was newly enabled.
    @discardableResult
    func autoEnableBundlesWithContent() -> Bool {
        let availableChannelIDs = Set(allChannels.map(\.id))
        var changed = false
        // Seasonal bundles are deliberately excluded: they are offered through
        // SeasonalPrompt and switched on only when the viewer says yes. Auto-enabling
        // them would put horror in front of someone every October without asking.
        for bundle in bundles where !bundle.id.hasPrefix("collections-")
            && bundle.activeMonths == nil {
            guard !enabledBundleIDs.contains(bundle.id) else { continue }
            let hasContent = bundle.channelIDs.contains { availableChannelIDs.contains($0) }
            if hasContent {
                enabledBundleIDs.insert(bundle.id)
                changed = true
                print("[Plex90] AUTO-ENABLE: '\(bundle.id)' (\(bundle.name)) has content")
            }
        }

        guard changed else { return false }

        for i in bundles.indices {
            bundles[i].enabled = enabledBundleIDs.contains(bundles[i].id)
        }
        saveBundlePreferences()
        applyBundleFilter()
        return true
    }

    /// Re-filter all channels using enriched TMDB data. Called after enrichment completes.
    /// Rebuilds from the full config so channels that were initially dropped (pool < minItems)
    /// can come back with enriched data.
    func refilterChannelsWithEnrichment() {
        print("[Plex90] ENRICHMENT: Re-filtering channels (\(enrichmentService.cache.count) TMDB, \(musicEnrichmentService.cache.count) music)")
        allItems = musicEnrichmentService.itemsWithDisplayMetadata(allItems)

        // Rebuild the filter cache from the post-enrichment item list so
        // matchesKeyword / matchesNetwork etc. see the freshly populated
        // enrichment data. Re-using a pre-enrichment cache here would silently
        // keep returning empty-enrichment results.
        let cached = makeFilterCache(allItems)

        let poolIDs = staticChannelIDsForPoolBuild(buildAllConfigChannels: false)
        var validStatic: [Channel] = []
        for var ch in channelConfigChannels where poolIDs.contains(ch.id) {
            ch.itemPool = Self.filterItems(cached, rules: ch.rules, forChannelID: ch.id, category: ch.category,
                                          memberships: channelMemberships, exclusiveRules: exclusiveRules)
            if ch.itemPool.count >= ch.minItems {
                validStatic.append(ch)
            }
        }
        validStatic.sort { $0.number < $1.number }

        let dynamicChannels = allChannels.filter { $0.rules == nil }
        allChannels = (validStatic + dynamicChannels).sorted { $0.number < $1.number }
        // The stock pools were just rebuilt from their rules alone.
        foldCoveredFranchisesIntoStockPools()
        applyBundleFilter()

        let newCount = validStatic.count
        let configCount = channelConfigChannels.count
        print("[Plex90] ENRICHMENT: \(newCount)/\(configCount) enabled-bundle channels have enough content after enrichment")
        printChannelAudit()
    }

    // MARK: - Seasonal invitations

    /// The seasonal bundle to invite the viewer to add, or nil. Seasonal bundles are never
    /// switched on for people — see `autoEnableBundlesWithContent`, which skips them.
    var seasonalBundleOnOffer: ChannelBundle? {
        _ = seasonalPromptRevision   // observation dependency; see the property's note
        return SeasonalPrompt.bundleToOffer(
            bundles: bundles,
            enabledBundleIDs: enabledBundleIDs,
            now: Date()
        ) { SeasonalPrompt.isSilenced(bundleID: $0, now: Date()) }
    }

    /// Applies the viewer's answer. "Yes" turns the bundle on for the rest of its season;
    /// Turning it on keeps it on: a seasonal package stays in the lineup until the viewer
    /// removes it. What the season controls is when it is offered and when it leads.
    func answerSeasonalPrompt(_ answer: SeasonalPrompt.Answer, for bundle: ChannelBundle) {
        let turnOn = SeasonalPrompt.record(answer, bundleID: bundle.id, now: Date())
        Analytics.track(.settingChanged(key: "seasonalPrompt:\(bundle.id)", value: "\(answer)"))
        seasonalPromptRevision += 1
        guard turnOn else { return }   // declined: the invite row just stops being offered
        toggleBundle(bundle)
    }

    func applyBundleFilter() {
        if bundles.isEmpty {
            // No bundles defined: show all channels (backward compat with v9 JSON)
            channels = allChannels
            return
        }

        var enabledChannelIDs: Set<Int> = bundles
            .filter { enabledBundleIDs.contains($0.id) }
            .reduce(into: Set<Int>()) { result, bundle in
                bundle.channelIDs.forEach { result.insert($0) }
            }
        // Found franchise channels are runtime channels that belong to the stock
        // FRANCHISES package: they show when it is on and go with it when it is off. The
        // bundle's own channelIDs stay the static list from channels.json so the Settings
        // row keeps reading "7/7 CH" and naming the classics only.
        if isFranchisesBundleOn {
            enabledChannelIDs.formUnion(foundFranchiseChannelIDs)
            // A classic switched off in the franchise list leaves the guide on its own.
            enabledChannelIDs.subtract(switchedOffStockFranchiseChannelIDs)
        }

        // A seasonal package leads the guide while it runs — see GuideChannelOrder.
        let seasonalLead = GuideChannelOrder.seasonalLeadIDs(
            bundles: bundles, enabledBundleIDs: enabledBundleIDs, now: Date())
        channels = GuideChannelOrder.sorted(
            allChannels.filter { enabledChannelIDs.contains($0.id) },
            seasonalFirst: seasonalLead)

        // Build bundle jump targets (first visible channel per enabled bundle)
        let channelSet = Set(channels.map(\.id))
        bundleJumpTargets = bundles
            .filter { enabledBundleIDs.contains($0.id) }
            .compactMap { bundle in
                // A FRANCHISES package whose classics have no content can still hold
                // found franchises; jump to the first of those instead of vanishing.
                let candidates = bundle.id == Self.franchisesBundleID
                    ? bundle.channelIDs + foundFranchiseChannelIDs
                    : bundle.channelIDs
                guard let firstID = candidates.first(where: { channelSet.contains($0) }),
                      let channel = channels.first(where: { $0.id == firstID }) else { return nil }
                return (bundleID: bundle.id, bundleName: bundle.name, firstChannelID: firstID, channelColor: channel.color)
            }
    }

    /// Saves the lineup on this TV. Only a change the viewer made (`byViewer`) goes to
    /// iCloud: the app also adjusts the set on its own while it loads (snapshot restore,
    /// collection categories, auto-enable, migrations), and pushing those let each TV's
    /// launch overwrite the other's lineup (seen on hardware, 2026-10-13).
    func saveBundlePreferences(byViewer: Bool = false) {
        UserDefaults.standard.set(Array(enabledBundleIDs), forKey: "nostalgex_enabled_bundles")
        if byViewer {
            preferenceSync.record(PreferenceSync.enabledBundlesKey, value: Array(enabledBundleIDs))
        }
    }

    // MARK: - Collection discovery and management

    private static let collectionColors: [String] = [
        "#E74C3C", "#3498DB", "#2ECC71", "#F39C12", "#9B59B6",
        "#1ABC9C", "#E67E22", "#00CED1", "#FF6B81", "#A29BFE"
    ]

    /// Scan Plex collections and populate discoveredCollections for user selection
    func scanCollections() async {
        isScanning = true
        scanningMessage = "Scanning collections..."
        collectionScanIndex = 0
        collectionScanTotal = 0
        print("[Plex90] COLLECTIONS: === STARTING SCAN ===")
        print("[Plex90] COLLECTIONS: allItems: \(allItems.count), serverURL: \(serverURL.prefix(30))...")

        guard !allItems.isEmpty else {
            print("[Plex90] COLLECTIONS: ERROR - allItems is empty")
            scanningMessage = "No library loaded"
            isScanning = false
            return
        }

        // Build static channel lookup for duplicate detection
        // Only check channels below the dynamic collection range (static channels)
        let staticChannels = allChannels.filter { $0.id < CollectionCategory.franchises.idBase }
        let staticChannelLookup: [(name: String, label: String)] = staticChannels.map {
            (name: $0.name.lowercased(), label: "CH \($0.number) \($0.name)")
        }

        // Scan collections on each selected server against that server's own movies.
        // Collection ratingKeys are server-local, so match per server and give each
        // discovered collection a server-qualified id to avoid cross-server collisions.
        let serversToScan: [ServerRef] = selectedServers.isEmpty
            ? [ServerRef(machineIdentifier: "", name: serverName, baseURL: serverURL, owned: true)]
            : selectedServers

        var collections4Plus: [DiscoveredCollection] = []
        var loggedSampleKeys = false
        // Every collection costs a round-trip; the sign-in can end while they run.
        let session = librarySessionGeneration

        for server in serversToScan {
            let scanAPI = server.machineIdentifier.isEmpty ? api : apiForServer(server)

            // Films and episodes from THIS server, keyed by raw ratingKey, with episodes
            // also grouped by show so a show in a collection expands to its episodes.
            // This used to index films only, which is where a collection of shows lost
            // every member and was skipped as "0 movies".
            // Items no channel may take (Emby Dolby Vision profile 5) are not members either.
            let serverItems = ChannelEligibility.onChannels(allItems, backend: backendKind)
                .filter { ($0.serverID ?? "") == server.machineIdentifier }
            let memberIndex = CollectionMemberIndex(items: serverItems)
            let serverMovieCount = serverItems.collectionMovieCount

            scanningMessage = "Reading collections on \(server.name)…"
            libraryLoadDetail = scanningMessage
            await Task.yield()

            guard let sections = try? await scanAPI.loadSections() else {
                print("[Plex90] COLLECTIONS: '\(server.name)' failed to load sections")
                continue
            }
            // TV libraries too: a Plex collection of shows lives in the TV library, and
            // reading movie libraries only meant it was never even listed. A section
            // the viewer turned off in library selection (I-054) is left out here too,
            // its collections are never read, same as its items never are.
            let excludedKeys = excludedSectionKeys(forServerID: server.machineIdentifier)
            let collectionSections = sections.filter {
                ($0.type == "movie" || $0.type == "show") && !excludedKeys.contains($0.key)
            }

            // Deduped by id: Plex scopes collections to a section, but Jellyfin and Emby
            // keep BoxSets in a virtual folder outside any library and hand back the same
            // global list for every section, so a two-library server would otherwise scan
            // and match each collection twice.
            var serverCollections: [PlexCollection] = []
            var seenCollectionKeys = Set<String>()
            for section in collectionSections {
                if let collections = try? await scanAPI.loadCollections(sectionKey: section.key) {
                    for collection in collections where seenCollectionKeys.insert(collection.ratingKey).inserted {
                        serverCollections.append(collection)
                    }
                }
            }
            print("[Plex90] COLLECTIONS: '\(server.name)' \(serverCollections.count) collections, \(serverMovieCount) movies, \(serverItems.count - serverMovieCount) episodes")

            collectionScanIndex = 0
            collectionScanTotal = serverCollections.count

            for (index, collection) in serverCollections.enumerated() {
                collectionScanIndex = index + 1
                if index % 2 == 0 {
                    scanningMessage = "Matching collections on \(server.name)…"
                    libraryLoadDetail = scanningMessage
                    await Task.yield()
                }

                let childKeys: [String]
                do {
                    childKeys = try await scanAPI.loadCollectionItems(collectionKey: collection.ratingKey)
                } catch {
                    continue
                }

                if !loggedSampleKeys && !childKeys.isEmpty {
                    print("[Plex90] COLLECTIONS: key sample \(childKeys.prefix(3)) vs \(serverItems.prefix(3).map(\.ratingKey))")
                    loggedSampleKeys = true
                }

                let matchedItems = memberIndex.resolve(childKeys)
                let matchedMovies = matchedItems.collectionMovieCount
                let membersLog = DiscoveredCollection.memberSummary(
                    movies: matchedMovies, shows: matchedItems.collectionShowCount,
                    episodes: matchedItems.count - matchedMovies)
                guard matchedItems.count >= CollectionMemberIndex.minimumItems else {
                    if !matchedItems.isEmpty {
                        print("[Plex90] COLLECTIONS: '\(collection.title)' -> \(membersLog) (too few, need \(CollectionMemberIndex.minimumItems)+)")
                    }
                    continue
                }

                // Check for matching static channel (fuzzy: strip "collection", compare substrings)
                let collectionClean = collection.title.lowercased()
                    .replacingOccurrences(of: " collection", with: "")
                    .replacingOccurrences(of: "collection", with: "")
                    .replacingOccurrences(of: "'s", with: "s")
                    .replacingOccurrences(of: "\u{2019}s", with: "s") // curly apostrophe
                    .trimmingCharacters(in: .whitespaces)

                // Extract decade from collection name (e.g., "2000s" -> "00s", "1980s" -> "80s")
                let decadeNormalized: String? = {
                    let digits = collectionClean.filter { $0.isNumber }
                    if digits.count == 4, let year = Int(digits) {
                        let short = year % 100
                        return String(format: "%02ds", short)
                    } else if digits.count == 2 {
                        return "\(digits)s"
                    }
                    return nil
                }()

                let matched = staticChannelLookup.first { entry in
                    if entry.name.contains(collectionClean) || collectionClean.contains(entry.name) {
                        return true
                    }
                    if let decade = decadeNormalized, entry.name.contains(decade) {
                        return true
                    }
                    return false
                }

                let collectionID = PlexAPIService.compositeID(serverID: server.machineIdentifier, ratingKey: collection.ratingKey)
                // Resolve enrichment eagerly into a plain map so the classifier can use
                // franchiseID truth (shared TMDB collection = franchise) without the
                // closure having to touch MainActor-isolated state.
                var enrichmentByID: [String: MediaEnrichment] = [:]
                for mi in matchedItems where mi.type == .movie {   // the classifier reads films only
                    if let e = enrichmentService.enrichment(for: mi) { enrichmentByID[mi.id] = e }
                }
                let category = CollectionClassifier.classify(
                    title: collection.title, items: matchedItems,
                    enrichmentFor: { enrichmentByID[$0.id] })
                // One entry per show, so a long-running show does not outweigh the rest of
                // the collection in "N% already on CH X".
                let overlap = computeContentOverlap(items: matchedItems.collectionTitleRepresentatives)
                collections4Plus.append(DiscoveredCollection(
                    id: collectionID,
                    title: collection.title.uppercased(),
                    movieCount: matchedMovies,
                    items: matchedItems,
                    enabled: enabledCollectionKeys.contains(collectionID),
                    matchedChannel: matched?.label,
                    contentOverlap: overlap,
                    category: category
                ))
                let overlapLog = overlap.map { " (overlap: \($0.percent)% on \($0.channelName))" } ?? ""
                print("[Plex90] COLLECTIONS: '\(collection.title)' -> \(membersLog) [\(category.rawValue)]\(matched.map { " (matches \($0.label))" } ?? "")\(overlapLog)")
            }
        }

        collectionScanIndex = 0
        collectionScanTotal = 0

        guard librarySessionGeneration == session else {
            print("[Plex90] COLLECTIONS: sign-in changed during the scan, discarding its results")
            isScanning = false
            scanningMessage = ""
            return
        }

        // Sort alphabetically
        collections4Plus.sort { a, b in
            return a.title < b.title
        }

        discoveredCollections = collections4Plus
        print("[Plex90] COLLECTIONS: \(discoveredCollections.count) discoverable channels (\(discoveredCollections.filter(\.enabled).count) enabled)")

        // A collection that is really a franchise the package already carries is credited
        // there and hidden here, so the same films are never offered twice.
        applyFranchiseFolds()

        // Materialize enabled ones into actual channels
        materializeDynamicChannels()
        applyBundleFilter()

        isScanning = false
        let now = Date()
        lastScanDate = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "nostalgex_last_scan_date")
        if discoveredCollections.isEmpty {
            scanningMessage = "No collections found"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanningMessage = ""
        } else {
            scanningMessage = ""
        }
        print("[Plex90] COLLECTIONS: === SCAN COMPLETE ===")
    }

    /// Toggle a discovered collection on/off and rebuild channels
    func toggleCollection(_ collection: DiscoveredCollection) {
        guard let idx = discoveredCollections.firstIndex(where: { $0.id == collection.id }) else { return }
        discoveredCollections[idx].enabled.toggle()

        if discoveredCollections[idx].enabled {
            enabledCollectionKeys.insert(collection.id)
        } else {
            enabledCollectionKeys.remove(collection.id)
        }
        saveCollectionPreferences()
        materializeDynamicChannels()
        applyBundleFilter()
    }

    /// Create Channel objects from enabled discovered collections, grouped by category
    /// Enables `collections-{category}` in the bundle filter whenever that category has at least one discovered collection.
    func syncCollectionCategoryBundlesWithDiscoveries(persistPreferences: Bool = true) {
        let visible = visibleDiscoveredCollections
        for category in CollectionCategory.allCases {
            let hasDiscoveries = visible.contains(where: { $0.category == category })
            if hasDiscoveries {
                enabledBundleIDs.insert(category.bundleID)
            }
        }
        if persistPreferences {
            saveBundlePreferences()
        }
    }

    /// Rebuilds every runtime channel: the found franchises that are switched on, then
    /// the enabled server collections per category. Both share the collection numbering
    /// convention (`idBase + slot`, `displayNumberBase + slot`); found franchises take the
    /// first slots of the FRANCHISES range and the category's own collections follow.
    func materializeDynamicChannels() {
        // Clear runtime-created channels only. This used to be "id >= 220", which also
        // deleted everything channels.json defined from 220 up — see ChannelIDSpace.
        allChannels.removeAll { ChannelIDSpace.isDynamic($0.id) }

        // Remove old collection bundles (both legacy and per-category)
        bundles.removeAll { $0.id == "collections" || $0.id.hasPrefix("collections-") }

        syncCollectionCategoryBundlesWithDiscoveries(persistPreferences: false)

        // Each block hands out at most `capacity` numbers. Anything enabled past that is
        // not built, so a big library can never reach the next block's numbers.
        var overCap: [DynamicChannelBlock: Int] = [:]

        func makeChannel(_ block: DynamicChannelBlock, slot: Int, name: String,
                         category: CollectionCategory, items: [PlexMediaItem]) -> Channel {
            var channel = Channel(
                id: block.idBase + slot,
                number: block.displayNumberBase + slot,
                name: name,
                color: Color(hex: Self.collectionColors[slot % Self.collectionColors.count]),
                category: category.rawValue,
                rules: nil,
                timeRestrictions: nil,
                minItems: 3
            )
            channel.itemPool = items
            return channel
        }

        // Found franchises: CH 300-449. They are not a bundle of their own: applyBundleFilter
        // shows them whenever the stock FRANCHISES package is on.
        let foundBlock = DynamicChannelBlock.foundFranchises
        let found = DynamicChannelBlock.keptInDisplayOrder(
            foundFranchises.filter { $0.enabled && !$0.isCoveredByStock },
            capacity: foundBlock.capacity,
            name: \.name, stableID: \.id, films: \.movies.count)
        if found.skipped > 0 { overCap[foundBlock] = found.skipped }
        var franchiseIDs: [Int] = []
        for (slot, franchise) in found.kept.enumerated() {
            let channel = makeChannel(foundBlock, slot: slot, name: franchise.name,
                                      category: .franchises, items: franchise.items)
            allChannels.append(channel)
            franchiseIDs.append(channel.id)
        }
        foundFranchiseChannelIDs = franchiseIDs
        if !franchiseIDs.isEmpty {
            print("[Plex90] FRANCHISES: \(franchiseIDs.count) found-franchise channel(s) from CH \(foundBlock.displayNumberBase)")
        }

        // Server collections, each category in its own block: franchise collections CH
        // 450-499, everything else CH 500-699. Neither depends on the found franchises, so
        // the FRANCHISES package and its switches never move them.
        // A folded collection is credited to a franchise and never materialised, even if
        // it was switched on before the fold existed.
        let visible = visibleDiscoveredCollections
        for category in CollectionCategory.allCases {
            let categoryCollections = visible.filter { $0.category == category }

            // Only create bundle if this category has discovered collections
            guard !categoryCollections.isEmpty else { continue }

            let block = category.block
            let enabledInCategory = categoryCollections.filter(\.enabled)
            let kept: [DiscoveredCollection]
            let skipped: Int
            switch block {
            case .otherCollections:
                // Unchanged, and what the web tuner mirrors: scan order (A to Z), the first
                // `capacity` switched on.
                kept = Array(enabledInCategory.prefix(block.capacity))
                skipped = enabledInCategory.count - kept.count
            default:
                (kept, skipped) = DynamicChannelBlock.keptInDisplayOrder(
                    enabledInCategory, capacity: block.capacity,
                    name: \.title, stableID: \.id, films: \.movieCount)
            }
            if skipped > 0 { overCap[block] = skipped }

            var channelIDs: [Int] = []
            for (slot, dc) in kept.enumerated() {
                let channel = makeChannel(block, slot: slot, name: dc.title, category: category, items: dc.items)
                allChannels.append(channel)
                channelIDs.append(channel.id)
            }

            let bundle = ChannelBundle(
                id: category.bundleID,
                name: category.displayName,
                description: category.bundleDescription,
                channelIDs: channelIDs,
                activeMonths: nil,
                enabled: enabledBundleIDs.contains(category.bundleID)
            )
            bundles.append(bundle)
            print("[Plex90] COLLECTIONS: [\(category.rawValue)] \(enabledInCategory.count)/\(categoryCollections.count) enabled -> \(channelIDs.count) channels")
        }

        for (block, skipped) in overCap.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("[Plex90] COLLECTIONS: [\(block.rawValue)] \(skipped) enabled channel(s) skipped, CH \(block.displayNumberBase)-\(block.displayNumberEnd) is full (\(block.capacity) max)")
        }
        if overCap != dynamicChannelsOverCap { dynamicChannelsOverCap = overCap }

        allChannels.sort { $0.number < $1.number }
        saveBundlePreferences()
    }

    /// Entry point for "Scan My Collections" button -- scans, classifies, and auto-enables non-empty category bundles
    func scanAndCategorizeCollections() {
        collectionScanTask?.cancel()
        collectionScanTask = Task {
            await scanCollections()
            // Auto-enable category bundles that have content
            let visible = visibleDiscoveredCollections
            for category in CollectionCategory.allCases {
                let hasContent = visible.contains { $0.category == category }
                if hasContent && !enabledBundleIDs.contains(category.bundleID) {
                    enabledBundleIDs.insert(category.bundleID)
                }
            }
            for i in bundles.indices {
                bundles[i].enabled = enabledBundleIDs.contains(bundles[i].id)
            }
            saveBundlePreferences()
            applyBundleFilter()
        }
    }

    /// Migrate legacy "collections" bundle ID to per-category bundle IDs
    func migrateCollectionBundleIDs() {
        if enabledBundleIDs.contains("collections") {
            enabledBundleIDs.remove("collections")
            for category in CollectionCategory.allCases {
                enabledBundleIDs.insert(category.bundleID)
            }
            saveBundlePreferences()
            print("[Plex90] MIGRATION: Migrated 'collections' -> per-category bundle IDs")
        }
        // NOTABLE STARS was retired; its collections now classify as OTHER COLLECTIONS, so
        // a viewer who had that category on keeps those collections under the new one.
        if enabledBundleIDs.contains(Self.retiredActorsBundleID) {
            enabledBundleIDs.remove(Self.retiredActorsBundleID)
            enabledBundleIDs.insert(CollectionCategory.custom.bundleID)
            saveBundlePreferences()
            print("[Plex90] MIGRATION: Migrated '\(Self.retiredActorsBundleID)' -> '\(CollectionCategory.custom.bundleID)'")
        }
    }

    /// The bundle id of the removed NOTABLE STARS category, kept only for migration.
    static let retiredActorsBundleID = "collections-actors"

    func saveCollectionPreferences() {
        UserDefaults.standard.set(Array(enabledCollectionKeys), forKey: "nostalgex_enabled_collections")
        preferenceSync.record(PreferenceSync.enabledCollectionsKey, value: Array(enabledCollectionKeys))
    }

    // MARK: - Channel audit log

    func printChannelAudit() {
        print("[Plex90] ====== CHANNEL AUDIT ======")
        // Compact regression-guard line for diffing filter behavior across
        // refactors. `printChannelAuditFingerprint` is grep-friendly so a
        // before/after run can be diffed in one shot.
        printChannelAuditFingerprint()
        var totalItems = 0
        for channel in allChannels {
            let pool = channel.itemPool
            totalItems += pool.count

            // Build rules summary
            var ruleParts: [String] = []
            if let rules = channel.rules {
                if let t = rules.type { ruleParts.append(t.rawValue) }
                if let g = rules.genres {
                    if !g.include.isEmpty { ruleParts.append("genres: \(g.include.joined(separator: "/"))") }
                    if !g.exclude.isEmpty { ruleParts.append("exclude: \(g.exclude.joined(separator: "/"))") }
                }
                if let yr = rules.yearRange {
                    let min = yr.min.map(String.init) ?? ""
                    let max = yr.max.map(String.init) ?? ""
                    ruleParts.append("years \(min)-\(max)")
                }
                if let s = rules.studios, !s.isEmpty { ruleParts.append("studios: \(s.prefix(3).joined(separator: "/"))") }
                if let r = rules.ratingMin { ruleParts.append("rating \(r)+") }
                if rules.watchedOnly { ruleParts.append("watched") }
                if rules.rewatched { ruleParts.append("rewatched 3+") }
                if let tc = rules.titleContains, !tc.isEmpty { ruleParts.append("titles: \(tc.prefix(3).joined(separator: "/"))...") }
                if let kw = rules.keywords, !kw.isEmpty { ruleParts.append("keywords: \(kw.prefix(3).joined(separator: "/"))") }
                if let net = rules.networks, !net.isEmpty { ruleParts.append("networks: \(net.joined(separator: "/"))") }
                if let pc = rules.productionCompanies, !pc.isEmpty { ruleParts.append("prodcos: \(pc.prefix(3).joined(separator: "/"))") }
            }
            if channel.rules == nil { ruleParts.append("no rules (dynamic)") }

            let rulesStr = ruleParts.isEmpty ? "all content" : ruleParts.joined(separator: ", ")
            print("[Plex90] CH \(channel.number) \(channel.name) | \(pool.count) items | Rules: \(rulesStr)")

            // All titles (include studio for studio-matched channels)
            let isStudioChannel = channel.rules?.studios != nil && !(channel.rules?.studios?.isEmpty ?? true)
            for item in pool {
                if item.type == .episode {
                    let ep = [item.seTag, item.episodeTitle].compactMap { $0 }.joined(separator: " ")
                    print("[Plex90]   - \(item.title): \(ep)")
                } else {
                    let genres = item.genres.joined(separator: ", ")
                    let studio = isStudioChannel ? " studio=\"\(item.studio ?? "nil")\"" : ""
                    print("[Plex90]   - \(item.title) (\(item.year ?? 0)) [\(genres)]\(studio)")
                }
            }
        }
        print("[Plex90] ==============================")
        print("[Plex90] TOTAL: \(allChannels.count) channels, \(totalItems) items across all pools")
    }

    /// One line per channel: `id | poolCount | first-20 ratingKey hash`. Diff
    /// before/after a filter refactor to prove behavior is preserved — any
    /// poolCount delta or hash delta = regression. Hash is FNV-1a 32-bit of
    /// the joined ratingKeys, plenty for our scale and reproducible across runs.
    private func printChannelAuditFingerprint() {
        for channel in allChannels.sorted(by: { $0.id < $1.id }) {
            let head = channel.itemPool.prefix(20).map(\.ratingKey).joined(separator: ",")
            var h: UInt32 = 2166136261
            for b in head.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            print("[Plex90] AUDIT-FP ch=\(channel.id) n=\(channel.itemPool.count) h=\(String(h, radix: 16))")
        }
    }

    // MARK: - Channel pool building

    /// Static channel IDs whose pools should be built (incremental = enabled bundles only).
    func staticChannelIDsForPoolBuild(buildAllConfigChannels: Bool) -> Set<Int> {
        if buildAllConfigChannels || bundles.isEmpty {
            return Set(channelConfigChannels.map(\.id))
        }
        var ids = Set<Int>()
        for bundle in bundles where enabledBundleIDs.contains(bundle.id) {
            bundle.channelIDs.forEach { ids.insert($0) }
        }
        return ids
    }

    /// Re-filter static channel pools and merge into `allChannels`.
    func rebuildStaticChannelPools(
        configChannels: [Channel],
        items: [PlexMediaItem],
        onlyChannelIDs: Set<Int>
    ) async -> [Channel] {
        channelBuildTotal = onlyChannelIDs.count
        channelBuildIndex = 0

        // Snapshot the per-item filter cache ONCE. Every channel below reads
        // the same precomputed titleLower/genreSet/enrichment — avoids 425k+
        // redundant lowercase + regex calls across the channel loop.
        let cached = makeFilterCache(items)
        LibraryLoadProbe.mark("filterCache")
        let memberships = channelMemberships
        let rules = exclusiveRules
        let targets = configChannels.filter { onlyChannelIDs.contains($0.id) }

        // The filtering runs off the main actor. Only the per-channel progress tick hops
        // back, so the focus engine stays responsive while a background refresh rebuilds
        // the lineup — the guide used to be unscrollable for the whole rebuild.
        let built = await Task.detached(priority: .utility) { () -> [Channel] in
            var out: [Channel] = []
            for var ch in targets {
                ch.itemPool = AppState.filterItems(cached, rules: ch.rules, forChannelID: ch.id,
                                                   category: ch.category,
                                                   memberships: memberships, exclusiveRules: rules)
                let name = ch.name
                if ch.itemPool.count >= ch.minItems { out.append(ch) }
                await MainActor.run { [weak self] in
                    self?.channelBuildIndex += 1
                    self?.setLibraryPhase(.buildingChannels, detail: name)
                }
            }
            return out
        }.value
        LibraryLoadProbe.mark("poolBuild")
        return built.sorted { $0.number < $1.number }
    }

    /// How long a package build waits after the last switch before it starts, so a few
    /// quick switches are built together: one filter pass, one guide swap, one snapshot.
    static let bundleBuildSettle: Duration = .milliseconds(500)

    /// Queues a build for packages just switched on. The switch itself has already flipped
    /// and saved; this only makes the channels. Matches the Roku app: the press never
    /// waits for the build, the row shows BUILDING, the guide takes the new lineup when
    /// it is ready, and switches made while one waits or builds are folded into one build.
    ///
    /// A new switch restarts the wait (and drops a build already running, whose result
    /// would be one package short), so a run of quick switches reaches the guide once.
    func scheduleBundleBuild(_ ids: [String]) {
        pendingBundleBuildIDs.formUnion(ids)
        let previous = bundleBuildTask
        previous?.cancel()
        bundleBuildTask = Task { [weak self] in
            await previous?.value
            try? await Task.sleep(for: Self.bundleBuildSettle)
            guard !Task.isCancelled, let self else { return }
            await self.buildPendingBundles()
        }
    }

    /// Builds every package waiting in `pendingBundleBuildIDs`. The filtering, the slow
    /// part, runs off the main actor; only the merge into the lineup runs on it. Before
    /// this, each package was filtered on the main actor (yielding every third channel),
    /// which held it for 350 to 580 ms at a time for about 3 s on an 11,863-item library
    /// on a simulator: the switch drew late and the remote stopped answering.
    func buildPendingBundles() async {
        let ids = pendingBundleBuildIDs
        let toBuild = bundles.filter { ids.contains($0.id) && enabledBundleIDs.contains($0.id) }
        let channelIDs = Set(toBuild.flatMap(\.channelIDs))
        guard !toBuild.isEmpty, !channelIDs.isEmpty,
              !channelConfigChannels.isEmpty, !allItems.isEmpty else {
            pendingBundleBuildIDs.subtract(ids)
            buildingBundleIDs.subtract(ids)
            return
        }

        let buildStarted = Date()
        let session = librarySessionGeneration
        let cached = makeFilterCache(allItems)
        let memberships = channelMemberships
        let rules = exclusiveRules
        let templates = channelConfigChannels.filter { channelIDs.contains($0.id) }

        let work = Task.detached(priority: .userInitiated) { () -> [Channel]? in
            var out: [Channel] = []
            for var template in templates {
                if Task.isCancelled { return nil }
                template.itemPool = AppState.filterItems(
                    cached, rules: template.rules, forChannelID: template.id,
                    category: template.category, memberships: memberships, exclusiveRules: rules)
                out.append(template)
            }
            return out
        }
        let filtered = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        // A newer switch took over, or the sign-in changed while this ran.
        guard let filtered, !Task.isCancelled, session == librarySessionGeneration else { return }

        mergeBuiltPackageChannels(filtered)
        if toBuild.contains(where: { $0.id == Self.franchisesBundleID }) {
            // The classics were not in the lineup while the package was off, so nothing
            // could fold into them. Now that CH100-106 exist, re-decide which found
            // franchises are covered and which collections fold.
            rebuildFoundFranchises()
            materializeDynamicChannels()
        }
        applyBundleFilter()
        saveLibrarySnapshotIfNeeded()
        bundleBuildCommits += 1
        pendingBundleBuildIDs.subtract(ids)
        buildingBundleIDs.subtract(ids)
        let made = filtered.filter { $0.itemPool.count >= $0.minItems }.count
        print("[Plex90] BUNDLE BUILD: \(toBuild.map(\.id).sorted()) -> \(made) channels with pools in \(String(format: "%.2f", Date().timeIntervalSince(buildStarted)))s")
    }

    /// Puts freshly filtered package channels into `allChannels`, as one change: a channel
    /// with enough items replaces or joins its old copy, one without drops out. Read
    /// against the lineup as it is now, not as it was when the build began, so anything
    /// that changed it meanwhile (a collection scan, a franchise switch) is kept.
    func mergeBuiltPackageChannels(_ filtered: [Channel]) {
        var builtStatic = allChannels.filter { $0.rules != nil }
        for template in filtered {
            if template.itemPool.count >= template.minItems {
                if let idx = builtStatic.firstIndex(where: { $0.id == template.id }) {
                    builtStatic[idx] = template
                } else {
                    builtStatic.append(template)
                }
            } else {
                builtStatic.removeAll { $0.id == template.id }
            }
        }
        let dynamic = allChannels.filter { $0.rules == nil }
        allChannels = (builtStatic + dynamic).sorted { $0.number < $1.number }
    }

    // MARK: - Filtering (keep in sync with scripts/nostalgex-channel-filter.cjs + plex-tuner)

    nonisolated private static let adultRatings: Set<String> = ["R", "NC-17", "TV-MA", "18", "18+", "X", "NR"]

    /// Compute how much a discovered Plex collection's content overlaps with what
    /// an existing channel already claims via the TMDB membership manifest.
    /// Returns the dominant matched channel only when overlap clears the threshold.
    /// Threshold of 60% balances "real overlap" against "tangentially related set."
    private func computeContentOverlap(items: [PlexMediaItem], thresholdPercent: Int = 60) -> ContentOverlap? {
        let total = items.count
        guard total > 0 else { return nil }
        var perChannel: [Int: Int] = [:]
        for item in items {
            guard let tmdbID = item.tmdbID else { continue }
            let mediaType = item.type == .episode ? "tv" : "movie"
            guard let claimed = channelMemberships.channels(forMediaType: mediaType, tmdbID: tmdbID) else { continue }
            for cid in claimed {
                perChannel[cid, default: 0] += 1
            }
        }
        guard let (channelID, count) = perChannel.max(by: { $0.value < $1.value }) else { return nil }
        let percent = Int((Double(count) / Double(total) * 100).rounded())
        guard percent >= thresholdPercent else { return nil }
        let name = allChannels.first(where: { $0.id == channelID }).map { "CH \($0.number) \($0.name)" } ?? "CH \(channelID)"
        return ContentOverlap(channelID: channelID, channelName: name, overlapCount: count, totalCount: total)
    }

    // Plex's originallyAvailableAt comes back as "YYYY-MM-DD"
    nonisolated private static let releaseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    // Genre-locked content: these genres ONLY appear on channels that explicitly include them
    nonisolated private static let horrorGenres: Set<String> = ["horror"]
    nonisolated private static let realityGenres: Set<String> = ["reality", "game show", "game-show", "reality-tv"]
    nonisolated private static let animationGenres: Set<String> = ["animation", "animated", "cartoon"]
    // "history" is deliberately not in documentaryGenres or warGenres. Plex tags
    // dramas like Apollo 13 and 12 Years a Slave as History, and no channel
    // includes History, so locking it barred them from every channel. Mirrors
    // scripts/nostalgex-channel-filter.cjs.
    nonisolated private static let documentaryGenres: Set<String> = ["documentary", "docuseries"]
    nonisolated private static let sportGenres: Set<String> = ["sport", "sports", "sports film"]
    nonisolated private static let musicGenres: Set<String> = ["music", "music video", "musical"]
    nonisolated private static let warGenres: Set<String> = ["war", "war & politics"]
    nonisolated private static let westernGenres: Set<String> = ["western"]
    nonisolated private static let talkShowGenres: Set<String> = ["talk show", "talk", "news"]

    /// Checks if a channel's genre include list contains any genre from the given set
    nonisolated private static func channelIncludesGenre(_ rules: ChannelRules?, from genreSet: Set<String>) -> Bool {
        rules?.genres?.include.contains(where: { genreSet.contains($0.lowercased()) }) ?? false
    }

    /// Word-boundary substring match (case-insensitive). The needle matches when
    /// it appears in haystack surrounded by word boundaries — letters/digits
    /// don't count as boundaries, but spaces and punctuation do.
    ///
    /// Example: needle "See" → matches "See", "See Me", "Don't See Me",
    /// but NOT "Stickbird", "Foundation", or "Seeing Red".
    ///
    /// Why this exists: titleContains / titleExcludes rules in channels.json
    /// sometimes include short common words (real Apple TV+ shows: "See",
    /// "Loot", "Trying"). Plain substring matching let those rules pull in
    /// unrelated content. Word boundaries fix it without forcing exact-only.
    ///
    /// Backward-compatible wrapper. Hot paths inside `filterItems` precompute
    /// lowercased rule arrays and call `titleContainsWordLower` directly to
    /// skip per-call lowercasing.
    nonisolated static func titleContainsWord(_ haystack: String, _ needle: String) -> Bool {
        titleContainsWordLower(haystack, needle.lowercased())
    }

    /// Same as `titleContainsWord` but assumes both inputs are already
    /// lowercased. Avoids NSRegularExpression entirely: linear scan with
    /// Character-based word-boundary checks (Unicode-correct via
    /// `Character.isLetter` / `isNumber`). This is the hot-path version called
    /// once per (item × rule entry) inside the filter loop, where the
    /// regex-based original was recompiling ~50k+ patterns per channel.
    nonisolated static func titleContainsWordLower(_ haystackLower: String, _ needleLower: String) -> Bool {
        guard !needleLower.isEmpty else { return false }
        var searchStart = haystackLower.startIndex
        while let range = haystackLower.range(of: needleLower, range: searchStart..<haystackLower.endIndex) {
            let leftOK: Bool
            if range.lowerBound == haystackLower.startIndex {
                leftOK = true
            } else {
                let prev = haystackLower[haystackLower.index(before: range.lowerBound)]
                leftOK = !prev.isLetter && !prev.isNumber
            }
            let rightOK: Bool
            if range.upperBound == haystackLower.endIndex {
                rightOK = true
            } else {
                let next = haystackLower[range.upperBound]
                rightOK = !next.isLetter && !next.isNumber
            }
            if leftOK && rightOK { return true }
            searchStart = haystackLower.index(after: range.lowerBound)
        }
        return false
    }

    /// Whether a channel carries episode rules (any of the three include lists).
    /// Mirrors `hasEpisodeRules` in scripts/nostalgex-channel-filter.cjs.
    nonisolated static func hasEpisodeRules(_ rules: ChannelRules) -> Bool {
        !(rules.episodeTitleContains ?? []).isEmpty
            || !(rules.episodeSummaryContains ?? []).isEmpty
            || !(rules.episodeSeasonalTitleContains ?? []).isEmpty
    }

    /// Episode rules, against the item's OWN title: the episode title for an episode, the
    /// title (year suffix stripped) for anything else, so a half-hour special stored as a
    /// film matches the way an episode does. Whole words, lists already lowercased.
    /// - excludes veto
    /// - a title word matches
    /// - a summary word matches
    /// - a seasonal title word matches only for an episode first aired inside the window
    /// Mirrors `episodeRulesMatch` in scripts/nostalgex-channel-filter.cjs; both read
    /// scripts/filter-golden.json.
    nonisolated static func episodeRulesMatch(
        _ item: PlexMediaItem,
        episodeTitleLower: String,
        titleContains: [String],
        summaryContains: [String],
        seasonalTitleContains: [String],
        airWindow: AirWindow?,
        titleExcludes: [String]
    ) -> Bool {
        let own = item.type == .episode
            ? episodeTitleLower
            : stripTrailingYearSuffix(item.title.lowercased())
        func has(_ list: [String], _ hay: String) -> Bool {
            !hay.isEmpty && list.contains(where: { titleContainsWordLower(hay, $0) })
        }
        if has(titleExcludes, own) { return false }
        if has(titleContains, own) { return true }
        if !summaryContains.isEmpty && has(summaryContains, item.summary.lowercased()) { return true }
        if item.type == .episode, !seasonalTitleContains.isEmpty,
           airWindow?.contains(date: item.originallyAvailableAt) == true,
           has(seasonalTitleContains, own) {
            return true
        }
        return false
    }

    /// Release year for filtering: Plex `year`, else calendar year from `originallyAvailableAt`.
    /// Plex genres plus MusicBrainz tags for music-video items.
    private func effectiveGenres(for item: PlexMediaItem) -> [String] {
        var genres = item.genres
        if (item.librarySource ?? .movie) == .musicVideo,
           let music = musicEnrichmentService.enrichment(for: item) {
            for g in music.genres {
                if !genres.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                    genres.append(g)
                }
            }
        }
        return genres
    }

    private func filterTitleHaystack(_ item: PlexMediaItem) -> String {
        var parts: [String] = []
        if let artist = item.artist ?? musicEnrichmentService.enrichment(for: item)?.artist,
           !artist.isEmpty {
            parts.append(artist)
        }
        parts.append(item.title)
        let lower = parts.joined(separator: " ").lowercased()
        return Self.stripTrailingYearSuffix(lower)
    }

    /// Strip a trailing " (YYYY)" suffix from a lowercased title. Plex's
    /// TMDB-Movie agent often appends release year to disambiguate; rules
    /// like "Bluey" should still match "bluey (2018)". The old impl ran a
    /// regex on every call which recompiled per-item; this manual scan is
    /// allocation-free for the common no-suffix case and a single substring
    /// otherwise.
    nonisolated static func stripTrailingYearSuffix(_ s: String) -> String {
        // Expect exactly " (NNNN)" — 7 chars — at the end.
        guard s.count >= 7, s.hasSuffix(")") else { return s }
        let endIdx = s.index(s.endIndex, offsetBy: -7)
        let chars = Array(s[endIdx..<s.endIndex])
        guard chars[0] == " ",
              chars[1] == "(",
              chars[2].isNumber, chars[3].isNumber,
              chars[4].isNumber, chars[5].isNumber,
              chars[6] == ")" else { return s }
        return String(s[..<endIdx])
    }

    nonisolated static func itemReleaseYear(_ item: PlexMediaItem) -> Int? {
        if let year = item.year { return year }
        if let dateStr = item.originallyAvailableAt,
           let date = Self.releaseDateFormatter.date(from: dateStr) {
            return Calendar.current.component(.year, from: date)
        }
        return nil
    }

    /// Decade/era gate — only when `yearRange` is set on the channel. Excludes
    /// items with a known year outside the range; items with no year metadata pass
    /// (avoid dropping good matches on sparse Plex data). Still applies to TMDB
    /// manifest claims so recommendations can't bypass era rules.
    nonisolated static func passesYearRange(_ item: PlexMediaItem, rules: ChannelRules) -> Bool {
        guard let yr = rules.yearRange else { return true }
        guard let year = Self.itemReleaseYear(item) else { return true }
        if let min = yr.min, year < min { return false }
        if let max = yr.max, year > max { return false }
        return true
    }

    /// Per-item data snapshotted once at the start of a filter pass so we don't
    /// recompute the same lowercased title, genre set, or enrichment lookup
    /// 425k+ times across the channel build loop. Build via `makeFilterCache`.
    struct FilterCache {
        let item: PlexMediaItem
        let titleLower: String          // lowercased + trailing " (YYYY)" stripped, prefixed with artist when present
        let episodeTitleLower: String   // "" for anything that is not an episode
        let genresLowerSet: Set<String> // effective genres (Plex + music enrichment) lowercased
        let enrichment: MediaEnrichment?
        let itemStudioLower: String     // "" when item has no studio
        /// `ChannelEligibility.isLeftOffChannels` for the active backend: no channel takes it.
        var leftOffChannels = false
        /// The item's rating as the US label the rules read (`ContentRating.usLabel`): GB-15 is R on
        /// a film, TV-MA on an episode. Worked out once here, not once per channel. Display keeps
        /// the raw label.
        let usContentRating: String?

        init(item: PlexMediaItem, titleLower: String, episodeTitleLower: String, genresLowerSet: Set<String>,
             enrichment: MediaEnrichment?, itemStudioLower: String, leftOffChannels: Bool = false) {
            self.item = item
            self.titleLower = titleLower
            self.episodeTitleLower = episodeTitleLower
            self.genresLowerSet = genresLowerSet
            self.enrichment = enrichment
            self.itemStudioLower = itemStudioLower
            self.leftOffChannels = leftOffChannels
            self.usContentRating = ContentRating.usLabel(item.contentRating, type: item.type)
        }
    }

    /// How many library items match a channel's own rules right now, ignoring
    /// `minItems`. For Settings' "why is this channel off the air" explainer (I-004)
    /// only: a plain re-run of the same `filterItems` the real pool build uses, on
    /// demand for one channel, so the count the viewer reads can never drift from what
    /// actually decides the channel's pool. Does not touch `itemPool` or `allChannels`.
    /// Dynamic and franchise channels have no `rules`, so the explainer never calls this
    /// for them; it falls back to the stored pool size rather than claim a count.
    func currentMatchCount(for channel: Channel) -> Int {
        guard let rules = channel.rules else { return channel.itemPool.count }
        let cached = makeFilterCache(allItems)
        return Self.filterItems(
            cached,
            rules: rules,
            forChannelID: channel.id,
            category: channel.category,
            memberships: channelMemberships,
            exclusiveRules: exclusiveRules
        ).count
    }

    /// Same as `currentMatchCount(for:)`, for several channels at once: the library
    /// cache is built once and reused for every channel, rather than once per channel.
    /// The explainer (I-004) calls this instead of looping `currentMatchCount` itself,
    /// so expanding a package with several missing channels doesn't re-scan the whole
    /// library once per row.
    func currentMatchCounts(for channels: [Channel]) -> [Int: Int] {
        let cached = makeFilterCache(allItems)
        var result: [Int: Int] = [:]
        for channel in channels {
            guard let rules = channel.rules else {
                result[channel.id] = channel.itemPool.count
                continue
            }
            result[channel.id] = Self.filterItems(
                cached,
                rules: rules,
                forChannelID: channel.id,
                category: channel.category,
                memberships: channelMemberships,
                exclusiveRules: exclusiveRules
            ).count
        }
        return result
    }

    /// Build a snapshot cache for a set of items. Called once per filter pass —
    /// per `loadLibrary`, per `buildPendingBundles`, and per
    /// `refilterChannelsWithEnrichment`. Enrichment is read here so any later
    /// asynchronous enrichment landings don't make the cache inconsistent
    /// mid-build (build loop is single-threaded on MainActor; rebuild is the
    /// re-snapshot point).
    private func makeFilterCache(_ items: [PlexMediaItem]) -> [FilterCache] {
        items.map { item in
            FilterCache(
                item: item,
                titleLower: filterTitleHaystack(item),
                episodeTitleLower: (item.episodeTitle ?? "").lowercased(),
                genresLowerSet: Set(effectiveGenres(for: item).map { $0.lowercased() }),
                enrichment: enrichmentService.enrichment(for: item),
                itemStudioLower: (item.studio ?? "").lowercased(),
                leftOffChannels: ChannelEligibility.isLeftOffChannels(item, backend: backendKind)
            )
        }
    }

    /// Pure, `nonisolated` so the channel build can run OFF the main actor. It used to be a
    /// main-actor method, and a post-launch background refresh rebuilding ~121 channel pools
    /// held the main actor in long blocks — measured at 240ms (2.6k items) and 1.1s (9.5k
    /// items) per block on a Mac, several times that on an Apple TV HD. The focus engine
    /// cannot move during those, which is what made the guide feel unscrollable.
    nonisolated static func filterItems(
        _ cached: [FilterCache],
        rules: ChannelRules?,
        forChannelID channelID: Int = 0,
        category: String? = nil,
        memberships: ChannelMemberships,
        exclusiveRules: [ExclusiveRule]
    ) -> [PlexMediaItem] {
        guard let rules else { return cached.filter { !$0.leftOffChannels }.map(\.item) }
        let currentYear = Calendar.current.component(.year, from: Date())
        let isKids = category == "kids"
        let hasFamilyGenre = rules.genres?.include.contains(where: { $0.lowercased() == "family" }) ?? false
        let isFamilySafe = isKids || hasFamilyGenre

        // Studio-only channels (e.g. streamers like Netflix, HBO) bypass genre-locking
        // so they show ALL their content regardless of genre
        let isStudioChannel = !(rules.studios ?? []).isEmpty
            && (rules.genres?.include.isEmpty ?? true)

        // Check which genre-locked categories this channel explicitly opts into
        let allowsHorror = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.horrorGenres)
        let allowsReality = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.realityGenres)
        // Episode rules are a curated list the same way a title list is, so they open the
        // Animation lock too: Bluey's and The Simpsons' Christmas episodes belong on the
        // holiday TV channels.
        let isEpisodeCurated = Self.hasEpisodeRules(rules)
        let hasTitleCurated = !(rules.titleContains ?? []).isEmpty || isEpisodeCurated
        let allowsAnimation = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.animationGenres) || isKids || hasTitleCurated
        let allowsDocumentary = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.documentaryGenres)
        // Sport genre is not globally blocked — sports movies (Rudy, Space Jam, The Sixth Man)
        // flow to any channel their other genres qualify them for.
        let allowsMusic = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.musicGenres) || category == "music"
        let allowsWar = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.warGenres)
        let allowsWestern = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.westernGenres)
        let allowsTalkShow = isStudioChannel || Self.channelIncludesGenre(rules, from: Self.talkShowGenres)

        // Lowercase rule arrays once per channel instead of per item (5000× savings)
        let titleContainsLower = rules.titleContains?.map { $0.lowercased() } ?? []
        let episodeTitleContainsLower = rules.episodeTitleContains?.map { $0.lowercased() } ?? []
        let episodeSummaryContainsLower = rules.episodeSummaryContains?.map { $0.lowercased() } ?? []
        let episodeSeasonalTitleContainsLower = rules.episodeSeasonalTitleContains?.map { $0.lowercased() } ?? []
        let episodeTitleExcludesLower = rules.episodeTitleExcludes?.map { $0.lowercased() } ?? []
        let titleExcludesLower = rules.titleExcludes?.map { $0.lowercased() } ?? []
        let studiosLower = rules.studios?.map { $0.lowercased() } ?? []
        let keywordsLower = rules.keywords?.map { $0.lowercased() } ?? []
        let keywordsExcludeLower = rules.keywordsExclude?.map { $0.lowercased() } ?? []
        let keywordsRequireAnyGenreLower = rules.keywordsRequireAnyGenre?.map { $0.lowercased() } ?? []
        let keywordGatedGenresLower = rules.keywordGatedGenres?.map { $0.lowercased() } ?? []
        let networksLower = rules.networks?.map { $0.lowercased() } ?? []
        let productionCompaniesLower = rules.productionCompanies?.map { $0.lowercased() } ?? []
        let genresIncludeLower = rules.genres?.include.map { $0.lowercased() } ?? []
        let genresExcludeLower = rules.genres?.exclude.map { $0.lowercased() } ?? []
        let genresRequireAllLower = rules.genres?.requireAll.map { $0.lowercased() } ?? []
        let editorialOverridesLower = rules.editorialOverrides?.map { $0.lowercased() } ?? []
        let contentRatingsSet: Set<String>? = rules.contentRatings.map { Set($0) }

        return cached.compactMap { cache -> PlexMediaItem? in
            // Emby Dolby Vision profile 5: on no channel, whatever the rules say.
            if cache.leftOffChannels { return nil }
            let item = cache.item
            // Title used for matching is lowercased + has any trailing " (YYYY)"
            // suffix stripped (Plex's TMDB-Movie agent often appends release year
            // to disambiguate; rules like "Bluey" should still match "Bluey (2018)").
            let titleLower = cache.titleLower
            let enrichment = cache.enrichment
            // `matchTmdbGenres`: this channel also sees the item's TMDB genres. A Plex
            // listing carries two genres per film, so a Hallmark-style Christmas romance
            // often reads "Family, Drama" while TMDB says "TV Movie, Romance, Family".
            // Exclusive rules still read the server's genres (ExclusiveRule.matches).
            // Mirrors scripts/nostalgex-channel-filter.cjs.
            let itemGenresLowerSet: Set<String> = {
                guard rules.matchTmdbGenres, let tmdb = enrichment?.tmdbGenres, !tmdb.isEmpty else {
                    return cache.genresLowerSet
                }
                return cache.genresLowerSet.union(tmdb.map { $0.lowercased() })
            }()
            let itemStudioLower = cache.itemStudioLower

            let matchesEpisodeRules: Bool = isEpisodeCurated && Self.episodeRulesMatch(
                item,
                episodeTitleLower: cache.episodeTitleLower,
                titleContains: episodeTitleContainsLower,
                summaryContains: episodeSummaryContainsLower,
                seasonalTitleContains: episodeSeasonalTitleContainsLower,
                airWindow: rules.episodeAirWindow,
                titleExcludes: episodeTitleExcludesLower
            )

            let matchesTitleRule: Bool = {
                guard !titleContainsLower.isEmpty else { return true }
                return titleContainsLower.contains(where: { Self.titleContainsWordLower(titleLower, $0) })
            }()

            // Library source: when a channel specifies a source, only items from that library pass.
            // When no source is specified, music-video items are excluded so they don't pollute movie/TV channels.
            let itemSource = item.librarySource ?? .movie
            if let requiredSource = rules.source {
                if itemSource != requiredSource { return nil }
            } else if itemSource == .musicVideo {
                return nil
            }

            // Safety: kids and family channels exclude R/18+ content. A rating from another
            // country counts as its US label (GB-18 is R), as it does in the allow-list below.
            if isFamilySafe {
                if let rating = cache.usContentRating, Self.adultRatings.contains(rating) {
                    return nil
                }
            }

            // Genre-locked content: only appears on channels that explicitly include the genre.
            // O(min(|item|,|set|)) intersection instead of N×M Array contains-where.
            if !allowsHorror      && !itemGenresLowerSet.isDisjoint(with: Self.horrorGenres)      { return nil }
            if !allowsReality     && !itemGenresLowerSet.isDisjoint(with: Self.realityGenres)     { return nil }
            if !allowsAnimation   && !itemGenresLowerSet.isDisjoint(with: Self.animationGenres)   { return nil }
            if !allowsDocumentary && !itemGenresLowerSet.isDisjoint(with: Self.documentaryGenres) { return nil }
            // Sport: no global block — sports movies qualify for any matching channel.
            // Music genre lock removed — redundant. The source filter already
            // keeps music videos out of channels that don't opt in via
            // `source: musicVideo`, and music feature films (8 Mile, La La Land,
            // Bohemian Rhapsody) need to flow through movie channels.
            if !allowsWar         && !itemGenresLowerSet.isDisjoint(with: Self.warGenres)         { return nil }
            if !allowsWestern     && !itemGenresLowerSet.isDisjoint(with: Self.westernGenres)     { return nil }
            if !allowsTalkShow    && !itemGenresLowerSet.isDisjoint(with: Self.talkShowGenres)    { return nil }

            // Reality channels should only show reality content (bidirectional)
            // Only apply when the channel explicitly includes reality genres (not via isStudioChannel bypass)
            let isExplicitReality = Self.channelIncludesGenre(rules, from: Self.realityGenres)
            if isExplicitReality && itemGenresLowerSet.isDisjoint(with: Self.realityGenres) { return nil }

            // Editorial overrides: if title matches exactly, include regardless of other rules
            if !editorialOverridesLower.isEmpty {
                if editorialOverridesLower.contains(where: { titleLower == $0 }) {
                    return item
                }
            }

            // Manifest-level exclusivity. The manifest builder flags items
            // carrying signal X (e.g. TMDB "stand-up comedy" keyword) as
            // exclusive to a single channel — those items must not appear
            // anywhere else, even when the channel's own rules would match.
            // Mirrors the check in nostalgex-channel-filter.cjs.
            if let tmdbID = item.tmdbID {
                let mediaType = item.type == .episode ? "tv" : "movie"
                if let locked = memberships.exclusive(forMediaType: mediaType, tmdbID: tmdbID),
                   locked != channelID {
                    return nil
                }
            }

            // Channel memberships manifest: additive whitelist. If this item is
            // claimed for the current channel, include without keyword/genre
            // matching. `yearRange` (when set) and `type` still apply — e.g. 90S
            // SITCOMS keeps era bounds; REWATCHABLES has no yearRange, only
            // rewatch count. For content exclusivity, use `exclusiveRules`.
            if let tmdbID = item.tmdbID {
                let mediaType = item.type == .episode ? "tv" : "movie"
                if let claimed = memberships.channels(forMediaType: mediaType, tmdbID: tmdbID),
                   claimed.contains(channelID) {
                    if let type = rules.type, item.type != type { return nil }
                    if !passesYearRange(item, rules: rules) { return nil }
                    // Title-curated channels: manifest cannot widen past titleContains
                    if !titleContainsLower.isEmpty && !matchesTitleRule {
                        return nil
                    }
                    // Nor past the episode rules. Keep in sync with the web filter.
                    if isEpisodeCurated && !matchesEpisodeRules { return nil }
                    // titleExcludes outranks a manifest claim for the same reason
                    // genres.exclude does. SCREAM ADULTS lists "Ring" for The Ring, and
                    // the manifest handed it The Fellowship of the Ring.
                    // Keep in sync with scripts/nostalgex-channel-filter.cjs.
                    if !titleExcludesLower.isEmpty,
                       titleExcludesLower.contains(where: { Self.titleContainsWordLower(titleLower, $0) }) {
                        return nil
                    }
                    // genres.exclude still applies. The manifest is built by expanding
                    // TMDB "similar" titles out from a few exemplars, and that drifts:
                    // SCI-FI (excludes Animation/Family/Kids) was being handed Aladdin,
                    // The Return of Jafar and TMNT purely for being "similar" to
                    // something. A channel's exclusions are an editorial statement
                    // about what must never air on it, so they outrank a similarity
                    // guess. Includes stay bypassed on purpose: widening past
                    // genres.include is what the manifest is for.
                    if !genresExcludeLower.isEmpty {
                        let excluded = itemGenresLowerSet.contains { genre in
                            genresExcludeLower.contains { genre.contains($0) }
                        }
                        if excluded { return nil }
                    }
                    return item
                }
            }

            // manifestOnly: membership normally comes solely from the manifest. A
            // channel can opt in to a second, additive claim path by also setting
            // `manifestOnlyGenreFallback: true`, the normal content-matching block
            // below then runs too, the same keyword/genre/keywordGatedGenres rules
            // as any other channel. STAND-UP opts in this way: Comedy/Documentary
            // alone still need the "stand-up comedy"/"comedian" keyword
            // (keywordGatedGenres), but the narrower "Stand-Up" server genre tag is
            // specific enough on its own, so a title TMDB never tagged with that
            // keyword can still reach the channel if the server tagged it that way.
            // The flag is a per-channel opt-in, not an automatic inference, it does
            // not itself guard against a catch-all, the channel's own rules do, so
            // each manifestOnly channel's rules get reviewed before it's set. CRITERION
            // defines no genre/keyword rules at all; ANIME, WORLD HORROR and MYSTERY
            // BOX TV haven't opted in (same gap, tracked separately). Keep in sync
            // with nostalgex-channel-filter.cjs.
            if rules.manifestOnly && !rules.manifestOnlyGenreFallback { return nil }

            // Title excludes: reject if title contains any excluded WORD.
            // Word-boundary match prevents short rule entries from accidentally
            // killing unrelated titles (e.g. "war" rule shouldn't reject
            // "warmth" or "warden").
            if !titleExcludesLower.isEmpty {
                if titleExcludesLower.contains(where: { Self.titleContainsWordLower(titleLower, $0) }) {
                    return nil
                }
            }

            // Channel exclusivity: if this item is claimed by another channel, skip it
            for rule in exclusiveRules {
                guard !rule.channelIDs.contains(channelID) else { continue }
                guard rule.applies(to: item) else { continue }
                if rule.matches(item) { return nil }
                // manifestExclusive: also block if the manifest claims this item for
                // one of the rule's channels (catches anime tagged only "Animation").
                if rule.manifestExclusive, let tmdbID = item.tmdbID {
                    let mt = item.type == .episode ? "tv" : "movie"
                    if let claimed = memberships.channels(forMediaType: mt, tmdbID: tmdbID),
                       claimed.contains(where: { rule.channelIDs.contains($0) }) {
                        return nil
                    }
                }
            }

            // Type
            if let type = rules.type, item.type != type { return nil }

            // Content matching logic:
            // - titleContains is always OR (editorial picks work independently)
            // - keywords is always OR (additive, broadens matches)
            // - When both studios AND genre include exist, require BOTH (AND)
            //   e.g. Disney Animation = Disney studio AND Animation/Family genre
            // - When only one of studios/genre include exists, it works alone
            let hasTitleRule = !titleContainsLower.isEmpty
            let hasGenreInclude = !genresIncludeLower.isEmpty
            let hasStudioRule = !studiosLower.isEmpty
            let hasKeywordRule = !keywordsLower.isEmpty
            let hasNetworkRule = !networksLower.isEmpty
            let hasProdCoRule = !productionCompaniesLower.isEmpty

            // Title-curated channels (e.g. ADULT CARTOONS): title list is the allowlist.
            // genres.include still sets allowsAnimation for genre-lock; Plex tags are
            // not required on every episode (Simpsons is often Comedy-only in Plex).
            // Episode-curated channels are curated the same way a title list is: the episode
            // rules are the allowlist, and nothing else may widen it.
            if isEpisodeCurated {
                if !matchesEpisodeRules { return nil }
            }
            let isTitleCuratedChannel = hasTitleRule && !hasKeywordRule && !hasNetworkRule && !hasProdCoRule && !hasStudioRule
            if isTitleCuratedChannel {
                if !matchesTitleRule { return nil }
            } else if !isEpisodeCurated && (hasTitleRule || hasGenreInclude || hasStudioRule || hasKeywordRule || hasNetworkRule || hasProdCoRule) {
                // Word-boundary match: a rule of "See" matches a title that
                // CONTAINS the word "See" but not "Stickbird" or "Stylesheet".
                // Prevents short dictionary-word rule entries from pulling in
                // unrelated titles.
                let matchesTitle = hasTitleRule && matchesTitleRule

                let matchesKeyword: Bool = {
                    guard hasKeywordRule else { return false }
                    guard let enrichment else { return false }
                    let itemKW = enrichment.keywords.map { $0.lowercased() }
                    let kwHit = keywordsLower.contains(where: { itemKW.contains($0) })
                    guard kwHit else { return false }
                    // Cross-reference: when keywordsRequireAnyGenre is set, the keyword
                    // match only counts if the item ALSO has at least one of those genres.
                    // Prevents broad keywords (e.g. "wedding") from pulling in items
                    // that aren't really in the channel's wheelhouse.
                    if !keywordsRequireAnyGenreLower.isEmpty {
                        return keywordsRequireAnyGenreLower.contains { g in
                            itemGenresLowerSet.contains { $0.contains(g) }
                        }
                    }
                    return true
                }()

                let matchesNetwork: Bool = {
                    guard hasNetworkRule else { return false }
                    guard let enrichment else { return false }
                    let itemNetworks = enrichment.networks.map { $0.lowercased() }
                    return networksLower.contains(where: { n in
                        itemNetworks.contains(where: { $0.contains(n) })
                    })
                }()

                let matchesProdCo: Bool = {
                    guard hasProdCoRule else { return false }
                    guard let enrichment else { return false }
                    let itemCompanies = enrichment.productionCompanies.map { $0.lowercased() }
                    return productionCompaniesLower.contains(where: { c in
                        itemCompanies.contains(where: { $0.contains(c) })
                    })
                }()

                let matchesGenre = hasGenreInclude && itemGenresLowerSet.contains(where: { genre in
                    genresIncludeLower.contains(where: { genre.contains($0) })
                })

                let matchesStudio: Bool = {
                    guard hasStudioRule else { return false }
                    if studiosLower.contains(where: { itemStudioLower.contains($0) }) {
                        return true
                    }
                    // Fall back to TMDB production companies + networks
                    if let enrichment {
                        if enrichment.productionCompanies.contains(where: { pc in
                            let pcLower = pc.lowercased()
                            return studiosLower.contains(where: { pcLower.contains($0) })
                        }) { return true }
                        if enrichment.networks.contains(where: { net in
                            let netLower = net.lowercased()
                            return studiosLower.contains(where: { netLower.contains($0) })
                        }) { return true }
                    }
                    return false
                }()

                // All content rules are OR — match any one path to pass
                if matchesTitle { /* pass */ }
                else if matchesKeyword { /* pass */ }
                else if matchesNetwork { /* pass */ }
                else if matchesProdCo { /* pass */ }
                // When both studio and genre are defined, require both (AND)
                else if hasStudioRule && hasGenreInclude {
                    if !matchesStudio || !matchesGenre { return nil }
                }
                // When only one is defined, it works alone
                else if hasStudioRule {
                    if !matchesStudio { return nil }
                }
                else if hasGenreInclude {
                    if !matchesGenre { return nil }
                    // keywordGatedGenres: broad genres (e.g. "Music" on MUSICALS, "Drama" on
                    // TEEN DRAMA) also require a keyword match to prevent unrelated content
                    // (rock films, adult dramas) from passing on genre alone.
                    if !keywordGatedGenresLower.isEmpty {
                        // Exact genre match, not substring — otherwise gating "Music"
                        // also gates "Musical", wrongly excluding genre-tagged
                        // musicals that have no keywords.
                        let isGatedMatch = keywordGatedGenresLower.contains { gatedGenre in
                            itemGenresLowerSet.contains(gatedGenre)
                        }
                        if isGatedMatch && !matchesKeyword { return nil }
                    }
                }
                // Nothing matched
                else { return nil }
            }

            // TMDB keyword exclude (soft — unenriched items pass)
            if !keywordsExcludeLower.isEmpty {
                if let enrichment {
                    let itemKW = enrichment.keywords.map { $0.lowercased() }
                    if keywordsExcludeLower.contains(where: { itemKW.contains($0) }) {
                        return nil
                    }
                }
            }

            // OMDb rating gates — all require enrichment with OMDb data
            // Items without OMDb data fail these checks (gated, same as TMDB rules)
            if let minRating = rules.imdbRatingMin {
                guard let r = enrichment?.imdbRating, r >= minRating else { return nil }
            }
            if let minVotes = rules.imdbVotesMin {
                guard let v = enrichment?.imdbVotes, v >= minVotes else { return nil }
            }
            if let minRT = rules.rtScoreMin {
                guard let rt = enrichment?.rottenTomatoesScore, rt >= minRT else { return nil }
            }
            if let minMC = rules.metacriticMin {
                guard let mc = enrichment?.metacriticScore, mc >= minMC else { return nil }
            }
            if rules.wonOscar {
                guard let awards = enrichment?.awards else { return nil }
                let awardsLower = awards.lowercased()
                if !(awardsLower.contains("won") && awardsLower.contains("oscar")) { return nil }
            }

            // Added within days (e.g. only items added to library in last 180 days)
            if let days = rules.addedWithinDays, days > 0 {
                let cutoff = Int(Date().timeIntervalSince1970) - (days * 86400)
                if item.addedAt < cutoff { return nil }
            }

            // Released within N months. Prefer Plex's originallyAvailableAt (YYYY-MM-DD)
            // for true month precision; fall back to year-only when missing.
            if let months = rules.releasedWithinMonths, months > 0 {
                let cal = Calendar.current
                let now = Date()
                if let dateStr = item.originallyAvailableAt,
                   let releaseDate = Self.releaseDateFormatter.date(from: dateStr) {
                    let cutoff = cal.date(byAdding: .month, value: -months, to: now) ?? now
                    if releaseDate < cutoff { return nil }
                } else if let year = item.year {
                    // No date metadata — approximate using year. months/12 (rounded up)
                    // gives the year cutoff so e.g. 6 months ≈ current year only.
                    let yearsBack = (months + 11) / 12 - 1
                    if year < currentYear - yearsBack { return nil }
                }
            }

            // Genre requireAll (AND -- every required genre must be present)
            if !genresRequireAllLower.isEmpty {
                let hasAll = genresRequireAllLower.allSatisfy { m in
                    itemGenresLowerSet.contains { $0.contains(m) }
                }
                if !hasAll { return nil }
            }

            // Genre exclude
            if !genresExcludeLower.isEmpty {
                let excluded = itemGenresLowerSet.contains { genre in
                    genresExcludeLower.contains { genre.contains($0) }
                }
                if excluded { return nil }
            }

            // Year range (only when channel defines yearRange — see passesYearRange)
            if !passesYearRange(item, rules: rules) { return nil }

            // Content ratings whitelist
            if let ratings = contentRatingsSet, !ratings.isEmpty {
                let rating = cache.usContentRating ?? ""
                if rating.isEmpty && rules.allowUnrated { /* pass */ }
                else if !ratings.contains(rating) { return nil }
            }

            // Minimum star rating. On Emby, CommunityRating (the field item.rating
            // is built from) came back null for 100% of a 500-title sample measured
            // against Chad's own server, so treating a missing native rating as an
            // automatic fail silently emptied the 13 channels that use a plain
            // ratingMin gate. When neither native rating clears the bar, fall back
            // to the same OMDb-enriched rating used by the imdbRatingMin gate above,
            // at the same threshold, before rejecting.
            if let ratingMin = rules.ratingMin {
                let nativeOk = item.rating >= ratingMin || item.userRating >= ratingMin
                if !nativeOk {
                    let omdbOk = (enrichment?.imdbRating).map { $0 >= ratingMin } ?? false
                    if !omdbOk { return nil }
                }
            }

            // Duration
            if let dr = rules.durationRange {
                if let min = dr.min, item.duration < min { return nil }
                if let max = dr.max, item.duration > max { return nil }
            }

            // Watch status
            let isNewRelease = (item.year ?? 0) >= currentYear - 1
            if rules.watchedOnly   && item.viewCount < 1 && !isNewRelease { return nil }
            if rules.unwatchedOnly && (item.viewCount > 0 || isNewRelease) { return nil }
            if rules.rewatched     && item.viewCount < 3 { return nil }

            return item
        }
    }
}

