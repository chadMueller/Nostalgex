import XCTest
@testable import Nostalgex

/// What airs, and when, on every surface.
///
/// The Apple TV is the reference. `scripts/schedule-parity-golden.json` holds fixtures (Plex,
/// Jellyfin and Emby item shapes, a lineup, a zone and some instants) and what this app does
/// with them: each channel's day, the guide's view at each instant (what is on, what is next,
/// which channel gives way when one title is on two at once), what tuning in plays and from
/// where, and what plays when a programme ends. The web tuner and the Docker image
/// (`npm run test:schedule-parity`, scripts/nostalgex-schedule-parity-smoke.mjs) and Roku
/// (roku/tests) must give the same answers byte for byte.
///
/// The file is generated from this test, never written by hand: run it with
/// `TEST_RUNNER_NX_SCHED_FIXTURE=<cases.json> TEST_RUNNER_NX_SCHED_OUT=<out.json>` and
/// `scripts/schedule-parity-golden.mjs` folds the output in.
final class ScheduleParityTests: XCTestCase {

    // MARK: - Golden

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testEverySurfaceAirsWhatTheAppleTVAirs() throws {
        let url = Self.repoRoot.appendingPathComponent("scripts/schedule-parity-golden.json")
        let golden = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(golden["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let fixture = try XCTUnwrap(c["fixture"] as? [String: Any], name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let got = try Self.dump(fixture)
            XCTAssertEqual(try Self.canonical(got), try Self.canonical(expect), "\(name): the Apple TV no longer airs what the golden file says")
        }
    }

    /// Opt-in: dump the Apple TV's answers for a cases file. No-op unless both paths are set.
    func testDumpForAFixtureFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["NX_SCHED_FIXTURE"], let output = env["NX_SCHED_OUT"] else {
            throw XCTSkip("set TEST_RUNNER_NX_SCHED_FIXTURE and TEST_RUNNER_NX_SCHED_OUT to dump a fixture")
        }
        let file = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as? [String: Any])
        var out: [[String: Any]] = []
        for c in try XCTUnwrap(file["cases"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let started = Date()
            out.append(["name": name, "expect": try Self.dump(try XCTUnwrap(c["fixture"] as? [String: Any], name))])
            print("[parity] \(name) dumped in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": out], options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }

    // MARK: - The dump

    static func canonical(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    private static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

    static func dump(_ fx: [String: Any]) throws -> [String: Any] {
        let zone = try XCTUnwrap(fx["zone"] as? String)
        let tz = try XCTUnwrap(TimeZone(identifier: zone), zone)
        let savedZone = NSTimeZone.default
        NSTimeZone.default = tz
        defer { NSTimeZone.default = savedZone }
        // buildSchedule and the advance read Calendar.current, as they do on the TV.
        guard Calendar.current.timeZone.identifier == zone else {
            throw NSError(domain: "parity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar.current did not take \(zone)"])
        }
        let fp = try XCTUnwrap(fx["fingerprint"] as? String)
        DailyManifestStore.clearAll(credentialFingerprint: fp)
        DailyManifestScheduler.invalidateMemo()
        defer {
            DailyManifestStore.clearAll(credentialFingerprint: fp)
            DailyManifestScheduler.invalidateMemo()
        }

        // Items, through the app's own parsers.
        var byKey: [String: PlexMediaItem] = [:]
        var parsed: [String: Any] = [:]
        for spec in (fx["items"] as? [[String: Any]]) ?? [] {
            let (key, item) = try makeItem(spec)
            if let item { byKey[item.ratingKey] = item }
            if spec["compact"] == nil {
                // addedAt as the schedule reads it: only a positive one can be recent. Before 1970
                // reads as 0, where Foundation (Julian before 1582) and JavaScript disagree.
                parsed[key] = item.map { [$0.duration, max(0, $0.addedAt), $0.title, $0.type == .episode ? "episode" : "movie"] as [Any] } ?? NSNull()
            }
        }

        // The lineup, in guide order.
        var channels: [Channel] = []
        var offGuide = Set<Int>()
        for row in try XCTUnwrap(fx["channels"] as? [[String: Any]]) {
            let id = try XCTUnwrap(int(row["id"]))
            let pool = ((row["pool"] as? [String]) ?? []).compactMap { byKey[$0] }
            // "gated": a channel whose pool changes with the hour, which packs after the rest
            // (DailyManifestScheduler.lineupPriority). An hour no fixture reaches, so the pool
            // itself never changes here.
            let gated = (row["gated"] as? Bool) ?? false
            var ch = Channel(id: id, number: int(row["number"]) ?? id, name: "CH \(id)", color: .blue, category: nil,
                             rules: nil, timeRestrictions: gated ? TimeRestrictions(blockRatings: nil, tvOnlyBefore: 0, onlyAfterHour: nil) : nil,
                             minItems: 1, itemPool: pool, enabled: true)
            ch.isPremiereChannel = (row["premiere"] as? Bool) ?? false
            if (row["offGuide"] as? Bool) == true { offGuide.insert(id) }
            channels.append(ch)
        }
        // The guide's lineup, as AppState registers it: each day is packed across all of it.
        // An offGuide row is dumped but not registered, like a channel the guide doesn't carry.
        DailyManifestScheduler.setLineup(channels.filter { !offGuide.contains($0.id) }, credentialFingerprint: fp)
        defer { DailyManifestScheduler.setLineup([], credentialFingerprint: nil) }

        func at(_ t: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }
        func unix(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }

        // Earlier days first, so "yesterday" exists the way it does on a TV that was on.
        for t in (fx["prime"] as? [NSNumber] ?? []).map(\.intValue) {
            for ch in channels {
                _ = DailyManifestScheduler.blocks(for: ch, at: at(t), credentialFingerprint: fp)
            }
        }

        var days: [String: Any] = [:]
        for t in (fx["days"] as? [NSNumber] ?? []).map(\.intValue) {
            var byChannel: [String: Any] = [:]
            for ch in channels {
                byChannel["\(ch.id)"] = DailyManifestScheduler.blocks(for: ch, at: at(t), credentialFingerprint: fp)
                    .map { [$0.item.ratingKey, unix($0.startTime), unix($0.endTime)] as [Any] }
            }
            days["\(t)"] = byChannel
        }

        var instants: [[String: Any]] = []
        for t in (fx["at"] as? [NSNumber] ?? []).map(\.intValue) {
            let now = at(t)
            var raw: [Int: ChannelSchedule] = [:]
            for ch in channels {
                if let s = ChannelScheduleBuilder.buildSchedule(for: ch, at: now, credentialFingerprint: fp) {
                    raw[ch.id] = s
                }
            }
            var shown = raw
            ChannelScheduleBuilder.resolveConflicts(&shown)

            var byChannel: [String: Any] = [:]
            for ch in channels {
                guard let u = raw[ch.id], let r = shown[ch.id] else {
                    byChannel["\(ch.id)"] = NSNull()
                    continue
                }
                let tune = tuneIn(ch, precomputed: r, at: now, fp: fp)
                let prev = tune?.key
                let endOfNow = u.nowPlaying.map(\.endTime) ?? now
                byChannel["\(ch.id)"] = [
                    "now": u.nowPlaying.map { [$0.item.ratingKey, unix($0.startTime), unix($0.endTime)] as [Any] } ?? NSNull(),
                    "elapsed": u.elapsedSeconds,
                    "next": u.upNext?.item.ratingKey ?? NSNull(),
                    "span": [u.entries.count,
                             u.entries.first.map { unix($0.startTime) } ?? 0,
                             u.entries.last.map { unix($0.endTime) } ?? 0],
                    "shown": r.nowPlaying.map { [$0.item.ratingKey, unix($0.startTime)] as [Any] } ?? NSNull(),
                    "shownNext": r.upNext?.item.ratingKey ?? NSNull(),
                    "gaveWay": r.entries.first(where: \.isConflict)?.item.ratingKey ?? NSNull(),
                    "tune": tune.map { [$0.key, $0.seek] as [Any] } ?? NSNull(),
                    "early": advance(ch, prev: prev, at: now, natural: true, lineup: channels, fp: fp),
                    "end": advance(ch, prev: prev, at: endOfNow, natural: true, lineup: channels, fp: fp),
                    "resync": advance(ch, prev: prev, at: endOfNow.addingTimeInterval(600), natural: false, lineup: channels, fp: fp),
                ] as [String: Any]
            }
            instants.append(["t": t, "ch": byChannel])
        }

        return ["items": parsed, "days": days, "at": instants]
    }

    /// AppState.selectChannel: the guide's schedule only while it still describes what is on,
    /// else a fresh one; the offset from the clock.
    private static func tuneIn(_ channel: Channel, precomputed: ChannelSchedule?, at now: Date, fp: String) -> (key: String, seek: Int)? {
        let usable = precomputed.flatMap { $0.isCurrent(at: now) ? $0 : nil }
        guard let schedule = usable ?? ChannelScheduleBuilder.buildSchedule(for: channel, at: now, credentialFingerprint: fp),
              let item = schedule.nowPlaying?.item else { return nil }
        return (item.ratingKey, schedule.livePlayback(at: now)?.elapsedSeconds ?? schedule.elapsedSeconds)
    }

    /// AppState.advanceToNextItem's choice, line for line, at a given instant. The app's copy
    /// reads Date() and falls back to a random pick with no schedule; `nil` here.
    private static func advance(_ channel: Channel, prev prevRatingKey: String?, at now: Date, natural fromNaturalEnd: Bool,
                                lineup channels: [Channel], fp: String) -> Any {
        guard let schedule = ChannelScheduleBuilder.buildSchedule(for: channel, at: now, credentialFingerprint: fp) else {
            return NSNull()
        }
        let scheduleHasMoved = schedule.nowPlaying?.item.ratingKey != prevRatingKey
        var pick = scheduleHasMoved
            ? schedule.nowPlaying?.item
            : (schedule.upNext?.item ?? schedule.nowPlaying?.item)
        var newSeekOffset = (scheduleHasMoved && pick != nil && !fromNaturalEnd) ? schedule.elapsedSeconds : 0
        if let item = pick,
           ChannelScheduleBuilder.findConflict(item: item, excludingChannelID: channel.id, in: channels,
                                               at: now, credentialFingerprint: fp) != nil {
            if let idx = schedule.entries.firstIndex(where: { $0.item.ratingKey == pick?.ratingKey }),
               idx + 1 < schedule.entries.count {
                pick = schedule.entries[idx + 1].item
                newSeekOffset = 0
            }
        }
        guard let next = pick else { return NSNull() }
        return [next.ratingKey, newSeekOffset] as [Any]
    }

    // MARK: - Items from server shapes

    private static func makeItem(_ spec: [String: Any]) throws -> (String, PlexMediaItem?) {
        if let c = spec["compact"] as? [Any] {
            let key = try XCTUnwrap(c[0] as? String)
            let type = (c[2] as? String) == "episode" ? MediaType.episode : MediaType.movie
            return (key, item(key: key, title: c[1] as? String ?? "", type: type, minutes: int(c[3]) ?? 0, addedAt: int(c[4]) ?? 0))
        }
        let backend = try XCTUnwrap(spec["backend"] as? String)
        let kind = try XCTUnwrap(spec["kind"] as? String)
        let rawObject = try XCTUnwrap(spec["raw"] as? [String: Any])
        let rawData = try JSONSerialization.data(withJSONObject: rawObject)
        let show = spec["show"] as? [String: Any] ?? [:]
        switch (backend, kind) {
        case ("plex", "movie"):
            let raw = try JSONDecoder().decode(PlexRawItem.self, from: rawData)
            return (raw.ratingKey, PlexAPIService(serverURL: "", token: "").parseMovieItem(raw, isMusicSection: false))
        case ("plex", "episode"):
            // PlexAPIService.makeEpisodeItem is private; these are its schedule inputs, as it reads them.
            let raw = try JSONDecoder().decode(PlexRawItem.self, from: rawData)
            let minutes = (raw.duration ?? 0) / 60000
            guard minutes > 0 else { return (raw.ratingKey, nil) }
            return (raw.ratingKey, item(key: raw.ratingKey, title: show["title"] as? String ?? "", type: .episode,
                                        minutes: minutes, addedAt: raw.addedAt ?? 0))
        case ("jellyfin", "movie"):
            let raw = try JSONDecoder().decode(JellyfinItem.self, from: rawData)
            return (raw.Id, JellyfinAPIService(serverURL: "", accessToken: "", userId: "").parseMovieItem(raw, isMusicSection: false))
        case ("emby", "movie"):
            let raw = try JSONDecoder().decode(JellyfinItem.self, from: rawData)
            return (raw.Id, EmbyAPIService(serverURL: "", accessToken: "", userId: "").parseMovieItem(raw, isMusicSection: false))
        case ("jellyfin", "episode"), ("emby", "episode"):
            // The episode loops in JellyfinAPIService/EmbyAPIService.fetchEpisodes, as they read them.
            let raw = try JSONDecoder().decode(JellyfinItem.self, from: rawData)
            let minutes = JellyfinAPIService.minutes(fromTicks: raw.RunTimeTicks)
            guard minutes > 0 else { return (raw.Id, nil) }
            return (raw.Id, item(key: raw.Id, title: show["Name"] as? String ?? raw.SeriesName ?? "", type: .episode,
                                 minutes: minutes, addedAt: JellyfinAPIService.unixSeconds(fromISO: raw.DateCreated)))
        default:
            throw NSError(domain: "parity", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown item \(backend) \(kind)"])
        }
    }

    private static func item(key: String, title: String, type: MediaType, minutes: Int, addedAt: Int) -> PlexMediaItem {
        PlexMediaItem(
            id: key, title: title, artist: nil, episodeTitle: nil, seTag: nil, summary: "",
            year: 2000, originallyAvailableAt: nil, contentRating: nil, duration: minutes,
            ratingKey: key, partKey: nil, container: "mp4", videoCodec: nil, audioCodec: nil,
            videoProfile: nil, bitrate: nil, genres: [], rating: 0, userRating: 0,
            type: type, thumb: nil, art: nil, viewCount: 0,
            addedAt: addedAt, studio: nil, tmdbID: nil, imdbID: nil,
            librarySource: type == .episode ? .tv : .movie)
    }
}
