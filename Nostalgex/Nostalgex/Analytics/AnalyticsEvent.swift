import Foundation

// MARK: - Fixed vocabulary

/// Which media server the event is about. `.demo` is separate so demo-mode sessions
/// can't drift into the real-backend cohort even when a user briefly explored demo.
enum AnalyticsBackend: String, Sendable {
    case plex
    case jellyfin
    case emby
    case demo
}

/// How the sign-in flow was started. `.pin` covers plex.tv PIN, `.password` covers
/// direct username+password (Jellyfin, Emby), `.quickConnect` is Jellyfin Quick Connect.
enum AnalyticsConnectMethod: String, Sendable {
    case pin
    case password
    case quickConnect

    var wireValue: String {
        switch self {
        case .quickConnect: return "quick_connect"
        default: return rawValue
        }
    }
}

/// How a channel change was initiated by the user. Automatic re-selections (library
/// load, snapshot restore, foreground return, bundle filter) are never counted.
enum AnalyticsTuneMethod: String, Sendable {
    case guide
    case miniStrip
    case next
    case previous

    var wireValue: String {
        switch self {
        case .miniStrip: return "mini_strip"
        default: return rawValue
        }
    }
}

/// How the current program is being delivered. Set on `playback.ready` and carried
/// on `playback.stopped` so we can tell direct play from transcode watch time.
enum AnalyticsPlaybackDelivery: String, Sendable {
    case directPlay
    case transcode

    var wireValue: String {
        switch self {
        case .directPlay: return "direct_play"
        default: return rawValue
        }
    }
}

/// Fixed, short reason codes for playback failures. Kept small on purpose so the
/// TelemetryDeck dashboard can group them without new codes appearing for every
/// underlying `AVPlayer` message.
enum AnalyticsPlaybackErrorCode: String, Sendable {
    /// No direct-play or transcode URL could be built for the current item.
    case noPlayableSource
    /// Transcode handshake (Jellyfin PlaybackInfo) returned no usable stream.
    case transcodingUnavailable
    /// The `AVPlayer` item transitioned to `.failed` and no fallback recovered it.
    case playerFailed
    /// The playback watchdog gave up waiting for `rate > 0` and skipped ahead.
    case watchdogSkip
    /// A load stalled with no progress and no error; distinct from `.playerFailed`.
    case stalled

    var wireValue: String {
        switch self {
        case .noPlayableSource: return "no_playable_source"
        case .transcodingUnavailable: return "transcoding_unavailable"
        case .playerFailed: return "player_failed"
        case .watchdogSkip: return "watchdog_skip"
        case .stalled: return "stalled"
        }
    }
}

/// First launch on this install vs. every subsequent launch. Distinguished by a
/// UserDefaults marker so installs → connect success can be joined on the dashboard.
enum AnalyticsLaunchKind: String, Sendable {
    case first
    case returning
}

// MARK: - Event catalog

/// Every signal the app can send. Closed enum on purpose so the wrapper is the only
/// place event names or parameters live: `grep` for a signal name and you land here.
///
/// "Can send", not "sends every time": `Analytics.track` passes each event through
/// `AnalyticsGate`, which decides how many of each actually leave the device.
///
/// Renaming note (2026-09):
/// The pre-analytics-rework catalog used `plex.connect.*` for Plex, Jellyfin, and Emby
/// alike, with no way to tell them apart. Those names are gone; the replacements live
/// under `connect.*` with an explicit `backend` parameter. The dashboard will need a
/// fresh cut of connect signals — the old series is not comparable.
enum AnalyticsEvent: Sendable {
    // MARK: Launch & credentials

    /// First launch on this install (`kind = .first`) or a return launch. Fires once
    /// per app start. Joins installs to later `connect.completed` on the dashboard.
    case launch(kind: AnalyticsLaunchKind)

    /// The device could not return a previously saved sign-in. `code` is the keychain
    /// OSStatus reported for the primary secret; no server URL or token bytes.
    case credentialsSignInLost(code: String)

    /// A successful credential save could not be read back. This session will die on
    /// relaunch. No secret material carried, just the fact that the write dropped.
    case credentialsPersistFailed

    // MARK: Connect

    /// A sign-in attempt started for `backend` using `method`.
    case connectStarted(backend: AnalyticsBackend, method: AnalyticsConnectMethod)

    /// A sign-in succeeded. `serverCount` is the number of reachable servers found
    /// (always 1 for Jellyfin/Emby which are single-server flows).
    case connectCompleted(backend: AnalyticsBackend, serverCount: Int)

    /// A sign-in failed. `reason` comes from a fixed, short vocabulary (see the
    /// existing `analyticsReason(for:)` pattern) — never a localized string.
    case connectFailed(backend: AnalyticsBackend, reason: String)

    /// The user cancelled an in-progress sign-in (tapped Cancel on the PIN /
    /// Quick Connect / Sign In screen).
    case connectCancelled(backend: AnalyticsBackend, method: AnalyticsConnectMethod)

    /// The PIN / Quick Connect code expired before the user approved it.
    case connectCodeExpired(backend: AnalyticsBackend, method: AnalyticsConnectMethod)

    /// The user confirmed which servers to include on the multi-server picker (Plex).
    case connectServerPickerConfirmed(backend: AnalyticsBackend, serverCount: Int)

    /// The user confirmed which library sections to include on the onboarding
    /// library-selection screen (I-054). `sectionCount` is how many sections the
    /// screen showed; `excludedCount` is how many were left off.
    case connectLibrarySelectionConfirmed(backend: AnalyticsBackend, sectionCount: Int, excludedCount: Int)

    // MARK: Library

    /// A library scan is starting. `background = true` means it's a silent 6h refresh
    /// behind an already-populated guide.
    case libraryLoadStarted(background: Bool, firstLoad: Bool)

    /// A library scan finished. `durationMs` covers the whole load path (fetch +
    /// enrichment + channel build). `partial = true` means one or more servers
    /// returned reduced results.
    case libraryLoadCompleted(channelCount: Int, itemCount: Int, background: Bool, durationMs: Int, partial: Bool)

    /// A foreground library scan failed. Background failures are reported by
    /// `libraryRefreshBackgroundFailed`.
    case libraryLoadFailed(reason: String, background: Bool)

    /// A scan was abandoned. `userInitiated = true` = the user tapped "stop waiting";
    /// `false` = the stall watchdog gave up. `itemsFound` is what came back so far.
    case libraryLoadAbandoned(background: Bool, itemsFound: Int, userInitiated: Bool)

    /// A scan finished with no channels — the "no channels found" empty-lineup state.
    case libraryLoadEmpty

    /// The user tapped the STOP WAITING button on the loading screen.
    case libraryStopWaitingTapped

    /// A background library refresh failed. Separate from `libraryLoadFailed` so
    /// silent failures don't wash out the foreground failure rate.
    case libraryRefreshBackgroundFailed(reason: String)

    // MARK: Tuning & playback

    /// A user-initiated channel change. Never fired by automatic re-selection paths
    /// (library load, snapshot restore, background refresh, foreground return).
    /// `channel` carries the cross-user-comparable identity (see
    /// `AnalyticsChannelDescriptor`); `channelNumber` is retained because it's
    /// still useful for correlating with UX (which slot in the mini-strip, etc.),
    /// even though it isn't comparable across installs.
    case channelTuned(channelNumber: Int, backend: AnalyticsBackend, method: AnalyticsTuneMethod, channel: AnalyticsChannelDescriptor)

    /// `AVPlayer` is actually ready to play (rate can reach 1). `delivery`
    /// distinguishes direct play from a server-side transcode.
    case playbackReady(channelNumber: Int, backend: AnalyticsBackend, delivery: AnalyticsPlaybackDelivery, channel: AnalyticsChannelDescriptor)

    /// A playback session ended (channel change, disconnect, sleep timer, background,
    /// or auto-advance after error). `activeWatchSeconds` is the accumulated time the
    /// player was actually playing for this session — sent as `floatValue`.
    case playbackStopped(channelNumber: Int, backend: AnalyticsBackend, delivery: AnalyticsPlaybackDelivery, channel: AnalyticsChannelDescriptor, activeWatchSeconds: Double)

    /// A playback failure. `code` is a fixed short vocabulary
    /// (see `AnalyticsPlaybackErrorCode`).
    case playbackError(channelNumber: Int, backend: AnalyticsBackend, code: AnalyticsPlaybackErrorCode)

    /// Direct play failed and playback fell back to a server-side transcode.
    case playbackTranscodeFallback(channelNumber: Int, backend: AnalyticsBackend)

    // MARK: Settings & UX

    /// A settings toggle or picker changed. `key` is a short, fixed identifier
    /// (`retro_mode`, `sync_plex_activity`, `bundle:essentials`, `server`,
    /// `library_section`, `rescan`, `disconnect`, `stream_quality`, `subtitle_language`,
    /// `audio_language`, `subtitles_fullscreen`, `auto_subtitles_foreign_audio`,
    /// `sleep_timer_minutes`).
    /// `value` is a short serialized value (`true`/`false`, a language code, a numeric
    /// bucket, or `tapped` for one-shot actions).
    case settingChanged(key: String, value: String)

    /// The user tapped the "Rate Nostalgex" row (opens the App Store product page).
    case rateTapped

    /// The rating nudge banner appeared on the guide (at most once per app version).
    case ratingNudgeShown

    /// The viewer chose RATE on the rating nudge banner (opens the product page).
    case ratingNudgeTapped

    // MARK: Update emails

    /// The update-emails QR in Settings was on screen. Once per Settings visit, never
    /// in demo mode. The scan happens on a phone, so signups are counted on the website.
    case signupQRShown(backend: AnalyticsBackend)

    // MARK: Session length

    /// Fires once every time the app moves to the background, carrying the
    /// wall-clock seconds spent in the foreground since the last launch or
    /// return-to-foreground. Sent as `floatValue` so the dashboard can sum
    /// it directly for "total time in app". See the PR description for the
    /// recommendation on this vs TelemetryDeck's own Sessions chart.
    ///
    /// `summary` is filled in by `AnalyticsGate` on the way out: the session's tune,
    /// playback start and error counts, including the ones it did not send one by one.
    /// Call sites never pass it.
    case sessionEnded(activeSeconds: Double, summary: AnalyticsSessionSummary? = nil)

    // MARK: - Wire mapping

    /// Signal name sent to TelemetryDeck.
    var name: String {
        switch self {
        case .launch: return "app.launch"
        case .credentialsSignInLost: return "credentials.sign_in_lost"
        case .credentialsPersistFailed: return "credentials.persist_failed"

        case .connectStarted: return "connect.started"
        case .connectCompleted: return "connect.completed"
        case .connectFailed: return "connect.failed"
        case .connectCancelled: return "connect.cancelled"
        case .connectCodeExpired: return "connect.code_expired"
        case .connectServerPickerConfirmed: return "connect.server_picker.confirmed"
        case .connectLibrarySelectionConfirmed: return "connect.library_selection.confirmed"

        case .libraryLoadStarted: return "library.load.started"
        case .libraryLoadCompleted: return "library.load.completed"
        case .libraryLoadFailed: return "library.load.failed"
        case .libraryLoadAbandoned: return "library.load.abandoned"
        case .libraryLoadEmpty: return "library.load.empty"
        case .libraryStopWaitingTapped: return "library.load.stop_waiting_tapped"
        case .libraryRefreshBackgroundFailed: return "library.refresh.background_failed"

        case .channelTuned: return "channel.tuned"
        case .playbackReady: return "playback.ready"
        case .playbackStopped: return "playback.stopped"
        case .playbackError: return "playback.error"
        case .playbackTranscodeFallback: return "playback.transcode_fallback"

        case .settingChanged: return "setting.changed"
        case .rateTapped: return "rate.tapped"
        case .ratingNudgeShown: return "rating_nudge.shown"
        case .ratingNudgeTapped: return "rating_nudge.tapped"
        case .signupQRShown: return "signup.qr.shown"
        case .sessionEnded: return "app.session.ended"
        }
    }

    /// String parameters sent alongside the signal. Every event that mentions a
    /// backend carries it as a top-level parameter so the dashboard can filter.
    var parameters: [String: String] {
        switch self {
        case .launch(let kind):
            return ["kind": kind.rawValue]

        case .credentialsSignInLost(let code):
            return ["code": code]

        case .credentialsPersistFailed:
            return [:]

        case .connectStarted(let backend, let method):
            return ["backend": backend.rawValue, "method": method.wireValue]

        case .connectCompleted(let backend, let serverCount):
            return ["backend": backend.rawValue, "serverCount": String(serverCount)]

        case .connectFailed(let backend, let reason):
            return ["backend": backend.rawValue, "reason": reason]

        case .connectCancelled(let backend, let method):
            return ["backend": backend.rawValue, "method": method.wireValue]

        case .connectCodeExpired(let backend, let method):
            return ["backend": backend.rawValue, "method": method.wireValue]

        case .connectServerPickerConfirmed(let backend, let serverCount):
            return ["backend": backend.rawValue, "serverCount": String(serverCount)]

        case .connectLibrarySelectionConfirmed(let backend, let sectionCount, let excludedCount):
            return ["backend": backend.rawValue, "sectionCount": String(sectionCount), "excludedCount": String(excludedCount)]

        case .libraryLoadStarted(let background, let firstLoad):
            return [
                "background": background ? "true" : "false",
                "firstLoad": firstLoad ? "true" : "false",
            ]

        case .libraryLoadCompleted(let channelCount, let itemCount, let background, let durationMs, let partial):
            return [
                "channelCount": String(channelCount),
                "itemCount": String(itemCount),
                "background": background ? "true" : "false",
                "durationMs": String(durationMs),
                "partial": partial ? "true" : "false",
            ]

        case .libraryLoadFailed(let reason, let background):
            return [
                "reason": reason,
                "background": background ? "true" : "false",
            ]

        case .libraryLoadAbandoned(let background, let itemsFound, let userInitiated):
            return [
                "background": background ? "true" : "false",
                "itemsFound": String(itemsFound),
                "userInitiated": userInitiated ? "true" : "false",
            ]

        case .libraryLoadEmpty:
            return [:]

        case .libraryStopWaitingTapped:
            return [:]

        case .libraryRefreshBackgroundFailed(let reason):
            return ["reason": reason]

        case .channelTuned(let channelNumber, let backend, let method, let channel):
            var params: [String: String] = [
                "channelNumber": String(channelNumber),
                "backend": backend.rawValue,
                "method": method.wireValue,
            ]
            for (key, value) in channel.wireParameters { params[key] = value }
            return params

        case .playbackReady(let channelNumber, let backend, let delivery, let channel):
            var params: [String: String] = [
                "channelNumber": String(channelNumber),
                "backend": backend.rawValue,
                "delivery": delivery.wireValue,
            ]
            for (key, value) in channel.wireParameters { params[key] = value }
            return params

        case .playbackStopped(let channelNumber, let backend, let delivery, let channel, _):
            // activeWatchSeconds rides as `floatValue`, not as a string parameter.
            var params: [String: String] = [
                "channelNumber": String(channelNumber),
                "backend": backend.rawValue,
                "delivery": delivery.wireValue,
            ]
            for (key, value) in channel.wireParameters { params[key] = value }
            return params

        case .playbackError(let channelNumber, let backend, let code):
            return [
                "channelNumber": String(channelNumber),
                "backend": backend.rawValue,
                "code": code.wireValue,
            ]

        case .playbackTranscodeFallback(let channelNumber, let backend):
            return [
                "channelNumber": String(channelNumber),
                "backend": backend.rawValue,
            ]

        case .settingChanged(let key, let value):
            return ["key": key, "value": value]

        case .rateTapped, .ratingNudgeShown, .ratingNudgeTapped:
            return [:]

        case .signupQRShown(let backend):
            return ["placement": "settings", "backend": backend.rawValue]

        case .sessionEnded(_, let summary):
            // activeSeconds rides as `floatValue`, matching playback.stopped.
            return summary?.wireParameters ?? [:]
        }
    }

    /// Optional numeric payload. `playback.stopped` uses this for accumulated
    /// active watch time; `app.session.ended` uses it for wall-clock seconds in
    /// the foreground. Both are summable on the dashboard without parsing a
    /// string parameter.
    var floatValue: Double? {
        switch self {
        case .playbackStopped(_, _, _, _, let seconds):
            return seconds
        case .sessionEnded(let seconds, _):
            return seconds
        default:
            return nil
        }
    }
}
