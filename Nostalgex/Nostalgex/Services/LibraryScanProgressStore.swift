import Foundation

/// Each library section's items, kept on disk the moment that section's scan finishes, so a
/// first setup that is killed part way (the app crashing, jetsam, the user pulling the plug,
/// #146) is not started over: the next launch keeps the finished sections and scans the rest.
///
/// This is NOT the library snapshot and never becomes one. The snapshot (`LibrarySnapshotStore`)
/// is the whole library plus the channels built from it, written once a scan has finished, and
/// nothing here writes to it or changes its format. This is a separate directory of finished
/// sections that exists only while a first-time scan is unfinished:
///
///     library_scan_progress/<server key>/<section key>/
///         items-0000.json ...   10k items per file
///         done.json             written LAST, atomically: the section is only real once it exists
///
/// A section directory with no `done.json` (killed mid-write) is ignored and removed. A section
/// that failed, was cancelled partway, or was never reached has no entry at all, so a partial
/// section can never be read back as a whole one. The same rule the web tuner follows: a section
/// that was lost is not kept as if it were complete.
///
/// A kept section is reused only if all of these hold, otherwise it is deleted and scanned again:
/// the same build of the app wrote it (a new build never merges items read by another), the scan
/// request version matches, it is young enough (an hour; six when Plex's own change counters for
/// the section still match what was saved), and every chunk decodes to the saved count.
///
/// Used by foreground loads only. A background refresh already has a library on screen and wants
/// a fresh read, so it neither reads nor writes here. The snapshot save that follows a complete
/// scan removes the whole directory; Disconnect, START OVER and RESCAN LIBRARY remove it too
/// (they clear the snapshot, and `LibrarySnapshotStore.clear()` calls `clearAll()`).
enum LibraryScanProgressStore {
    static let formatVersion = 1
    /// Items per file; the same size the snapshot uses, so encoding one costs tens of MB, not a
    /// section's worth (a section can be 105,000 movies).
    /// A var only so tests can lower it.
    nonisolated(unsafe) static var chunkSize = 10_000
    /// How long a kept section may be reused when nothing can say it is unchanged.
    static let maxAgeSeconds = 3600
    /// How long when Plex's change counters for the section (`updatedAt`, `contentChangedAt`)
    /// are the same now as when it was saved.
    static let maxAgeSignedSeconds = 6 * 3600

    static let directoryName = "library_scan_progress"
    private static let doneName = "done.json"

    static var directoryURL: URL? {
        LocalStore.rootDirectory?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The build number that wrote a section. A kept section from another build is dropped.
    static var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    // MARK: Write ordering (same idea as LibrarySnapshotStore)

    private static let epochLock = NSLock()
    private static var epoch: UInt64 = 0
    private static let queue = DispatchQueue(label: "com.muellhaus.nostalgex.scan-progress", qos: .utility)

    private static func currentEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        return epoch
    }

    /// Removes everything and cancels writes still queued, so a section that was being saved
    /// when the user hit Disconnect can never bring the old library's items back.
    static func clearAll() {
        epochLock.lock(); defer { epochLock.unlock() }
        epoch &+= 1
        if let dir = directoryURL { try? FileManager.default.removeItem(at: dir) }
    }

    /// Runs `work` after every queued section write, on the writer queue. Used to clear after the
    /// snapshot commits.
    static func afterPendingWrites(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Blocks until every queued section write has finished or been dropped. Tests.
    static func waitForPendingWrites() {
        queue.sync {}
    }

    /// Test hook: called after each chunk file of a section is written, with the chunk index.
    /// Throwing stops the write there, the way a kill would, leaving no `done.json`.
    nonisolated(unsafe) static var afterChunkWritten: ((Int) throws -> Void)?

    // MARK: Files

    struct Done: Codable {
        var format: Int
        var build: String
        var scanFieldsVersion: Int
        var sectionKey: String
        var sectionTitle: String
        var signature: String?
        var savedAtUnix: Int
        var itemCount: Int
        var chunkCounts: [Int]
        var skippedNoRuntime: Int
    }

    /// A kept section handed back to the scan.
    struct Resumed {
        let items: [PlexMediaItem]
        let skippedNoRuntime: Int
    }

    /// One server's scan. Make one per server per load; it holds no open files.
    final class Checkpoint: @unchecked Sendable {
        private let root: URL?
        private let scanFieldsVersion: Int
        private let build: String
        private let now: @Sendable () -> Date
        /// The write epoch when this checkpoint was made, i.e. when its load started. A
        /// `clearAll()` after that (Disconnect, START OVER, RESCAN) drops every later write from
        /// it, including a section that finishes while the cancelled scan has not noticed yet.
        private let epoch: UInt64
        private let lock = NSLock()
        private var resumedKeys: [String] = []
        private var sweptUncommitted = false

        /// `identity` is the snapshot identity seed (backend, server, user); `serverID` tells
        /// the servers of a multi-server sign-in apart.
        init(identity: String, serverID: String, scanFieldsVersion: Int,
             build: String = LibraryScanProgressStore.currentBuild,
             now: @escaping @Sendable () -> Date = { Date() }) {
            let key = LibrarySnapshotStore.fingerprint(identity: identity + "|" + serverID)
            self.root = LibraryScanProgressStore.directoryURL?.appendingPathComponent(String(key.prefix(32)), isDirectory: true)
            self.scanFieldsVersion = scanFieldsVersion
            self.build = build
            self.now = now
            self.epoch = LibraryScanProgressStore.currentEpoch()
        }

        /// Section keys this scan took from disk instead of reading from the server.
        var resumedSectionKeys: [String] { lock.lock(); defer { lock.unlock() }; return resumedKeys }

        private func dir(for sectionKey: String) -> URL? {
            root?.appendingPathComponent(String(LibrarySnapshotStore.fingerprint(identity: "section|" + sectionKey).prefix(24)), isDirectory: true)
        }

        /// Directories a kill left without `done.json`.
        private func sweepUncommittedOnce() {
            lock.lock()
            let first = !sweptUncommitted
            sweptUncommitted = true
            lock.unlock()
            guard first, let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
            for name in names {
                let sub = root.appendingPathComponent(name, isDirectory: true)
                if !FileManager.default.fileExists(atPath: sub.appendingPathComponent(LibraryScanProgressStore.doneName).path) {
                    try? FileManager.default.removeItem(at: sub)
                }
            }
        }

        /// The kept items of a finished section, or nil when there are none worth trusting.
        /// `signature` is the section's change counters as the server reports them now (Plex),
        /// nil when the server has none.
        func resumable(sectionKey: String, signature: String?) -> Resumed? {
            sweepUncommittedOnce()
            guard let dir = dir(for: sectionKey) else { return nil }
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.path) else { return nil }
            func discard(_ why: String) -> Resumed? {
                InstallDiagnostics.note("scan progress: dropping kept section \(sectionKey): \(why)")
                try? fm.removeItem(at: dir)
                return nil
            }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(LibraryScanProgressStore.doneName)),
                  let done = try? JSONDecoder().decode(Done.self, from: data) else { return discard("no done marker") }
            guard done.format == LibraryScanProgressStore.formatVersion else { return discard("format \(done.format)") }
            guard done.build == build else { return discard("written by build \(done.build)") }
            guard done.scanFieldsVersion == scanFieldsVersion else { return discard("scan version \(done.scanFieldsVersion)") }
            guard done.sectionKey == sectionKey else { return discard("section key mismatch") }
            let age = Int(now().timeIntervalSince1970) - done.savedAtUnix
            let sameCounters = signature != nil && signature == done.signature
            let limit = sameCounters ? LibraryScanProgressStore.maxAgeSignedSeconds : LibraryScanProgressStore.maxAgeSeconds
            guard age >= 0, age <= limit else { return discard("\(age)s old") }
            if let signature, let saved = done.signature, signature != saved { return discard("section changed on the server") }

            var items: [PlexMediaItem] = []
            items.reserveCapacity(done.itemCount)
            let decoder = JSONDecoder()
            for (i, expected) in done.chunkCounts.enumerated() {
                guard let chunk = try? Data(contentsOf: dir.appendingPathComponent(LibraryScanProgressStore.chunkName(i))),
                      let part = try? decoder.decode([PlexMediaItem].self, from: chunk), part.count == expected else {
                    return discard("chunk \(i) unreadable")
                }
                items.append(contentsOf: part)
            }
            guard items.count == done.itemCount else { return discard("count \(items.count) != \(done.itemCount)") }
            lock.lock(); resumedKeys.append(sectionKey); lock.unlock()
            InstallDiagnostics.note("scan progress: resumed section \(sectionKey) (\(done.sectionTitle)) with \(items.count) items, \(age)s old")
            return Resumed(items: items, skippedNoRuntime: done.skippedNoRuntime)
        }

        /// Keeps a section that has just been read IN FULL. Call only when the section's fetch
        /// returned without being cancelled and without an error; the write runs on a
        /// background queue and returns at once.
        func record(sectionKey: String, sectionTitle: String, signature: String?, skippedNoRuntime: Int, items: [PlexMediaItem]) {
            guard let dir = dir(for: sectionKey), let root else { return }
            let e = epoch
            let done = Done(format: LibraryScanProgressStore.formatVersion, build: build, scanFieldsVersion: scanFieldsVersion,
                            sectionKey: sectionKey, sectionTitle: sectionTitle, signature: signature,
                            savedAtUnix: Int(now().timeIntervalSince1970), itemCount: items.count,
                            chunkCounts: [], skippedNoRuntime: skippedNoRuntime)
            LibraryScanProgressStore.queue.async {
                do {
                    try LibraryScanProgressStore.write(done, items: items, to: dir, root: root, epoch: e)
                } catch {
                    // Losing a kept section costs a re-scan of that section, nothing else.
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
    }

    fileprivate static func chunkName(_ i: Int) -> String { String(format: "items-%04d.json", i) }

    private enum WriteError: Error { case superseded }

    private static func write(_ template: Done, items: [PlexMediaItem], to dir: URL, root: URL, epoch e: UInt64) throws {
        let fm = FileManager.default
        // Cleared since this checkpoint was made: write nothing, and do not recreate the directory.
        guard currentEpoch() == e else { throw WriteError.superseded }
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var counts: [Int] = []
        var start = 0
        while start < items.count {
            guard currentEpoch() == e else { throw WriteError.superseded }
            let end = min(start + chunkSize, items.count)
            let index = counts.count
            try autoreleasepool {
                let data = try encoder.encode(Array(items[start..<end]))
                try data.write(to: dir.appendingPathComponent(chunkName(index)))
            }
            counts.append(end - start)
            start = end
            try afterChunkWritten?(index)
        }
        var done = template
        done.chunkCounts = counts
        let doneData = try encoder.encode(done)
        // Commit under the lock clearAll() deletes under: either it ran first (nothing commits)
        // or it runs after and removes what this wrote.
        epochLock.lock()
        defer { epochLock.unlock() }
        guard epoch == e else { throw WriteError.superseded }
        try doneData.write(to: dir.appendingPathComponent(doneName), options: .atomic)
    }
}
