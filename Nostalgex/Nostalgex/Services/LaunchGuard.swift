import Foundation

/// Two launch-time checks that keep a viewer from being trapped by a library load that
/// keeps killing the app.
///
/// Reinstall: tvOS keeps keychain items after the app is deleted, so a fresh install used
/// to find the old sign-in and go straight back into the same load. Deleting the app was
/// the obvious way out, and it did nothing.
///
/// Unfinished loads: a load that ends in the app being killed (memory, watchdog, force
/// quit) never reaches its own cleanup. A marker set when a load starts and cleared when
/// it ends tells the next launch that the previous one died mid-load. After two in a row
/// the app asks first instead of starting the same load again.
enum LaunchGuard {
    // MARK: Reinstall

    /// Keys an earlier launch of this install always leaves in UserDefaults. Deleting the
    /// app wipes all of them; an update keeps them. Several, so a build that predates any
    /// one key still counts as an existing install.
    static let existingInstallKeys = [
        "nostalgex_launch_count",            // InstallDiagnostics, every launch
        "nostalgex_first_run_at",            // InstallDiagnostics, first launch
        "nostalgex_first_launch_recorded",   // launch analytics
        AppState.hasHeldSignInMarkerKey,
        AppState.initialLoadCompleteKey,
    ]

    /// Every credential key AppState writes. Deleting one removes both keychain copies
    /// and the UserDefaults mirror (KeychainService.delete).
    static let credentialKeys = [
        "plex_server_url",
        "plex_token",
        AppState.serversKey,
        AppState.backendKindKey,
        AppState.jellyfinUserIdKey,
    ]

    /// A fresh install: UserDefaults holds nothing an earlier launch writes, and the
    /// install stamp file is missing too. Requiring both keeps a device whose UserDefaults
    /// alone went missing (InstallDiagnostics watches for that) signed in.
    static func isFreshInstall(defaults: UserDefaults, installStampExists: Bool) -> Bool {
        guard !installStampExists else { return false }
        return !existingInstallKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// Clears a sign-in left in the keychain by a deleted install. Call once per launch,
    /// before InstallDiagnostics.recordLaunch and launch analytics write their keys.
    /// Returns true when it cleared something.
    @discardableResult
    static func clearCredentialsLeftByDeletedInstall(store: any CredentialStoring,
                                                     defaults: UserDefaults = .standard,
                                                     installStampExists: Bool) -> Bool {
        guard isFreshInstall(defaults: defaults, installStampExists: installStampExists) else { return false }
        let leftovers = credentialKeys.filter { store.load(key: $0) != nil }
        guard !leftovers.isEmpty else { return false }
        for key in credentialKeys { store.delete(key: key) }
        InstallDiagnostics.note("AUTH: fresh install found a sign-in from a deleted install (\(leftovers.count) keys), cleared it")
        return true
    }

    // MARK: Unfinished loads

    static let loadInFlightKey = "nostalgex_library_load_in_flight"
    static let unfinishedLoadsKey = "nostalgex_unfinished_library_loads"
    /// Unfinished loads in a row before the app asks instead of loading.
    static let unfinishedLoadLimit = 2

    /// Call once per launch. A marker still set means the previous process died inside a load.
    static func recordLaunch(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: loadInFlightKey) else { return }
        defaults.removeObject(forKey: loadInFlightKey)
        let count = defaults.integer(forKey: unfinishedLoadsKey) + 1
        defaults.set(count, forKey: unfinishedLoadsKey)
        InstallDiagnostics.note("LOAD: the previous launch ended inside a library load (\(count) in a row)")
    }

    /// Whether a load carries the marker. A background refresh (a guide already on screen)
    /// does not: tvOS ends suspended apps whenever it likes, and two of those days apart
    /// must not put LOADING DIDN'T FINISH in front of a library that loads fine. Mirrors
    /// loadLibrary's own rule: `background` with no channels yet is a foreground load.
    static func tracksLoad(background: Bool, hasChannels: Bool) -> Bool {
        !(background && hasChannels)
    }

    static func loadStarted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: loadInFlightKey)
    }

    /// Any end the process lived to see: success, error, cancel, stop waiting, sign-out.
    /// `resetCount: false` only clears the marker, for a step that proves nothing about
    /// whether the full load can finish.
    static func loadEnded(resetCount: Bool = true, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: loadInFlightKey)
        if resetCount { defaults.removeObject(forKey: unfinishedLoadsKey) }
    }

    static func shouldAskBeforeLoading(defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: unfinishedLoadsKey) >= unfinishedLoadLimit
    }

    /// TRY AGAIN: the next load gets the full allowance again.
    static func resetUnfinishedLoads(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: unfinishedLoadsKey)
    }
}
