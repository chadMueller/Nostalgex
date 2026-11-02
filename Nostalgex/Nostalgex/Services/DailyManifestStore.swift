import CryptoKit
import Foundation

// MARK: - On-disk daily EPG manifest (one calendar day per channel)

struct StoredManifestBlock: Codable, Equatable {
    let ratingKey: String
    let startUnix: Int
    let endUnix: Int
}

struct DailyManifestFile: Codable {
    var schemaVersion: Int
    let channelId: Int
    let dayKey: String
    let credentialFingerprint: String
    let poolFingerprint: String
    let blocks: [StoredManifestBlock]
}

enum DailyManifestStore {
    /// 2: the lineup's days are packed together, so one title is never on two channels at once
    /// (DailyManifestScheduler.packLineupDay). A day stored at 1 is packed again once, from
    /// what aired the day before, which still reads at any version.
    static let schemaVersion = 2
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    static func poolFingerprint(ratingKeys: [String]) -> String {
        let sorted = ratingKeys.sorted().joined(separator: ",")
        let digest = SHA256.hash(data: Data(sorted.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func localDayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return "1970-01-01" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func startOfLocalDay(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The start of the local day after the one containing `date`.
    ///
    /// Where the clocks change a day is 23 or 25 hours long (23.5 or 24.5 on Lord Howe), so
    /// midnight plus 86,400 s lands an hour short of the next midnight when they go back and an
    /// hour into the next day when they go forward. 36 hours after a day's start is always inside
    /// the next day, and that day's start is the answer, even where midnight itself is skipped
    /// (Santiago, Havana, Beirut). Stepping `.day` from a start that fell at 1 AM would keep the
    /// 1 AM. Mirrors `startOfNextLocalDayMs` in scripts/nostalgex-daily-manifest.js.
    static func startOfNextLocalDay(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: startOfLocalDay(for: date, calendar: calendar).addingTimeInterval(36 * 3600))
    }

    /// The key of the local day before the one containing `date`. 12 hours before a day's start
    /// is always inside the day before; 24 hours before the day after the clocks go forward is
    /// two days back. Mirrors `previousLocalDayKey` in scripts/nostalgex-daily-manifest.js.
    static func previousLocalDayKey(before date: Date, calendar: Calendar = .current) -> String {
        localDayKey(for: startOfLocalDay(for: date, calendar: calendar).addingTimeInterval(-12 * 3600),
                    calendar: calendar)
    }

    static func localDayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        Int(startOfLocalDay(for: date, calendar: calendar).timeIntervalSince1970 / 86400)
    }

    private static func baseDirectory(credentialFingerprint: String) -> URL? {
        guard let root = LocalStore.rootDirectory else { return nil }
        let dir = root
            .appendingPathComponent("daily_manifests", isDirectory: true)
            .appendingPathComponent(credentialFingerprint, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    private static func fileURL(channelId: Int, dayKey: String, credentialFingerprint: String) -> URL? {
        baseDirectory(credentialFingerprint: credentialFingerprint)?
            .appendingPathComponent("\(channelId)_\(dayKey).json")
    }

    static func load(
        channelId: Int,
        dayKey: String,
        credentialFingerprint: String,
        expectedPoolFingerprint: String
    ) -> DailyManifestFile? {
        guard let url = fileURL(channelId: channelId, dayKey: dayKey, credentialFingerprint: credentialFingerprint),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try decoder.decode(DailyManifestFile.self, from: data)
            guard manifest.schemaVersion == schemaVersion,
                  manifest.credentialFingerprint == credentialFingerprint,
                  manifest.poolFingerprint == expectedPoolFingerprint else {
                return nil
            }
            return manifest
        } catch {
            print("[Plex90] Manifest: load failed CH\(channelId) \(dayKey): \(error)")
            return nil
        }
    }

    static func save(_ manifest: DailyManifestFile) {
        guard let url = fileURL(
            channelId: manifest.channelId,
            dayKey: manifest.dayKey,
            credentialFingerprint: manifest.credentialFingerprint
        ) else { return }
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Plex90] Manifest: save failed CH\(manifest.channelId) \(manifest.dayKey): \(error)")
        }
    }

    /// A stored day's blocks, in the order they air, whatever schema or pool stored them; []
    /// if the day was never scheduled. What aired yesterday, and what ran past its midnight.
    static func storedBlocks(channelId: Int, dayKey: String, credentialFingerprint: String) -> [StoredManifestBlock] {
        guard let url = fileURL(channelId: channelId, dayKey: dayKey, credentialFingerprint: credentialFingerprint),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(DailyManifestFile.self, from: data) else {
            return []
        }
        return manifest.blocks
    }

    static func airedRatingKeys(channelId: Int, dayKey: String, credentialFingerprint: String) -> Set<String> {
        guard let dir = baseDirectory(credentialFingerprint: credentialFingerprint) else { return [] }
        let url = dir.appendingPathComponent("\(channelId)_\(dayKey).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(DailyManifestFile.self, from: data) else {
            return []
        }
        return Set(manifest.blocks.map(\.ratingKey))
    }

    /// The item a channel was airing right before midnight, if that day was ever scheduled.
    /// `blocks` is written in chronological order (packDay appends as it packs the day), so
    /// the last element is the last thing that aired. Used to stop a title from playing
    /// again immediately after midnight -- the same seam-duplicate the wraparound fill
    /// guards against within a day, one level up at the day boundary.
    static func lastAiredRatingKey(channelId: Int, dayKey: String, credentialFingerprint: String) -> String? {
        guard let dir = baseDirectory(credentialFingerprint: credentialFingerprint) else { return nil }
        let url = dir.appendingPathComponent("\(channelId)_\(dayKey).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(DailyManifestFile.self, from: data) else {
            return nil
        }
        return manifest.blocks.last?.ratingKey
    }

    /// Copies the stored days `dayKeys` from one fingerprint's folder to another's, replacing
    /// what the target held for them. For ScheduleTiming, which packs in a scratch folder so a
    /// TV's own schedules are never touched.
    static func copyDays(_ dayKeys: [String], from source: String, to target: String) {
        guard let src = baseDirectory(credentialFingerprint: source),
              let dst = baseDirectory(credentialFingerprint: target),
              let names = try? FileManager.default.contentsOfDirectory(atPath: src.path) else { return }
        for name in names where dayKeys.contains(where: { name.hasSuffix("_\($0).json") }) {
            let to = dst.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: src.appendingPathComponent(name), to: to)
        }
    }

    static func clearAll(credentialFingerprint: String? = nil) {
        guard let root = LocalStore.rootDirectory else { return }
        let manifests = root.appendingPathComponent("daily_manifests", isDirectory: true)
        if let fp = credentialFingerprint {
            try? FileManager.default.removeItem(at: manifests.appendingPathComponent(fp, isDirectory: true))
        } else {
            try? FileManager.default.removeItem(at: manifests)
        }
        DailyManifestScheduler.invalidateMemo()
    }

    /// Delete manifest files for any day key other than `keepDayKey`.
    /// Preserves today's schedule so a library refresh (background or foreground)
    /// can't blow away an EPG the user is currently watching.
    ///
    /// Also drops the scheduler's in-memory memo: this runs right after a library
    /// rebuild, and a refreshed pool can keep the same shape (and therefore the same
    /// memo key) while its contents differ.
    static func purgeDays(keeping keepDayKey: String, credentialFingerprint: String) {
        DailyManifestScheduler.invalidateMemo()
        guard let dir = baseDirectory(credentialFingerprint: credentialFingerprint) else { return }
        let suffix = "_\(keepDayKey).json"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for url in entries where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(suffix) {
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                print("[Plex90] Manifest: purge failed for \(url.lastPathComponent): \(error)")
            }
        }
        if removed > 0 {
            print("[Plex90] Manifest: purged \(removed) stale day file(s), kept \(keepDayKey)")
        }
    }
}
