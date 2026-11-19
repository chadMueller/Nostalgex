import Foundation

// MARK: - Schedule entry (one program block in the guide)

struct ScheduleEntry: Identifiable {
    let id: String
    let item: PlexMediaItem
    let startTime: Date
    let endTime: Date
    let isNowPlaying: Bool
    /// True if this item is also playing on another channel right now
    var isConflict: Bool = false

    var durationSeconds: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

// MARK: - Channel schedule (all visible entries for one channel)

struct ChannelSchedule {
    var entries: [ScheduleEntry]
    let nowPlaying: ScheduleEntry?
    let upNext: ScheduleEntry?
    let progress: Double        // 0.0-1.0 through current item
    let elapsedSeconds: Int     // seconds into current item

    /// Whether this schedule still describes what is on right now.
    ///
    /// `nowPlaying` and `elapsedSeconds` are baked in when the schedule is built, so a
    /// schedule the guide built moments ago can already be describing the previous
    /// programme. Tuning from a stale one seeks to the wrong offset, or past a boundary
    /// and onto the programme queued next.
    func isCurrent(at now: Date = Date()) -> Bool {
        guard let np = nowPlaying else { return false }
        return np.startTime <= now && now < np.endTime
    }

    /// Wall-clock position within the current program (for live UI; use with `TimelineView`).
    func livePlayback(at now: Date = Date()) -> (elapsedSeconds: Int, progress: Double, totalSeconds: Int)? {
        guard let np = nowPlaying else { return nil }
        let totalSeconds = max(1, np.item.slotSeconds)
        let elapsed = max(0, min(totalSeconds, Int(now.timeIntervalSince(np.startTime))))
        let blockDuration = np.durationSeconds
        let progress = blockDuration > 0
            ? min(1, now.timeIntervalSince(np.startTime) / blockDuration)
            : 0
        return (elapsed, progress, totalSeconds)
    }
}

// MARK: - Schedule builder

enum ChannelScheduleBuilder {

    /// Build schedule from the persisted daily manifest for this channel.
    static func buildSchedule(
        for channel: Channel,
        at now: Date = Date(),
        credentialFingerprint: String
    ) -> ChannelSchedule? {
        // CH 299, LOCAL WEATHER: hour blocks of the loop, not a manifest (AppState+Weather.swift).
        if channel.isWeather { return WeatherChannel.schedule(at: now) }
        let nowUnix = Int(now.timeIntervalSince1970)
        let windowStartUnix = (nowUnix / 1800) * 1800
        // 24-hour rolling horizon. Fetch across day boundaries so late-night
        // users (e.g. 11 PM) get a full 24h of guide, not just until midnight.
        let windowEndUnix = windowStartUnix + 86400
        let windowStart = Date(timeIntervalSince1970: Double(windowStartUnix))
        let windowEnd = Date(timeIntervalSince1970: Double(windowEndUnix))

        let dayBlocks = DailyManifestScheduler.blocksInRange(
            for: channel,
            from: windowStart,
            to: windowEnd,
            credentialFingerprint: credentialFingerprint
        )
        guard !dayBlocks.isEmpty else { return nil }

        var entries: [ScheduleEntry] = []
        var nowPlayingEntry: ScheduleEntry?
        var upNextEntry: ScheduleEntry?

        for block in dayBlocks {
            guard block.endTime > windowStart, block.startTime < windowEnd else { continue }
            let isNow = block.startTime <= now && block.endTime > now
            let entry = ScheduleEntry(
                id: "\(block.item.id)_\(Int(block.startTime.timeIntervalSince1970))",
                item: block.item,
                startTime: block.startTime,
                endTime: block.endTime,
                isNowPlaying: isNow
            )
            entries.append(entry)
            if isNow { nowPlayingEntry = entry }
        }

        if nowPlayingEntry == nil {
            nowPlayingEntry = entries.first { $0.startTime <= now && $0.endTime > now }
        }

        if let nowIdx = entries.firstIndex(where: { $0.isNowPlaying }),
           nowIdx + 1 < entries.count {
            upNextEntry = entries[nowIdx + 1]
        }

        let progress: Double
        let elapsedSeconds: Int
        if let np = nowPlayingEntry {
            let elapsed = now.timeIntervalSince(np.startTime)
            let dur = np.durationSeconds
            progress = dur > 0 ? elapsed / dur : 0
            elapsedSeconds = max(0, Int(elapsed))
        } else {
            progress = 0
            elapsedSeconds = 0
        }

        return ChannelSchedule(
            entries: entries,
            nowPlaying: nowPlayingEntry,
            upNext: upNextEntry,
            progress: progress,
            elapsedSeconds: elapsedSeconds
        )
    }

    /// Build every schedule entry that intersects the [from, to] range for a channel.
    static func buildScheduleRange(
        for channel: Channel,
        from: Date,
        to: Date,
        credentialFingerprint: String
    ) -> [ScheduleEntry] {
        let blocks = DailyManifestScheduler.blocksInRange(
            for: channel,
            from: from,
            to: to,
            credentialFingerprint: credentialFingerprint
        )
        return blocks.map { block in
            ScheduleEntry(
                id: "\(block.item.id)_\(Int(block.startTime.timeIntervalSince1970))",
                item: block.item,
                startTime: block.startTime,
                endTime: block.endTime,
                isNowPlaying: false
            )
        }
    }

    /// Detect and resolve cross-channel conflicts where the same item plays
    /// on multiple channels simultaneously. Lower channel IDs win; the higher
    /// channel's nowPlaying is bumped to its upNext.
    static func resolveConflicts(_ schedules: inout [Int: ChannelSchedule]) {
        var nowPlayingByItem: [String: [(channelID: Int, schedule: ChannelSchedule)]] = [:]
        for (channelID, schedule) in schedules {
            guard let np = schedule.nowPlaying else { continue }
            nowPlayingByItem[np.item.ratingKey, default: []].append((channelID, schedule))
        }

        for (_, group) in nowPlayingByItem where group.count > 1 {
            let sorted = group.sorted { $0.channelID < $1.channelID }
            let winner = sorted[0]
            let losers = sorted.dropFirst()

            for loser in losers {
                var schedule = loser.schedule
                let oldTitle = schedule.nowPlaying?.item.title ?? "?"

                for i in schedule.entries.indices {
                    if schedule.entries[i].isNowPlaying {
                        schedule.entries[i] = ScheduleEntry(
                            id: schedule.entries[i].id,
                            item: schedule.entries[i].item,
                            startTime: schedule.entries[i].startTime,
                            endTime: schedule.entries[i].endTime,
                            isNowPlaying: false,
                            isConflict: true
                        )
                        break
                    }
                }

                if let upNext = schedule.upNext {
                    let newNowPlaying = ScheduleEntry(
                        id: upNext.id,
                        item: upNext.item,
                        startTime: upNext.startTime,
                        endTime: upNext.endTime,
                        isNowPlaying: true
                    )

                    let newUpNext: ScheduleEntry? = {
                        guard let idx = schedule.entries.firstIndex(where: { $0.id == upNext.id }),
                              idx + 1 < schedule.entries.count else { return nil }
                        return schedule.entries[idx + 1]
                    }()

                    schedule = ChannelSchedule(
                        entries: schedule.entries,
                        nowPlaying: newNowPlaying,
                        upNext: newUpNext,
                        progress: 0,
                        elapsedSeconds: 0
                    )
                    print("[Plex90] CONFLICT: \"\(oldTitle)\" on CH \(loser.channelID) also on CH \(winner.channelID), bumped to \"\(upNext.item.title)\"")
                } else {
                    print("[Plex90] CONFLICT: \"\(oldTitle)\" on CH \(loser.channelID) also on CH \(winner.channelID), no upNext available")
                }

                schedules[loser.channelID] = schedule
            }
        }
    }

    static func findConflict(
        item: PlexMediaItem,
        excludingChannelID: Int,
        in channels: [Channel],
        at now: Date = Date(),
        credentialFingerprint: String
    ) -> Int? {
        for channel in channels where channel.id != excludingChannelID {
            guard let schedule = buildSchedule(for: channel, at: now, credentialFingerprint: credentialFingerprint),
                  let np = schedule.nowPlaying else { continue }
            if np.item.ratingKey == item.ratingKey {
                return channel.id
            }
        }
        return nil
    }

    static func widthFraction(for entry: ScheduleEntry, windowStart: Date, windowDuration: TimeInterval = 7200) -> CGFloat {
        let visStart = max(entry.startTime, windowStart)
        let windowEnd = windowStart.addingTimeInterval(windowDuration)
        let visEnd = min(entry.endTime, windowEnd)
        let visDuration = visEnd.timeIntervalSince(visStart)
        return max(0, CGFloat(visDuration / windowDuration))
    }

    static func timeSlotLabels(at now: Date = Date(), slotOffset: Int = 0) -> [String] {
        let nowUnix = Int(now.timeIntervalSince1970)
        let windowStartUnix = (nowUnix / 1800) * 1800 + (slotOffset * 1800)

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        return (0..<4).map { i in
            let slotTime = Date(timeIntervalSince1970: Double(windowStartUnix + i * 1800))
            return formatter.string(from: slotTime)
        }
    }

    static func visibleWindowStart(at now: Date = Date(), slotOffset: Int = 0) -> Date {
        let nowUnix = Int(now.timeIntervalSince1970)
        let snapped = (nowUnix / 1800) * 1800 + (slotOffset * 1800)
        return Date(timeIntervalSince1970: Double(snapped))
    }

    static func windowStart(at now: Date = Date()) -> Date {
        let nowUnix = Int(now.timeIntervalSince1970)
        let snapped = (nowUnix / 1800) * 1800
        return Date(timeIntervalSince1970: Double(snapped))
    }
}
