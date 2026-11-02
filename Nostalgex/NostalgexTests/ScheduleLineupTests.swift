import XCTest
@testable import Nostalgex

/// One title on one channel at a time: a day is packed across the guide's lineup
/// (DailyManifestScheduler.packLineupDay). The golden file holds the three engines to the same
/// answers (ScheduleParityTests); this holds the Apple TV to the wiring around it.
@MainActor
final class ScheduleLineupTests: XCTestCase {

    private let fp = "lineup-tests"

    override func setUp() {
        super.setUp()
        DailyManifestStore.clearAll(credentialFingerprint: fp)
        DailyManifestScheduler.setLineup([], credentialFingerprint: nil)
    }

    override func tearDown() {
        DailyManifestStore.clearAll(credentialFingerprint: fp)
        DailyManifestScheduler.setLineup([], credentialFingerprint: nil)
        super.tearDown()
    }

    private func film(_ i: Int) -> PlexMediaItem {
        PlexMediaItem(
            id: "lt\(i)", title: "Film \(i)", artist: nil, episodeTitle: nil, seTag: nil, summary: "",
            year: 1990, originallyAvailableAt: nil, contentRating: nil, duration: 85 + (i * 13) % 50,
            ratingKey: "lt\(i)", partKey: nil, container: "mp4", videoCodec: nil, audioCodec: nil,
            videoProfile: nil, bitrate: nil, genres: [], rating: 0, userRating: 0,
            type: .movie, thumb: nil, art: nil, viewCount: 0,
            addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie)
    }

    /// Six channels drawing on one 30-film library, pools overlapping by most of their length.
    private func lineup() -> [Channel] {
        let films = (0..<30).map(film)
        return (0..<6).map { c in
            Channel(id: 40 + c, number: 40 + c, name: "CH \(c)", color: .blue, category: nil, rules: nil,
                    timeRestrictions: nil, minItems: 1, itemPool: Array(films[(c * 3)..<(c * 3 + 12)]), enabled: true)
        }
    }

    private func overlaps(_ channels: [Channel], at day: Date) -> Int {
        var spans: [String: [(Int, Int, Int)]] = [:]
        var n = 0
        for ch in channels {
            for b in DailyManifestScheduler.blocks(for: ch, at: day, credentialFingerprint: fp) {
                let s = Int(b.startTime.timeIntervalSince1970), e = Int(b.endTime.timeIntervalSince1970)
                for o in spans[b.item.id, default: []] where o.0 != ch.id && min(e, o.2) > max(s, o.1) { n += 1 }
                spans[b.item.id, default: []].append((ch.id, s, e))
            }
        }
        return n
    }

    private let day = Date(timeIntervalSince1970: 1_794_000_000)

    func testTheLineupAirsNoTitleOnTwoChannelsAtOnce() {
        let channels = lineup()
        // The control: alone, these pools clash.
        XCTAssertGreaterThan(overlaps(channels, at: day), 5)
        DailyManifestStore.clearAll(credentialFingerprint: fp)

        DailyManifestScheduler.setLineup(channels, credentialFingerprint: fp)
        XCTAssertEqual(overlaps(channels, at: day), 0)
    }

    func testTheSameDayWhicheverChannelIsAskedFirst() {
        let channels = lineup()
        DailyManifestScheduler.setLineup(channels, credentialFingerprint: fp)
        let forward = channels.map { DailyManifestScheduler.blocks(for: $0, at: day, credentialFingerprint: fp).map(\.item.id) }
        DailyManifestStore.clearAll(credentialFingerprint: fp)
        let backward = channels.reversed().map { DailyManifestScheduler.blocks(for: $0, at: day, credentialFingerprint: fp).map(\.item.id) }
        XCTAssertEqual(forward, Array(backward.reversed()))
    }

    /// A rescan that changed nothing: today is kept, the days ahead are purged (purgeDays) and
    /// packed again from the same pools. They must come back the same (the 1.0.29 rule).
    func testARescanThatChangedNothingKeepsTheDaysAhead() {
        let channels = lineup()
        let tomorrow = day.addingTimeInterval(86400)
        DailyManifestScheduler.setLineup(channels, credentialFingerprint: fp)
        let today0 = channels.map { DailyManifestScheduler.blocks(for: $0, at: day, credentialFingerprint: fp).map(\.item.id) }
        let ahead0 = channels.map { DailyManifestScheduler.blocks(for: $0, at: tomorrow, credentialFingerprint: fp).map(\.item.id) }

        DailyManifestStore.purgeDays(keeping: DailyManifestStore.localDayKey(for: day), credentialFingerprint: fp)
        let rescanned = lineup()
        DailyManifestScheduler.setLineup(rescanned, credentialFingerprint: fp)
        let ahead1 = rescanned.reversed().map { DailyManifestScheduler.blocks(for: $0, at: tomorrow, credentialFingerprint: fp).map(\.item.id) }
        let today1 = rescanned.map { DailyManifestScheduler.blocks(for: $0, at: day, credentialFingerprint: fp).map(\.item.id) }
        XCTAssertEqual(today0, today1)
        XCTAssertEqual(ahead0, Array(ahead1.reversed()))
    }

    /// A caller that found its day unstored, then waited on the pack lock while another thread
    /// packed the day and a purge (`purgeDays`, or the memo filling up) dropped the memo, must
    /// still get the day back, not an empty schedule (review of 89a2f5c).
    func testAWaiterGetsTheDayAnotherThreadPacked() {
        let channels = lineup()
        DailyManifestScheduler.setLineup(channels, credentialFingerprint: fp)
        let target = channels[3]
        DailyManifestScheduler.testHookBeforePackLock = { [fp, day] in
            DailyManifestScheduler.testHookBeforePackLock = nil
            // The other thread's pack, then the memo dropped under it.
            _ = DailyManifestScheduler.blocks(for: channels[0], at: day, credentialFingerprint: fp)
            DailyManifestScheduler.invalidateMemo()
        }
        defer { DailyManifestScheduler.testHookBeforePackLock = nil }
        let got = DailyManifestScheduler.blocks(for: target, at: day, credentialFingerprint: fp)
        XCTAssertFalse(got.isEmpty, "the waiter got an empty schedule for a day that was packed")
        DailyManifestScheduler.invalidateMemo()
        XCTAssertEqual(got.map(\.item.id),
                       DailyManifestScheduler.blocks(for: target, at: day, credentialFingerprint: fp).map(\.item.id))
    }

    func testAnotherSignInsLineupIsNotUsed() {
        let channels = lineup()
        DailyManifestScheduler.setLineup(channels, credentialFingerprint: "someone-else")
        XCTAssertGreaterThan(overlaps(channels, at: day), 5, "a lineup registered for another sign-in must not shape this one's days")
    }

    func testAppStateRegistersItsChannels() {
        let state = AppState()
        let channels = lineup()
        state.channels = channels
        // The fingerprint AppState packs under: the same lineup comes back for it.
        let expected = state.scheduleCredentialFingerprint
        DailyManifestStore.clearAll(credentialFingerprint: expected)
        defer { DailyManifestStore.clearAll(credentialFingerprint: expected) }
        var spans: [String: [(Int, Int, Int)]] = [:]
        var n = 0
        for ch in channels {
            for b in DailyManifestScheduler.blocks(for: ch, at: day, credentialFingerprint: expected) {
                let s = Int(b.startTime.timeIntervalSince1970), e = Int(b.endTime.timeIntervalSince1970)
                for o in spans[b.item.id, default: []] where o.0 != ch.id && min(e, o.2) > max(s, o.1) { n += 1 }
                spans[b.item.id, default: []].append((ch.id, s, e))
            }
        }
        XCTAssertEqual(n, 0, "AppState.channels must reach the scheduler as the lineup")
        state.channels = []
    }
}
