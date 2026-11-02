import XCTest
import Foundation
@testable import Nostalgex

/// How often is one title on air on two channels at once, and what does the app's conflict
/// handling do about it? Measured with the real `ChannelScheduleBuilder` over what an Apple TV
/// actually holds (its library snapshot and daily manifests, pulled read-only with
/// `xcrun devicectl device copy from`), minute by minute over a day.
///
/// The web-engine twin is `scripts/qa/cross-channel-duplicates.mjs`; the two are parity-tested
/// engines, and this file's per-instant rows can be diffed against that script's
/// `--dump-instants` output. The control (`scripts/qa/make-duplicates-control.mjs`) is a
/// five-channel "device" whose overlaps are placed by hand, with the numbers a correct
/// harness must report; `testControlReadsTheHandPlacedOverlaps` checks the harness against it.
/// Run the control first: a harness that misreads it makes the real numbers meaningless.
///
/// Off unless the data is named. The data is a user's library: it stays out of the repo and out
/// of any report that is published.
///
///     TEST_RUNNER_NX_DUP_DATA=<dir with library_snapshot/ and daily_manifests/> \
///     TEST_RUNNER_NX_DUP_DAY=2026-10-31 \
///     TEST_RUNNER_NX_DUP_OUT=<report.json> \
///     [TEST_RUNNER_NX_DUP_CONTROL=<dir from make-duplicates-control.mjs>] \
///     [TEST_RUNNER_NX_DUP_AT=2026-10-31T16:14:21-04:00] [TEST_RUNNER_NX_DUP_WATCH="part of a title"] \
///     [TEST_RUNNER_NX_DUP_STEP=60] [TEST_RUNNER_NX_DUP_ADVANCE_EVERY=2] \
///     xcodebuild test ... -only-testing:NostalgexTests/CrossChannelDuplicateHarness
///
/// The day and the day after it must both have manifests on the device.
final class CrossChannelDuplicateHarness: XCTestCase {

    // MARK: - Data

    private struct SnapshotMeta: Decodable {
        let allChannelRows: [StoredChannel]
        let allChannelPools: [[Int32]]
    }

    private struct Lineup {
        let items: [PlexMediaItem]
        let channels: [Channel]
        let fingerprint: String
        let content: ContentIdentity
        let dataDir: URL
        var installedManifests: URL
    }

    /// One piece of content under any number of ratingKeys: items that share a TMDB id, an
    /// IMDb id, a title and year, an episode tag or an artist and title are the same thing.
    private final class ContentIdentity {
        private var parent: [String: String] = [:]

        init(items: [PlexMediaItem]) {
            for it in items {
                let node = "id:\(it.id)"
                parent[node] = node
                for token in Self.tokens(it) {
                    if parent[token] == nil { parent[token] = token }
                    union(node, token)
                }
            }
        }

        private func find(_ start: String) -> String {
            var x = start
            while let p = parent[x], p != x {
                parent[x] = parent[p]
                x = parent[x] ?? p
            }
            return x
        }

        private func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        func key(_ id: String) -> String { find("id:\(id)") }

        static func norm(_ s: String?) -> String {
            var out = ""
            var lastSpace = true
            for u in (s ?? "").lowercased().unicodeScalars {
                if (97...122).contains(u.value) || (48...57).contains(u.value) {
                    out.unicodeScalars.append(u)
                    lastSpace = false
                } else if !lastSpace {
                    out += " "
                    lastSpace = true
                }
            }
            if out.hasSuffix(" ") { out.removeLast() }
            return out
        }

        static func tokens(_ it: PlexMediaItem) -> [String] {
            if it.type == .episode {
                return ["ep:\(norm(it.title))|\(it.seTag ?? norm(it.episodeTitle))"]
            }
            if it.librarySource == .musicVideo {
                return ["mv:\(norm(it.artist))|\(norm(it.title))"]
            }
            var t: [String] = []
            if let v = it.tmdbID, !v.isEmpty { t.append("tmdb:\(v)") }
            if let v = it.imdbID, !v.isEmpty { t.append("imdb:\(v)") }
            if let y = it.year, y != 0 { t.append("ty:\(norm(it.title))|\(y)") }
            return t
        }
    }

    /// Reads the pulled directory and puts its manifests where the scheduler looks for them.
    private func install(dataDir: URL) throws -> Lineup {
        let fm = FileManager.default
        let snap = dataDir.appendingPathComponent("library_snapshot")
        let current = try JSONDecoder().decode(
            LibrarySnapshotManifestV3.self, from: Data(contentsOf: snap.appendingPathComponent("current.json")))
        let gen = snap.appendingPathComponent(current.generation)
        let meta = try JSONDecoder().decode(SnapshotMeta.self, from: Data(contentsOf: gen.appendingPathComponent("meta.json")))
        var items: [PlexMediaItem] = []
        for i in 0..<current.chunkCount {
            let name = String(format: "items-%04d.json", i)
            items += try JSONDecoder().decode([PlexMediaItem].self, from: Data(contentsOf: gen.appendingPathComponent(name)))
        }
        XCTAssertEqual(meta.allChannelRows.count, meta.allChannelPools.count)
        var channels: [Channel] = []
        for (i, row) in meta.allChannelRows.enumerated() {
            var ch = Channel.fromSnapshotRow(row, itemLookup: { _ in nil }, includePool: false)
            ch.itemPool = meta.allChannelPools[i].map { items[Int($0)] }
            channels.append(ch)
        }
        let mroot = dataDir.appendingPathComponent("daily_manifests")
        let fp = try XCTUnwrap(try fm.contentsOfDirectory(atPath: mroot.path).filter { !$0.hasPrefix(".") }.sorted().first)
        let root = try XCTUnwrap(LocalStore.rootDirectory)
        let dest = root.appendingPathComponent("daily_manifests", isDirectory: true).appendingPathComponent(fp, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: mroot.appendingPathComponent(fp), to: dest)
        DailyManifestScheduler.invalidateMemo()
        return Lineup(items: items, channels: channels, fingerprint: fp, content: ContentIdentity(items: items),
                      dataDir: dataDir, installedManifests: dest)
    }

    private func uninstall(_ l: Lineup) {
        try? FileManager.default.removeItem(at: l.installedManifests)
        DailyManifestScheduler.invalidateMemo()
    }

    private static func localMidnight(_ day: String) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    // MARK: - One instant

    private struct Row {
        var t = 0
        var rawDupTitles = 0, rawDupChannels = 0, rawContentDupTitles = 0
        var bumped = 0, bumpedEntries = 0
        var shownDupTitles = 0, shownDupChannels = 0, shownContentDupTitles = 0
        var tunePlays = 0, tunedDupTitles = 0, tunedDupChannels = 0
        var causeBumpedLands = 0, causeNoUpNext = 0, causeWinnerCollided = 0, causeOther = 0
        var gridChanged = 0, conflictFlags = 0, channels = 0
        var raw: [Int: ChannelSchedule] = [:]
        var shown: [Int: ChannelSchedule] = [:]
        var rawGroups: [(String, [Int])] = []
        var shownGroups: [(String, [Int])] = []
        var bumpedIDs: [Int] = []
        var tuned: [Int: String] = [:]
    }

    private func measure(_ l: Lineup, at t: Date) -> Row {
        var row = Row()
        row.t = Int(t.timeIntervalSince1970)
        var raw: [Int: ChannelSchedule] = [:]
        for ch in l.channels {
            if let s = ChannelScheduleBuilder.buildSchedule(for: ch, at: t, credentialFingerprint: l.fingerprint),
               s.nowPlaying != nil {
                raw[ch.id] = s
            }
        }
        // TunerView.buildAllSchedules: build every channel, then resolve.
        var shown = raw
        ChannelScheduleBuilder.resolveConflicts(&shown)

        func rawNow(_ c: Int) -> String { raw[c]!.nowPlaying!.item.id }
        func shownNow(_ c: Int) -> String { shown[c]!.nowPlaying!.item.id }
        func groups(_ key: (Int) -> String) -> [(String, [Int])] {
            var g: [String: [Int]] = [:]
            for c in raw.keys { g[key(c), default: []].append(c) }
            return g.filter { $0.value.count > 1 }.map { ($0.key, $0.value.sorted()) }.sorted { $0.0 < $1.0 }
        }
        let rawG = groups { rawNow($0) }
        let shownG = groups { shownNow($0) }
        let rawContentG = groups { l.content.key(rawNow($0)) }
        let shownContentG = groups { l.content.key(shownNow($0)) }
        let bumped = raw.keys.filter { shownNow($0) != rawNow($0) }.sorted()
        let bumpedSet = Set(bumped)

        row.channels = raw.count
        row.rawDupTitles = rawG.count
        row.rawDupChannels = rawG.reduce(0) { $0 + $1.1.count }
        row.rawContentDupTitles = rawContentG.count
        row.bumped = bumped.count
        row.bumpedEntries = raw.keys.filter { shown[$0]!.nowPlaying!.id != raw[$0]!.nowPlaying!.id }.count
        row.shownDupTitles = shownG.count
        row.shownDupChannels = shownG.reduce(0) { $0 + $1.1.count }
        row.shownContentDupTitles = shownContentG.count

        for (_, chs) in shownG {
            for c in chs {
                let lowest = raw.keys.filter { rawNow($0) == rawNow(c) }.min() ?? c
                if bumpedSet.contains(c) {
                    row.causeBumpedLands += 1
                } else if c != lowest, shown[c]!.nowPlaying!.id == raw[c]!.nowPlaying!.id {
                    row.causeNoUpNext += 1
                } else if chs.contains(where: { bumpedSet.contains($0) }) {
                    row.causeWinnerCollided += 1
                } else {
                    row.causeOther += 1
                }
            }
        }

        // The guide's grid draws `entries`. resolveConflicts flags one entry and leaves the rest.
        for c in bumped {
            let a = raw[c]!.entries, b = shown[c]!.entries
            let same = a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.endTime == $1.endTime }
            if !same { row.gridChanged += 1 }
        }
        row.conflictFlags = shown.values.reduce(0) { $0 + $1.entries.filter(\.isConflict).count }

        // AppState.selectChannel (App/AppState+Schedule.swift): the guide's schedule only while
        // it still describes what is on, otherwise one built now.
        var tuned: [Int: String] = [:]
        for ch in l.channels {
            guard let pre = shown[ch.id] else { continue }
            let usable = pre.isCurrent(at: t) ? pre : nil
            let schedule = usable ?? ChannelScheduleBuilder.buildSchedule(for: ch, at: t, credentialFingerprint: l.fingerprint)
            if let np = schedule?.nowPlaying {
                tuned[ch.id] = np.item.id
                if bumpedSet.contains(ch.id), np.item.id == rawNow(ch.id) { row.tunePlays += 1 }
            }
        }
        var tg: [String: [Int]] = [:]
        for (c, k) in tuned { tg[k, default: []].append(c) }
        let tunedG = tg.filter { $0.value.count > 1 }
        row.tunedDupTitles = tunedG.count
        row.tunedDupChannels = tunedG.reduce(0) { $0 + $1.value.count }

        row.raw = raw
        row.shown = shown
        row.rawGroups = rawG
        row.shownGroups = shownG
        row.bumpedIDs = bumped
        row.tuned = tuned
        return row
    }

    // MARK: - Natural end of a programme

    /// AppState.advanceToNextItem(fromNaturalEnd: true) (App/AppState+Playback.swift): the
    /// schedule's next programme, skipped once when another channel has it on now.
    private func advancePick(_ l: Lineup, channel: Channel, previousID: String, now: Date) -> PlexMediaItem? {
        guard let schedule = ChannelScheduleBuilder.buildSchedule(for: channel, at: now, credentialFingerprint: l.fingerprint) else { return nil }
        let moved = schedule.nowPlaying?.item.ratingKey != previousID
        var pick = moved ? schedule.nowPlaying?.item : (schedule.upNext?.item ?? schedule.nowPlaying?.item)
        if let item = pick,
           ChannelScheduleBuilder.findConflict(item: item, excludingChannelID: channel.id, in: l.channels, at: now,
                                               credentialFingerprint: l.fingerprint) != nil,
           let idx = schedule.entries.firstIndex(where: { $0.item.ratingKey == pick?.ratingKey }),
           idx + 1 < schedule.entries.count {
            pick = schedule.entries[idx + 1].item
        }
        return pick
    }

    // MARK: - Control

    private func runControl(dir: URL) throws {
        let l = try install(dataDir: dir)
        defer { uninstall(l) }
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("expected.json"))) as? [String: Any])
        let days = try XCTUnwrap(expected["days"] as? [String])
        let probes = try XCTUnwrap(expected["probes"] as? [[String: Any]])
        let midnight = Self.localMidnight(days[0])
        for p in probes {
            let minute = try XCTUnwrap((p["atMinute"] as? NSNumber)?.intValue)
            let r = measure(l, at: midnight.addingTimeInterval(Double(minute * 60)))
            let got: [String: Int] = [
                "rawDupTitles": r.rawDupTitles, "rawDupChannels": r.rawDupChannels, "rawContentDupTitles": r.rawContentDupTitles,
                "bumped": r.bumped, "shownDupTitles": r.shownDupTitles, "shownContentDupTitles": r.shownContentDupTitles,
                "tunePlaysTheTitleItGaveWay": r.tunePlays, "tunedDupTitles": r.tunedDupTitles, "tunedDupChannels": r.tunedDupChannels,
            ]
            for (k, want) in p where k != "atMinute" && k != "note" {
                XCTAssertEqual(got[k], (want as? NSNumber)?.intValue, "control, minute \(minute), \(k)")
            }
        }
        print("DUPHARNESS control: \(probes.count) probes checked")
    }

    // MARK: - The measurement

    /// The control alone: five channels with overlaps placed by hand. Run this first.
    func testControlReadsTheHandPlacedOverlaps() throws {
        guard let control = ProcessInfo.processInfo.environment["NX_DUP_CONTROL"] else {
            throw XCTSkip("set TEST_RUNNER_NX_DUP_CONTROL to the directory scripts/qa/make-duplicates-control.mjs wrote")
        }
        try runControl(dir: URL(fileURLWithPath: control))
    }

    /// The device's day packed again from the day before it, by the real scheduler: each channel
    /// alone (what every build up to 1.0.29 does) and across the lineup (packLineupDay), with
    /// the time each takes. Writes both days, block for block, so they can be compared with the
    /// device's own manifest and with scripts/qa/cross-channel-repack.mjs (the web engine). A
    /// time-gated pool follows the clock the test runs at, as on a TV.
    ///
    ///     TEST_RUNNER_NX_DUP_DATA=<dir> TEST_RUNNER_NX_DUP_HISTORY=2026-10-31 \
    ///     TEST_RUNNER_NX_DUP_DAY=2026-11-01 TEST_RUNNER_NX_DUP_REPACK_OUT=<out.json> \
    ///     [TEST_RUNNER_NX_DUP_RUNS=5] xcodebuild test ... \
    ///     -only-testing:NostalgexTests/CrossChannelDuplicateHarness/testRepackOnDeviceData
    func testRepackOnDeviceData() throws {
        let env = ProcessInfo.processInfo.environment
        guard let data = env["NX_DUP_DATA"], let history = env["NX_DUP_HISTORY"], let day = env["NX_DUP_DAY"],
              let out = env["NX_DUP_REPACK_OUT"] else {
            throw XCTSkip("set TEST_RUNNER_NX_DUP_DATA, TEST_RUNNER_NX_DUP_HISTORY, TEST_RUNNER_NX_DUP_DAY and TEST_RUNNER_NX_DUP_REPACK_OUT")
        }
        let runs = Int(env["NX_DUP_RUNS"] ?? "") ?? 5
        let l = try install(dataDir: URL(fileURLWithPath: data))
        defer {
            uninstall(l)
            DailyManifestScheduler.setLineup([], credentialFingerprint: nil)
        }
        let at = Self.localMidnight(day).addingTimeInterval(3600)
        let fm = FileManager.default

        /// Leaves only the history day on disk, then packs `day` for every channel in guide order.
        func pack(lineup: Bool) throws -> (ms: [Double], days: [String: [[Any]]]) {
            var times: [Double] = []
            var days: [String: [[Any]]] = [:]
            for _ in 0..<runs {
                for name in try fm.contentsOfDirectory(atPath: l.installedManifests.path) where !name.hasSuffix("_\(history).json") {
                    try fm.removeItem(at: l.installedManifests.appendingPathComponent(name))
                }
                DailyManifestScheduler.invalidateMemo()
                DailyManifestScheduler.setLineup(lineup ? l.channels : [], credentialFingerprint: l.fingerprint)
                let t0 = Date()
                var got: [String: [[Any]]] = [:]
                for ch in l.channels {
                    got["\(ch.id)"] = DailyManifestScheduler.blocks(for: ch, at: at, credentialFingerprint: l.fingerprint)
                        .map { [$0.item.id, Int($0.startTime.timeIntervalSince1970), Int($0.endTime.timeIntervalSince1970)] }
                }
                times.append(Date().timeIntervalSince(t0) * 1000)
                days = got
            }
            return (times, days)
        }

        let alone = try pack(lineup: false)
        let together = try pack(lineup: true)
        func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
        let report: [String: Any] = [
            "channels": l.channels.count, "runs": runs,
            "alone": ["msMedian": median(alone.ms), "ms": alone.ms, "days": alone.days],
            "lineup": ["msMedian": median(together.ms), "ms": together.ms, "days": together.days],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: out))
        print("[repack] \(l.channels.count) channels: alone \(Int(median(alone.ms))) ms, lineup \(Int(median(together.ms))) ms")
    }

    func testMeasureDuplicatesOnDeviceData() throws {
        let env = ProcessInfo.processInfo.environment
        guard let data = env["NX_DUP_DATA"], let day = env["NX_DUP_DAY"], let out = env["NX_DUP_OUT"] else {
            throw XCTSkip("set TEST_RUNNER_NX_DUP_DATA, TEST_RUNNER_NX_DUP_DAY and TEST_RUNNER_NX_DUP_OUT")
        }

        let step = Double(env["NX_DUP_STEP"] ?? "") ?? 60
        let advanceEvery = Int(env["NX_DUP_ADVANCE_EVERY"] ?? "") ?? 2
        let l = try install(dataDir: URL(fileURLWithPath: data))
        defer { uninstall(l) }
        let start = Self.localMidnight(day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!

        // Fidelity: the real scheduler, given each channel's pool, must give back the device's
        // own manifest. A channel whose pool differs now (a time-of-day gate) repacks instead.
        var reproduced = 0
        var notReproduced: [Int] = []
        for ch in l.channels {
            let url = l.dataDir.appendingPathComponent("daily_manifests/\(l.fingerprint)/\(ch.id)_\(day).json")
            let file = try JSONDecoder().decode(DailyManifestFile.self, from: Data(contentsOf: url))
            let blocks = DailyManifestScheduler.blocks(for: ch, at: start.addingTimeInterval(43200), credentialFingerprint: l.fingerprint)
            let same = blocks.count == file.blocks.count
                && zip(blocks, file.blocks).allSatisfy { $0.item.id == $1.ratingKey
                    && Int($0.startTime.timeIntervalSince1970) == $1.startUnix && Int($0.endTime.timeIntervalSince1970) == $1.endUnix }
            if same { reproduced += 1 } else { notReproduced.append(ch.id) }
        }
        // Re-install: a channel that repacked rewrote its copy.
        uninstall(l)
        _ = try install(dataDir: URL(fileURLWithPath: data))

        var rows: [Row] = []
        let t0 = Date()
        var t = start
        while t < end {
            var r = measure(l, at: t)
            r.raw = [:]; r.shown = [:]; r.rawGroups = []; r.shownGroups = []; r.tuned = [:]
            rows.append(r)
            t = t.addingTimeInterval(step)
        }
        let sampleSeconds = Date().timeIntervalSince(t0)
        let n = Double(max(1, rows.count))
        func sum(_ f: (Row) -> Int) -> Int { rows.reduce(0) { $0 + f($1) } }
        func share(_ f: (Row) -> Bool) -> Double { Double(rows.filter(f).count) / n }
        let chs = Double(rows.first?.channels ?? 1)

        // Natural end of a programme.
        var advances = 0, skipped = 0, upNextOnAnother = 0, pickOnAnother = 0
        var nowCache: [Int: [Int: String]] = [:]
        func nowMap(at s: Date) -> [Int: String] {
            let key = Int(s.timeIntervalSince1970)
            if let m = nowCache[key] { return m }
            var m: [Int: String] = [:]
            for ch in l.channels {
                if let np = ChannelScheduleBuilder.buildSchedule(for: ch, at: s, credentialFingerprint: l.fingerprint)?.nowPlaying { m[ch.id] = np.item.id }
            }
            if nowCache.count > 40 { nowCache.removeAll() }
            nowCache[key] = m
            return m
        }
        if advanceEvery > 0 {
            var counter = 0
            for ch in l.channels {
                let blocks = DailyManifestScheduler.blocks(for: ch, at: start.addingTimeInterval(43200), credentialFingerprint: l.fingerprint)
                for i in 0..<max(0, blocks.count - 1) {
                    counter += 1
                    if counter % advanceEvery != 0 { continue }
                    let b = blocks[i]
                    if b.endTime > end.addingTimeInterval(-120) { continue }
                    guard let pick = advancePick(l, channel: ch, previousID: b.item.ratingKey, now: b.endTime.addingTimeInterval(-30)) else { continue }
                    advances += 1
                    let atStart = nowMap(at: b.endTime.addingTimeInterval(1))
                    let up = blocks[i + 1].item.id
                    func onOther(_ id: String) -> Bool { atStart.contains { $0.key != ch.id && $0.value == id } }
                    if pick.id != up { skipped += 1 }
                    if onOther(pick.id) { pickOnAnother += 1 }
                    if onOther(up) { upNextOnAnother += 1 }
                }
            }
        }

        // The instant named, in detail.
        var atNow: [String: Any]? = nil
        if let at = env["NX_DUP_AT"], let when = ISO8601DateFormatter().date(from: at) {
            let r = measure(l, at: when)
            func name(_ c: Int) -> String { "\(l.channels.first { $0.id == c }!.number) \(l.channels.first { $0.id == c }!.name)" }
            func title(_ id: String) -> String { l.items.first { $0.id == id }?.title ?? id }
            atNow = [
                "at": at,
                "rawDuplicatedTitles": r.rawGroups.map { ["title": title($0.0), "channels": $0.1.map(name)] },
                "bumpedChannels": r.bumpedIDs.map { ["channel": name($0), "guideShowsNow": title(r.shown[$0]!.nowPlaying!.item.id),
                                                     "wasOn": title(r.raw[$0]!.nowPlaying!.item.id), "tuningPlays": title(r.tuned[$0] ?? "?")] },
                "stillDuplicatedAfterResolve": r.shownGroups.map { ["title": title($0.0), "channels": $0.1.map(name)] },
                "counts": ["rawDupTitles": r.rawDupTitles, "rawDupChannels": r.rawDupChannels, "bumped": r.bumped,
                           "shownDupTitles": r.shownDupTitles, "tunedDupChannels": r.tunedDupChannels],
            ]
            if let w = env["NX_DUP_WATCH"] {
                let needle = ContentIdentity.norm(w)
                let ids = Set(l.items.filter { ContentIdentity.norm($0.title).contains(needle) }.map(\.id))
                atNow?["watched"] = r.raw.filter { ids.contains($0.value.nowPlaying!.item.id) }.map { c, s in
                    ["channel": name(c), "title": s.item(),
                     "guideShowsNow": title(r.shown[c]!.nowPlaying!.item.id), "tuningPlays": title(r.tuned[c] ?? "?"),
                     "isCurrentAfterResolve": r.shown[c]!.isCurrent(at: when)] as [String: Any]
                }
            }
        }

        var report: [String: Any] = [:]
        report["fidelity"] = ["channels": l.channels.count, "manifestsReproducedExactly": reproduced,
                              "notReproducedChannelIDs": notReproduced] as [String: Any]
        report["samples"] = rows.count
        report["stepSeconds"] = step
        report["wallSeconds"] = sampleSeconds
        report["channelsPerInstant"] = rows.first?.channels ?? 0

        var rawOut: [String: Any] = [:]
        rawOut["shareOfInstantsWithAnyDuplicateTitle"] = share { $0.rawDupTitles > 0 }
        rawOut["meanDuplicatedTitles"] = Double(sum { $0.rawDupTitles }) / n
        rawOut["meanChannelsOnADuplicatedTitle"] = Double(sum { $0.rawDupChannels }) / n
        rawOut["shareOfChannelInstantsOnADuplicatedTitle"] = Double(sum { $0.rawDupChannels }) / (n * chs)
        rawOut["contentShareOfInstantsWithAnyDuplicate"] = share { $0.rawContentDupTitles > 0 }
        report["raw"] = rawOut

        var afterOut: [String: Any] = [:]
        afterOut["meanChannelsBumped"] = Double(sum { $0.bumped }) / n
        afterOut["meanChannelsBumpedByEntry"] = Double(sum { $0.bumpedEntries }) / n
        afterOut["shareOfInstantsWithAnyDuplicateTitle"] = share { $0.shownDupTitles > 0 }
        afterOut["meanChannelsOnADuplicatedTitle"] = Double(sum { $0.shownDupChannels }) / n
        afterOut["contentShareOfInstantsWithAnyDuplicate"] = share { $0.shownContentDupTitles > 0 }
        var causes: [String: Int] = [:]
        causes["bumpedChannelLandsOnAnotherChannelsTitle"] = sum { $0.causeBumpedLands }
        causes["loserHadNoNextProgramme"] = sum { $0.causeNoUpNext }
        causes["winnerCollidedWithABumpedChannel"] = sum { $0.causeWinnerCollided }
        causes["other"] = sum { $0.causeOther }
        afterOut["survivingByCause"] = causes
        afterOut["guideGridEntriesChangedOnBumpedChannels"] = sum { $0.gridChanged }
        afterOut["isConflictFlagsSet"] = sum { $0.conflictFlags }
        report["afterResolveConflicts"] = afterOut

        var tuneOut: [String: Any] = [:]
        tuneOut["meanBumpedChannelsThatStillPlayTheTitleTheyGaveWay"] = Double(sum { $0.tunePlays }) / n
        tuneOut["shareOfInstantsWithAnyDuplicateTitle"] = share { $0.tunedDupTitles > 0 }
        tuneOut["meanChannelsOnADuplicatedTitle"] = Double(sum { $0.tunedDupChannels }) / n
        tuneOut["shareOfChannelInstantsOnADuplicatedTitle"] = Double(sum { $0.tunedDupChannels }) / (n * chs)
        report["whatTuningPlays"] = tuneOut

        var advOut: [String: Int] = [:]
        advOut["advances"] = advances
        advOut["skippedByConflictCheck"] = skipped
        advOut["upNextWasOnAnotherChannelAtItsStart"] = upNextOnAnother
        advOut["pickIsOnAnotherChannelAtItsStart"] = pickOnAnother
        report["naturalEndAdvance"] = advOut
        report["atNow"] = atNow ?? NSNull()

        let columns: [String] = ["t", "rawDupTitles", "rawDupChannels", "rawContentDupTitles", "bumped", "shownDupTitles",
                                 "shownDupChannels", "shownContentDupTitles", "tunePlaysTheTitleItGaveWay", "tunedDupTitles", "tunedDupChannels"]
        var rowsOut: [[Int]] = []
        for r in rows {
            var one: [Int] = [r.t, r.rawDupTitles, r.rawDupChannels, r.rawContentDupTitles, r.bumped]
            one += [r.shownDupTitles, r.shownDupChannels, r.shownContentDupTitles, r.tunePlays, r.tunedDupTitles, r.tunedDupChannels]
            rowsOut.append(one)
        }
        report["columns"] = columns
        report["rows"] = rowsOut
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try json.write(to: URL(fileURLWithPath: out))
        print("DUPHARNESS wrote \(out): \(rows.count) instants, \(reproduced)/\(l.channels.count) manifests reproduced, \(advances) advances")
    }

    // MARK: - ratingKey is server-local; conflicts key on it

    /// `PlexMediaItem.id` is "serverID:ratingKey" but `ratingKey` is the server's own number, and
    /// `resolveConflicts` and `findConflict` compare `ratingKey`. Two different films on two
    /// servers that reuse a number are "the same title on two channels". Characterisation of
    /// today's behaviour: when this is fixed, this test should flip.
    func testResolveConflictsComparesServerLocalRatingKeys() throws {
        func item(id: String, rk: String, server: String, title: String) -> PlexMediaItem {
            PlexMediaItem(
                id: id, title: title, artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: 2000,
                originallyAvailableAt: nil, contentRating: nil, duration: 600, ratingKey: rk, partKey: nil,
                container: "mp4", videoCodec: nil, audioCodec: nil, videoProfile: nil, bitrate: nil, genres: [],
                rating: 0, userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil,
                tmdbID: nil, imdbID: nil, librarySource: .movie, serverID: server)
        }
        let a = item(id: "srvA:1", rk: "1", server: "srvA", title: "Film From Server A")
        let b = item(id: "srvB:1", rk: "1", server: "srvB", title: "A Different Film From Server B")
        let fp = "dup-harness-multiserver"
        DailyManifestStore.clearAll(credentialFingerprint: fp)
        defer { DailyManifestStore.clearAll(credentialFingerprint: fp) }
        let ch10 = Channel(id: 10, number: 10, name: "A", color: .blue, category: nil, rules: nil, timeRestrictions: nil, minItems: 1, itemPool: [a], enabled: true)
        let ch20 = Channel(id: 20, number: 20, name: "B", color: .blue, category: nil, rules: nil, timeRestrictions: nil, minItems: 1, itemPool: [b], enabled: true)
        let now = Date()
        var all: [Int: ChannelSchedule] = [:]
        for ch in [ch10, ch20] { all[ch.id] = ChannelScheduleBuilder.buildSchedule(for: ch, at: now, credentialFingerprint: fp) }
        XCTAssertEqual(all[10]?.nowPlaying?.item.id, "srvA:1")
        XCTAssertEqual(all[20]?.nowPlaying?.item.id, "srvB:1")
        ChannelScheduleBuilder.resolveConflicts(&all)
        let gaveWay = (all[20]?.nowPlaying?.startTime ?? .distantPast) > now
        print("DUPHARNESS multi-server: two different films with the same server-local ratingKey, channel 20 gave way = \(gaveWay)")
        XCTAssertTrue(gaveWay, "two different films from two servers were treated as one title on two channels")
        XCTAssertNotNil(ChannelScheduleBuilder.findConflict(item: a, excludingChannelID: 10, in: [ch10, ch20], at: now, credentialFingerprint: fp),
                        "findConflict matched a different film from the other server")
    }
}

private extension ChannelSchedule {
    func item() -> String { nowPlaying?.item.title ?? "?" }
}
