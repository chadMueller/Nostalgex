import Foundation

// Applying preferences that arrived from another Apple TV through iCloud.
// Outgoing writes happen in the existing didSet / save paths; see PreferenceSync.
extension AppState: PreferenceSyncApplying {
    func applyIncomingPreferences(_ values: [String: Any]) {
        if let v = values[PreferenceSync.retroModeKey] as? Bool, v != retroMode {
            retroMode = v
        }
        if let v = values[PreferenceSync.guideTextSizeKey] as? String, GuideTextSize(stored: v) != guideTextSize {
            guideTextSize = GuideTextSize(stored: v)
        }
        if let v = values[PreferenceSync.subtitlesFullscreenKey] as? Bool, v != subtitlesInFullscreenEnabled {
            subtitlesInFullscreenEnabled = v
        }
        if let v = values[PreferenceSync.autoSubsForeignAudioKey] as? Bool, v != autoSubtitlesForForeignAudioEnabled {
            autoSubtitlesForForeignAudioEnabled = v
        }
        if let v = values[PreferenceSync.subtitleLanguageKey] as? String, v != preferredSubtitleLanguageCode {
            preferredSubtitleLanguageCode = v
        }
        if let v = values[PreferenceSync.audioLanguageKey] as? String, v != preferredAudioLanguageCode {
            preferredAudioLanguageCode = v
        }
        // The legacy cloud switch may fill missing choices, but can never override
        // an explicit v2 value (especially false). Apply a received pair atomically.
        let incomingNow = values[PreferenceSync.nowPlayingKey] as? Bool
        let incomingMark = values[PreferenceSync.markWatchedKey] as? Bool
        let old = values[PreferenceSync.reportPlaybackKey] as? Bool
        let defaults = UserDefaults.standard
        let legacyNow = defaults.object(forKey: Self.showNowPlayingDefaultsKey) == nil ? old : nil
        let legacyMark = defaults.object(forKey: Self.markWatchedDefaultsKey) == nil ? old : nil
        if incomingNow != nil || incomingMark != nil || legacyNow != nil || legacyMark != nil {
            setPlaybackReporting(showNowPlaying: incomingNow ?? legacyNow ?? showNowPlaying,
                                 markWatched: incomingMark ?? legacyMark ?? markWatched)
        }
        // Stream quality has no AppState property: `apply` already wrote it to
        // UserDefaults, which is where `StreamQuality.current` reads it on the next tune.
        if let v = values[PreferenceSync.enabledCollectionsKey] as? [String], Set(v) != enabledCollectionKeys {
            applyEnabledCollectionKeys(Set(v))
        }
        if let v = values[PreferenceSync.enabledBundlesKey] as? [String], !v.isEmpty, Set(v) != enabledBundleIDs {
            applyEnabledBundleIDs(Set(v))
        }
        // On and off arrive as two keys and may come together or alone; apply them as one
        // change so a default-on franchise is never briefly rebuilt in the wrong state.
        let incomingOn = (values[PreferenceSync.enabledFranchisesKey] as? [String]).map(Set.init)
        let incomingOff = (values[PreferenceSync.disabledFranchisesKey] as? [String]).map(Set.init)
        let onChanged = incomingOn.map { $0 != enabledFranchiseIDs } ?? false
        let offChanged = incomingOff.map { $0 != disabledFranchiseIDs } ?? false
        if onChanged || offChanged {
            applyEnabledFranchiseIDs(incomingOn ?? enabledFranchiseIDs, disabled: incomingOff)
        }
    }

    /// Replaces the enabled bundles and rebuilds the lineup the way a Settings toggle does.
    /// Ids this TV's lineup does not have are kept and match nothing. Collection category
    /// bundles this TV has discoveries for stay on (they have no switch of their own), so
    /// another TV's lineup never hides this TV's collection channels.
    func applyEnabledBundleIDs(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let ids = ids.union(visibleDiscoveredCollections.map(\.category.bundleID))
        let added = ids.subtracting(enabledBundleIDs)
        enabledBundleIDs = ids
        rebuildLineupAfterBundleChange(newlyEnabled: bundles.filter { added.contains($0.id) }, byViewer: false)
    }

    /// Replaces the enabled collections and re-materializes their channels the way
    /// `toggleCollection` does. Ids from a server this TV is not signed into are kept in
    /// the set (so they survive a round trip) and match no discovered collection here.
    func applyEnabledCollectionKeys(_ keys: Set<String>) {
        enabledCollectionKeys = keys
        var changed = false
        for i in discoveredCollections.indices {
            let on = keys.contains(discoveredCollections[i].id)
            if discoveredCollections[i].enabled != on {
                discoveredCollections[i].enabled = on
                changed = true
            }
        }
        saveCollectionPreferences()
        guard changed else { return }
        materializeDynamicChannels()
        applyBundleFilter()
        reselectIfCurrentChannelFilteredOut()
    }

    /// The bundle set to use after restoring a snapshot: the saved preference when there
    /// is one, plus the collection categories the snapshot has discoveries for (those are
    /// always on, see `syncCollectionCategoryBundlesWithDiscoveries`).
    nonisolated static func preferredBundleIDsAfterSnapshot(
        stored: [String]?,
        snapshotWithDiscoveries: Set<String>,
        discoveredCategoryBundleIDs: Set<String>
    ) -> Set<String> {
        guard let stored, !stored.isEmpty else { return snapshotWithDiscoveries }
        return Set(stored).union(discoveredCategoryBundleIDs)
    }

    #if DEBUG
    /// Hardware test hook: `-NostalgexSyncProbe retro=1` (or `retro=0`) sets retro mode on
    /// launch so it syncs like a Settings change. `retro=unset-local` removes the local value
    /// without touching iCloud, and `clear-cloud` removes the synced keys from iCloud.
    /// `sync=on` / `sync=off` flip the per-TV switch the way the Settings row does.
    func runPreferenceSyncProbeIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-NostalgexSyncProbe"), i + 1 < args.count else { return }
        let probe = args[i + 1]
        print("[Sync] probe: \(probe), sync \(iCloudSyncEnabled ? "on" : "off"), retro mode currently \(retroMode)")
        switch probe {
        case "sync=on": iCloudSyncEnabled = true
        case "sync=off": iCloudSyncEnabled = false
        case "retro=1": retroMode = true
        case "retro=0": retroMode = false
        case "retro=unset-local":
            UserDefaults.standard.removeObject(forKey: PreferenceSync.retroModeKey)
            print("[Sync] probe: removed local retro mode")
        case "clear-cloud":
            preferenceSync.debugClearCloud()
        default:
            print("[Sync] probe: unknown")
        }
        if preferenceSync.isEnabled { preferenceSync.cloud.synchronize() }
    }
    #endif
}
