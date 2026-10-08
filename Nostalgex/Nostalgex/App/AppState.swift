import Foundation
import Observation
import SwiftUI
import AVFoundation
import Combine
import UIKit

@MainActor
@Observable
class AppState {
    // MARK: - Dependencies

    let credentialStore: any CredentialStoring

    init(credentialStore: any CredentialStoring = KeychainCredentialStore()) {
        self.credentialStore = credentialStore

        // UI tests run in a shared simulator environment; allow a launch argument to reset
        // persisted credentials so tests don't leak state across runs.
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetCredentials")
            || ProcessInfo.processInfo.arguments.contains("-reproAppReviewFlow") {
            credentialStore.delete(key: "plex_server_url")
            credentialStore.delete(key: "plex_token")
            UserDefaults.standard.removeObject(forKey: "plex_server_url")
            UserDefaults.standard.removeObject(forKey: "plex_token")
            LibrarySnapshotStore.clear()
        }

        setupBackgroundObservers()

        // Deterministic App Review repro harness: simulate a "connected + loaded" state.
        if ProcessInfo.processInfo.arguments.contains("-reproAppReviewFlow") {
            serverURL = "https://example.com"
            token = "TEST_TOKEN"
            saveCredentials()

            let stubChannel = Channel(
                id: 1,
                number: 1,
                name: "STUB",
                color: .blue,
                category: nil,
                rules: nil,
                timeRestrictions: nil,
                minItems: 0,
                itemPool: []
            )
            allChannels = [stubChannel]
            channels = [stubChannel]
            isLoading = false
        }
    }

    // MARK: - Background / foreground observation

    /// Wall-clock start of the current foreground period. Set on init and on
    /// `willEnterForeground`; drained by `emitSessionEnded()` on backgrounding.
    /// Used only by analytics — no UI depends on it.
    private var analyticsSessionStartedAt: Date = Date()

    private func setupBackgroundObservers() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Flush watch time before the tracker's own background handler zeroes it.
                self?.emitPlaybackStoppedForActiveSession()
                self?.playbackTracker?.onBackground()
                // Then close out the foreground period. Ordering matters: watch time
                // rides its own signal, and app.session.ended is the umbrella around
                // it.
                self?.emitSessionEnded()
            }
            .store(in: &_lifetimeObservers)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.playbackTracker?.onForeground()
                self?.revalidateSleepTimerOnForeground()
                // Start a fresh foreground window so the next background emits the
                // right duration.
                self?.analyticsSessionStartedAt = Date()
            }
            .store(in: &_lifetimeObservers)
    }

    /// Sends `playback.stopped` with the tracker's accumulated active-watch time and
    /// resets that accumulator so subsequent stops don't double-count. Safe to call
    /// when there is no live session: it silently no-ops.
    func emitPlaybackStoppedForActiveSession() {
        guard let tracker = playbackTracker,
              let channel = currentChannel,
              let delivery = currentPlaybackDelivery else { return }
        let seconds = tracker.flushWatchSecondsForAnalytics()
        // Skip signals with zero time so pause / rapid tune-past cases don't spam.
        guard seconds >= 1.0 else { return }
        Analytics.track(.playbackStopped(
            channelNumber: channel.number,
            backend: analyticsBackend,
            delivery: delivery,
            channel: AnalyticsChannelDescriptor.describe(channel),
            activeWatchSeconds: seconds
        ))
    }

    /// Fires `app.session.ended` with the number of wall-clock seconds this app
    /// process has been in the foreground since the last launch or foreground
    /// return. Zero-length windows are skipped so a fast background→foreground
    /// re-entry doesn't send an empty envelope.
    private func emitSessionEnded() {
        let seconds = Date().timeIntervalSince(analyticsSessionStartedAt)
        guard seconds >= 1.0 else { return }
        Analytics.track(.sessionEnded(activeSeconds: seconds))
    }

    // MARK: - UI test hooks

    var isUITestStubLibrarySuccess: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestStubLibrarySuccess")
        || ProcessInfo.processInfo.arguments.contains("-reproAppReviewFlow")
    }

    var isUITestInstantAuth: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestInstantAuth")
        || ProcessInfo.processInfo.arguments.contains("-reproAppReviewFlow")
    }

    // MARK: - Stored credentials (Keychain-backed)

    /// A Plex server the user has chosen to include. The Plex token is account-level and
    /// works against every server, so multi-server is one shared token + this list.
    struct ServerRef: Codable, Hashable, Identifiable {
        let machineIdentifier: String
        let name: String
        let baseURL: String
        let owned: Bool
        /// Per-server access token (shared servers reject the account token). Optional
        /// for back-compat with older persisted entries; falls back to the account token.
        var token: String? = nil
        /// Jellyfin user id (paired with `token` as the access token). Nil for Plex.
        var userId: String? = nil
        var id: String { machineIdentifier }
    }

    /// Primary server URL — mirrors `selectedServers.first` for display and legacy
    /// single-server paths (demo, App Review repro). Source of truth is `selectedServers`.
    var serverURL: String = ""
    var token: String     = ""
    var serverName: String = ""

    /// Which media backend the user authenticated with. Drives `apiForServer`.
    /// Defaults to `.plex` so existing installs keep working without re-auth.
    var backendKind: MediaBackendKind = .plex
    /// Jellyfin user id (paired with `token` as the access token when on Jellyfin).
    var jellyfinUserId: String = ""

    static let backendKindKey = "backend_kind"
    static let jellyfinUserIdKey = "jellyfin_user_id"

    /// User-facing name of the active backend ("Plex" / "Jellyfin"). Drives Settings copy.
    var backendDisplayName: String {
        switch backendKind {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }

    /// Backend value used on analytics signals. `.demo` when the session is running on
    /// bundled sample channels — separate from real backends so demo watch time can be
    /// filtered out on the dashboard without touching the real cohort.
    var analyticsBackend: AnalyticsBackend {
        if isDemoMode { return .demo }
        switch backendKind {
        case .plex: return .plex
        case .jellyfin: return .jellyfin
        case .emby: return .emby
        }
    }

    /// Servers feeding the library. Persisted. Empty in demo / App Review repro
    /// (those use `serverURL`/`token` directly).
    var selectedServers: [ServerRef] = []
    /// Most recent discovery result — drives the login picker and the Settings server list.
    var availableServers: [ServerRef] = []

    static let serversKey = "plex_servers"

    // MARK: - App state

    var isConnected: Bool = false
    var isLoading: Bool = false

    /// False until launch has finished reading the Keychain. RootView gates on this so a
    /// signed-in user is never shown the connect screen: credentials are loaded in a
    /// `.task`, which SwiftUI runs AFTER the first body evaluation, so `hasCredentials`
    /// is false for at least one frame on every launch. On an Apple TV HD the Keychain
    /// read is slow enough (and `hydrateCredentialsWithRetry` sleeps a second per
    /// transient refusal) that the connect screen was on screen long enough to press,
    /// and the press appeared to "go straight through" when hydration landed underneath.
    var didAttemptCredentialHydration: Bool = false

    /// Bumped whenever a seasonal invite is answered. `seasonalBundleOnOffer` reads it so
    /// @Observable re-evaluates the guide: the silencing itself lives in UserDefaults,
    /// which observation cannot see, so without this the invite row would sit there after
    /// the viewer declined it.
    var seasonalPromptRevision: Int = 0
    var isBackgroundRefreshing: Bool = false
    var isLibraryStale: Bool = false
    /// Change signature of the library as of the last full scan; nil when unknown.
    var librarySignature: String?
    /// Last time the library was asked whether it changed, so the 15-minute tick does not
    /// re-ask every time once the 6h mark has passed.
    var lastLibraryCheckAtUnix: Int = 0

    /// False when the keychain accepted a credential write but could not read it back, which
    /// means this session dies on relaunch. Drives a warning rather than letting the user
    /// discover it by being thrown back to the connect screen.
    var credentialsArePersistent: Bool = !UserDefaults.standard.bool(forKey: KeychainService.writeVerificationFailedKey)

    /// Why the app last signed the user out on purpose, surviving relaunch. Cleared by the
    /// next successful sign-in. The involuntary counterpart, signInLossDiagnostic, covers
    /// credentials the DEVICE lost; this covers credentials the APP destroyed.
    var lastSignOutNotice: String? = UserDefaults.standard.string(forKey: AppState.lastSignOutNoticeKey)

    /// Non-nil when a previous session's sign-in vanished without the user disconnecting.
    /// Carries the keychain status code so a lost session reports its own cause from the
    /// connect screen instead of needing a reproduction with a debugger attached.
    var signInLossDiagnostic: String? = nil

    /// Written on every successful save, removed on deliberate disconnect. A launch that
    /// finds the marker but no credentials proves the device lost them; a launch missing
    /// both is indistinguishable from a fresh install (a container wipe takes the marker
    /// with it), which is itself the answer when the connect screen shows no diagnosis.
    static let hasHeldSignInMarkerKey = "nostalgex_has_held_sign_in"
    var libraryUpdateNotice: String? = nil
    var loadingMessage: String = ""
    /// Step rail + detail line on `LoadingView`.
    var libraryLoadPhase: LibraryLoadPhase = .preparing
    var libraryLoadDetail: String = ""
    var libraryLoadVisibleSteps: [LibraryLoadPhase] = LibraryLoadPhase.visibleSteps(includesCollections: false, includesMusic: false)
    var channelBuildIndex: Int = 0
    var channelBuildTotal: Int = 0
    var errorMessage: String? = nil

    static let initialLoadCompleteKey = "nostalgex_completed_initial_load"

    /// First full library setup on this device (show “may take a few minutes”).
    var isFirstLibraryLoad: Bool {
        !UserDefaults.standard.bool(forKey: Self.initialLoadCompleteKey)
    }

    /// Set true between a successful PIN auth and the first successful library load.
    /// Used to distinguish "your saved session expired" (relaunch path) from "we just
    /// signed you in and the server immediately rejected the token" (App Store rejection
    /// case). The two need different user-facing messages.
    var justAuthenticated: Bool = false

    /// Short diagnostic shown beneath the CONNECTION FAILED screen. Server URL + HTTP code
    /// (or a short reason). Captures the next rejection screenshot with actionable info
    /// instead of guessing what went wrong.
    var lastFailureDiagnostic: String? = nil

    /// Demo mode bypasses Plex entirely: bundled sample channels, no network. Reviewers
    /// can navigate the full UI without depending on a reachable Plex server.
    var isDemoMode: Bool = false

    /// Section scan progress (0..<totalSections). Used by LoadingView for a progress bar.
    var scanSectionIndex: Int = 0
    var scanTotalSections: Int = 0
    var scanItemsFound: Int = 0

    /// Collection scan progress. Each collection costs a round-trip for its member list, so
    /// on a library with hundreds of collections this phase is long enough to need a bar.
    var collectionScanIndex: Int = 0
    var collectionScanTotal: Int = 0

    /// True while a foreground scan has gone quiet long enough to say so. Drives the
    /// "still waiting" block on LoadingView. Never set during a background refresh — the
    /// user is watching a guide and shouldn't be told about work they didn't start.
    var isLoadStalling: Bool = false

    /// Set by the user choosing to stop waiting on a quiet scan. Consumed by the stall
    /// watch, which then resolves the load the same way an automatic stall does (partial
    /// guide if anything was fetched, clear error if not).
    var loadCancelRequested: Bool = false

    /// The user's way out of a scan that has gone quiet. Resolution is deliberately the
    /// same path as an automatic stall, so there is only one behaviour to reason about.
    func stopWaitingForLibraryScan() {
        guard isLoading else { return }
        Analytics.track(.libraryStopWaitingTapped)
        loadCancelRequested = true
    }

    func consumeLoadCancelRequest() -> Bool {
        guard loadCancelRequested else { return false }
        loadCancelRequested = false
        return true
    }

    // PIN auth state
    var pinCode: String = ""
    var pinID: Int = 0
    var isAuthInProgress: Bool = false
    var authError: String? = nil
    /// Backend + method for the sign-in currently in flight. Set by the four
    /// `startPINAuth` / `authenticate…` / `startJellyfinQuickConnect` entry points and
    /// cleared once the attempt resolves. Only used by analytics — it drives
    /// `connect.cancelled` / `connect.code_expired`, which need to say WHICH kind of
    /// sign-in the user backed out of.
    var currentAuthAttempt: (backend: AnalyticsBackend, method: AnalyticsConnectMethod)? = nil
    /// True after auth when the account can reach more than one server and the user
    /// hasn't yet chosen which to include. Drives the login server picker.
    var needsServerSelection: Bool = false
    /// True while discovering reachable servers after a successful PIN auth. Lets the
    /// login screen say "finding your servers" instead of leaving the "waiting for
    /// authorization" message up during the (network-bound) discovery step.
    var isDiscoveringServers: Bool = false
    /// Jellyfin Quick Connect code the user enters/approves in their dashboard.
    /// Displayed by the login screen while polling, analogous to `pinCode`.
    var jellyfinQuickConnectCode: String = ""
    var pinPollTask: Task<Void, Never>?
    var collectionScanTask: Task<Void, Never>?

    // MARK: - Data

    var allItems: [PlexMediaItem] = []
    var allChannels: [Channel] = []
    var channels: [Channel] = []
    /// Full channel config from JSON (kept for re-filtering after enrichment)
    var channelConfigChannels: [Channel] = []

    // MARK: - TMDB Enrichment

    let enrichmentService = EnrichmentService()
    let musicEnrichmentService = MusicEnrichmentService()

    // MARK: - Bundles & Exclusivity

    var bundles: [ChannelBundle] = []
    var exclusiveRules: [ExclusiveRule] = []
    var channelMemberships: ChannelMemberships = ChannelMembershipsLoader.loadBundled()
    /// Enabled bundle IDs. On first launch (no key saved), only "essentials" is on.
    var enabledBundleIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "nostalgex_enabled_bundles") ?? ["nostalgex"]
    )

    /// Maps enabled bundles to their first visible channel for bundle-jump navigation
    var bundleJumpTargets: [(bundleID: String, bundleName: String, firstChannelID: Int, channelColor: Color)] = []

    // MARK: - Collection discovery

    var isScanning: Bool = false
    var scanningMessage: String = ""
    var lastScanDate: Date? = {
        let ts = UserDefaults.standard.double(forKey: "nostalgex_last_scan_date")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }()
    var discoveredCollections: [DiscoveredCollection] = []
    var enabledCollectionKeys: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "nostalgex_enabled_collections") ?? []
    )

    // MARK: - Display settings

    var retroMode: Bool = UserDefaults.standard.object(forKey: "nostalgex_retro_mode") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(retroMode, forKey: "nostalgex_retro_mode")
            if oldValue != retroMode {
                Analytics.track(.settingChanged(key: "retro_mode", value: retroMode ? "true" : "false"))
            }
        }
    }

    static let syncPlexActivityDefaultsKey = "nostalgex_sync_plex_activity"

    /// When true, playback is reported to the connected server so play counts grow
    /// and items can surface in Continue Watching. Off = watch privately.
    /// Same switch for Plex, Jellyfin, and Emby. Demo never reports.
    ///
    /// Defaults OFF. Channel surfing tunes past dozens of programs in a sitting, and
    /// reporting each one buries the household's real "Continue Watching" row under
    /// half-watched items nobody chose to start. Opt in, don't opt out.
    /// Rewatch channels still fill from plays the server already recorded.
    var syncPlexActivity: Bool = AppState.resolveSyncPlexActivity(
        stored: UserDefaults.standard.object(forKey: AppState.syncPlexActivityDefaultsKey)
    ) {
        didSet {
            UserDefaults.standard.set(syncPlexActivity, forKey: Self.syncPlexActivityDefaultsKey)
            // Turning off mid-program: silently abandon the live tracker so the current
            // item stops reporting immediately (no final "stopped" offset). The next item
            // gets a tracker with no Plex API. Turning on takes effect on the next item.
            if !syncPlexActivity { playbackTracker?.abandon() }
            if oldValue != syncPlexActivity {
                Analytics.track(.settingChanged(key: "sync_plex_activity", value: syncPlexActivity ? "true" : "false"))
            }
        }
    }

    /// Resolves the stored `syncPlexActivity` preference. The key is only written once the
    /// user touches the toggle, so an explicit choice (either way) always wins and only
    /// never-touched installs pick up the OFF default.
    static func resolveSyncPlexActivity(stored: Any?) -> Bool {
        (stored as? Bool) ?? false
    }

    /// Global subtitle language (`__system__` = follow Apple TV language).
    var preferredSubtitleLanguageCode: String = AppState.loadPreferredSubtitleLanguageInitial() {
        didSet {
            UserDefaults.standard.set(preferredSubtitleLanguageCode, forKey: Self.subtitleLanguageDefaultsKey)
            applySubtitleSelection()
            if oldValue != preferredSubtitleLanguageCode {
                Analytics.track(.settingChanged(key: "subtitle_language", value: preferredSubtitleLanguageCode))
            }
        }
    }

    /// When true, legible tracks are selected only while `isFullScreen` is true.
    var subtitlesInFullscreenEnabled: Bool =
        UserDefaults.standard.object(forKey: "nostalgex_subtitles_fullscreen") as? Bool ?? false {
        didSet { UserDefaults.standard.set(subtitlesInFullscreenEnabled, forKey: "nostalgex_subtitles_fullscreen")
            applySubtitleSelection()
            if oldValue != subtitlesInFullscreenEnabled {
                Analytics.track(.settingChanged(key: "subtitles_fullscreen", value: subtitlesInFullscreenEnabled ? "true" : "false"))
            }
        }
    }

    /// Auto-enable fullscreen subtitles when no audio track matches the preferred audio
    /// language (foreign-audio fallback). Bypasses `subtitlesInFullscreenEnabled` only;
    /// the fullscreen gate still applies.
    var autoSubtitlesForForeignAudioEnabled: Bool =
        UserDefaults.standard.object(forKey: "nostalgex_auto_subs_foreign_audio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSubtitlesForForeignAudioEnabled, forKey: "nostalgex_auto_subs_foreign_audio")
            applySubtitleSelection()
            if oldValue != autoSubtitlesForForeignAudioEnabled {
                Analytics.track(.settingChanged(key: "auto_subtitles_foreign_audio", value: autoSubtitlesForForeignAudioEnabled ? "true" : "false"))
            }
        }
    }

    private static let subtitleLanguageDefaultsKey = "nostalgex_subtitle_language"

    private static func loadPreferredSubtitleLanguageInitial() -> String {
        if let s = UserDefaults.standard.string(forKey: subtitleLanguageDefaultsKey), !s.isEmpty {
            return s
        }
        return "__system__"
    }

    /// Global audio language (`__system__` = follow Apple TV language).
    var preferredAudioLanguageCode: String = AppState.loadPreferredAudioLanguageInitial() {
        didSet {
            UserDefaults.standard.set(preferredAudioLanguageCode, forKey: Self.audioLanguageDefaultsKey)
            applyAudioTrackSelection()
            if oldValue != preferredAudioLanguageCode {
                Analytics.track(.settingChanged(key: "audio_language", value: preferredAudioLanguageCode))
            }
        }
    }

    private static let audioLanguageDefaultsKey = "nostalgex_audio_language"

    private static func loadPreferredAudioLanguageInitial() -> String {
        if let s = UserDefaults.standard.string(forKey: audioLanguageDefaultsKey), !s.isEmpty {
            return s
        }
        return "__system__"
    }

    // MARK: - In-player audio track selection (per-item, ephemeral)

    /// Audio tracks exposed by the current player item, published when the `.audible`
    /// group loads. Drives the Now Playing panel's audio list. Empty when the item has
    /// no audible group or a single track.
    var audioTracks: [AudioTrackDescriptor] = []

    /// Index of the currently selected audio option (into `audibleGroup.options`).
    var selectedAudioTrackID: Int? = nil

    /// True when the current item exposes at least one real (non-forced) subtitle track.
    /// Drives whether the panel's CC toggle is enabled.
    var hasSubtitleTracks: Bool = false

    /// The live `.audible` group + the exact item it was loaded from. Held so an in-player
    /// selection can validate item identity before mutating (a channel change invalidates it).
    @ObservationIgnored var audibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored weak var audibleGroupItem: AVPlayerItem?

    /// Per-item audio track override triggered from the Now Playing panel. Does NOT touch
    /// `preferredAudioLanguageCode`, so the next program reverts to the global preference.
    func selectAudioTrack(id: Int) {
        guard let group = audibleGroup,
              let item = audibleGroupItem,
              player?.currentItem === item,
              group.options.indices.contains(id) else { return }
        item.select(group.options[id], in: group)
        selectedAudioTrackID = id
    }

    // MARK: - Playback state

    // Moved here from the channel-control section during the AppState split:
    // @Observable requires stored properties to live in the main class body.
    var seekOffset: Int = 0
    /// Offset the server was asked to start an HLS transcode at (0 = none). See hlsBaseOffset.
    var hlsRequestedOffset: Int = 0
    /// Added to the player's clock for every position report. An HLS transcode started at an
    /// offset may count from zero, in which case the true position is clock + offset.
    var hlsBaseOffset: Double = 0
    /// Attached to the current AVPlayerItem so "is video actually decoding" can be asked
    /// directly: a declared presentation size is not the same as a delivered frame.
    var videoFrameProbe: AVPlayerItemVideoOutput?
    var currentChannel: Channel? = nil
    var currentItem: PlexMediaItem? = nil {
        didSet { if currentItem?.ratingKey != oldValue?.ratingKey { refreshNowPlayingInfo() } }
    }
    var currentPartIndex: Int = 0
    var isFullScreen: Bool = false {
        didSet {
            if oldValue != isFullScreen {
                applySubtitleSelection()
            }
        }
    }

    /// Delivery mode for the current playback session. Set on `readyToPlay` inside
    /// `loadCurrentItem`, cleared when the session ends. Rides on `playback.stopped`
    /// so watch time can be split by direct play vs transcode.
    var currentPlaybackDelivery: AnalyticsPlaybackDelivery? = nil

    /// Guard so `playback.ready` fires once per session even though the ready path is
    /// entered again on transcode fallback / retry. Reset in `loadCurrentItem`.
    var playbackReadyReported: Bool = false
    var player: AVPlayer?
    var playbackState: PlaybackState = .idle {
        didSet { if playbackState != oldValue { refreshNowPlayingInfo() } }
    }

    /// The URL the player was last given. Kept so that when a stream fails, the app can ask
    /// the server directly what it says about that exact URL. AVFoundation does not report
    /// the HTTP status of a failed HLS request on tvOS, and "your server answered 500" is
    /// the single most useful thing the failure card can say. See `StreamFailureProbe`.
    var lastStreamURL: URL?

    // Moved here from the shared-playback section during the AppState split:
    // @Observable requires stored properties to live in the main class body.
    /// The active server-side transcode (if any) so we can stop it on a channel change.
    /// `playSessionId` is Jellyfin's session token (nil for Plex, which is keyed off the
    /// stable client id). Set only when a transcode item loads; cleared by the stop helper.
    var activeTranscode: (serverID: String?, playSessionId: String?)?

    // MARK: - Sleep timer

    /// When the armed sleep timer will fire. `nil` = off. Source of truth for the
    /// countdown display; survives channel changes (never cleared by `selectChannel`).
    var sleepTimerEndDate: Date? = nil

    /// Duration the running timer was armed for, in minutes. `nil` = off.
    ///
    /// Stored alongside the end date so the panel can mark the exact row the user chose.
    /// Inferring it from the time remaining only worked for the first minute after arming,
    /// after which no row matched and the countdown disappeared from the panel entirely.
    var sleepTimerMinutes: Int? = nil

    /// Drives the "Still watching?" grace overlay shown when the timer reaches zero.
    var sleepGracePromptActive: Bool = false

    @ObservationIgnored var sleepTimer: Timer?
    @ObservationIgnored var sleepGraceTimer: Timer?

    var cancellables = Set<AnyCancellable>()
    /// Lifetime observers (background/foreground) — never cleared by loadCurrentItem.
    private var _lifetimeObservers = Set<AnyCancellable>()
    var loadGeneration: Int = 0
    var loadDebounceTimer: Timer?
    var playbackTracker: PlaybackTracker?
    var dailyRefreshTask: Task<Void, Never>?
    /// Unix seconds when the library was last loaded. Drives 24h rolling cache
    /// validity for both the on-disk snapshot and the background daily refresh.
    /// Mirrored to UserDefaults via `lastLoadKey` so even if the snapshot JSON
    /// fails to decode on relaunch we still know we loaded recently.
    var lastLoadAtUnix: Int = 0 {
        didSet {
            if lastLoadAtUnix > 0 {
                UserDefaults.standard.set(lastLoadAtUnix, forKey: Self.lastLoadKey)
            }
        }
    }
    static let lastLoadKey = "nostalgex_last_load_at_unix"

    /// True when a full library load finished within the last 24 hours, based on
    /// the UserDefaults-backed timestamp. Used at launch to suppress the heavy
    /// step-rail loader when we know we loaded today, even if the snapshot file
    /// itself is missing or fails to decode.
    var hasRecentSuccessfulLoad: Bool {
        let saved = UserDefaults.standard.integer(forKey: Self.lastLoadKey)
        guard saved > 0 else { return false }
        let now = Int(Date().timeIntervalSince1970)
        return now - saved < 86400
    }

    var scheduleCredentialFingerprint: String {
        LibrarySnapshotStore.fingerprint(identity: snapshotIdentitySeed)
    }

    /// What the snapshot and schedules are keyed on. Plex: the server set (accounts are
    /// separated by Disconnect clearing the snapshot). Jellyfin/Emby: server plus user id,
    /// since those tokens are per-user and the user id is stable across sign-ins.
    var snapshotIdentitySeed: String {
        switch backendKind {
        case .plex: return "plex|\(snapshotServerSeed)"
        default: return "\(backendKind.rawValue)|\(serverURL)|\(jellyfinUserId)"
        }
    }

    var libraryLastUpdatedText: String {
        guard lastLoadAtUnix > 0 else { return "Never" }
        let date = Date(timeIntervalSince1970: Double(lastLoadAtUnix))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - API convenience

    /// Backend for the primary (first selected) server. Used by single-server paths
    /// (connection test, collection scan) and as the routing fallback.
    var api: any MediaBackend { apiForServer(selectedServers.first) }

    /// Backend for a specific server id (an item's `serverID`). Falls back to the primary
    /// server when the id is nil/unknown — covers legacy single-server snapshots.
    func api(for serverID: String?) -> any MediaBackend {
        if let id = serverID, let server = selectedServers.first(where: { $0.machineIdentifier == id }) {
            return apiForServer(server)
        }
        return api
    }

    /// Constructs the right backend for a server. Backends are lightweight value types
    /// (a few stored strings + a shared URLSession), so we build them on demand rather
    /// than caching — avoids stale-token bugs across re-auth.
    func apiForServer(_ server: ServerRef?) -> any MediaBackend {
        switch backendKind {
        case .plex:
            // Demo / App Review repro: no structured server, use raw serverURL+token.
            guard let server else {
                return PlexAPIService(serverURL: serverURL, token: token, serverID: "")
            }
            // Shared servers need their own access token; owned servers fall back to account token.
            let serverToken = server.token ?? token
            return PlexAPIService(serverURL: server.baseURL, token: serverToken, serverID: server.machineIdentifier)
        case .jellyfin:
            // Jellyfin is single-server: one URL + access token + user id.
            return JellyfinAPIService(
                serverURL: server?.baseURL ?? serverURL,
                accessToken: server?.token ?? token,
                userId: server?.userId ?? jellyfinUserId,
                serverID: server?.machineIdentifier ?? ""
            )
        case .emby:
            // Emby is single-server: same credential shape as Jellyfin.
            return EmbyAPIService(
                serverURL: server?.baseURL ?? serverURL,
                accessToken: server?.token ?? token,
                userId: server?.userId ?? jellyfinUserId,
                serverID: server?.machineIdentifier ?? ""
            )
        }
    }

    /// Seed for the library snapshot fingerprint. Built from the sorted set of selected
    /// server ids so changing which servers are included invalidates the cached library.
    var snapshotServerSeed: String {
        selectedServers.isEmpty ? serverURL
            : selectedServers.map(\.machineIdentifier).sorted().joined(separator: ",")
    }
}
