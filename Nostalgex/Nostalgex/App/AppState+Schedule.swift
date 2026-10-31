import Foundation
import Observation
import SwiftUI
import AVFoundation
import Combine
import UIKit

// Daily refresh wiring and channel selection / schedule building.
// Split out of AppState.swift; behavior unchanged.
extension AppState {
    // MARK: - Daily library refresh

    /// Start a background loop that re-fetches the Plex library every 24h
    /// (rolling, not on UTC day boundary — so the refresh doesn't kick in
    /// mid-evening when UTC midnight crosses for users in western timezones).
    func startDailyRefresh() {
        dailyRefreshTask?.cancel()
        if lastLoadAtUnix == 0 {
            lastLoadAtUnix = Int(Date().timeIntervalSince1970)
        }
        dailyRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900)) // check every 15 min
                guard !Task.isCancelled else { break }
                let now = Int(Date().timeIntervalSince1970)
                let lastLoad = self?.lastLoadAtUnix ?? 0
                let lastCheck = self?.lastLibraryCheckAtUnix ?? 0
                if now - lastLoad >= LibrarySnapshotStore.refreshAfterSeconds,
                   now - lastCheck >= LibrarySnapshotStore.refreshAfterSeconds {
                    await self?.refreshLibraryIfChanged()
                }
            }
        }
    }

    // MARK: - Channel control

    /// Programmatically tune to a channel. This path is used by automatic re-selection
    /// (library load, snapshot restore, background refresh, foreground return, demo
    /// mode, music enrichment, bundle filter) — it does NOT emit `channel.tuned`.
    /// User-initiated tunes go through `tuneChannelFromUser(_:method:precomputedSchedule:)`,
    /// which fires the signal with the correct method parameter.
    func selectChannel(_ channel: Channel, precomputedSchedule: ChannelSchedule? = nil) {
        // A channel that stopped after repeated failures gets a fresh run whenever it is
        // chosen again: by the viewer, on foreground return, or after a library reload.
        channelFailureRun.reset()
        let pool = channel.filteredPool()
        print("[Plex90] SELECT CH \(channel.number) \(channel.name) (pool: \(pool.count) items)")
        currentPartIndex = 0
        currentChannel = channel
        // Prefer the pre-computed schedule from the guide so the title the user clicked
        // always matches what actually plays — but only while it still describes what is
        // on. Schedules are rebuilt off the main thread now, so the guide's copy can lag,
        // and an out-of-date one sends the player to the wrong offset or to the programme
        // queued next. Rebuilding one channel inline costs a few milliseconds.
        let now = scheduleClock()
        let usable = precomputedSchedule.flatMap { $0.isCurrent(at: now) ? $0 : nil }
        let schedule = usable ?? ChannelScheduleBuilder.buildSchedule(
            for: channel,
            at: now,
            credentialFingerprint: scheduleCredentialFingerprint
        )
        if let schedule {
            currentItem = schedule.nowPlaying?.item
            // Taken from the clock rather than the baked value, so any lag between the
            // schedule being built and the channel being tuned cannot offset playback.
            seekOffset = schedule.livePlayback(at: now)?.elapsedSeconds ?? schedule.elapsedSeconds
            print("[Plex90] Schedule: now=\"\(schedule.nowPlaying?.item.title ?? "nil")\" elapsed=\(schedule.elapsedSeconds)s next=\"\(schedule.upNext?.item.title ?? "nil")\" precomputed=\(precomputedSchedule != nil)")
        } else {
            currentItem = pool.randomElement()
            seekOffset = 0
            print("[Plex90] No schedule, random pick: \"\(currentItem?.title ?? "nil")\"")
        }
        loadCurrentItem()
    }

    /// User-initiated channel change. Emits `channel.tuned` with the calling `method`,
    /// then delegates to `selectChannel` for the actual work.
    ///
    /// One choke point on purpose: the view layer never calls `Analytics.track` for
    /// tuning, so a new tune surface (e.g. a future voice command) that forgets to
    /// pass a method here still doesn't accidentally start double-counting.
    func tuneChannelFromUser(
        _ channel: Channel,
        method: AnalyticsTuneMethod,
        precomputedSchedule: ChannelSchedule? = nil
    ) {
        Analytics.track(.channelTuned(
            channelNumber: channel.number,
            backend: analyticsBackend,
            method: method,
            channel: AnalyticsChannelDescriptor.describe(channel)
        ))
        selectChannel(channel, precomputedSchedule: precomputedSchedule)
    }

    func nextChannel() {
        guard let current = currentChannel,
              let idx = channels.firstIndex(where: { $0.id == current.id }),
              channels.count > 1 else { return }
        tuneChannelFromUser(channels[(idx + 1) % channels.count], method: .next)
    }

    func previousChannel() {
        guard let current = currentChannel,
              let idx = channels.firstIndex(where: { $0.id == current.id }),
              channels.count > 1 else { return }
        tuneChannelFromUser(channels[(idx - 1 + channels.count) % channels.count], method: .previous)
    }
}

// MARK: - Top Shelf snapshot

extension AppState {
    /// Denormalise "what is on now" for the Top Shelf extension.
    ///
    /// The extension cannot reach the app's manifests, snapshot or Keychain, so
    /// rather than hand it credentials and duplicate the scheduling rules, the
    /// app writes the answer out. Cheap to produce (the schedules are already
    /// built) and it keeps every scheduling decision in one place.
    ///
    /// Safe to call before the App Group exists: the write no-ops and the Top
    /// Shelf keeps showing its static image.
    func refreshTopShelfSnapshot() {
        guard TopShelfStore.containerURL != nil else {
            print("[Plex90] TOPSHELF: container unavailable — App Group not granted to this process")
            return
        }

        let api = apiForServer(selectedServers.first)
        var entries: [TopShelfSnapshot.Entry] = []

        for channel in channels.prefix(20) {
            guard let schedule = ChannelScheduleBuilder.buildSchedule(
                for: channel,
                credentialFingerprint: scheduleCredentialFingerprint
            ), let now = schedule.nowPlaying else { continue }

            entries.append(
                TopShelfSnapshot.Entry(
                    channelID: channel.id,
                    channelNumber: channel.number,
                    channelName: channel.name,
                    title: now.item.isMusicVideo ? now.item.musicDisplayLine : now.item.title,
                    startUnix: Int(now.startTime.timeIntervalSince1970),
                    endUnix: Int(now.endTime.timeIntervalSince1970),
                    imageURL: api.thumbnailURL(for: now.item)?.absoluteString
                )
            )
        }

        guard !entries.isEmpty else {
            print("[Plex90] TOPSHELF: no channel had a live nowPlaying across \(channels.prefix(20).count) checked — writing nothing")
            return
        }
        TopShelfStore.write(
            TopShelfSnapshot(generatedUnix: Int(Date().timeIntervalSince1970), entries: entries)
        )
        print("[Plex90] TOPSHELF: wrote \(entries.count) entries")
    }
}
