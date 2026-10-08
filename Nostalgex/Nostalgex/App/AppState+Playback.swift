import Foundation
import Observation
import SwiftUI
import AVFoundation
import Combine
import UIKit

// Player control, subtitles and audio selection, sleep timer, retries and auto-advance.
// Split out of AppState.swift; behavior unchanged.
extension AppState {
    // MARK: - Open in Plex

    /// Whether the current program can be handed to the Plex app: Plex backend, not demo,
    /// and the Plex app is installed (canOpenURL requires the scheme to be declared in
    /// LSApplicationQueriesSchemes).
    var canOpenCurrentItemInPlex: Bool {
        guard backendKind == .plex, !isDemoMode, currentItem != nil,
              let probe = URL(string: "plex://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    /// Deep-links the current program into the Plex app via the community-documented
    /// preplay scheme. Completion false means the app refused or the scheme didn't
    /// resolve — the row shows that instead of failing silently.
    func openCurrentItemInPlex(completion: @escaping (Bool) -> Void) {
        guard let item = currentItem else { completion(false); return }
        let machineID = item.serverID ?? selectedServers.first?.machineIdentifier ?? ""
        var components = URLComponents()
        components.scheme = "plex"
        components.host = "preplay"
        components.path = "/"
        components.queryItems = [
            .init(name: "metadataKey", value: "/library/metadata/\(item.ratingKey)"),
            .init(name: "server", value: machineID),
        ]
        guard let url = components.url else { completion(false); return }
        print("[Plex90] OPEN IN PLEX: \(url.absoluteString)")
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }

    /// Poster for the panel header. Plex-only: its server-side thumbnail transcode puts
    /// the token in the URL, which is what lets plain AsyncImage load it.
    func posterURL(for item: PlexMediaItem) -> URL? {
        guard backendKind == .plex, !isDemoMode else { return nil }
        if let sid = item.serverID,
           let server = selectedServers.first(where: { $0.machineIdentifier == sid }),
           let service = apiForServer(server) as? PlexAPIService {
            return service.thumbnailURL(for: item, width: 300)
        }
        return (api as? PlexAPIService)?.thumbnailURL(for: item, width: 300)
    }

    // MARK: - Subtitles (fullscreen + media selection)

    private var resolvedPreferredSubtitleLanguageCode: String {
        SubtitleSelectionLogic.resolvedLanguageCode(storedCode: preferredSubtitleLanguageCode, locale: Locale.current)
    }

    private var resolvedPreferredAudioLanguageCode: String {
        SubtitleSelectionLogic.resolvedLanguageCode(storedCode: preferredAudioLanguageCode, locale: Locale.current)
    }

    /// Applies legible track selection to the current item: on when fullscreen + toggle, or
    /// (fullscreen) when no audio track matches the preferred audio language; otherwise off.
    /// Pass `loadGenerationToken` from playback ready handlers so async work does not affect a replaced item.
    func applySubtitleSelection(loadGenerationToken: Int? = nil) {
        guard let playerItem = player?.currentItem else { return }
        if let token = loadGenerationToken, loadGeneration != token { return }

        let preferredLang = resolvedPreferredSubtitleLanguageCode.lowercased()
        let preferredAudioLang = resolvedPreferredAudioLanguageCode.lowercased()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let token = loadGenerationToken, self.loadGeneration != token { return }
            guard self.player?.currentItem === playerItem else { return }

            do {
                guard let group = try await playerItem.asset.loadMediaSelectionGroup(for: .legible) else { return }
                if let token = loadGenerationToken, self.loadGeneration != token { return }
                guard self.player?.currentItem === playerItem else { return }

                // Publish caption availability so the Now Playing panel can disable the
                // CC toggle when a stream exposes no real (non-forced) subtitle track.
                self.hasSubtitleTracks = group.options.contains { !Self.isForcedOnly($0) }

                var shouldEnable = self.subtitlesInFullscreenEnabled && self.isFullScreen
                var autoEnabled = false
                if !shouldEnable, self.autoSubtitlesForForeignAudioEnabled, self.isFullScreen,
                   let audioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible) {
                    if let token = loadGenerationToken, self.loadGeneration != token { return }
                    guard self.player?.currentItem === playerItem else { return }
                    // Foreign-audio fallback: nothing plays in the preferred audio language,
                    // so show subtitles even though the fullscreen-subtitles toggle is off.
                    let audioTags = audioGroup.options.map { Self.languageTag(for: $0) }
                    shouldEnable = SubtitleSelectionLogic.shouldAutoEnableSubtitles(
                        audioTags: audioTags,
                        preferredAudioLowercased: preferredAudioLang
                    )
                    autoEnabled = shouldEnable
                }

                if !shouldEnable {
                    // Even with subtitles off, surface forced narrative subs in the
                    // preferred language (e.g. Na'vi sections of Avatar). If no
                    // forced track exists, turn subtitles fully off.
                    if let forced = Self.pickForcedLegibleOption(in: group, preferredLanguage: preferredLang) {
                        playerItem.select(forced, in: group)
                    } else if group.allowsEmptySelection {
                        playerItem.select(nil, in: group)
                    } else if let off = group.options.first(where: { $0.displayName.localizedCaseInsensitiveContains("off") }) {
                        playerItem.select(off, in: group)
                    } else {
                        playerItem.select(nil, in: group)
                    }
                    return
                }

                let pick = Self.pickLegibleOption(in: group, preferredLanguage: preferredLang)
                if autoEnabled, let pick {
                    // Auto mode: only show subs that actually match the preferred subtitle
                    // language — wrong-language subs are worse than none. Fall back to the
                    // forced-narrative/off handling used when subtitles are disabled.
                    let tag = Self.languageTag(for: pick)?.lowercased()
                    if let tag, tag == preferredLang || tag.hasPrefix(preferredLang + "-") {
                        playerItem.select(pick, in: group)
                    } else if let forced = Self.pickForcedLegibleOption(in: group, preferredLanguage: preferredLang) {
                        playerItem.select(forced, in: group)
                    } else if group.allowsEmptySelection {
                        playerItem.select(nil, in: group)
                    }
                } else if let pick {
                    playerItem.select(pick, in: group)
                }
            } catch {
                // Stream may not expose a legible group (common for some direct-play paths).
            }
        }
    }

    /// Selects the preferred audio track on the current player item.
    /// Falls back to the default track if no match is found rather than forcing silence.
    func applyAudioTrackSelection(loadGenerationToken: Int? = nil) {
        guard let playerItem = player?.currentItem else { return }
        if let token = loadGenerationToken, loadGeneration != token { return }

        let preferredLang = resolvedPreferredAudioLanguageCode.lowercased()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let token = loadGenerationToken, self.loadGeneration != token { return }
            guard self.player?.currentItem === playerItem else { return }

            do {
                guard let group = try await playerItem.asset.loadMediaSelectionGroup(for: .audible) else { return }
                if let token = loadGenerationToken, self.loadGeneration != token { return }
                guard self.player?.currentItem === playerItem else { return }

                let tags = group.options.map { Self.languageTag(for: $0) }
                let idx = SubtitleSelectionLogic.preferredTrackIndex(tags: tags, preferredLowercased: preferredLang)
                playerItem.select(group.options[idx], in: group)

                // Publish descriptors for the Now Playing panel. Behind the same
                // generation + item-identity guards, so stale loads never publish.
                self.audibleGroup = group
                self.audibleGroupItem = playerItem
                self.audioTracks = AudioTrackDescriptorBuilder.build(from: group)
                self.selectedAudioTrackID = idx
            } catch {
                // Stream doesn't expose an audible group — leave AVPlayer's default selection
            }
        }
    }

    private static func isForcedOnly(_ opt: AVMediaSelectionOption) -> Bool {
        opt.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }

    private static func languageTag(for opt: AVMediaSelectionOption) -> String? {
        let ext: String?
        if #available(tvOS 16.0, *) {
            ext = opt.extendedLanguageTag
        } else {
            ext = nil
        }
        return SubtitleSelectionLogic.languageTagForComparison(
            extendedLanguageTag: ext,
            localeIdentifier: opt.locale?.identifier
        )
    }

    /// Find a forced-only subtitle track matching the preferred language.
    /// Used when the user has subtitles disabled but we still want foreign-dialogue
    /// captions (Avatar's Na'vi, Star Wars' Huttese, etc.) to display.
    private static func pickForcedLegibleOption(
        in group: AVMediaSelectionGroup,
        preferredLanguage: String
    ) -> AVMediaSelectionOption? {
        group.options.first { opt in
            guard isForcedOnly(opt) else { return false }
            guard let tag = languageTag(for: opt)?.lowercased() else { return false }
            return tag == preferredLanguage || tag.hasPrefix(preferredLanguage + "-")
        }
    }

    /// Pick the full legible track for the preferred language. When multiple
    /// tracks share the language, prefer the non-forced one so the user gets
    /// complete subtitles, not just foreign-dialogue translations.
    private static func pickLegibleOption(
        in group: AVMediaSelectionGroup,
        preferredLanguage: String
    ) -> AVMediaSelectionOption? {
        let candidates = group.options
        guard !candidates.isEmpty else { return nil }

        // First pass: non-forced match for preferred language
        if let full = candidates.first(where: { opt in
            guard !isForcedOnly(opt) else { return false }
            guard let tag = languageTag(for: opt)?.lowercased() else { return false }
            return tag == preferredLanguage || tag.hasPrefix(preferredLanguage + "-")
        }) {
            return full
        }

        // Fallback: existing index-based lookup (may land on forced if that's all there is)
        let tags = candidates.map { languageTag(for: $0) }
        let idx = SubtitleSelectionLogic.preferredTrackIndex(tags: tags, preferredLowercased: preferredLanguage)
        return candidates[idx]
    }

    // MARK: - Shared playback

    /// Stops the previous transcode session immediately (don't wait on the server's idle
    /// timeout) so sessions don't pile up while channel-surfing. Fire-and-forget, off-MainActor.
    func stopActiveTranscodeIfNeeded() {
        guard let active = activeTranscode else { return }
        activeTranscode = nil
        let backend = api(for: active.serverID)
        let psid = active.playSessionId
        Task.detached { await backend.stopTranscode(playSessionId: psid) }
    }

    // MARK: - Sleep timer

    /// Arms the sleep timer for `minutes`. `minutes <= 0` cancels. Survives channel changes.
    func startSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        sleepGraceTimer?.invalidate()
        sleepGracePromptActive = false
        // Log both arm and cancel through the same generic settings channel; the
        // value (`0` for OFF, minutes for anything else) reads on the dashboard
        // without needing a second event.
        Analytics.track(.settingChanged(key: "sleep_timer_minutes", value: String(max(minutes, 0))))
        guard minutes > 0 else {
            sleepTimerEndDate = nil
            sleepTimerMinutes = nil
            return
        }
        let interval = TimeInterval(minutes * 60)
        sleepTimerEndDate = Date().addingTimeInterval(interval)
        sleepTimerMinutes = minutes
        sleepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.beginSleepGrace() }
        }
    }

    /// Cancels the sleep timer and dismisses any grace prompt.
    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepGraceTimer?.invalidate()
        sleepGraceTimer = nil
        sleepTimerEndDate = nil
        sleepTimerMinutes = nil
        sleepGracePromptActive = false
    }

    /// User responded to the "Still watching?" prompt — keep playing, consume the timer.
    func keepAwakeFromGrace() {
        sleepGraceTimer?.invalidate()
        sleepGraceTimer = nil
        sleepGracePromptActive = false
        sleepTimerEndDate = nil
        sleepTimerMinutes = nil
    }

    /// Timer reached zero: show the grace prompt, then stop playback if it's ignored.
    private func beginSleepGrace() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepGracePromptActive = true
        sleepGraceTimer?.invalidate()
        sleepGraceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.expireSleepTimer() }
        }
    }

    /// Lightweight stop: pause the stream, drop the transcode, return to the guide.
    /// Deliberately NOT `disconnect()` — that would drop server credentials.
    private func expireSleepTimer() {
        emitPlaybackStoppedForActiveSession()
        player?.pause()
        stopActiveTranscodeIfNeeded()
        cancelSleepTimer()
        isFullScreen = false
    }

    /// Re-checks the sleep timer on foreground — a backgrounded `Timer` may not have fired.
    func revalidateSleepTimerOnForeground() {
        guard sleepTimerEndDate != nil, !sleepGracePromptActive else { return }
        if SleepTimerLogic.isExpired(endDate: sleepTimerEndDate, now: Date()) {
            beginSleepGrace()
        }
    }

    /// Shows the reason on screen, then advances so a single bad item never strands a channel.
    ///
    /// Every failure path funnels through here, including the ones that used to advance in
    /// silence (the startup watchdog, the starvation verdict, and an AVPlayer item that
    /// reached `.failed`). A silent skip reads as a broken app and hides whether the person
    /// should go and look at their server or at the file.
    ///
    /// Five seconds, not the old two and a half: the card now carries a sentence worth
    /// reading, and this is the only place the reason is ever shown.
    private func showErrorThenSkip(_ failure: PlaybackFailure, generation: Int, title: String? = nil,
                                   detail: String? = nil) {
        playbackState = .error(failure)
        emitPlaybackError(failure.analyticsCode)
        PlaybackDiagnostics.record(
            outcome: failure.diagnosticSummary,
            title: title ?? currentItem?.title ?? "?",
            detail: detail ?? failure.headline
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.loadGeneration == generation else { return }
            self.advanceToNextItem()
        }
    }

    /// Ends a load early when the server has already said no.
    ///
    /// The startup watchdog gives a 4K source forty seconds to produce a picture, which is
    /// right for a transcoder spinning up and wrong for a server that refused the job in a
    /// tenth of a second. The viewer should not watch static for forty seconds to be told
    /// something the server said immediately.
    ///
    /// Probing the URL handed to the player is not enough: that is the master playlist, and
    /// it answers 200 while the segments beneath it fail. The failing request is named in
    /// the player's own error log, so this takes the most recent logged URI and asks about
    /// that. Returns true when it has taken over and shown the card.
    ///
    /// Only a 4xx or 5xx ends the load. A timeout, a refused connection or a slow answer
    /// all leave the watchdog to run its full deadline, because those are the shapes a
    /// healthy-but-slow transcode start also has.
    private func failFastOnServerRefusal(playerItem: AVPlayerItem, item: PlexMediaItem?,
                                         generation: Int) async -> Bool {
        guard playbackState != .playing,
              let events = playerItem.errorLog()?.events, !events.isEmpty,
              let failing = events.reversed().compactMap({ $0.uri }).first,
              let url = URL(string: failing) else { return false }
        let headers = item.map { api(for: $0.serverID).authHeaders } ?? [:]
        guard let status = await StreamFailureProbe.status(of: url, headers: headers),
              StreamFailureProbe.isRefusal(status),
              loadGeneration == generation else { return false }
        print("[Plex90] gen=\(generation) | FAIL FAST: \(url.host ?? "?") answered HTTP \(status) for \(url.lastPathComponent); not waiting out the deadline")
        let failure = PlaybackFailure.classify(
            backend: backendKind,
            evidence: { var e = PlaybackFailure.Evidence(); e.httpStatuses = [status]; return e }()
        )
        showErrorThenSkip(failure, generation: generation, title: item?.title ?? "?",
                          detail: "server refused \(url.lastPathComponent) with HTTP \(status) before any picture")
        return true
    }

    /// Reads back what the player actually saw, so the message on screen is evidence and
    /// not a guess.
    ///
    /// `AVPlayerItemErrorLogEvent.httpStatusCode` is the load-bearing field and nothing
    /// used to read it: it is how the app can say "your server answered HTTP 500" instead
    /// of "playback error". It is -1 on events that were not HTTP failures, which is why
    /// the filter is here rather than at the point of use.
    private func failureEvidence(for playerItem: AVPlayerItem?,
                                 starvedAfterCappedRetry: Bool = false,
                                 hadPicture: Bool = false,
                                 item: PlexMediaItem? = nil) -> PlaybackFailure.Evidence {
        var e = PlaybackFailure.Evidence()
        e.starvedAfterCappedRetry = starvedAfterCappedRetry
        e.everShowedPicture = hadPicture
        e.sourceCodec = item?.videoCodec
        if let events = playerItem?.errorLog()?.events {
            e.coreMediaStatuses = events.map(\.errorStatusCode).filter { $0 != 0 }
            // tvOS has no httpStatusCode on an error-log event, but AVFoundation often
            // writes the status into the free-text comment ("... 500 ..."). Worth reading,
            // never trusted on its own: `StreamFailureProbe` is what actually settles it.
            e.httpStatuses = events.compactMap { Self.httpStatus(inComment: $0.errorComment) }
        }
        if let ns = playerItem?.error as NSError?, ns.domain == NSURLErrorDomain {
            e.urlErrorCode = ns.code
        }
        return e
    }

    /// A three-digit HTTP status mentioned in an error-log comment, if there is one.
    private static func httpStatus(inComment comment: String?) -> Int? {
        guard let comment, let range = comment.range(of: #"\b[45]\d{2}\b"#, options: .regularExpression)
        else { return nil }
        return Int(comment[range])
    }

    /// Classify what just went wrong, asking the server when the player's own signals do
    /// not already name a cause. The probe is one ranged GET on the URL that just failed.
    private func classifyFailure(for playerItem: AVPlayerItem?, item: PlexMediaItem?,
                                 starvedAfterCappedRetry: Bool = false,
                                 hadPicture: Bool = false) async -> PlaybackFailure {
        var evidence = failureEvidence(for: playerItem,
                                       starvedAfterCappedRetry: starvedAfterCappedRetry,
                                       hadPicture: hadPicture, item: item)
        // Starvation is already decided; asking the server would only slow the card down.
        if !starvedAfterCappedRetry, evidence.httpStatuses.isEmpty, let url = lastStreamURL {
            let headers = item.map { api(for: $0.serverID).authHeaders } ?? [:]
            if let status = await StreamFailureProbe.status(of: url, headers: headers),
               StreamFailureProbe.isRefusal(status) {
                print("[Plex90] FAILURE PROBE: \(url.host ?? "?") answered HTTP \(status) for the failed stream")
                evidence.httpStatuses.append(status)
            }
        }
        return PlaybackFailure.classify(backend: backendKind, evidence: evidence)
    }

    /// Convenience for firing `playback.error` from any playback path. No-op when there
    /// is no active channel (which is the only case where an error signal wouldn't have
    /// a channel number to send).
    private func emitPlaybackError(_ code: AnalyticsPlaybackErrorCode) {
        guard let channel = currentChannel else { return }
        Analytics.track(.playbackError(
            channelNumber: channel.number,
            backend: analyticsBackend,
            code: code
        ))
    }

    /// Fire `playback.ready` once per session and record delivery mode for the later
    /// `playback.stopped` signal. Every readyToPlay path in loadCurrentItem/retry/
    /// fallback funnels through here.
    fileprivate func reportPlaybackReadyIfNeeded(delivery: AnalyticsPlaybackDelivery) {
        currentPlaybackDelivery = delivery
        guard !playbackReadyReported, let channel = currentChannel else { return }
        playbackReadyReported = true
        Analytics.track(.playbackReady(
            channelNumber: channel.number,
            backend: analyticsBackend,
            delivery: delivery,
            channel: AnalyticsChannelDescriptor.describe(channel)
        ))
    }

    func loadCurrentItem() {
        // Clear the previous item's audio-track list so a new/uni-track program never
        // shows stale tracks; applyAudioTrackSelection republishes when the group loads.
        audioTracks = []
        selectedAudioTrackID = nil
        audibleGroup = nil
        audibleGroupItem = nil
        hasSubtitleTracks = false

        // Flush accumulated watch time for the outgoing session before creating a new
        // tracker. This is where per-item watch time analytics is emitted: the previous
        // channel+delivery is still current at this point.
        emitPlaybackStoppedForActiveSession()

        // Session state resets — the new item gets a fresh delivery and a fresh ready
        // signal. Both are set inside the readyToPlay branches below.
        currentPlaybackDelivery = nil
        playbackReadyReported = false

        // Stop the previous tracker before anything else so its scrobble fires cleanly.
        let outgoing = playbackTracker
        playbackTracker = nil
        outgoing?.stop()

        // Invalidate everything from previous load
        loadDebounceTimer?.invalidate()
        cancellables.removeAll()
        loadGeneration += 1
        let generation = loadGeneration
        // Free any prior transcode before starting the next one (covers selectChannel /
        // next/previousChannel / advanceToNextItem — they all funnel through here).
        stopActiveTranscodeIfNeeded()

        guard let item = currentItem else {
            print("[Plex90] gen=\(generation) | No item, going idle")
            playbackState = .idle
            return
        }

        // Create a fresh tracker for this item. Reporting stays off unless the user
        // turned it on: Plex gets timeline + scrobble, Jellyfin and Emby get the same
        // watch counted on their server. Either way the tracker still accumulates time.
        let reportingOn = !isDemoMode && syncPlexActivity
        let reportingBackend: (any MediaBackend)? = reportingOn ? api(for: item.serverID) : nil
        playbackTracker = PlaybackTracker(
            item: item,
            seekOffset: seekOffset,
            plexAPI: reportingBackend as? PlexAPIService,
            watchReporter: reportingBackend as? any WatchActivityReporting
        )

        // Show the retro "tuning" loading state while we resolve + start playback. The
        // overlay itself only appears after a ~0.75s threshold (view-side), so fast starts
        // don't flash it. readyToPlay flips this to .playing.
        playbackState = .loading

        // Demo mode: every channel plays Apple's canonical HLS sample stream (bipbop).
        // Hosted on Apple's own devstreaming-cdn, so it's reachable from Apple's review
        // network and doesn't require a Plex auth header.
        let demoStreamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")

        // Synchronous decisions. Direct play resolves now; the transcode branch resolves
        // asynchronously inside the Task below (Jellyfin PlaybackInfo handshake).
        let itemAPI: (any MediaBackend)? = isDemoMode ? nil : api(for: item.serverID)
        let directPlayHeaders = itemAPI?.authHeaders ?? [:]
        let directURL = itemAPI?.buildDirectPlayURL(for: item)
        // Fallback for direct play failing at runtime. Built with its own session id so the
        // stop on the next channel change ends this transcode and no other.
        let fallbackSession = UUID().uuidString
        let fallbackStartsAtOffset = itemAPI is PlexAPIService && seekOffset > 0
        let transcodeURL: URL? = (itemAPI as? PlexAPIService)?.transcodeURL(for: item, sessionID: fallbackSession, offsetSeconds: seekOffset)
            ?? itemAPI?.buildTranscodeURL(for: item)

        if !isDemoMode && directURL == nil && transcodeURL == nil {
            print("[Plex90] gen=\(generation) | No URL available")
            showErrorThenSkip(.noPlayableSource(server: backendKind.displayName), generation: generation)
            return
        }

        let title = item.title
        let chName = currentChannel?.name ?? "?"
        let codec = "\(item.videoCodec ?? "?"):\(item.audioCodec ?? "?") (\(item.container ?? "?"))"
        let hdr = item.videoProfile?.lowercased().contains("10") == true ? " HDR" : ""
        let initialDirect = directURL != nil
        print("[Plex90] gen=\(generation) | LOAD: \"\(title)\" on CH \(chName) | \(codec)\(hdr) | seekOffset=\(seekOffset) | direct=\(initialDirect)")

        // Pause immediately to stop old content
        player?.pause()

        // Tear down old item before creating new one
        player?.replaceCurrentItem(with: nil)

        // Small delay to let AVPlayer clean up the old item
        var seekTo = seekOffset > 0 ? seekOffset : nil
        hlsRequestedOffset = 0
        hlsBaseOffset = 0
        let itemServerID = item.serverID
        loadDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else {
                    print("[Plex90] gen=\(generation) | STALE: debounce fired but generation changed")
                    return
                }

                // Resolve the final playback URL.
                let resolvedURL: URL
                let isDirectPlay: Bool
                if isDemoMode, let demo = demoStreamURL {
                    resolvedURL = demo; isDirectPlay = false
                } else if let directURL {
                    resolvedURL = directURL; isDirectPlay = true
                } else {
                    // Transcode branch: ask the backend how to play it (Jellyfin = PlaybackInfo,
                    // others = hand-built URL). This is the only await in the load path.
                    guard let api = itemAPI else {
                        self.showErrorThenSkip(.noPlayableSource(server: backendKind.displayName), generation: generation)
                        return
                    }
                    let resolved = await api.resolveTranscodePlayback(for: item, offsetSeconds: self.seekOffset)
                    let resolution = resolved?.resolution
                    if resolved?.startsAtOffset == true {
                        self.hlsRequestedOffset = self.seekOffset
                        seekTo = nil
                    }
                    guard self.loadGeneration == generation else {
                        // A channel-flip superseded us mid-handshake. PlaybackInfo just opened a
                        // server-side transcode session that the superseding load couldn't see
                        // (activeTranscode was still nil) — stop it here so it doesn't orphan.
                        if let psid = resolution?.playSessionId {
                            Task.detached { await api.stopTranscode(playSessionId: psid) }
                        }
                        return
                    }
                    guard let resolution else {
                        print("[Plex90] gen=\(generation) | No playable source after PlaybackInfo")
                        self.showErrorThenSkip(.transcodingUnavailable(server: backendKind.displayName), generation: generation)
                        return
                    }
                    resolvedURL = resolution.url
                    isDirectPlay = resolution.isDirectPlay
                    self.activeTranscode = (itemServerID, resolution.playSessionId)
                }

                print("[Plex90] gen=\(generation) | Creating AVPlayerItem for \"\(title)\" (direct=\(isDirectPlay))")
                // Direct play: use AVURLAsset with auth headers (token not in URL)
                // Transcode: token stays in URL query params (HLS segments inherit it)
                let playerItem: AVPlayerItem
                if isDirectPlay {
                    let asset = AVURLAsset(url: resolvedURL, options: [
                        "AVURLAssetHTTPHeaderFieldsKey": directPlayHeaders
                    ])
                    playerItem = AVPlayerItem(asset: asset)
                } else {
                    playerItem = AVPlayerItem(url: resolvedURL)
                }
                self.lastStreamURL = resolvedURL
                playerItem.preferredForwardBufferDuration = 5

                self.installFreshPlayer(with: playerItem, generation: generation)

                // Status observer
                playerItem.publisher(for: \.status)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] status in
                        guard let self, self.loadGeneration == generation else {
                            print("[Plex90] gen=\(generation) | STALE: status callback ignored")
                            return
                        }
                        switch status {
                        case .readyToPlay:
                            print("[Plex90] gen=\(generation) | READY: \"\(title)\"")
                            // First readyToPlay in this session wins: record delivery and
                            // emit the analytics ready signal. Retry / transcode-fallback
                            // paths re-enter readyToPlay for the same channel; they'd
                            // otherwise double-count.
                            self.reportPlaybackReadyIfNeeded(delivery: isDirectPlay ? .directPlay : .transcode)
                            if let seekTo, seekTo > 0 {
                                print("[Plex90] gen=\(generation) | Seeking to \(seekTo)s")
                                let target = CMTime(seconds: Double(seekTo), preferredTimescale: 600)
                                self.player?.seek(to: target) { finished in
                                    Task { @MainActor [weak self] in
                                        guard let self, self.loadGeneration == generation else { return }
                                        print("[Plex90] gen=\(generation) | Seek done (finished=\(finished)), playing")
                                        self.playbackState = .playing
                                        self.player?.play()
                                        self.applySubtitleSelection(loadGenerationToken: generation)
                                        self.applyAudioTrackSelection(loadGenerationToken: generation)
                                        self.playbackTracker?.onPlaybackReady()
                                    }
                                }
                            } else {
                                print("[Plex90] gen=\(generation) | No seek needed, playing")
                                self.noteHLSTimelineStart(playerItem, generation: generation)
                                self.playbackState = .playing
                                self.player?.play()
                                self.applySubtitleSelection(loadGenerationToken: generation)
                                self.applyAudioTrackSelection(loadGenerationToken: generation)
                                self.playbackTracker?.onPlaybackReady()
                            }
                        case .failed:
                            guard self.loadGeneration == generation else { return }
                            let errMsg = playerItem.error?.localizedDescription ?? "Unknown error"
                            print("[Plex90] gen=\(generation) | FAILED: \"\(title)\" - \(errMsg)")
                            // If direct play failed and we have a transcode URL, fall back
                            if isDirectPlay, let fallback = transcodeURL {
                                print("[Plex90] gen=\(generation) | Direct play failed, falling back to transcode")
                                if itemAPI is PlexAPIService { self.activeTranscode = (itemServerID, fallbackSession) }
                                if fallbackStartsAtOffset { self.hlsRequestedOffset = self.seekOffset }
                                self.fallbackToTranscode(url: fallback, seekTo: fallbackStartsAtOffset ? nil : seekTo, generation: generation)
                            } else {
                                // Already transcode or no fallback — retry once. A URL that
                                // carries the offset must not be seeked again on the client.
                                self.retryLoad(url: resolvedURL, seekTo: self.hlsRequestedOffset > 0 ? nil : seekTo, generation: generation, isDirectPlay: isDirectPlay)
                            }
                        default:
                            break
                        }
                    }
                    .store(in: &self.cancellables)

                // Auto-advance when content finishes (or play next disc for multi-part movies)
                NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        guard let self, self.loadGeneration == generation else { return }
                        print("[Plex90] gen=\(generation) | END OF ITEM: \"\(title)\" - checking for next part")
                        self.handlePartEnded()
                    }
                    .store(in: &self.cancellables)

                self.installEndOfItemFallback(for: playerItem, generation: generation, title: title)

                // Playback watchdog. Symptom we're handling: on first-channel auto-play
                // at launch, occasionally the readyToPlay observer fires but the player
                // doesn't actually start (rate stays 0), or the first scheduled item is
                // unplayable (bad codec / no audio track / corrupt file) and the user
                // sees a static black screen until they manually channel-up.
                // After 4s: nudge play() once. Then give it up to the skip deadline before
                // advancing — direct play should start fast (7s), but a transcode must spin
                // up ffmpeg from a mid-content offset, so it gets a much longer leash (20s).
                // The .loading "tuning" overlay covers the wait visually.
                // rate==0 alone misses one real failure mode: `automaticallyWaitsToMinimizeStalling`
                // combined with Plex's HLS transcode manifest (a rolling playlist while segments
                // are still being generated, not a plain VOD file) can leave AVPlayer reporting
                // rate==1 — "playing" — while playbackBufferEmpty stays true and nothing ever
                // decodes: a black screen the rate check alone cannot see. Good Burger (1997)
                // reproduced this: full-screen black past the deadline with no recovery, because
                // the watchdog only ever asked about rate.
                self.installWatchdog(for: playerItem, item: item, isDirectPlay: isDirectPlay, generation: generation, allowCappedRetry: true)
                self.installStarvationMonitor(for: playerItem, item: item, isDirectPlay: isDirectPlay, generation: generation, allowCappedRetry: true)
            }
        }
    }

    private func retryLoad(url: URL, seekTo: Int?, generation: Int, isDirectPlay: Bool = false) {
        guard loadGeneration == generation else { return }
        let title = currentItem?.title ?? "Unknown"
        print("[Plex90] gen=\(generation) | RETRY: \"\(title)\" - waiting 300ms")
        cancellables.removeAll()
        player?.replaceCurrentItem(with: nil)

        // Wait briefly then try once more
        loadDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else {
                    print("[Plex90] gen=\(generation) | STALE: retry fired but generation changed")
                    return
                }

                print("[Plex90] gen=\(generation) | RETRY: creating new AVPlayerItem for \"\(title)\"")
                let playerItem = AVPlayerItem(url: url)
                self.lastStreamURL = url
                playerItem.preferredForwardBufferDuration = 5
                self.installFreshPlayer(with: playerItem, generation: generation)

                playerItem.publisher(for: \.status)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] status in
                        guard let self, self.loadGeneration == generation else { return }
                        switch status {
                        case .readyToPlay:
                            print("[Plex90] gen=\(generation) | RETRY READY: \"\(title)\"")
                            // Retry re-uses whatever delivery the session already had.
                            self.reportPlaybackReadyIfNeeded(delivery: self.currentPlaybackDelivery ?? .transcode)
                            if let seekTo, seekTo > 0 {
                                let target = CMTime(seconds: Double(seekTo), preferredTimescale: 600)
                                self.player?.seek(to: target) { _ in
                                    Task { @MainActor [weak self] in
                                        guard let self, self.loadGeneration == generation else { return }
                                        print("[Plex90] gen=\(generation) | RETRY seek done, playing")
                                        self.playbackState = .playing
                                        self.player?.play()
                                        self.applySubtitleSelection(loadGenerationToken: generation)
                                        self.playbackTracker?.onPlaybackReady()
                                    }
                                }
                            } else {
                                print("[Plex90] gen=\(generation) | RETRY no seek, playing")
                                self.noteHLSTimelineStart(playerItem, generation: generation)
                                self.playbackState = .playing
                                self.player?.play()
                                self.applySubtitleSelection(loadGenerationToken: generation)
                                self.playbackTracker?.onPlaybackReady()
                            }
                        case .failed:
                            guard self.loadGeneration == generation else { return }
                            let msg = playerItem.error?.localizedDescription ?? "Unknown error"
                            print("[Plex90] gen=\(generation) | RETRY FAILED: \"\(title)\" - \(msg)")
                            self.emitPlaybackError(.playerFailed)
                            self.autoSkipOnError(generation: generation, playerItem: playerItem)
                        default:
                            break
                        }
                    }
                    .store(in: &self.cancellables)

                NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        guard let self, self.loadGeneration == generation else { return }
                        print("[Plex90] gen=\(generation) | RETRY END OF ITEM: \"\(title)\" - checking for next part")
                        self.handlePartEnded()
                    }
                    .store(in: &self.cancellables)

                self.installEndOfItemFallback(for: playerItem, generation: generation, title: title)
                self.installWatchdog(for: playerItem, item: self.currentItem, isDirectPlay: isDirectPlay, generation: generation, allowCappedRetry: !isDirectPlay)
                self.installStarvationMonitor(for: playerItem, item: self.currentItem, isDirectPlay: isDirectPlay, generation: generation, allowCappedRetry: !isDirectPlay)
            }
        }
    }

    private func fallbackToTranscode(url: URL, seekTo: Int?, generation: Int, allowCappedRetry: Bool = true, prepared: Bool = false) {
        guard loadGeneration == generation else { return }
        let title = currentItem?.title ?? "Unknown"
        print("[Plex90] gen=\(generation) | TRANSCODE FALLBACK: \"\(title)\"")
        // Analytics: direct play failed and we're moving to the server-side transcoder.
        if let channel = currentChannel {
            Analytics.track(.playbackTranscodeFallback(
                channelNumber: channel.number,
                backend: analyticsBackend
            ))
        }
        cancellables.removeAll()
        player?.replaceCurrentItem(with: nil)

        loadDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }

                if !prepared, let serverID = self.currentItem?.serverID {
                    await self.api(for: serverID).prepareTranscodeSession(startURL: url)
                    guard self.loadGeneration == generation else { return }
                }
                print("[Plex90] gen=\(generation) | TRANSCODE: creating AVPlayerItem for \"\(title)\"")
                let playerItem = AVPlayerItem(url: url)
                self.lastStreamURL = url
                playerItem.preferredForwardBufferDuration = 5
                self.installFreshPlayer(with: playerItem, generation: generation)

                playerItem.publisher(for: \.status)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] status in
                        guard let self, self.loadGeneration == generation else { return }
                        switch status {
                        case .readyToPlay:
                            print("[Plex90] gen=\(generation) | TRANSCODE READY: \"\(title)\"")
                            // Fallback path is by definition a transcode delivery.
                            self.reportPlaybackReadyIfNeeded(delivery: .transcode)
                            if let seekTo, seekTo > 0 {
                                let target = CMTime(seconds: Double(seekTo), preferredTimescale: 600)
                                self.player?.seek(to: target) { _ in
                                    Task { @MainActor [weak self] in
                                        guard let self, self.loadGeneration == generation else { return }
                                        self.playbackState = .playing
                                        self.player?.play()
                                        self.applySubtitleSelection(loadGenerationToken: generation)
                                        self.playbackTracker?.onPlaybackReady()
                                    }
                                }
                            } else {
                                self.noteHLSTimelineStart(playerItem, generation: generation)
                                self.playbackState = .playing
                                self.player?.play()
                                self.applySubtitleSelection(loadGenerationToken: generation)
                                self.playbackTracker?.onPlaybackReady()
                            }
                        case .failed:
                            guard self.loadGeneration == generation else { return }
                            let msg = playerItem.error?.localizedDescription ?? "Unknown error"
                            print("[Plex90] gen=\(generation) | TRANSCODE FAILED: \"\(title)\" - \(msg)")
                            self.emitPlaybackError(.playerFailed)
                            self.autoSkipOnError(generation: generation, playerItem: playerItem)
                        default:
                            break
                        }
                    }
                    .store(in: &self.cancellables)

                NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        guard let self, self.loadGeneration == generation else { return }
                        self.handlePartEnded()
                    }
                    .store(in: &self.cancellables)

                self.installEndOfItemFallback(for: playerItem, generation: generation, title: title)
                self.installWatchdog(for: playerItem, item: self.currentItem, isDirectPlay: false, generation: generation, allowCappedRetry: allowCappedRetry)
                self.installStarvationMonitor(for: playerItem, item: self.currentItem, isDirectPlay: false, generation: generation, allowCappedRetry: allowCappedRetry)
            }
        }
    }

    // MARK: - Auto-skip on error

    /// Gives a load a bounded time to show picture, then either retries once with the video
    /// forced to 1080p (an HLS copy the device could not decode) or advances.
    private func installWatchdog(for playerItem: AVPlayerItem, item: PlexMediaItem?, isDirectPlay: Bool, generation: Int, allowCappedRetry: Bool) {
        let deadline = PlaybackWatchdog.deadlineSeconds(
            isDirectPlay: isDirectPlay, videoWidth: item?.videoWidth, videoHeight: item?.videoHeight)
        // Ask for decoded frames, not a declared size: a 4K H.264 copy reported 3840x2160
        // while never producing a single picture.
        let probe = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        playerItem.add(probe)
        videoFrameProbe = probe
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.loadGeneration == generation else { return }
            if self.player?.rate == 0, playerItem.status != .failed {
                print("[Plex90] gen=\(generation) | WATCHDOG: 4s in, not playing yet (state=\(self.playbackState)) — nudging play()")
                self.player?.play()
            }
            // A server that has already refused the stream should not cost the viewer the
            // whole deadline, which is 40s for a 4K source. If the player has logged a
            // failed request by now and nothing has decoded, ask that exact URL what it
            // answers. A refusal is final: no amount of waiting turns a 500 into a picture.
            if await self.failFastOnServerRefusal(playerItem: playerItem, item: item, generation: generation) {
                return
            }
            let window = PlaybackWatchdog.progressWindowSeconds
            try? await Task.sleep(for: .seconds(max(1, deadline - 4 - window)))
            guard self.loadGeneration == generation else { return }
            let sampleA = playerItem.currentTime().seconds
            try? await Task.sleep(for: .seconds(window))
            guard self.loadGeneration == generation else { return }
            let sampleB = playerItem.currentTime().seconds
            let progressed = sampleB - sampleA
            let reachedReady = self.playbackState == .playing || playerItem.status == .readyToPlay
            let frames = probe.hasNewPixelBuffer(forItemTime: playerItem.currentTime())
            guard !PlaybackWatchdog.hasPicture(reachedReady: reachedReady, progressedSeconds: progressed, decodedFrame: frames) else { return }
            let access = playerItem.accessLog()?.events.last.map { "segments=\($0.numberOfMediaRequests) stalls=\($0.numberOfStalls) bytes=\($0.numberOfBytesTransferred) dropped=\($0.numberOfDroppedVideoFrames) watched=\(String(format: "%.1f", $0.durationWatched))s" } ?? "no access log"
            let errors = playerItem.errorLog()?.events.suffix(3).map { "\($0.errorStatusCode) \($0.errorComment ?? "") \(($0.uri ?? "").suffix(48))" }.joined(separator: " | ") ?? ""
            let detail = "ready=\(reachedReady), playhead moved \(String(format: "%.1f", progressed))s, frames=\(frames), declared \(Int(playerItem.presentationSize.width))x\(Int(playerItem.presentationSize.height)), rate=\(self.player?.rate ?? -1), status=\(playerItem.status.rawValue), \(access)\(errors.isEmpty ? "" : ", errors: " + errors)"
            if isDirectPlay, let item {
                // Audio with a black picture is the signature of a file AVPlayer opened but
                // cannot render: an HEVC MP4 tagged hev1, an exotic profile, a broken index.
                // The server stream is the answer, and it gets its own capped retry after.
                print("[Plex90] gen=\(generation) | WATCHDOG: \(deadline)s deadline, direct play gave no picture (\(detail)) — switching to the server stream")
                PlaybackDiagnostics.record(outcome: "direct play → server stream after \(deadline)s", title: item.title, detail: detail)
                if let channel = self.currentChannel {
                    Analytics.track(.playbackTranscodeFallback(channelNumber: channel.number, backend: self.analyticsBackend))
                }
                let backend = self.api(for: item.serverID)
                let offset = self.seekOffset
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    guard let resolved = await backend.resolveTranscodePlayback(for: item, offsetSeconds: offset),
                          self.loadGeneration == generation else {
                        if self.loadGeneration == generation {
                            self.emitPlaybackError(.watchdogSkip)
                            self.advanceToNextItem()
                        }
                        return
                    }
                    self.activeTranscode = (item.serverID, resolved.resolution.playSessionId)
                    self.hlsRequestedOffset = resolved.startsAtOffset ? offset : 0
                    self.fallbackToTranscode(url: resolved.resolution.url, seekTo: resolved.startsAtOffset ? nil : offset,
                                             generation: generation, allowCappedRetry: true, prepared: true)
                }
                return
            }
            if allowCappedRetry, !isDirectPlay, let item,
               let backend = Optional(self.api(for: item.serverID)),
               let capped = backend.cappedTranscodeURL(for: item, offsetSeconds: self.seekOffset, sessionID: UUID().uuidString) {
                print("[Plex90] gen=\(generation) | WATCHDOG: \(deadline)s deadline, no picture (\(detail)) — retrying once with video capped at 1080p")
                PlaybackDiagnostics.record(outcome: "retry capped at 1080p after \(deadline)s", title: item.title, detail: detail)
                self.stopActiveTranscodeIfNeeded()
                let query = URLComponents(url: capped, resolvingAgainstBaseURL: false)?.queryItems
                let session = query?.first { $0.name == "session" || $0.name == "PlaySessionId" }?.value
                self.activeTranscode = (item.serverID, session)
                // Same split as the starvation ladder: Plex builds the offset into the
                // capped request, Jellyfin and Emby reject a start time on segment
                // requests so their capped stream begins at zero and we seek.
                let startsAtOffset = backend.cappedStreamStartsAtOffset
                self.hlsRequestedOffset = startsAtOffset ? self.seekOffset : 0
                self.fallbackToTranscode(url: capped, seekTo: startsAtOffset ? nil : self.seekOffset,
                                         generation: generation, allowCappedRetry: false)
                return
            }
            print("[Plex90] gen=\(generation) | WATCHDOG: \(deadline)s deadline, no picture (\(detail)) — advancing to next item")
            // The error log is read here for the first time to say *why*. A segment that
            // came back 500 is the server's problem and the card now says so.
            let failure = await self.classifyFailure(for: playerItem, item: item, hadPicture: false)
            guard self.loadGeneration == generation else { return }
            self.showErrorThenSkip(failure, generation: generation,
                                   title: item?.title ?? "?", detail: detail)
        }
    }

    /// Watches a stream that reached picture for a source that cannot keep up: the playhead
    /// stops while the player is not paused. The startup watchdog cannot see this (it
    /// judges once, at the deadline) and the end-of-item fallback only acts in the tail.
    /// Policy in `PlaybackStarvation`. Measured 2026-10-06: a 4K 60fps HEVC file transcoded
    /// at 0.72x real time and froze for good; capped to 1080p the same file ran at 1.8x.
    /// So the ladder resumes the *same* item from the current position one rung down,
    /// and only skips when the capped stream starves too.
    private func installStarvationMonitor(for playerItem: AVPlayerItem, item: PlexMediaItem?, isDirectPlay: Bool, generation: Int, allowCappedRetry: Bool) {
        var monitor = PlaybackStarvation()
        let title = item?.title ?? currentItem?.title ?? "Unknown"
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.loadGeneration == generation, let player = self.player,
                      player.currentItem === playerItem else { return }
                guard case .playing = self.playbackState else { return }
                let paused = player.timeControlStatus == .paused
                let duration = playerItem.duration
                // Same clock on both sides, so it holds whether the server rebased the HLS
                // timeline to zero or kept source timestamps.
                let remaining: Double? = duration.isNumeric ? duration.seconds - playerItem.currentTime().seconds : nil
                guard let verdict = monitor.observe(playhead: playerItem.currentTime().seconds, wall: Date().timeIntervalSinceReferenceDate,
                                                    paused: paused, remaining: remaining) else { return }
                guard case .starving(let stalls, let longest) = verdict else { return }
                let position = max(0, Int(player.currentTime().seconds + self.hlsBaseOffset))
                let access = playerItem.accessLog()?.events.last.map {
                    "segments=\($0.numberOfMediaRequests) stalls=\($0.numberOfStalls) observedKbps=\(Int($0.observedBitrate / 1000)) indicatedKbps=\(Int($0.indicatedBitrate / 1000)) watched=\(String(format: "%.0f", $0.durationWatched))s"
                } ?? "no access log"
                let detail = "stalls=\(stalls) longest=\(String(format: "%.0f", longest))s at \(position)s, timeControl=\(player.timeControlStatus.rawValue), \(access)"
                self.handleStarvation(item: item, isDirectPlay: isDirectPlay, generation: generation,
                                      allowCappedRetry: allowCappedRetry, position: position, title: title, detail: detail)
            }
            .store(in: &cancellables)
    }

    private func handleStarvation(item: PlexMediaItem?, isDirectPlay: Bool, generation: Int, allowCappedRetry: Bool,
                                  position: Int, title: String, detail: String) {
        guard loadGeneration == generation else { return }
        if isDirectPlay, let item {
            // The file itself cannot reach the device fast enough (remote server, weak wifi).
            // The server stream adapts; resume it where we are.
            print("[Plex90] gen=\(generation) | STARVED: \"\(title)\" on direct play (\(detail)) — switching to the server stream at \(position)s")
            PlaybackDiagnostics.record(outcome: "starved on direct play → server stream from \(position)s", title: title, detail: detail)
            let backend = api(for: item.serverID)
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                guard let resolved = await backend.resolveTranscodePlayback(for: item, offsetSeconds: position),
                      self.loadGeneration == generation else {
                    if self.loadGeneration == generation { self.advanceToNextItem() }
                    return
                }
                self.seekOffset = position
                self.activeTranscode = (item.serverID, resolved.resolution.playSessionId)
                self.hlsRequestedOffset = resolved.startsAtOffset ? position : 0
                self.fallbackToTranscode(url: resolved.resolution.url, seekTo: resolved.startsAtOffset ? nil : position,
                                         generation: generation, allowCappedRetry: true, prepared: true)
            }
            return
        }
        if allowCappedRetry, let item,
           let capped = api(for: item.serverID).cappedTranscodeURL(for: item, offsetSeconds: position, sessionID: UUID().uuidString) {
            // Plex builds the offset into the capped request; Jellyfin and Emby reject a
            // start time on segment requests, so their capped stream begins at zero and we
            // seek, exactly as the first attempt does.
            let startsAtOffset = api(for: item.serverID).cappedStreamStartsAtOffset
            print("[Plex90] gen=\(generation) | STARVED: \"\(title)\" (\(detail)) — resuming at \(position)s with video capped at 1080p (\(startsAtOffset ? "server offset" : "client seek"))")
            PlaybackDiagnostics.record(outcome: "starved → capped 1080p from \(position)s", title: title, detail: detail)
            stopActiveTranscodeIfNeeded()
            let query = URLComponents(url: capped, resolvingAgainstBaseURL: false)?.queryItems
            let session = query?.first { $0.name == "session" || $0.name == "PlaySessionId" }?.value
            activeTranscode = (item.serverID, session)
            seekOffset = position
            hlsRequestedOffset = startsAtOffset ? position : 0
            fallbackToTranscode(url: capped, seekTo: startsAtOffset ? nil : position,
                                generation: generation, allowCappedRetry: false)
            return
        }
        print("[Plex90] gen=\(generation) | STARVED: \"\(title)\" (\(detail)) — nothing smaller to ask for, advancing to next item")
        // The server answered correctly and still could not be watched, which is a
        // different sentence from "your server refused it".
        showErrorThenSkip(.serverTooSlow(server: backendKind.displayName),
                          generation: generation, title: title, detail: detail)
    }

    /// One AVPlayer per load. Reusing a single player across dozens of item swaps, mixing
    /// HLS and raw files, degraded on a real Apple TV: after about forty channel changes,
    /// files that had played fine minutes earlier stopped reaching ready. The video layer
    /// follows `player`, so swapping the instance costs nothing visible.
    private func installFreshPlayer(with playerItem: AVPlayerItem, generation: Int) {
        let old = player
        old?.pause()
        old?.replaceCurrentItem(with: nil)
        let fresh = AVPlayer(playerItem: playerItem)
        fresh.automaticallyWaitsToMinimizeStalling = true
        player = fresh
        print("[Plex90] gen=\(generation) | Fresh AVPlayer")
    }

    private func noteHLSTimelineStart(_ playerItem: AVPlayerItem, generation: Int) {
        guard hlsRequestedOffset > 0 else { hlsBaseOffset = 0; return }
        let t = playerItem.currentTime().seconds
        hlsBaseOffset = PlaybackWatchdog.hlsBaseOffset(requested: hlsRequestedOffset, observedStart: t)
        let d = playerItem.duration
        print("[Plex90] gen=\(generation) | HLS timeline starts at \(String(format: "%.1f", t))s for a \(hlsRequestedOffset)s offset, base \(Int(hlsBaseOffset))s, item duration \(d.isNumeric ? String(format: "%.0f", d.seconds) : "indefinite")s")
    }

    /// `playerItem` is the one that failed. It carries the error log, which is the only
    /// place the HTTP status of a refused segment survives, so this path can finally tell a
    /// server that said no from a file the device could not decode.
    private func autoSkipOnError(generation: Int, playerItem: AVPlayerItem? = nil) {
        guard loadGeneration == generation else { return }
        let title = currentItem?.title ?? "Unknown"
        let reason = playerItem?.error?.localizedDescription ?? "no error on the item"
        print("[Plex90] gen=\(generation) | AUTO-SKIP: \"\(title)\" failed, skipping to next")
        let hadPicture = playbackState == .playing
        Task { @MainActor [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            let failure = await self.classifyFailure(for: playerItem, item: self.currentItem,
                                                     hadPicture: hadPicture)
            guard self.loadGeneration == generation else { return }
            self.showErrorThenSkip(failure, generation: generation, title: title,
                                   detail: "AVPlayer failed before any watchdog deadline: \(reason)")
        }
    }

    /// Backstop for an item that finishes without announcing it.
    ///
    /// `AVPlayerItemDidPlayToEndTime` is the primary end-of-item signal, but it does not
    /// always arrive. A Plex HLS transcode whose playlist never receives `#EXT-X-ENDLIST`,
    /// or a transcode session that dies as the file runs out, leaves AVPlayer parked on the
    /// final frame with no notification and no error. The channel then sits on a finished
    /// program until the user tunes away and back, which is the one thing a continuously
    /// playing guide must never do.
    ///
    /// Safe to treat a stopped rate as "ended" because fullscreen playback has no pause:
    /// Play/Pause only flashes the OSD (see PlayerView), so the user cannot park the player
    /// here deliberately. Firing advances the schedule, which bumps `loadGeneration` and
    /// retires this timer, so it cannot fire twice for the same item.
    private func installEndOfItemFallback(for playerItem: AVPlayerItem, generation: Int, title: String) {
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.loadGeneration == generation else { return }
                guard case .playing = self.playbackState, let player = self.player else { return }
                let duration = playerItem.duration
                guard duration.isNumeric else { return }
                // Both on the item's own clock. A transcode started at an offset reports
                // the *remainder* as its duration (measured 2026-10-06: 2806s for a 3908s
                // offset on a 111-minute film), so adding the offset back here drove
                // `remaining` negative on every tuned-in transcode and turned the first
                // rate-0 moment into a skip to the next film.
                let total = duration.seconds
                let current = playerItem.currentTime().seconds
                guard total.isFinite, total > 0, current.isFinite else { return }
                let remaining = total - current
                // Parked at the tail with no forward motion. Mid-item buffering also stops
                // the rate, hence the requirement that we are already at the end.
                guard remaining <= 2.0, player.rate == 0 else { return }
                print("[Plex90] gen=\(generation) | END FALLBACK: \"\(title)\" parked \(String(format: "%.1f", remaining))s from end, no end-of-item notification — advancing")
                PlaybackDiagnostics.record(outcome: "end-of-item fallback", title: title, detail: String(format: "parked %.1fs from end, rate 0, item duration %.0fs, playhead %.0fs, offset base %.0fs", remaining, total, current, self.hlsBaseOffset))
                self.handlePartEnded()
            }
            .store(in: &self.cancellables)
    }

    // MARK: - Auto-advance

    // Called when AVPlayerItemDidPlayToEndTime fires. For multi-disc Plex movies (stored as
    // a single item with multiple Media.Part entries), plays the next disc before advancing
    // the schedule. For single-disc / single-file content, advances to the next item.
    private func handlePartEnded() {
        if let item = currentItem,
           let extra = item.additionalPartKeys,
           currentPartIndex < extra.count {
            let nextKey = extra[currentPartIndex]
            let partNum = currentPartIndex + 2  // human-readable: disc 2, disc 3, …
            let totalParts = extra.count + 1
            print("[Plex90] MULTI-PART: \"\(item.title)\" — starting disc \(partNum) of \(totalParts)")
            currentPartIndex += 1
            currentItem = item.withPartKey(nextKey)
            seekOffset = 0
            loadCurrentItem()
        } else {
            currentPartIndex = 0
            advanceToNextItem(fromNaturalEnd: true)
        }
    }

    // fromNaturalEnd: true when called from AVPlayerItemDidPlayToEndTime. In that case we
    // always start the next item at 0 — actual file durations differ from Jellyfin/Plex
    // metadata (sometimes by 40+ seconds), so applying schedule.elapsedSeconds would skip
    // into the next episode. Schedule-sync seeks are only correct when tuning into a channel.
    private func advanceToNextItem(fromNaturalEnd: Bool = false) {
        guard let channel = currentChannel else { return }
        let prevRatingKey = currentItem?.ratingKey
        let prevTitle = currentItem?.title ?? "nil"

        if let schedule = ChannelScheduleBuilder.buildSchedule(
            for: channel,
            credentialFingerprint: scheduleCredentialFingerprint
        ) {
            let scheduleHasMoved = schedule.nowPlaying?.item.ratingKey != prevRatingKey
            var pick = scheduleHasMoved
                ? schedule.nowPlaying?.item
                : (schedule.upNext?.item ?? schedule.nowPlaying?.item)
            // Never seek on natural playback end: file duration ≠ scheduled duration,
            // so elapsedSeconds would skip into the next item. Only apply seek when
            // the schedule is being re-synced from outside (channel change, watchdog).
            var newSeekOffset = (scheduleHasMoved && pick != nil && !fromNaturalEnd) ? schedule.elapsedSeconds : 0

            if let item = pick,
               let conflictCH = ChannelScheduleBuilder.findConflict(
                   item: item,
                   excludingChannelID: channel.id,
                   in: channels,
                   credentialFingerprint: scheduleCredentialFingerprint
               ) {
                print("[Plex90] ADVANCE CONFLICT: \"\(item.title)\" already on CH \(conflictCH), skipping")
                if let idx = schedule.entries.firstIndex(where: { $0.item.ratingKey == pick?.ratingKey }),
                   idx + 1 < schedule.entries.count {
                    pick = schedule.entries[idx + 1].item
                    newSeekOffset = 0
                }
            }

            if let next = pick {
                currentItem = next
                seekOffset = newSeekOffset
                print("[Plex90] ADVANCE: \"\(prevTitle)\" -> \"\(next.title)\" on CH \(channel.name) seek=\(newSeekOffset)s (from schedule)")
            } else {
                currentItem = channel.filteredPool().randomElement()
                seekOffset = 0
                print("[Plex90] ADVANCE: \"\(prevTitle)\" -> \"\(currentItem?.title ?? "nil")\" on CH \(channel.name) (random fallback)")
            }
        } else {
            currentItem = channel.filteredPool().randomElement()
            seekOffset = 0
            print("[Plex90] ADVANCE: \"\(prevTitle)\" -> \"\(currentItem?.title ?? "nil")\" on CH \(channel.name) (random fallback)")
        }
        loadCurrentItem()
    }
}

// MARK: - Now Playing Info Center

extension AppState {
    /// Push the current programme to the system now-playing card. Driven from
    /// `didSet` on `currentItem` and `playbackState`, so every playback path
    /// feeds it without eight separate call sites to keep in step.
    func refreshNowPlayingInfo() {
        guard let item = currentItem else {
            NowPlayingInfoService.clear()
            return
        }
        let playing: Bool
        if case .playing = playbackState { playing = true } else { playing = false }

        // Only AppState knows which server this item came from, so the artwork
        // URL is resolved here rather than inside the service.
        let artwork = apiForServer(selectedServers.first).thumbnailURL(for: item)

        NowPlayingInfoService.update(
            item: item,
            channel: currentChannel,
            isPlaying: playing,
            elapsed: (player?.currentTime().seconds ?? 0) + hlsBaseOffset,
            artworkURL: artwork
        )
    }
}
