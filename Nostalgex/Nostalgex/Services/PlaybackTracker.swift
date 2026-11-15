import Foundation

/// Tracks a single playback session for one item on one channel.
/// Reports to Plex (timeline + scrobble) or to Jellyfin/Emby (session + play count).
/// With neither reporter, it only accumulates watch time for analytics.
///
/// Scrobble rule (hybrid gate), same on every server:
///   1. Entry gate — tuned in during the first 15% of the program
///   2. Active time — accumulated ≥ 75% of total runtime while this tracker is active
/// Both gates must pass. The count increments as soon as the threshold is crossed or on stop.
///
/// Continue Watching: reporting must never leave a program in the user's Continue
/// Watching, Resume or On Deck rows.
/// - Plex: every timeline report is position-free (PR #18), so Now Playing sees the title
///   and whether it is playing, paused or buffering, and Plex stores nothing. A counted
///   episode's next-up entry is removed unless its show was already in Continue Watching.
/// - Jellyfin/Emby: reports carry the position (a stop without one marks the item played),
///   so the tracker reads UserData before the first report and writes it back when the
///   session ends, the app backgrounds or the user turns reporting off.
/// See `WatchCleanupPlan`. Every server call goes through one `ReportQueue`, so cleanup
/// always lands after the last report. A server that stops answering gets fewer pulses
/// (`PulseBackoff`); nothing here ever changes the user's setting.
@MainActor
final class PlaybackTracker {

    // MARK: - Identity

    let sessionID = UUID().uuidString
    let item: PlexMediaItem
    /// Seconds into the program when the user tuned in.
    let seekOffset: Int

    // MARK: - Entry gate

    /// True if the user tuned in during the first 15% of the program.
    let eligibleEntry: Bool

    // MARK: - Watch clock

    private var activeWatchSeconds: Double = 0
    /// Independent accumulator drained by `flushWatchSecondsForAnalytics`. Kept
    /// separate from `activeWatchSeconds` so draining it for a `playback.stopped`
    /// analytics signal doesn't reset the scrobble threshold ( ≥ 75% of runtime ).
    private var analyticsWatchSeconds: Double = 0
    private var watchStart: Date? = nil

    // MARK: - State

    private(set) var scrobbled = false
    private var stopped = false

    // MARK: - Rating nudge

    /// Set once this watch has been counted toward the rating nudge, so the same
    /// continuous watch is never counted twice (once at exit-to-guide, again on stop).
    var countedAsViewingSession = false
    /// Called from `stop()` with the session's total active watch seconds.
    var onStop: ((PlaybackTracker, Double) -> Void)?

    /// Total active watch time so far, including the running stretch. Read-only: it
    /// does not drain either accumulator.
    var watchedSecondsSoFar: Double {
        activeWatchSeconds + (watchStart.map { now().timeIntervalSince($0) } ?? 0)
    }

    // MARK: - 10-second timeline pulse

    private var timelineTimer: Timer?

    // MARK: - Server reporting (nil = demo or unavailable backend)

    private let plexAPI: PlexAPIService?
    private let watchReporter: (any WatchActivityReporting)?
    private var showNowPlaying: Bool
    private var markWatched: Bool
    private let permissions: PlaybackReportPermissions

    /// AVPlayer's last state ("playing", "paused", "buffering"), so Now Playing on Plex
    /// shows a pause as a pause. From PR #18.
    private var playerState: String?
    /// Backgrounding already sent the stop; foregrounding clears it. From PR #18.
    private var backgrounded = false
    private let backoff = PulseBackoff()

    // MARK: - Continue Watching guard

    private let watchGuard: (any WatchStateGuarding)?
    private let queue: ReportQueue
    private let now: () -> Date
    /// Written by the capture operation on `queue`, read by the cleanup operation on it.
    private let reportState = PlaybackReportState()

    var hasReportingWork: Bool { showNowPlaying || markWatched || permissions.hasAttemptedReporting }

    // MARK: - Init

    init(
        item: PlexMediaItem,
        seekOffset: Int,
        plexAPI: PlexAPIService?,
        watchReporter: (any WatchActivityReporting)? = nil,
        showNowPlaying: Bool = false,
        markWatched: Bool = false,
        controlScope: PlaybackReportingControlScope? = nil,
        queue: ReportQueue = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.item = item
        self.seekOffset = seekOffset
        self.plexAPI = plexAPI
        self.watchReporter = watchReporter
        self.showNowPlaying = showNowPlaying
        self.markWatched = markWatched
        self.permissions = PlaybackReportPermissions(showNowPlaying: showNowPlaying, markWatched: markWatched, scope: controlScope)
        if let plexAPI {
            self.watchGuard = plexAPI.watchStateGuard
        } else {
            self.watchGuard = watchReporter?.watchStateGuard
        }
        self.queue = queue
        self.now = now

        let totalSec = Double(item.slotSeconds)
        let entryFrac = totalSec > 0 ? Double(seekOffset) / totalSec : 1.0
        self.eligibleEntry = entryFrac <= 0.15

        print("[Tracker] \(sessionID.prefix(8)) START \"\(item.title)\" offset=\(seekOffset)s eligible=\(eligibleEntry)")
    }

    deinit {
        timelineTimer?.invalidate()
    }

    // MARK: - Lifecycle hooks

    /// Call when AVPlayer becomes .readyToPlay and begins playing.
    /// Idempotent — safe to call from retry / transcode-fallback paths for the same item.
    func onPlaybackReady() {
        guard !stopped, !backgrounded else { return }
        if watchStart == nil {
            watchStart = now()
        }
        if timelineTimer == nil {
            scheduleTimeline()
        }
        sendTimeline(state: "playing")
    }

    /// Keep one logical viewing session across parts without counting loading time.
    func onPlaybackPreparing() {
        guard !stopped else { return }
        accumulateTime()
        timelineTimer?.invalidate()
        timelineTimer = nil
    }

    /// AVPlayer's state, from `timeControlStatus`. On Plex a change shows in Now Playing
    /// at once instead of on the next pulse. Never touches the watch clock.
    func onHeartbeatPlaybackState(_ state: String) {
        guard !stopped, !backgrounded, state != playerState else { return }
        playerState = state
        if plexAPI != nil, timelineTimer != nil { sendTimeline(state: state) }
    }

    /// Call when the app enters the background. The app may never come back, so the
    /// item is put back the way it was now; returning to the foreground reports again
    /// and the next stop cleans up again.
    func onBackground() {
        guard !stopped, !backgrounded else { return }
        backgrounded = true
        playerState = nil
        accumulateTime()
        sendTimeline(state: "stopped")
        timelineTimer?.invalidate()
        timelineTimer = nil
        enqueueCleanup()
    }

    /// Call when the app returns to the foreground.
    func onForeground() {
        guard !stopped else { return }
        backgrounded = false
        watchStart = now()
        scheduleTimeline()
        sendTimeline(state: "playing")
    }

    /// Finalize the session: flush accumulated time, send stopped, evaluate scrobble,
    /// then restore Continue Watching. Called before advancing, channel change, or disconnect.
    func stop() {
        guard !stopped else { return }
        stopped = true
        timelineTimer?.invalidate()
        timelineTimer = nil
        accumulateTime()
        if !backgrounded { sendTimeline(state: "stopped") }
        evaluateAndScrobble()
        enqueueCleanup()
        print("[Tracker] \(sessionID.prefix(8)) STOP \"\(item.title)\" watched=\(Int(activeWatchSeconds))s scrobbled=\(scrobbled)")
        onStop?(self, activeWatchSeconds)
        onStop = nil
    }

    /// Live preference changes keep the watch clock and analytics running. Epochs
    /// invalidate queued starts, progress and watched writes immediately; final stops
    /// and restoration are unconditional queue operations for attempted sessions.
    func updateReporting(showNowPlaying: Bool, markWatched: Bool) {
        let wasShowing = self.showNowPlaying
        let wasMarking = self.markWatched
        guard wasShowing != showNowPlaying || wasMarking != markWatched else { return }
        self.showNowPlaying = showNowPlaying
        self.markWatched = markWatched
        permissions.update(showNowPlaying: showNowPlaying, markWatched: markWatched)
        if wasMarking != markWatched {
            // A canceled queued mark is eligible again after re-enabling. An already
            // attempted mark is never replayed just because the setting changed.
            scrobbled = permissions.hasAttemptedMark
        }
        if wasShowing && !showNowPlaying { sendTimeline(state: "stopped") }
        if (wasShowing && !showNowPlaying) || (wasMarking && !markWatched) { enqueueCleanup() }
        if !wasShowing, showNowPlaying, !stopped, !backgrounded, watchStart != nil {
            sendTimeline(state: playerState ?? "playing")
        }
    }

    /// Compatibility for the old all-off switch. Accounting continues independently.
    func abandon() {
        updateReporting(showNowPlaying: false, markWatched: false)
    }

    /// Runs one pulse now. Tests drive the tracker with this instead of the 10s timer.
    func timelineTickForTesting() {
        onTimelineTick()
    }

    /// Return the accumulated active watch time and reset the counter so the next
    /// `playback.stopped` analytics signal doesn't double-count. Independent of the
    /// Plex scrobble path (which needs the running total until `stop()`), so this is
    /// called by AppState in every backend, including Jellyfin/Emby/demo.
    ///
    /// Safe to call while the session is still running: the split second between the
    /// last accumulation and now is folded in, and a fresh accumulation window opens
    /// for whatever comes next.
    func flushWatchSecondsForAnalytics() -> Double {
        if let start = watchStart {
            let delta = now().timeIntervalSince(start)
            activeWatchSeconds += delta
            analyticsWatchSeconds += delta
            // Keep accumulating from now if the session is still live; otherwise leave
            // it nil so nothing is added after a stop.
            watchStart = stopped ? nil : now()
        }
        let out = analyticsWatchSeconds
        analyticsWatchSeconds = 0
        return out
    }

    // MARK: - Private

    private func accumulateTime() {
        guard let start = watchStart else { return }
        let delta = now().timeIntervalSince(start)
        activeWatchSeconds += delta
        analyticsWatchSeconds += delta
        watchStart = nil
    }

    private func scheduleTimeline() {
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onTimelineTick() }
        }
    }

    private func onTimelineTick() {
        guard !stopped, !backgrounded else {
            timelineTimer?.invalidate()
            return
        }
        // accumulateTime folds elapsed since watchStart into BOTH counters (scrobble
        // and analytics). Resetting watchStart keeps the next tick's delta clean.
        accumulateTime()
        watchStart = now()
        sendTimeline(state: "playing", pulse: true)
        evaluateAndScrobble()
    }

    private func currentTimeMs() -> Int {
        (seekOffset * 1000) + Int(activeWatchSeconds * 1000)
    }

    /// Capture only before a write that is still allowed. Mark-only episodes need
    /// this too: their scrobble creates a next-up row without any timeline reports.
    nonisolated private static func captureIfNeeded(_ box: PlaybackReportState, guardian: (any WatchStateGuarding)?, item: PlexMediaItem) async {
        guard !box.captureAttempted else { return }
        box.captureAttempted = true
        box.prior = await guardian?.captureWatchState(for: item)
    }

    private func enqueueCleanup() {
        guard let guardian = watchGuard else { return }
        let item = self.item
        let box = reportState
        let permissions = self.permissions
        queue.enqueue {
            guard box.needsCleanup else { return }
            // Read at execution, not enqueue: a queued scrobble may have been canceled.
            await guardian.restoreWatchState(for: item, prior: box.prior,
                                              countedWatch: permissions.hasAttemptedMark)
            box.needsCleanup = false
        }
    }

    private func sendTimeline(state: String, pulse: Bool = false) {
        guard plexAPI != nil || watchReporter != nil else { return }
        if state != "stopped", !showNowPlaying { return }
        if pulse, !backoff.allowPulse() { return }
        let api = plexAPI
        let reporter = watchReporter
        let guardian = watchGuard
        let item = self.item
        let box = reportState
        let permissions = self.permissions
        let epoch = permissions.activityEpoch
        let sid = sessionID
        let ticks = currentTimeMs() * 10_000
        let durationTicks = item.slotSeconds * 10_000_000
        let reported = state == "playing" ? (playerState ?? "playing") : state
        let backoff = self.backoff
        queue.enqueue {
            if state == "stopped" {
                guard box.sessionAttempted else { return }
                if let api {
                    backoff.record(success: await api.reportHeartbeat(ratingKey: item.ratingKey, state: "stopped", sessionID: sid))
                } else if let reporter {
                    // A Now Playing-only session must not cross the server's completion
                    // line on stop. Restoration still repairs the start report's count.
                    let capped = durationTicks > 0 ? min(ticks, Int(Double(durationTicks) * 0.89)) : ticks
                    backoff.record(success: await reporter.reportWatchActivity(
                        itemId: item.ratingKey, mediaSourceId: item.partKey ?? item.ratingKey,
                        playSessionId: sid, positionTicks: capped, event: .stopped))
                }
                box.sessionAttempted = false
                box.needsCleanup = true
                return
            }
            guard permissions.allowsActivity(epoch: epoch) else { return }
            if api == nil || permissions.markEnabled {
                await Self.captureIfNeeded(box, guardian: guardian, item: item)
            }
            // Jellyfin/Emby mutate play counts on session start. Without a prior
            // snapshot there is no safe restoration, so skip this item's session.
            if api == nil, box.prior == nil { return }
            guard permissions.beginActivity(epoch: epoch) else { return }
            let started = box.sessionAttempted
            box.sessionAttempted = true // A lost response still needs a bounded stop.
            box.needsCleanup = true
            if let api {
                backoff.record(success: await api.reportHeartbeat(ratingKey: item.ratingKey, state: reported, sessionID: sid))
            } else if let reporter {
                backoff.record(success: await reporter.reportWatchActivity(
                    itemId: item.ratingKey, mediaSourceId: item.partKey ?? item.ratingKey,
                    playSessionId: sid, positionTicks: ticks, event: started ? .progress : .started))
            }
        }
    }

    private func evaluateAndScrobble() {
        guard markWatched, eligibleEntry, !scrobbled, plexAPI != nil || watchReporter != nil else { return }
        let totalSec = Double(item.slotSeconds)
        guard totalSec > 0, activeWatchSeconds / totalSec >= 0.75 else { return }
        scrobbled = true
        let api = plexAPI
        let reporter = watchReporter
        let guardian = watchGuard
        let item = self.item
        let box = reportState
        let permissions = self.permissions
        let epoch = permissions.markEpoch
        queue.enqueue {
            guard permissions.allowsMark(epoch: epoch) else { return }
            await Self.captureIfNeeded(box, guardian: guardian, item: item)
            // Without a baseline, skip this Jellyfin/Emby session's watched writes too.
            guard api != nil || box.prior != nil else { return }
            guard permissions.beginMark(epoch: epoch) else { return }
            box.needsCleanup = true
            if let api { await api.scrobble(ratingKey: item.ratingKey) }
            else if let reporter {
                // Always explicit, including mark-only watches past 90%. Session stops
                // stay below auto-completion; cleanup normalizes to one counted watch.
                await reporter.markWatched(itemId: item.ratingKey)
            }
        }
    }
}

/// Queue-owned state. One ReportQueue serializes every access.
private final class PlaybackReportState: @unchecked Sendable {
    var captureAttempted = false
    var prior: PriorWatchState?
    var sessionAttempted = false
    var needsCleanup = false
}

/// The main actor revokes permission while detached queue operations may be waiting.
/// Separate epochs prevent an old request becoming valid again after OFF -> ON.
private final class PlaybackReportPermissions: @unchecked Sendable {
    private let lock = NSLock()
    private let scope: PlaybackReportingControlScope
    private var markAttempted = false

    init(showNowPlaying: Bool, markWatched: Bool, scope: PlaybackReportingControlScope?) {
        self.scope = scope ?? PlaybackReportingControlScope(showNowPlaying: showNowPlaying, markWatched: markWatched)
        self.scope.update(showNowPlaying: showNowPlaying, markWatched: markWatched)
    }
    var activityEpoch: Int { scope.activityEpoch }
    var markEpoch: Int { scope.markEpoch }
    var hasAttemptedMark: Bool { lock.withLock { markAttempted } }
    var hasAttemptedReporting: Bool { scope.hasAttemptedReporting }
    var markEnabled: Bool { scope.markEnabled }
    func beginActivity(epoch: Int) -> Bool { scope.beginActivity(epoch: epoch) }
    func update(showNowPlaying: Bool, markWatched: Bool) {
        scope.update(showNowPlaying: showNowPlaying, markWatched: markWatched)
    }
    func allowsActivity(epoch: Int) -> Bool { scope.allowsActivity(epoch: epoch) }
    func allowsMark(epoch: Int) -> Bool { scope.allowsMark(epoch: epoch) && !hasAttemptedMark }
    func beginMark(epoch: Int) -> Bool {
        scope.beginMark(epoch: epoch) {
            lock.withLock {
                guard !markAttempted else { return false }
                markAttempted = true
                return true
            }
        }
    }
}
