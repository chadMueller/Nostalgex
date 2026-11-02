import Foundation

/// On-device timing of the schedule pack, the work a tune waits for on the main thread when
/// the day isn't packed yet (PlayerView, NowPlayingPanel, the advance at a programme's end).
///
/// Triggered like the playback soak: a file `soak.trigger` in the app's Caches/Nostalgex
/// folder whose first line is `sched-timing` (or `sched-timing:N` for N runs, default 3),
/// dropped with `devicectl device copy to`, then a launch. scripts/qa/appletv-schedule-timing.sh
/// does all of it. Lines go to `soak-results.log` and stdout, ending `[sched-timing] done`.
///
/// It packs in scratch manifest folders seeded with this TV's own yesterday, under scratch
/// fingerprints: one with no lineup (each channel alone) and one with the guide's lineup
/// registered next to the app's own (setAdditionalLineup). The app's registration is never
/// changed, so a guide build running at the same time packs and saves the TV's own days
/// across the lineup as usual.
/// Each run, on the main actor:
///   - alone: every channel's today packed on its own, as every build before the lineup did,
///     with the slowest single channel (what one tune used to wait for at most);
///   - lineup: the first channel's today, which packs the whole lineup (what a tune waits for
///     now when the guide hasn't built the day), then the rest from memory;
///   - tune: ChannelScheduleBuilder.buildSchedule for one channel with nothing stored, today
///     and tomorrow, the whole of a main-thread tune's wait.
@MainActor
enum ScheduleTiming {
    static var requestedRuns: Int? {
        guard let url = PlaybackSoak.triggerURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let first = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.hasPrefix("sched-timing") else { return nil }
        return Int(first.dropFirst("sched-timing:".count)) ?? 3
    }

    static var isRequested: Bool { requestedRuns != nil }

    static func run(appState: AppState) {
        let runs = max(1, requestedRuns ?? 3)
        if let t = PlaybackSoak.triggerURL { try? FileManager.default.removeItem(at: t) }  // one run per trigger
        if let r = PlaybackSoak.resultsURL { try? FileManager.default.removeItem(at: r) }
        func emit(_ line: String) { PlaybackSoak.emit("[sched-timing] \(line)") }
        func ms(_ since: Date) -> Double { Date().timeIntervalSince(since) * 1000 }
        func fmt(_ x: Double) -> String { String(format: "%.0f", x) }

        let channels = appState.channels
        let realFP = appState.scheduleCredentialFingerprint
        let scratch = "timing-\(realFP.prefix(12))"
        let scratchAlone = "timing-alone-\(realFP.prefix(12))"
        let now = Date()
        let yesterday = DailyManifestStore.previousLocalDayKey(before: now)
        defer {
            DailyManifestScheduler.setAdditionalLineup([], credentialFingerprint: scratch)
            DailyManifestStore.clearAll(credentialFingerprint: scratch)
            DailyManifestStore.clearAll(credentialFingerprint: scratchAlone)
            emit("done")
        }
        guard !channels.isEmpty else {
            emit("no channels in the guide; nothing to time")
            return
        }
        let pools = channels.map { $0.filteredPool().count }
        emit("start: \(channels.count) channels, \(appState.allItems.count) items, pools \(pools.min() ?? 0) to \(pools.max() ?? 0), \(runs) runs, yesterday \(yesterday) seeded from this TV")

        /// Scratch folders with only this TV's yesterday in them, memo empty.
        func reset() {
            for fp in [scratch, scratchAlone] {
                DailyManifestStore.clearAll(credentialFingerprint: fp)
                DailyManifestStore.copyDays([yesterday], from: realFP, to: fp)
            }
            DailyManifestScheduler.invalidateMemo()
        }
        DailyManifestScheduler.setAdditionalLineup(channels, credentialFingerprint: scratch)

        var alone: [Double] = [], aloneMax: [Double] = [], lineup: [Double] = [], rest: [Double] = [], tune: [Double] = []
        for _ in 0..<runs {
            reset()
            var worst = 0.0
            let t0 = Date()
            for ch in channels {
                let t = Date()
                _ = DailyManifestScheduler.blocks(for: ch, at: now, credentialFingerprint: scratchAlone)
                worst = max(worst, ms(t))
            }
            alone.append(ms(t0))
            aloneMax.append(worst)

            reset()
            let t1 = Date()
            _ = DailyManifestScheduler.blocks(for: channels[0], at: now, credentialFingerprint: scratch)
            lineup.append(ms(t1))
            let t2 = Date()
            for ch in channels.dropFirst() {
                _ = DailyManifestScheduler.blocks(for: ch, at: now, credentialFingerprint: scratch)
            }
            rest.append(ms(t2))

            reset()
            let t3 = Date()
            _ = ChannelScheduleBuilder.buildSchedule(for: channels[channels.count / 2], at: now, credentialFingerprint: scratch)
            tune.append(ms(t3))
        }
        func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
        emit("alone (before): whole lineup \(fmt(median(alone))) ms, slowest single channel \(fmt(median(aloneMax))) ms; runs \(alone.map(fmt).joined(separator: ","))")
        emit("lineup (after): first tune packs the lineup's day \(fmt(median(lineup))) ms, every other channel then \(fmt(median(rest))) ms in all; runs \(lineup.map(fmt).joined(separator: ","))")
        emit("tune with nothing stored (after, today and tomorrow): \(fmt(median(tune))) ms; runs \(tune.map(fmt).joined(separator: ","))")
    }
}
