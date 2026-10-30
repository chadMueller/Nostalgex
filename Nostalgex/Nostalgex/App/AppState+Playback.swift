import Foundation
import Observation
import SwiftUI
import AVFoundation
import Combine
import UIKit

// Player control, subtitles and audio selection, sleep timer, retries and auto-advance.
// Split out of AppState.swift; behavior unchanged.
extension AppState {
    // MARK: - Explicit original-video compatibility retry

    var canRetryOriginalVideo: Bool {
        guard backendKind == .plex, !isDemoMode, let item = currentItem,
              let backend = api(for: item.serverID) as? PlexAPIService else { return false }
        return PlexAPIService.canRetryOriginalVideo(item, isLocal: backend.isLikelyLocalServer,
                                                    hevcCapable: CodecSupport.deviceSupportsHEVC)
    }

    /// A fresh session is prepared while the old player stays in place. Rejected or stale
    /// decisions clean up only their own session. No automatic 1080p recovery is allowed.
    func retryOriginalVideoCompatibility() async -> String {
        guard canRetryOriginalVideo, !compatibilityRetryInFlight, !playbackRecoveryInFlight, let item = currentItem,
              let backend = api(for: item.serverID) as? PlexAPIService,
              let oldItem = player?.currentItem else { return "RETRY UNAVAILABLE" }
        compatibilityRetryInFlight = true
        defer { compatibilityRetryInFlight = false }
        let generation = loadGeneration
        let attempt = playbackAttemptGeneration
        let observed = oldItem.currentTime().seconds + hlsBaseOffset
        let offset = observed.isFinite && observed >= 0 ? Int(observed) : max(0, seekOffset)
        let playbackItem = await backend.itemWithPlaybackStreamFacts(item)
        let convertSurround = playbackItem.audioCodec?.lowercased() == "eac3" && playbackItem.audioChannelCount == 8
        let session = UUID().uuidString
        guard let original = backend.transcodeURL(for: playbackItem, sessionID: session, offsetSeconds: offset),
              let url = PlexAPIService.preservationRetryURL(from: original, audioStreamID: playbackItem.audioStreamID,
                                                           convertSurroundAudio: convertSurround) else { return "RETRY UNAVAILABLE" }
        let decision = await backend.prepareTranscodeSession(startURL: url)
        guard isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: oldItem),
              !playbackRecoveryInFlight else {
            await backend.stopTranscode(playSessionId: session)
            return "PROGRAM CHANGED"
        }
        guard decision.code.hasPrefix("1"), decision.preservesOriginalVideo else {
            await backend.stopTranscode(playSessionId: session)
            return "SERVER CANNOT KEEP ORIGINAL VIDEO"
        }
        guard !convertSurround || decision.convertsAudioToAC3Surround else {
            await backend.stopTranscode(playSessionId: session)
            return "SERVER CANNOT KEEP SURROUND AUDIO"
        }
        // Invalidate the old player's watchdogs before installing the prepared session.
        loadGeneration += 1
        stopActiveTranscodeIfNeeded()
        activeTranscode = (item.serverID, session)
        playbackRequiresOriginalVideo = true
        seekOffset = offset
        hlsRequestedOffset = offset
        hlsBaseOffset = 0
        audioTracks = []
        audibleGroup = nil
        audibleGroupItem = nil
        selectedAudioTrackID = nil
        fallbackToTranscode(url: url, seekTo: nil, generation: loadGeneration,
                            allowCappedRetry: false, prepared: true,
                            informationReason: .originalVideoRetry)
        return "RETRYING ORIGINAL VIDEO"
    }

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

    /// Invalidate work even when a retry replaces a player within the same channel load.
    /// A cancelled backend may still return a session; its completion must check the token
    /// and clean up that exact session before returning.
    func invalidatePlaybackAttempt() {
        playbackAttemptGeneration += 1
        playbackInformation?.invalidateAttempt()
        playbackRecoveryInFlight = false
        playbackResolutionTask?.cancel()
        playbackResolutionTask = nil
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
        playbackSkipTask?.cancel()
        playbackSkipTask = nil
    }

    func isCurrentPlaybackAttempt(generation: Int, attempt: Int, playerItem: AVPlayerItem? = nil) -> Bool {
        guard loadGeneration == generation, playbackAttemptGeneration == attempt else { return false }
        return playerItem.map { player?.currentItem === $0 } ?? true
    }

    private func claimPlaybackRecovery(for playerItem: AVPlayerItem, generation: Int, attempt: Int) -> Bool {
        guard isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem),
              !playbackRecoveryInFlight else { return false }
        playbackRecoveryInFlight = true
        playbackWatchdogTask?.cancel()
        return true
    }

    /// Shared by the startup watchdog and the starvation monitor. Only one negotiation
    /// owns the current player; a channel change or replacement makes a late reply cleanup-only.
    private func beginServerFallback(for item: PlexMediaItem, position: Int, generation: Int,
                                     attempt: Int, playerItem: AVPlayerItem,
                                     informationReason: PlaybackInformation.FallbackReason,
                                     reportWatchdogFailure: Bool = false) {
        guard claimPlaybackRecovery(for: playerItem, generation: generation, attempt: attempt) else { return }
        beginPlaybackInformationAttempt(generation: generation, attempt: attempt,
                                        isDirectPlay: false, reason: informationReason)
        let backend = api(for: item.serverID)
        playbackResolutionTask?.cancel()
        playbackResolutionTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled,
                  self?.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) == true else { return }
            let resolved = await backend.resolveServerStream(for: item, offsetSeconds: position)
            guard let self, !Task.isCancelled,
                  self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else {
                if let session = resolved?.resolution.playSessionId {
                    await backend.stopTranscode(playSessionId: session)
                }
                return
            }
            guard let resolved else {
                // No server stream either. Skips without a card, as it always has, but is
                // reported and counted like every other failure so a channel of these stops.
                // A starved stream used to skip here without any report; `stalled` is its code.
                if self.recordFailedItem(reportWatchdogFailure ? .watchdogSkip : .stalled) {
                    self.stopChannelAfterRepeatedFailures(last: .transcodingUnavailable(server: self.backendKind.displayName))
                } else {
                    self.advanceToNextItem()
                }
                return
            }
            self.stopActiveTranscodeIfNeeded()
            self.seekOffset = position
            self.activeTranscode = (item.serverID, resolved.resolution.playSessionId)
            self.playbackRequiresOriginalVideo = resolved.resolution.requiresOriginalVideo
            self.hlsRequestedOffset = resolved.startsAtOffset ? position : 0
            self.fallbackToTranscode(url: resolved.resolution.url, seekTo: resolved.startsAtOffset ? nil : position,
                                     generation: generation, allowCappedRetry: true, prepared: true,
                                     informationReason: informationReason,
                                     informationIsDirectPlay: resolved.resolution.isDirectPlay)
        }
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
        isVideoPlaying = false
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
        let stopsChannel = recordFailedItem(failure.analyticsCode)
        playbackState = .error(failure)
        noteRatingNudgePlaybackFailure()
        PlaybackDiagnostics.record(
            outcome: failure.diagnosticSummary,
            title: title ?? currentItem?.title ?? "?",
            detail: detail ?? failure.headline
        )
        if stopsChannel {
            stopChannelAfterRepeatedFailures(last: failure)
            return
        }
        let attempt = playbackAttemptGeneration
        playbackWatchdogTask?.cancel()
        playbackSkipTask?.cancel()
        let cardSeconds = errorCardSeconds
        playbackSkipTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(cardSeconds)) } catch { return }
            guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt) else { return }
            self.advanceToNextItem()
        }
    }

    /// The one place a programme that will not play is reported and counted: one
    /// `playback.error`, and one more failure on the channel's `ChannelFailureRun`.
    /// Returns true when the run has reached its limit and the channel should stop.
    private func recordFailedItem(_ code: AnalyticsPlaybackErrorCode) -> Bool {
        emitPlaybackError(code)
        guard let channel = currentChannel else { return false }
        return channelFailureRun.recordFailure(onChannel: channel.id)
    }

    /// Ends the error-and-skip loop on a channel where nothing plays. Tears down what the
    /// next load would have torn down (player item, server transcode, tracker) and starts
    /// nothing, so no request for this channel reaches the server until `selectChannel`
    /// runs again: the viewer tunes or re-selects the channel, or the app comes back to
    /// the foreground.
    private func stopChannelAfterRepeatedFailures(last failure: PlaybackFailure) {
        invalidatePlaybackAttempt()
        cancellables.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        // cancellables.removeAll() just cancelled the KVO mirror from installFreshPlayer,
        // so nothing will flip this to false on its own.
        isVideoPlaying = false
        stopActiveTranscodeIfNeeded()
        emitPlaybackStoppedForActiveSession()
        let outgoing = playbackTracker
        playbackTracker = nil
        outgoing?.stop()
        let stopped = PlaybackFailure.channelStopped(last: failure)
        playbackState = .error(stopped)
        PlaybackDiagnostics.record(outcome: stopped.diagnosticSummary,
                                   title: currentItem?.title ?? "?", detail: stopped.headline)
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
                                         generation: Int, attempt: Int) async -> Bool {
        guard isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem),
              playbackState != .playing,
              let events = playerItem.errorLog()?.events, !events.isEmpty,
              let failing = events.reversed().compactMap({ $0.uri }).first,
              let url = URL(string: failing) else { return false }
        let headers = item.map { api(for: $0.serverID).authHeaders } ?? [:]
        guard let status = await StreamFailureProbe.refusalStatus(of: url, headers: headers),
              StreamFailureProbe.isRefusal(status), !Task.isCancelled,
              isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return false }
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
        // A decoded frame proves the device can handle the stream, whatever happened next.
        if let probe = videoFrameProbe, let playerItem {
            e.decodedAFrame = probe.hasNewPixelBuffer(forItemTime: playerItem.currentTime())
        }
        if let access = playerItem?.accessLog()?.events.last {
            e.serverDeliveredBytes = access.numberOfBytesTransferred > 0
        }
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
        //
        // Ask about the request that actually failed, which the player names in its error
        // log, and only fall back to the URL the player was handed. That URL is the master
        // playlist and it answers 200 while the segments beneath it fail, so probing it
        // proves nothing: measured 2026-10-08, The Dark Knight failed with CoreMedia
        // -12927 and the master still answered 200, so the card said "no reason came back"
        // about a server that had returned 500 on every segment.
        if !starvedAfterCappedRetry, evidence.httpStatuses.isEmpty {
            let fromLog = playerItem?.errorLog()?.events.reversed()
                .compactMap({ $0.uri }).compactMap(URL.init(string:)).first
            if let url = fromLog ?? lastStreamURL {
                let headers = item.map { api(for: $0.serverID).authHeaders } ?? [:]
                // Walks the playlist down to real media: the master answers 200 even
                // when every segment under it is refused.
                let status = await StreamFailureProbe.refusalStatus(of: url, headers: headers)
                // Through InstallDiagnostics, not print: a bare print never reaches the
                // unified log on a simulator, so an unexplained classification could not
                // be told apart from a probe that never ran.
                InstallDiagnostics.note("FAILURE PROBE: \(url.lastPathComponent) -> "
                    + (status.map(String.init) ?? "no answer")
                    + " (from \(fromLog == nil ? "last stream URL" : "player error log"))")
                if let status, StreamFailureProbe.isRefusal(status) {
                    evidence.httpStatuses.append(status)
                }
            }
        }
        return PlaybackFailure.classify(backend: backendKind, evidence: evidence)
    }

    /// Sends `playback.error`. Called from `recordFailedItem`, and from `autoSkipOnError`
    /// for a failure the viewer tuned away from before its card showed (`channel` is then
    /// the one that failed, not the one now on). No-op without a channel.
    private func emitPlaybackError(_ code: AnalyticsPlaybackErrorCode, channel: Channel? = nil) {
        guard let channel = channel ?? currentChannel else { return }
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

    func loadCurrentItem(preservingTracker: Bool = false) {
        // Clear the previous item's audio-track list so a new/uni-track program never
        // shows stale tracks; applyAudioTrackSelection republishes when the group loads.
        audioTracks = []
        selectedAudioTrackID = nil
        audibleGroup = nil
        audibleGroupItem = nil
        hasSubtitleTracks = false

        if !preservingTracker {
            currentPartBaseSeconds = 0
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
        }

        // Invalidate everything from previous load
        invalidatePlaybackAttempt()
        cancellables.removeAll()
        loadGeneration += 1
        let generation = loadGeneration
        let attempt = playbackAttemptGeneration
        // Free any prior transcode before starting the next one (covers selectChannel /
        // next/previousChannel / advanceToNextItem — they all funnel through here).
        stopActiveTranscodeIfNeeded()

        playbackInformation = nil
        playbackRequiresOriginalVideo = false
        guard var item = currentItem else {
            // Watershed can empty a channel's pool without the channel being genuinely
            // empty: say so with its own card rather than the plain idle screen.
            if let channel = currentChannel, channel.isWatershedHold(watershedEnabled: watershedEnabled) {
                print("[Plex90] gen=\(generation) | No item, watershed hold on CH \(channel.number)")
                playbackState = .watershedHold
            } else {
                print("[Plex90] gen=\(generation) | No item, going idle")
                playbackState = .idle
            }
            return
        }

        if !preservingTracker {
            let position = item.playbackPosition(at: seekOffset)
            item = position.item
            currentItem = item
            currentPartIndex = item.partIndex
            currentPartBaseSeconds = position.baseSeconds
            seekOffset = position.offsetSeconds
        }

        beginPlaybackInformation(for: item, generation: generation)

        // An item stamped with a server that is not signed in cannot be played by the one
        // that is: its rating key means something else there (on Emby, a Plex key resolved
        // to a Person record and the server answered 500). Say so and move on rather than
        // sending the request.
        if !isDemoMode, !itemBelongsToConnectedServers(item) {
            print("[Plex90] gen=\(generation) | \"\(item.title)\" belongs to server \(item.serverID ?? "?") which is not signed in, skipping")
            showErrorThenSkip(.noPlayableSource(server: backendKind.displayName), generation: generation,
                              title: item.title, detail: "Item belongs to a server that is not signed in")
            return
        }

        // Create a fresh tracker for this item. Reporting stays off unless the user
        // turned it on: Plex gets timeline + scrobble, Jellyfin and Emby get the same
        // watch counted on their server. Either way the tracker still accumulates time.
        if !preservingTracker {
            // Keep the backend available even with both choices off so a live
            // preference change takes effect without retuning or resetting analytics.
            let reportingBackend: (any MediaBackend)? = isDemoMode ? nil : api(for: item.serverID)
            playbackTracker = PlaybackTracker(
                item: item,
                seekOffset: Int(currentPartBaseSeconds) + seekOffset,
                plexAPI: reportingBackend as? PlexAPIService,
                watchReporter: reportingBackend as? any WatchActivityReporting,
                showNowPlaying: !isDemoMode && showNowPlaying,
                markWatched: !isDemoMode && markWatched,
                controlScope: playbackReportingScope
            )
            if let tracker = playbackTracker { attachRatingNudgeCounter(to: tracker) }
        }

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
        // Emby needs the session id on the URL or every segment is refused; see
        // EmbyAPIService.buildTranscodeURL(for:sessionID:).
        let transcodeURL: URL? = (itemAPI as? PlexAPIService)?.transcodeURL(for: item, sessionID: fallbackSession, offsetSeconds: seekOffset)
            ?? (itemAPI as? EmbyAPIService)?.buildTranscodeURL(for: item, sessionID: fallbackSession)
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
        playbackResolutionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt) else {
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
                let offset = self.seekOffset
                let resolved = await api.resolveTranscodePlayback(for: item, offsetSeconds: offset)
                let resolution = resolved?.resolution
                guard !Task.isCancelled, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt) else {
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
                if resolved?.startsAtOffset == true {
                    self.hlsRequestedOffset = offset
                    seekTo = nil
                }
                resolvedURL = resolution.url
                isDirectPlay = resolution.isDirectPlay
                self.activeTranscode = (itemServerID, resolution.playSessionId)
                self.playbackRequiresOriginalVideo = resolution.requiresOriginalVideo
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
            let informationAttempt = self.beginPlaybackInformationAttempt(
                generation: generation, attempt: attempt, isDirectPlay: isDirectPlay,
                reason: isDirectPlay || isDemoMode ? .none : .serverStreamSelected)

            // Status observer
            playerItem.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else {
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
                        self.markPlaybackInformationReady(for: playerItem, generation: generation,
                                                          attempt: attempt, attemptID: informationAttempt)
                        self.reportPlaybackReadyIfNeeded(delivery: isDirectPlay ? .directPlay : .transcode)
                        if let seekTo, seekTo > 0 {
                            print("[Plex90] gen=\(generation) | Seeking to \(seekTo)s")
                            let target = CMTime(seconds: Double(seekTo), preferredTimescale: 600)
                            self.player?.seek(to: target) { finished in
                                Task { @MainActor [weak self] in
                                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
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
                        guard self.claimPlaybackRecovery(for: playerItem, generation: generation, attempt: attempt) else { return }
                        let errMsg = playerItem.error?.localizedDescription ?? "Unknown error"
                        print("[Plex90] gen=\(generation) | FAILED: \"\(title)\" - \(errMsg)")
                        // If direct play failed and we have a transcode URL, fall back
                        if isDirectPlay, let fallback = transcodeURL {
                            print("[Plex90] gen=\(generation) | Direct play failed, falling back to transcode")
                            if itemAPI is PlexAPIService || itemAPI is EmbyAPIService {
                                self.activeTranscode = (itemServerID, fallbackSession)
                            }
                            if fallbackStartsAtOffset { self.hlsRequestedOffset = self.seekOffset }
                            self.fallbackToTranscode(url: fallback, seekTo: fallbackStartsAtOffset ? nil : seekTo,
                                                    generation: generation, informationReason: .directPlayFailed)
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
                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
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

    private func retryLoad(url: URL, seekTo: Int?, generation: Int, isDirectPlay: Bool) {
        guard loadGeneration == generation else { return }
        invalidatePlaybackAttempt()
        let attempt = playbackAttemptGeneration
        let informationAttempt = beginPlaybackInformationAttempt(
            generation: generation, attempt: attempt, isDirectPlay: isDirectPlay, reason: .playerRetry)
        let title = currentItem?.title ?? "Unknown"
        print("[Plex90] gen=\(generation) | RETRY: \"\(title)\" - waiting 300ms")
        cancellables.removeAll()
        player?.replaceCurrentItem(with: nil)

        // Wait briefly then try once more
        playbackResolutionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt) else {
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
                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
                    switch status {
                    case .readyToPlay:
                        print("[Plex90] gen=\(generation) | RETRY READY: \"\(title)\"")
                        self.markPlaybackInformationReady(for: playerItem, generation: generation,
                                                          attempt: attempt, attemptID: informationAttempt)
                        // Retry re-uses whatever delivery the session already had.
                        self.reportPlaybackReadyIfNeeded(delivery: self.currentPlaybackDelivery ?? .transcode)
                        if let seekTo, seekTo > 0 {
                            let target = CMTime(seconds: Double(seekTo), preferredTimescale: 600)
                            self.player?.seek(to: target) { _ in
                                Task { @MainActor [weak self] in
                                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
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
                        guard self.claimPlaybackRecovery(for: playerItem, generation: generation, attempt: attempt) else { return }
                        let msg = playerItem.error?.localizedDescription ?? "Unknown error"
                        print("[Plex90] gen=\(generation) | RETRY FAILED: \"\(title)\" - \(msg)")
                        // Reported once, by autoSkipOnError, with the classified code.
                        self.autoSkipOnError(generation: generation, playerItem: playerItem)
                    default:
                        break
                    }
                }
                .store(in: &self.cancellables)

            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
                    print("[Plex90] gen=\(generation) | RETRY END OF ITEM: \"\(title)\" - checking for next part")
                    self.handlePartEnded()
                }
                .store(in: &self.cancellables)

            self.installEndOfItemFallback(for: playerItem, generation: generation, title: title)
            self.installWatchdog(for: playerItem, item: self.currentItem, isDirectPlay: isDirectPlay, generation: generation, allowCappedRetry: !isDirectPlay)
            self.installStarvationMonitor(for: playerItem, item: self.currentItem, isDirectPlay: isDirectPlay, generation: generation, allowCappedRetry: !isDirectPlay)
        }
    }

    private func fallbackToTranscode(url: URL, seekTo: Int?, generation: Int, allowCappedRetry: Bool = true, prepared: Bool = false,
                                     informationReason: PlaybackInformation.FallbackReason,
                                     informationRequest: PlaybackInformation.RecoveryRequest? = nil,
                                     informationIsDirectPlay: Bool = false) {
        guard loadGeneration == generation else { return }
        invalidatePlaybackAttempt()
        let attempt = playbackAttemptGeneration
        let informationAttempt = beginPlaybackInformationAttempt(
            generation: generation, attempt: attempt, isDirectPlay: informationIsDirectPlay,
            reason: informationReason, recoveryRequest: informationRequest)
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

        playbackResolutionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt) else { return }

            if !prepared, let serverID = self.currentItem?.serverID {
                let backend = self.api(for: serverID)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                let session = query?.first { $0.name == "session" || $0.name == "PlaySessionId" }?.value
                await backend.prepareTranscodeSession(startURL: url)
                guard !Task.isCancelled, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt) else {
                    if let session { await backend.stopTranscode(playSessionId: session) }
                    return
                }
            }
            print("[Plex90] gen=\(generation) | TRANSCODE: creating AVPlayerItem for \"\(title)\"")
            let playerItem = AVPlayerItem(url: url)
            self.lastStreamURL = url
            playerItem.preferredForwardBufferDuration = 5
            self.installFreshPlayer(with: playerItem, generation: generation)

            playerItem.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
                    switch status {
                    case .readyToPlay:
                        print("[Plex90] gen=\(generation) | TRANSCODE READY: \"\(title)\"")
                        self.markPlaybackInformationReady(for: playerItem, generation: generation,
                                                          attempt: attempt, attemptID: informationAttempt)
                        // Fallback path is by definition a transcode delivery.
                        self.reportPlaybackReadyIfNeeded(delivery: .transcode)
                        if let seekTo, seekTo > 0 {
                            let target = CMTime(seconds: Double(seekTo), preferredTimescale: 600)
                            self.player?.seek(to: target) { _ in
                                Task { @MainActor [weak self] in
                                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
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
                        guard self.claimPlaybackRecovery(for: playerItem, generation: generation, attempt: attempt) else { return }
                        let msg = playerItem.error?.localizedDescription ?? "Unknown error"
                        print("[Plex90] gen=\(generation) | TRANSCODE FAILED: \"\(title)\" - \(msg)")
                        // Reported once, by autoSkipOnError, with the classified code.
                        self.autoSkipOnError(generation: generation, playerItem: playerItem)
                    default:
                        break
                    }
                }
                .store(in: &self.cancellables)

            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
                    self.handlePartEnded()
                }
                .store(in: &self.cancellables)

            self.installEndOfItemFallback(for: playerItem, generation: generation, title: title)
            self.installWatchdog(for: playerItem, item: self.currentItem, isDirectPlay: false, generation: generation, allowCappedRetry: allowCappedRetry)
            self.installStarvationMonitor(for: playerItem, item: self.currentItem, isDirectPlay: false, generation: generation, allowCappedRetry: allowCappedRetry)
        }
    }

    // MARK: - Auto-skip on error

    /// Gives a load a bounded time to show picture, then either retries once with the video
    /// forced to 1080p (an HLS copy the device could not decode) or advances.
    private func installWatchdog(for playerItem: AVPlayerItem, item: PlexMediaItem?, isDirectPlay: Bool, generation: Int, allowCappedRetry: Bool) {
        let attempt = playbackAttemptGeneration
        playbackWatchdogTask?.cancel()
        let deadline = PlaybackWatchdog.deadlineSeconds(
            isDirectPlay: isDirectPlay, videoWidth: item?.videoWidth, videoHeight: item?.videoHeight)
        // Ask for decoded frames, not a declared size: a 4K H.264 copy reported 3840x2160
        // while never producing a single picture.
        let probe = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        playerItem.add(probe)
        videoFrameProbe = probe
        playbackWatchdogTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
            if self.player?.rate == 0, playerItem.status != .failed {
                print("[Plex90] gen=\(generation) | WATCHDOG: 4s in, not playing yet (state=\(self.playbackState)) — nudging play()")
                self.player?.play()
            }
            // A server that has already refused the stream should not cost the viewer the
            // whole deadline, which is 40s for a 4K source. If the player has logged a
            // failed request by now and nothing has decoded, ask that exact URL what it
            // answers. A refusal is final: no amount of waiting turns a 500 into a picture.
            if await self.failFastOnServerRefusal(playerItem: playerItem, item: item, generation: generation, attempt: attempt) {
                return
            }
            let window = PlaybackWatchdog.progressWindowSeconds
            do { try await Task.sleep(for: .seconds(max(1, deadline - 4 - window))) } catch { return }
            guard self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
            let sampleA = playerItem.currentTime().seconds
            do { try await Task.sleep(for: .seconds(window)) } catch { return }
            guard self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
            let sampleB = playerItem.currentTime().seconds
            let progressed = sampleB - sampleA
            let reachedReady = self.playbackState == .playing || playerItem.status == .readyToPlay
            let frames = probe.hasNewPixelBuffer(forItemTime: playerItem.currentTime())
            guard !PlaybackWatchdog.hasPicture(reachedReady: reachedReady, progressedSeconds: progressed, decodedFrame: frames) else {
                self.channelFailureRun.reset()   // a picture: the channel plays
                return
            }
            let access = playerItem.accessLog()?.events.last.map { "segments=\($0.numberOfMediaRequests) stalls=\($0.numberOfStalls) bytes=\($0.numberOfBytesTransferred) dropped=\($0.numberOfDroppedVideoFrames) watched=\(String(format: "%.1f", $0.durationWatched))s" } ?? "no access log"
            let errors = playerItem.errorLog()?.events.suffix(3).map { "\($0.errorStatusCode) \(PlaybackDiagnostics.redactSensitiveText($0.errorComment ?? ""))" }.joined(separator: " | ") ?? ""
            let detail = "ready=\(reachedReady), playhead moved \(String(format: "%.1f", progressed))s, frames=\(frames), declared \(Int(playerItem.presentationSize.width))x\(Int(playerItem.presentationSize.height)), rate=\(self.player?.rate ?? -1), status=\(playerItem.status.rawValue), \(access)\(errors.isEmpty ? "" : ", errors: " + errors)"
            self.handleWatchdogNoPicture(playerItem: playerItem, item: item, isDirectPlay: isDirectPlay,
                                         generation: generation, attempt: attempt, allowCappedRetry: allowCappedRetry,
                                         deadline: deadline, detail: detail)
        }
    }

    /// Called only after the watchdog has measured no picture. Kept separate from its
    /// sleeping task so cancellation and overlapping recovery can be tested without timers.
    func handleWatchdogNoPicture(playerItem: AVPlayerItem, item: PlexMediaItem?, isDirectPlay: Bool,
                                generation: Int, attempt: Int, allowCappedRetry: Bool,
                                deadline: Int, detail: String) {
        guard isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem),
              !playbackRecoveryInFlight else { return }
        if isDirectPlay, let item {
            // Audio with a black picture is the signature of a file AVPlayer opened but
            // cannot render: an HEVC MP4 tagged hev1, an exotic profile, a broken index.
            // The server stream is the answer, and it gets its own capped retry after.
            print("[Plex90] gen=\(generation) | WATCHDOG: \(deadline)s deadline, direct play gave no picture (\(detail)) — switching to the server stream")
            PlaybackDiagnostics.record(outcome: "direct play → server stream after \(deadline)s", title: item.title, detail: detail)
            if let channel = self.currentChannel {
                Analytics.track(.playbackTranscodeFallback(channelNumber: channel.number, backend: self.analyticsBackend))
            }
            self.beginServerFallback(for: item, position: self.seekOffset, generation: generation,
                                     attempt: attempt, playerItem: playerItem,
                                     informationReason: .startupNoPicture, reportWatchdogFailure: true)
            return
        }
        guard self.claimPlaybackRecovery(for: playerItem, generation: generation, attempt: attempt) else { return }
        if allowCappedRetry, !playbackRequiresOriginalVideo, !isDirectPlay, let item,
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
                                     generation: generation, allowCappedRetry: false,
                                     informationReason: .startupNoPicture, informationRequest: .compatibility1080p)
            return
        }
        print("[Plex90] gen=\(generation) | WATCHDOG: \(deadline)s deadline, no picture (\(detail)) — advancing to next item")
        // The error log is read here for the first time to say *why*. A segment that
        // came back 500 is the server's problem and the card now says so.
        self.playbackResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let failure = await self.classifyFailure(for: playerItem, item: item, hadPicture: false)
            guard !Task.isCancelled,
                  self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
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
        let attempt = playbackAttemptGeneration
        // AVPlayer's playing / paused / buffering feeds Plex Now Playing (PR #18). Only the
        // current player and item count, so an old channel's callback cannot reach the
        // next tracker. The watch clock is separate.
        if let observedPlayer = player {
            observedPlayer.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak observedPlayer, weak playerItem] status in
                    guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem),
                          let observedPlayer, self.player === observedPlayer,
                          let playerItem, observedPlayer.currentItem === playerItem else { return }
                    let state = status == .playing ? "playing" : status == .paused ? "paused" : "buffering"
                    self.playbackTracker?.onHeartbeatPlaybackState(state)
                }
                .store(in: &cancellables)
        }
        var monitor = PlaybackStarvation()
        let title = item?.title ?? currentItem?.title ?? "Unknown"
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem), let player = self.player,
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
                                      attempt: attempt, playerItem: playerItem,
                                      allowCappedRetry: allowCappedRetry, position: position, title: title, detail: detail)
            }
            .store(in: &cancellables)
    }

    func handleStarvation(item: PlexMediaItem?, isDirectPlay: Bool, generation: Int, attempt: Int,
                          playerItem: AVPlayerItem, allowCappedRetry: Bool,
                          position: Int, title: String, detail: String) {
        guard isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem),
              !playbackRecoveryInFlight else { return }
        if isDirectPlay, let item {
            // The file itself cannot reach the device fast enough (remote server, weak wifi).
            // The server stream adapts; resume it where we are.
            print("[Plex90] gen=\(generation) | STARVED: \"\(title)\" on direct play (\(detail)) — switching to the server stream at \(position)s")
            PlaybackDiagnostics.record(outcome: "starved on direct play → server stream from \(position)s", title: title, detail: detail)
            beginServerFallback(for: item, position: position, generation: generation,
                                attempt: attempt, playerItem: playerItem, informationReason: .streamStalled)
            return
        }
        guard claimPlaybackRecovery(for: playerItem, generation: generation, attempt: attempt) else { return }
        if allowCappedRetry, !playbackRequiresOriginalVideo, let item,
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
                                generation: generation, allowCappedRetry: false,
                                informationReason: .streamStalled, informationRequest: .compatibility1080p)
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
    // Not private: PlaybackRecoveryOwnershipTests-style harnesses and the dedicated
    // ChannelOverlayPlaybackStateTests exercise this directly to drive a real AVPlayer's
    // KVO without going through the full network-resolving loadCurrentItem path.
    func installFreshPlayer(with playerItem: AVPlayerItem, generation: Int) {
        let old = player
        old?.pause()
        old?.replaceCurrentItem(with: nil)
        let fresh = AVPlayer(playerItem: playerItem)
        fresh.automaticallyWaitsToMinimizeStalling = true
        player = fresh
        isVideoPlaying = fresh.timeControlStatus == .playing

        // Keep `isVideoPlaying` mirrored to this exact player for as long as it's the
        // current one. Every load path (loadCurrentItem / retryLoad / fallbackToTranscode)
        // calls `cancellables.removeAll()` right before this function runs, so the previous
        // player's subscription is already gone before this one is added, no leaked
        // observer, and a channel change re-attaches fresh rather than relying on a stale
        // one left over from the old AVPlayer instance.
        fresh.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak fresh] status in
                guard let self, let fresh, self.player === fresh else { return }
                self.isVideoPlaying = status == .playing
            }
            .store(in: &cancellables)

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
        let attempt = playbackAttemptGeneration
        let failedChannel = currentChannel
        let title = currentItem?.title ?? "Unknown"
        let reason = playerItem?.error?.localizedDescription ?? "no error on the item"
        print("[Plex90] gen=\(generation) | AUTO-SKIP: \"\(title)\" failed, skipping to next")
        // Whether THIS item ever played, not whether the player is in a playing state:
        // playbackState is still .playing for the outgoing programme while the next one
        // loads, and reading it here marked a programme that never produced a frame as
        // one that had, which pushed the classification into .unknown.
        let hadPicture = (playerItem?.currentTime().seconds ?? 0) > 0.5
        playbackResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Tuned away before the card: no card and no count, but still this failure's
            // one report, for the channel it happened on.
            guard self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else {
                self.emitPlaybackError(.playerFailed, channel: failedChannel)
                return
            }
            let failure = await self.classifyFailure(for: playerItem, item: self.currentItem,
                                                     hadPicture: hadPicture)
            guard !Task.isCancelled, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else {
                self.emitPlaybackError(failure.analyticsCode, channel: failedChannel)
                return
            }
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
        let attempt = playbackAttemptGeneration
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
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
        playbackTracker?.onPlaybackPreparing()
        if let item = currentItem,
           let extra = item.additionalPartKeys,
           currentPartIndex < extra.count {
            let nextKey = extra[currentPartIndex]
            let partNum = currentPartIndex + 2  // human-readable: disc 2, disc 3, …
            let totalParts = extra.count + 1
            print("[Plex90] MULTI-PART: \"\(item.title)\" — starting disc \(partNum) of \(totalParts)")
            let metadataDuration = item.playbackParts?.first { $0.key == item.partKey }?.durationSeconds
            let measuredDuration = player?.currentItem?.duration.seconds
            if let duration = metadataDuration, duration.isFinite, duration > 0 {
                currentPartBaseSeconds += duration
            } else if let duration = measuredDuration, duration.isFinite, duration > 0 {
                currentPartBaseSeconds += duration + hlsBaseOffset
            }
            currentPartIndex += 1
            currentItem = item.withPartKey(nextKey)
            seekOffset = 0
            loadCurrentItem(preservingTracker: true)
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
