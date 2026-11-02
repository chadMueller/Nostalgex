import Foundation

// MARK: - Resolved manifest block (with media item)

struct ManifestBlock {
    let item: PlexMediaItem
    let startTime: Date
    let endTime: Date

    var durationSeconds: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

// MARK: - What the other channels have on, by title

/// Every block the lineup's channels already air on a day, by title (the manifest's key), so a
/// channel packing its day can see where a title is on elsewhere. `overlap` is the seconds of
/// [start, end) another channel airs the title for. Mirrors `makeOccupancy` in
/// scripts/nostalgex-daily-manifest.js.
struct ScheduleOccupancy {
    private struct Span {
        let channelID: Int
        let start: Int
        let end: Int
    }

    private var byKey: [String: [Span]] = [:]

    mutating func add(channelID: Int, key: String, start: Int, end: Int) {
        guard end > start else { return }
        byKey[key, default: []].append(Span(channelID: channelID, start: start, end: end))
    }

    func overlap(key: String, start: Int, end: Int, excludingChannel channelID: Int) -> Int {
        guard let spans = byKey[key] else { return 0 }
        var seconds = 0
        for s in spans where s.channelID != channelID {
            let lo = max(start, s.start), hi = min(end, s.end)
            if hi > lo { seconds += hi - lo }
        }
        return seconds
    }
}

// MARK: - Builds and caches one 24h EPG per channel per local calendar day

enum DailyManifestScheduler {

    // MARK: - In-memory memo
    //
    // A day's blocks are a pure function of (channel pool, day, credentials), but callers
    // are SwiftUI bodies: the mini guide rebuilds a schedule for *every* channel card on
    // every body evaluation, and the body re-evaluates on every focus move. Without this
    // memo each of those rebuilds re-hashes the pool, re-reads the manifest off disk and
    // re-decodes it — tens of milliseconds of main-thread work per remote press.

    private static let memoLock = NSLock()
    private static var memo: [String: [ManifestBlock]] = [:]
    private static var memoOrder: [String] = []
    private static let memoLimit = 256

    private static func memoized(_ key: String) -> [ManifestBlock]? {
        memoLock.lock()
        defer { memoLock.unlock() }
        return memo[key]
    }

    private static func storeMemo(_ blocks: [ManifestBlock], for key: String) {
        memoLock.lock()
        defer { memoLock.unlock() }
        if memo[key] == nil {
            memoOrder.append(key)
            if memoOrder.count > memoLimit {
                memo.removeValue(forKey: memoOrder.removeFirst())
            }
        }
        memo[key] = blocks
    }

    /// Drop the memo. Must be called whenever the on-disk manifests or the channel pools
    /// change underneath it (library reload, manifest wipe), otherwise the guide keeps
    /// serving yesterday's lineup.
    static func invalidateMemo() {
        memoLock.lock()
        defer { memoLock.unlock() }
        memo.removeAll()
        memoOrder.removeAll()
    }

    // MARK: - The lineup
    //
    // Each channel's day used to be packed on its own, so a film in several pools aired on two
    // or more channels at once for most of the day (94 to 95% of minutes on a 128-channel test
    // library, 2026-11-01). The guide's channels are registered here and a day is packed for
    // all of them together (packLineupDay), each giving way where another has the title.

    private static let lineupLock = NSLock()
    private static var lineup: [Channel] = []
    private static var lineupFingerprint: String?
    /// Serialises packing: two threads asking for an unpacked day pack it once.
    private static let packLock = NSLock()

    /// How far down its running order a channel looks for a programme no other channel has on
    /// in the same slot. 4 already left nothing avoidable on a 128-channel test library; 8 is
    /// the margin. Mirrors `LOOKAHEAD` in scripts/nostalgex-daily-manifest.js.
    static let lookahead = 8

    /// The guide's channels, with the pools they air from, for the sign-in whose manifests they
    /// are packed into. AppState sets it whenever its `channels` change. A schedule asked for
    /// under any other fingerprint (another sign-in, a test) packs each channel on its own,
    /// as every build up to 1.0.29 did.
    static func setLineup(_ channels: [Channel], credentialFingerprint: String?) {
        lineupLock.lock()
        defer { lineupLock.unlock() }
        lineup = channels
        lineupFingerprint = channels.isEmpty ? nil : credentialFingerprint
    }

    private static func registeredLineup(for credentialFingerprint: String) -> [Channel] {
        lineupLock.lock()
        defer { lineupLock.unlock() }
        return lineupFingerprint == credentialFingerprint ? lineup : []
    }

    /// The order channels claim programmes in: channels whose pool changes with the hour
    /// (`timeRestrictions`) last, so no other channel's day depends on when a device first
    /// built it; then by id, so the lowest keeps a title, as `resolveConflicts` does.
    /// Mirrors `sortByLineupPriority` in scripts/nostalgex-daily-manifest.js.
    static func lineupPriority(_ a: Channel, _ b: Channel) -> Bool {
        let ra = a.timeRestrictions == nil ? 0 : 1
        let rb = b.timeRestrictions == nil ? 0 : 1
        if ra != rb { return ra < rb }
        return a.id < b.id
    }

    private static func memoKey(channelID: Int, dayKey: String, pool: [PlexMediaItem], credentialFingerprint: String) -> String {
        [
            credentialFingerprint,
            String(channelID),
            dayKey,
            String(pool.count),
            pool.first?.id ?? "",
            pool.last?.id ?? ""
        ].joined(separator: "|")
    }

    static func blocks(
        for channel: Channel,
        at now: Date = Date(),
        credentialFingerprint: String,
        calendar: Calendar = .current
    ) -> [ManifestBlock] {
        let pool = channel.filteredPool().filter { $0.duration > 0 }
        guard !pool.isEmpty else { return [] }

        let dayKey = DailyManifestStore.localDayKey(for: now, calendar: calendar)

        // Pool shape is part of the key because `filteredPool()` is time-of-day dependent:
        // a channel that gates R-rated content flips pools at a fixed hour and must not
        // keep serving the schedule built from the other pool. Pools that change without
        // changing shape (a library refresh) are covered by `invalidateMemo()`.
        let key = memoKey(channelID: channel.id, dayKey: dayKey, pool: pool, credentialFingerprint: credentialFingerprint)
        if let hit = memoized(key) { return hit }

        let poolFP = DailyManifestStore.poolFingerprint(ratingKeys: pool.map(\.id))
        if let cached = DailyManifestStore.load(
            channelId: channel.id,
            dayKey: dayKey,
            credentialFingerprint: credentialFingerprint,
            expectedPoolFingerprint: poolFP
        ) {
            let resolved = resolveBlocks(cached.blocks, pool: pool)
            storeMemo(resolved, for: key)
            return resolved
        }

        packLock.lock()
        defer { packLock.unlock() }
        // Another thread may have packed the day while this one waited.
        if let hit = memoized(key) { return hit }

        // The whole lineup's day, this channel in its place with the pool it was asked with.
        // One the guide doesn't carry packs after the lineup, against it, and is seen by
        // nothing, so it never changes what the guide's channels air.
        var entries: [LineupEntry] = []
        var seen = Set<Int>()
        var isMember = false
        for c in registeredLineup(for: credentialFingerprint) where seen.insert(c.id).inserted {
            if c.id == channel.id {
                entries.append(LineupEntry(channel: channel, pool: pool))
                isMember = true
            } else {
                let p = c.filteredPool().filter { $0.duration > 0 }
                if !p.isEmpty { entries.append(LineupEntry(channel: c, pool: p)) }
            }
        }
        let extra = isMember ? nil : LineupEntry(channel: channel, pool: pool)
        let packed = packLineupDay(entries, extra: extra, at: now,
                                   credentialFingerprint: credentialFingerprint, calendar: calendar)
        return packed[channel.id] ?? []
    }

    struct LineupEntry {
        let channel: Channel
        let pool: [PlexMediaItem]
    }

    /// Packs one local day for the lineup's channels whose day isn't stored yet, together, so
    /// no title is on two of them at once. Channels pack in `lineupPriority` order: each
    /// one's day is its own running order (packDay) except where a programme is already on
    /// another channel in that slot. Days already stored, and the programmes that run over
    /// from the day before, are fixed: what airs now never moves because another channel's
    /// pool changed. Saves and memoises every day it packs; returns them by channel id.
    /// Mirrors `packLineupDay` in scripts/nostalgex-daily-manifest.js.
    static func packLineupDay(
        _ entries: [LineupEntry],
        extra: LineupEntry?,
        at now: Date,
        credentialFingerprint: String,
        calendar: Calendar = .current
    ) -> [Int: [ManifestBlock]] {
        let dayStart = DailyManifestStore.startOfLocalDay(for: now, calendar: calendar)
        let dayEnd = DailyManifestStore.startOfNextLocalDay(after: now, calendar: calendar)
        let dayStartUnix = Int(dayStart.timeIntervalSince1970)
        let dayKey = DailyManifestStore.localDayKey(for: now, calendar: calendar)
        let dayNumber = DailyManifestStore.localDayNumber(for: now, calendar: calendar)
        // By the calendar, not 86,400 s: the day after the clocks go forward, 24 hours before
        // midnight is two days back, and the no-repeat check would read the wrong day.
        let yesterdayKey = DailyManifestStore.previousLocalDayKey(before: now, calendar: calendar)

        var all = entries.sorted { lineupPriority($0.channel, $1.channel) }
        let extraID = extra?.channel.id
        if let extra { all.append(extra) }

        var occupancy = ScheduleOccupancy()
        var yesterday: [Int: [StoredManifestBlock]] = [:]
        for entry in all {
            let id = entry.channel.id
            let prev = DailyManifestStore.storedBlocks(channelId: id, dayKey: yesterdayKey,
                                                       credentialFingerprint: credentialFingerprint)
            yesterday[id] = prev
            // What runs past midnight from yesterday is on air today too (the guide's
            // channels' only: one off the guide is seen by nothing).
            guard id != extraID else { continue }
            for b in prev where b.endUnix > dayStartUnix {
                occupancy.add(channelID: id, key: b.ratingKey, start: b.startUnix, end: b.endUnix)
            }
        }

        var toPack: [(entry: LineupEntry, fingerprint: String)] = []
        for entry in all {
            let fp = DailyManifestStore.poolFingerprint(ratingKeys: entry.pool.map(\.id))
            if let cached = DailyManifestStore.load(channelId: entry.channel.id, dayKey: dayKey,
                                                    credentialFingerprint: credentialFingerprint,
                                                    expectedPoolFingerprint: fp) {
                if entry.channel.id != extraID {
                    for b in cached.blocks {
                        occupancy.add(channelID: entry.channel.id, key: b.ratingKey, start: b.startUnix, end: b.endUnix)
                    }
                }
                storeMemo(resolveBlocks(cached.blocks, pool: entry.pool),
                          for: memoKey(channelID: entry.channel.id, dayKey: dayKey, pool: entry.pool,
                                       credentialFingerprint: credentialFingerprint))
            } else {
                toPack.append((entry, fp))
            }
        }

        var packedByChannel: [Int: [ManifestBlock]] = [:]
        for (entry, fp) in toPack {
            let channel = entry.channel
            let prev = yesterday[channel.id] ?? []
            let packed = packDay(
                pool: entry.pool,
                dayStart: dayStart,
                dayEnd: dayEnd,
                dayNumber: dayNumber,
                channelId: channel.id,
                isPremiereChannel: channel.isPremiereChannel,
                yesterdayAiredKeys: Set(prev.map(\.ratingKey)),
                yesterdayLastItemID: prev.last?.ratingKey,
                occupancy: occupancy
            )
            let stored = packed.map {
                StoredManifestBlock(
                    ratingKey: $0.item.id,
                    startUnix: Int($0.startTime.timeIntervalSince1970),
                    endUnix: Int($0.endTime.timeIntervalSince1970)
                )
            }
            DailyManifestStore.save(DailyManifestFile(
                schemaVersion: DailyManifestStore.schemaVersion,
                channelId: channel.id,
                dayKey: dayKey,
                credentialFingerprint: credentialFingerprint,
                poolFingerprint: fp,
                blocks: stored
            ))
            storeMemo(packed, for: memoKey(channelID: channel.id, dayKey: dayKey, pool: entry.pool,
                                           credentialFingerprint: credentialFingerprint))
            packedByChannel[channel.id] = packed
            if channel.id != extraID {
                for b in stored {
                    occupancy.add(channelID: channel.id, key: b.ratingKey, start: b.startUnix, end: b.endUnix)
                }
            }
        }
        return packedByChannel
    }

    static func blocksInRange(
        for channel: Channel,
        from: Date,
        to: Date,
        credentialFingerprint: String,
        calendar: Calendar = .current
    ) -> [ManifestBlock] {
        var result: [ManifestBlock] = []
        var cursor = DailyManifestStore.startOfLocalDay(for: from, calendar: calendar)
        let endDay = DailyManifestStore.startOfLocalDay(for: to, calendar: calendar)

        while cursor <= endDay {
            let dayBlocks = blocks(
                for: channel,
                at: cursor.addingTimeInterval(3600),
                credentialFingerprint: credentialFingerprint,
                calendar: calendar
            )
            for block in dayBlocks where block.endTime > from && block.startTime < to {
                result.append(block)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return result.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Packing

    /// `dayEnd` is the next local midnight, not `dayStart + 86400`: a 25-hour day packed for
    /// 24 left its last hour empty, and a 23-hour one ran an hour into the next day.
    /// Which of the first `lookahead` programmes in `queue` airs at `t`: the first one no other
    /// channel has on during its slot; failing that, nil when `mustFit` (the caller has
    /// something else to try), else the one that overlaps least (the earliest of those).
    /// `playSeconds(i)` is how long candidate i would run from `t`. `avoidKey` (the title that
    /// just played here) is passed over while there is anything else, and a later part of a
    /// story never goes ahead of an earlier one waiting before it. With no occupancy, or
    /// nothing on elsewhere, this is always 0: the channel's own order. Mirrors
    /// `pickCandidate` in scripts/nostalgex-daily-manifest.js.
    static func pickCandidate(
        _ queue: [PlexMediaItem],
        at t: Int,
        playSeconds: (Int) -> Int,
        occupancy: ScheduleOccupancy?,
        channelId: Int,
        avoidKey: String?,
        mustFit: Bool
    ) -> Int? {
        let n = min(lookahead, queue.count)
        var best = -1
        var bestOverlap = Int.max
        for i in 0..<n {
            let item = queue[i]
            if n > 1, let avoidKey, item.id == avoidKey { continue }
            if i > 0, waitsForEarlierPart(queue, i) { continue }
            let overlap = occupancy?.overlap(key: item.id, start: t, end: t + playSeconds(i), excludingChannel: channelId) ?? 0
            if overlap == 0 { return i }
            if overlap < bestOverlap {
                bestOverlap = overlap
                best = i
            }
        }
        if mustFit { return nil }
        return best >= 0 ? best : 0
    }

    /// A later part may not jump ahead of an earlier part of the same story waiting before it.
    private static func waitsForEarlierPart(_ queue: [PlexMediaItem], _ i: Int) -> Bool {
        guard let mark = SchedulePoolOrdering.sequelMark(queue[i]) else { return false }
        for k in 0..<i {
            if let other = SchedulePoolOrdering.sequelMark(queue[k]),
               other.base == mark.base, other.ordinal < mark.ordinal {
                return true
            }
        }
        return false
    }

    private static func packDay(
        pool: [PlexMediaItem],
        dayStart: Date,
        dayEnd: Date,
        dayNumber: Int,
        channelId: Int,
        isPremiereChannel: Bool,
        yesterdayAiredKeys: Set<String>,
        yesterdayLastItemID: String?,
        occupancy: ScheduleOccupancy? = nil
    ) -> [ManifestBlock] {
        let totalPoolSec = pool.reduce(0) { $0 + $1.duration * 60 }
        guard totalPoolSec > 0 else { return [] }

        let unplayed = pool.filter { !yesterdayAiredKeys.contains($0.id) }
        let dayStartUnix = Int(dayStart.timeIntervalSince1970)
        // Interleave for variety, then reunite multi-part stories. On the premiere
        // channel only, this week's additions are first slotted at the prime-time anchor
        // so they air while people are watching - and because that runs before the
        // sequel grouping, a just-added Part 1 drags its Part 2 with it.
        //
        // Every other channel skips the promotion: a new title is in several pools, and
        // promoting it on each one is what made Point Break premiere on five channels at
        // the same moment. Elsewhere it just enters the rotation.
        let interleaved = SchedulePoolOrdering.interleaveByShow(
            unplayed, seed: channelId, dayNumber: dayNumber
        )
        let promoted = isPremiereChannel
            ? SchedulePoolOrdering.promoteRecentlyAdded(
                interleaved,
                dayStartUnix: dayStartUnix,
                channelId: channelId
              )
            : interleaved
        var unplayedOrdered = SchedulePoolOrdering.groupSequelParts(promoted)

        // Cross-day seam: this function only ever sees one day at a time, so with no
        // guard here, whatever the pool ordering picks to lead off today has no idea it
        // might be the exact title that just finished airing seconds before midnight --
        // the same coincidence as the wraparound seam below, one level up. Move it later
        // in today's order instead of opening the day with a repeat.
        if let yesterdayLastItemID, unplayedOrdered.count > 1,
           unplayedOrdered.first?.id == yesterdayLastItemID {
            let duplicate = unplayedOrdered.removeFirst()
            unplayedOrdered.append(duplicate)
        }

        var blocks: [ManifestBlock] = []
        var t = dayStart

        // In the channel's order, except that a programme another channel has on in the same
        // slot waits for a later one (pickCandidate). It stays in the queue, so it still airs
        // today if the day has room, and counts as unplayed tomorrow if not. When nothing
        // waiting fits, the day goes on with the filler loop below, which holds the whole pool.
        var queue = unplayedOrdered.filter { $0.duration > 0 }
        while !queue.isEmpty, t < dayEnd {
            // Scoped, so the snapshot the closure reads is released before the queue changes
            // (holding it would copy the whole queue on every programme placed).
            let picked: Int? = {
                let current = queue
                return pickCandidate(current, at: Int(t.timeIntervalSince1970),
                                     playSeconds: { current[$0].duration * 60 },
                                     occupancy: occupancy, channelId: channelId,
                                     avoidKey: nil, mustFit: true)
            }()
            guard let j = picked else { break }
            let item = queue.remove(at: j)
            let end = t.addingTimeInterval(TimeInterval(item.duration * 60))
            blocks.append(ManifestBlock(item: item, startTime: t, endTime: end))
            t = end
        }

        if t < dayEnd {
            let orderedFull = SchedulePoolOrdering.groupSequelParts(
                SchedulePoolOrdering.interleaveByShow(pool, seed: channelId, dayNumber: dayNumber &+ 1)
            )
            let goldenShift = Int(Double(totalPoolSec) * 0.6180339887)
            let offsetSec = (dayNumber * goldenShift) % totalPoolSec

            var posInLoop = offsetSec
            var cycleIndex = 0
            var elapsed = 0
            for i in 0..<orderedFull.count {
                let d = orderedFull[i].duration * 60
                if elapsed + d > offsetSec {
                    cycleIndex = i
                    posInLoop = offsetSec - elapsed
                    break
                }
                elapsed += d
            }

            // The golden-ratio offset picks an arbitrary starting point in the full pool
            // with no idea what the primary pass just finished playing. On a small pool --
            // most of this app's niche channels: MINION HQ, BUDDIES, DIZNEY TOONS, DIZ
            // FLICKS, LAST ACTION HEROES -- the primary pass exhausts within a couple of
            // hours, so this wraparound path runs on nearly every day, and the offset
            // landing on the same title that just finished is common, not rare: the same
            // film played twice back to back with zero gap (Toy Story, Cobra, Waterworld,
            // Heavyweights, Dirty Dancing all reproduced this on device). If the seam lands
            // on a repeat, start from the next item instead.
            // Falls back to yesterday's last item when blocks is still empty here: that
            // happens only when today's primary pass placed nothing at all (an empty or
            // fully-exhausted unplayed pool), in which case the wraparound's first pick
            // *is* the item opening the day across the midnight boundary, and the cross-day
            // guard above never got a chance to run because there was nothing to reorder.
            if orderedFull.count > 1, let lastPlayed = blocks.last?.item.id ?? yesterdayLastItemID,
               orderedFull[cycleIndex].id == lastPlayed {
                cycleIndex = (cycleIndex + 1) % orderedFull.count
                posInLoop = 0
            }

            // The loop as a queue from the cycle's start: what airs goes to the back, so with
            // nothing on elsewhere this is the cycle in order. The first programme starts part
            // way in (posInLoop) only if it airs first; one picked ahead of it starts at 0.
            var loop = (Array(orderedFull[cycleIndex...]) + Array(orderedFull[..<cycleIndex]))
                .filter { $0.duration > 0 }
            var first = true
            while t < dayEnd, !loop.isEmpty {
                let remainingDay = Int(dayEnd.timeIntervalSince(t))
                let lead = first ? posInLoop : 0
                let lastKey = blocks.last?.item.id ?? yesterdayLastItemID
                // Scoped like the primary pass: no copy of the loop per programme.
                let j: Int = {
                    let current = loop
                    return pickCandidate(current, at: Int(t.timeIntervalSince1970),
                                         playSeconds: { min(current[$0].duration * 60 - ($0 == 0 ? lead : 0), remainingDay) },
                                         occupancy: occupancy, channelId: channelId,
                                         avoidKey: lastKey, mustFit: false) ?? 0
                }()
                let playSec = min(loop[j].duration * 60 - (j == 0 ? lead : 0), remainingDay)
                let item = loop.remove(at: j)
                loop.append(item)
                first = false

                let end = t.addingTimeInterval(TimeInterval(playSec))
                blocks.append(ManifestBlock(item: item, startTime: t, endTime: end))
                t = end
            }
        }

        return blocks
    }

    private static func resolveBlocks(_ stored: [StoredManifestBlock], pool: [PlexMediaItem]) -> [ManifestBlock] {
        let lookup = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stored.compactMap { row in
            guard let item = lookup[row.ratingKey] else { return nil }
            return ManifestBlock(
                item: item,
                startTime: Date(timeIntervalSince1970: Double(row.startUnix)),
                endTime: Date(timeIntervalSince1970: Double(row.endUnix))
            )
        }
    }
}
