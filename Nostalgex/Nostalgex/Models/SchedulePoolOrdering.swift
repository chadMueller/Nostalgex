import Foundation

// MARK: - Deterministic pool ordering (shared by schedule + daily manifest)

enum SchedulePoolOrdering {

    // MARK: - Series order (EPISODE ORDER, I-103)

    /// Season and episode from an item's `seTag` ("S01E04", "E04", "S02"); a missing half reads as 0. Nil when
    /// the item carries neither. Mirrors `seriesNumber` in scripts/nostalgex-daily-manifest.js.
    static func seriesNumber(_ item: PlexMediaItem) -> (season: Int, episode: Int)? {
        guard let tag = item.seTag, !tag.isEmpty else { return nil }
        var season: Int?
        var episode: Int?
        var rest = Substring(tag)
        if rest.first == "S" {
            let digits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { return nil }
            season = n
            rest = rest.dropFirst(1 + digits.count)
        }
        if rest.first == "E" {
            let digits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { return nil }
            episode = n
            rest = rest.dropFirst(1 + digits.count)
        }
        guard rest.isEmpty, season != nil || episode != nil else { return nil }
        return (season ?? 0, episode ?? 0)
    }

    /// One show's episodes in series order: by season then episode, and an episode with no numbers after the
    /// numbered ones. Ties, and the unnumbered, keep the order they came in (the library's).
    static func inSeriesOrder(_ episodes: [PlexMediaItem]) -> [PlexMediaItem] {
        let keyed = episodes.enumerated().map { (index: $0.offset, number: seriesNumber($0.element), item: $0.element) }
        return keyed.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?):
                if x.season != y.season { return x.season < y.season }
                if x.episode != y.episode { return x.episode < y.episode }
                return a.index < b.index
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.index < b.index
            }
        }.map(\.item)
    }

    private static func showKey(_ item: PlexMediaItem) -> String {
        item.type == .episode ? item.title : "movie_\(item.ratingKey)"
    }

    /// For each episode in `pool`, the id of the one after it in its show's series order; the last is followed
    /// by the first. A show with one episode has no entry. This is what makes two episodes a pair.
    static func seriesNext(_ pool: [PlexMediaItem]) -> [String: String] {
        var groups: [String: [PlexMediaItem]] = [:]
        for item in pool where item.type == .episode { groups[item.title, default: []].append(item) }
        var next: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let ordered = inSeriesOrder(group)
            for (i, item) in ordered.enumerated() { next[item.id] = ordered[(i + 1) % ordered.count].id }
        }
        return next
    }

    /// Interleave items by show for the day (EPISODE ORDER, I-103).
    ///
    /// CLASSIC RERUNS: each show's episodes run in series order from a random spot, two back to back. The two are
    /// always consecutive episodes (7 then 8; the last of a season then the first of the next; the last of the
    /// series then the first). `seriesNext` says which episode follows which in the whole pool, so when `items`
    /// is the pool less what aired yesterday, an episode whose neighbour is missing airs alone, never beside a
    /// stranger. SHUFFLE: each show's episodes in random order, one at a time.
    ///
    /// A title alone in its group (every film, a show with one episode) draws nothing from the generator, so a
    /// channel of films is ordered exactly as it was before the setting existed.
    static func interleaveByShow(
        _ items: [PlexMediaItem],
        seed: Int,
        dayNumber: Int,
        order: EpisodeOrder = .classicReruns,
        seriesNext: [String: String]? = nil
    ) -> [PlexMediaItem] {
        guard items.count > 1 else { return items }

        var rng = SeededRNG(seed: UInt64(abs(seed) + 1) &+ UInt64(dayNumber))

        var showGroups: [[PlexMediaItem]] = []
        var groupsByTitle: [String: Int] = [:]

        for item in items {
            let key = showKey(item)
            if let idx = groupsByTitle[key] {
                showGroups[idx].append(item)
            } else {
                groupsByTitle[key] = showGroups.count
                showGroups.append([item])
            }
        }

        let next = order == .classicReruns ? (seriesNext ?? Self.seriesNext(items)) : [:]
        for i in showGroups.indices where showGroups[i].count > 1 {
            switch order {
            case .classicReruns:
                let ordered = inSeriesOrder(showGroups[i])
                let start = Int.random(in: 0..<ordered.count, using: &rng)
                showGroups[i] = Array(ordered[start...] + ordered[..<start])
            case .shuffle:
                showGroups[i].shuffle(using: &rng)
            }
        }
        showGroups.shuffle(using: &rng)

        var result: [PlexMediaItem] = []
        var groupPositions = Array(repeating: 0, count: showGroups.count)
        var groupIndex = 0
        var exhaustedCount = 0

        while exhaustedCount < showGroups.count {
            var attempts = 0
            while groupPositions[groupIndex] >= showGroups[groupIndex].count {
                groupIndex = (groupIndex + 1) % showGroups.count
                attempts += 1
                if attempts > showGroups.count { break }
            }
            if attempts > showGroups.count { break }

            let group = showGroups[groupIndex]
            let pos = groupPositions[groupIndex]
            var take = 1
            if order == .classicReruns, pos + 1 < group.count, next[group[pos].id] == group[pos + 1].id {
                take = 2
            }

            for i in 0..<take {
                result.append(group[pos + i])
            }
            groupPositions[groupIndex] = pos + take

            if groupPositions[groupIndex] >= group.count {
                exhaustedCount += 1
            }

            groupIndex = (groupIndex + 1) % showGroups.count
        }

        return result
    }

    // MARK: - Recently-added priority ("premieres")

    /// Seconds of recency that earn an item priority placement. A week covers "I ripped
    /// three movies this weekend" without permanently pinning a slow-growing library's
    /// whole tail to the front of every day.
    static let premiereWindowSeconds = 7 * 86400

    /// Where in the day new additions air. The day is packed from midnight, so promoting
    /// to the FRONT of the ordering — the first version of this — scheduled every premiere
    /// at 12 AM: by the time an afternoon scan picked up a morning rip, its slot had
    /// already elapsed and it aired overnight. Prime time is where the person who added it
    /// is actually watching.
    static let premiereAnchorSeconds = 19 * 3600

    /// How wide the premiere window is, and how finely it is divided.
    ///
    /// The anchor alone used to be the whole story, and it was a constant: a film added
    /// to six channels premiered at 19:00 on all six, so the guide showed Point Break
    /// six times in the same slot. Slots are derived per (channel, item) instead, so the
    /// same film lands at a different hour on each channel that carries it. Deterministic
    /// in both, so a rebuilt manifest reproduces the same schedule.
    /// 19:00-24:00 in 15-minute steps. Finer steps mean fewer channels landing on the
    /// exact same minute, which is what reads as "it is on six channels at once" in the
    /// guide. It does NOT stop a two-hour film from overlapping itself across channels:
    /// five channels cannot hold five non-overlapping two-hour slots in one evening. Only
    /// limiting how many channels premiere an item can do that.
    static let premiereSpreadSeconds = 5 * 3600
    static let premiereSlotSeconds = 15 * 60

    /// Target airtime for one premiere, as seconds from midnight.
    static func premiereOffset(channelId: Int, ratingKey: String) -> Int {
        let slots = max(1, premiereSpreadSeconds / premiereSlotSeconds)
        var x = UInt64(bitPattern: Int64(channelId)) &+ 0x9E37_79B9_7F4A_7C15
        for byte in ratingKey.utf8 {
            x = (x ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        x ^= x >> 33
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        return premiereAnchorSeconds + Int(x % UInt64(slots)) * premiereSlotSeconds
    }

    /// Slots items added within the window into the ordering so each one's airtime lands
    /// on its own slot inside the premiere window. Everything not recent keeps its order.
    /// Pools shorter than a premiere's target append it at the end, which still airs it
    /// the same evening rather than displacing it to an already-elapsed slot.
    static func promoteRecentlyAdded(
        _ items: [PlexMediaItem],
        dayStartUnix: Int,
        channelId: Int,
        windowSeconds: Int = premiereWindowSeconds
    ) -> [PlexMediaItem] {
        guard items.count > 1 else { return items }
        let cutoff = dayStartUnix - windowSeconds
        let recent = items.filter { $0.addedAt > 0 && $0.addedAt >= cutoff }
        guard !recent.isEmpty, recent.count < items.count else { return items }
        let rest = items.filter { !($0.addedAt > 0 && $0.addedAt >= cutoff) }

        // Ascending by target so earlier premieres are placed first; the cumulative walk
        // below then counts the ones already inserted, and two premieres an hour apart
        // stay an hour apart instead of stacking. ratingKey breaks ties so the order is
        // total and the manifest is reproducible.
        struct PremiereTarget {
            let item: PlexMediaItem
            let offset: Int
        }
        var targets: [PremiereTarget] = []
        targets.reserveCapacity(recent.count)
        for item in recent {
            let offset = premiereOffset(channelId: channelId, ratingKey: item.ratingKey)
            targets.append(PremiereTarget(item: item, offset: offset))
        }
        targets.sort { lhs, rhs in
            if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
            return lhs.item.ratingKey < rhs.item.ratingKey
        }

        var out = rest
        for target in targets {
            var insertAt = out.count
            var cumulativeSeconds = 0
            for (index, existing) in out.enumerated() {
                if cumulativeSeconds >= target.offset {
                    insertAt = index
                    break
                }
                cumulativeSeconds += existing.duration * 60
            }
            out.insert(target.item, at: insertAt)
        }
        return out
    }

    // MARK: - Sequel-part adjacency

    /// Titles ending in an explicit part marker ("Mockingjay Part 1", "Deathly Hallows
    /// Part 2"). Anchored to the END of the title so mid-title words never match.
    private static let sequelMarker = try! NSRegularExpression(
        pattern: #"^(.*?)[\s:,-]+(?:part|pt\.?)\s*([0-9]{1,2})\s*$"#,
        options: [.caseInsensitive]
    )

    /// The story and part of a film titled with a part marker ("... Part 2"), the same test
    /// `groupSequelParts` applies. Mirrors `sequelMark` in scripts/nostalgex-daily-manifest.js.
    static func sequelMark(_ item: PlexMediaItem) -> (base: String, ordinal: Int)? {
        guard item.type == .movie else { return nil }
        let title = item.title
        let range = NSRange(title.startIndex..., in: title)
        guard let match = sequelMarker.firstMatch(in: title, options: [], range: range),
              let baseRange = Range(match.range(at: 1), in: title),
              let ordRange = Range(match.range(at: 2), in: title),
              let ordinal = Int(title[ordRange]) else { return nil }
        let base = title[baseRange].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : (base, ordinal)
    }

    /// Reorders so films that are parts of one story air back to back in part order,
    /// anchored where the earliest of them already sat. Grouping runs AFTER premiere
    /// promotion: if part 1 was just added, part 2 rides forward next to it.
    static func groupSequelParts(_ items: [PlexMediaItem]) -> [PlexMediaItem] {
        guard items.count > 1 else { return items }

        struct Marked { let index: Int; let base: String; let ordinal: Int }
        var marked: [Marked] = []
        for (index, item) in items.enumerated() where item.type == .movie {
            let title = item.title
            let range = NSRange(title.startIndex..., in: title)
            guard let match = sequelMarker.firstMatch(in: title, options: [], range: range),
                  let baseRange = Range(match.range(at: 1), in: title),
                  let ordRange = Range(match.range(at: 2), in: title),
                  let ordinal = Int(title[ordRange]) else { continue }
            let base = title[baseRange].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { continue }
            marked.append(Marked(index: index, base: base, ordinal: ordinal))
        }

        var groups: [String: [Marked]] = [:]
        for mark in marked { groups[mark.base, default: []].append(mark) }
        // Only real multi-part stories move; a lone "Part 2" in the library stays put.
        let families = groups.values.filter { $0.count > 1 }
        guard !families.isEmpty else { return items }

        var pulled = Set<Int>()
        var insertions: [Int: [PlexMediaItem]] = [:]
        for family in families {
            let anchor = family.map(\.index).min()!
            let ordered = family.sorted { $0.ordinal < $1.ordinal }.map { items[$0.index] }
            for member in family { pulled.insert(member.index) }
            insertions[anchor] = ordered
        }

        var result: [PlexMediaItem] = []
        for (index, item) in items.enumerated() {
            if let familyRun = insertions[index] {
                result.append(contentsOf: familyRun)
            } else if !pulled.contains(index) {
                result.append(item)
            }
        }
        return result
    }
}

// MARK: - Seed hashing

func splitmix64(_ input: UInt64) -> UInt64 {
    var z = input &+ 0x9e3779b97f4a7c15
    z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
    z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
    return z ^ (z >> 31)
}

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = splitmix64(seed)
        if state == 0 { state = 1 }
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
