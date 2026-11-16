import Foundation

/// Live channel rules (N-074), the part that reaches the guide: a check, then a rebuild from the library already in
/// memory at a safe point. The rules are `LiveChannelRules`; the file handling is `ChannelConfigStore`.
extension AppState {
    /// The moment as the rules see it.
    func liveRulesMoment(atLaunch: Bool = false) -> LiveChannelRules.Moment {
        LiveChannelRules.Moment(isFullScreen: isFullScreen, isLoading: isLoading || isScanning || isBackgroundRefreshing,
                                isRebuilding: isApplyingLiveRules, onGuide: guideIsOnScreen, atLaunch: atLaunch)
    }

    /// The viewer's guide came on screen or left it (TunerView). Coming on is a safe point.
    func noteGuideOnScreen(_ on: Bool) {
        guideIsOnScreen = on
        if on { Task { await applyLiveChannelRulesIfSafe() } }
    }

    /// At launch, on return to the foreground and from the background loop: ask nostalgex.app whether channels.json
    /// changed (at most once in `ChannelConfigStore.checkInterval`, conditional so unchanged is a 304), then apply a
    /// newer copy if this is a safe point.
    func checkLiveChannelRules(atLaunch: Bool = false) async {
        if ChannelConfigStore.isDue() { await ChannelConfigStore.refresh() }
        await applyLiveChannelRulesIfSafe(atLaunch: atLaunch)
    }

    /// Rebuilds the channels from the kept channels.json when it is newer than the one the guide was built from and
    /// now is a safe point. Playback is not touched: whatever is playing keeps playing, its channel struct is swapped
    /// for the rebuilt one without reloading, and the next programme comes from the new pools.
    func applyLiveChannelRulesIfSafe(atLaunch: Bool = false) async {
        guard hasCredentials, !isDemoMode, !channels.isEmpty, !allItems.isEmpty else { return }
        let active = ChannelConfigStore.active()
        let applied = ChannelConfigStore.appliedVersion(bundledVersion: ChannelConfigStore.version(of: ChannelConfigStore.bundledData()))
        let decision = LiveChannelRules.decide(appliedVersion: applied, keptVersion: active.version, moment: liveRulesMoment(atLaunch: atLaunch))
        guard decision == .applyNow else {
            if decision != .nothing { print("[Plex90] CONFIG: live rules v\(active.version) after v\(applied): \(decision)") }
            return
        }
        await rebuildChannelsFromLoadedLibrary(config: active.result, version: active.version)
    }

    /// The middle of `loadLibrary` without the scan: bundles and rules from `config`, every enabled static channel's
    /// pool filtered from `allItems` (off the main actor), the franchises and collections rebuilt, the lineup
    /// re-filtered. No server request. The header says UPDATING LIBRARY, then GUIDE READY.
    func rebuildChannelsFromLoadedLibrary(config: ChannelConfigResult, version: Int) async {
        guard !isApplyingLiveRules else { return }
        isApplyingLiveRules = true
        let session = librarySessionGeneration
        let started = Date()
        scanItemsFound = allItems.count
        isBackgroundRefreshing = true
        defer {
            isApplyingLiveRules = false
            isBackgroundRefreshing = false
        }
        print("[Plex90] CONFIG: applying live rules v\(version) to \(allItems.count) loaded titles, no rescan")

        bundles = config.bundles.map { $0.toChannelBundle(enabled: enabledBundleIDs.contains($0.id)) }
        exclusiveRules = config.exclusiveRules
        channelConfigChannels = config.channels
        let poolChannelIDs = staticChannelIDsForPoolBuild(buildAllConfigChannels: false)
        let staticBuilt = await rebuildStaticChannelPools(configChannels: config.channels, items: allItems, onlyChannelIDs: poolChannelIDs)
        // A sign-out or a new sign-in while the pools were built: those results are for a library the viewer left.
        guard librarySessionGeneration == session else { return }

        let dynamicChannels = allChannels.filter { $0.rules == nil }
        allChannels = (staticBuilt + dynamicChannels).sorted { $0.number < $1.number }
        // The franchise builder runs off the main actor (1.4 s on a 10.7k item library); only its result is applied here.
        await rebuildFoundFranchisesOffMain()
        guard librarySessionGeneration == session else { return }
        materializeDynamicChannels()
        applyBundleFilter()
        if channels.isEmpty { autoEnableBundlesWithContent() }

        // What is playing keeps playing: the channel it is on is swapped for its rebuilt self (no reload), or, if the
        // new rules took the channel out of the lineup, the viewer is moved the way any removed channel moves them.
        if let current = currentChannel {
            if let rebuilt = channels.first(where: { $0.id == current.id }) { currentChannel = rebuilt } else { reselectIfCurrentChannelFilteredOut() }
        }

        ChannelConfigStore.recordApplied(version: version)
        saveLibrarySnapshotIfNeeded()
        endLoadInPlace(readWhole: true)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("[Plex90] CONFIG: live rules v\(version) applied in \(ms) ms, \(allChannels.count) channels, \(channels.count) in the guide")
    }
}
