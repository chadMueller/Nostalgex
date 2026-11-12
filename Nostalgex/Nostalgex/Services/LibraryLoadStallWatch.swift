import Foundation

// MARK: - Progress sample

/// The counters a healthy library scan keeps moving. Compared as a whole: any field
/// changing means the load is still doing something, however slowly.
struct LibraryLoadProgressSample: Equatable, Sendable {
    var phase: Int = 0
    var sectionIndex: Int = 0
    var totalSections: Int = 0
    var itemsFound: Int = 0
    /// Carries the finer-grained progress the counters can't express (shows completed
    /// inside one section, which server is being read). Without it a TV section reporting
    /// `60/130 shows` looks identical to a frozen one, because `itemsFound` only moves
    /// when a page lands.
    var detail: String = ""
}

// MARK: - Stall detection

/// Separates "stalled" from "slow but working".
///
/// Elapsed time alone cannot tell those apart: a large library over a thin connection
/// legitimately takes many minutes, and killing that scan would punish exactly the users
/// this is meant to protect. Only the *absence of forward progress* counts.
struct LibraryLoadStallDetector {
    enum Verdict: Equatable {
        case progressing
        /// Quiet long enough to tell the user, not long enough to act on.
        case slow(secondsWithoutProgress: TimeInterval)
        case stalled(secondsWithoutProgress: TimeInterval)
    }

    /// A single page request can legitimately go quiet for its whole retry ladder: three
    /// attempts against a 60s request timeout plus ~1.5s of backoff, about 181s. That path
    /// ends in a real URL error whose message beats anything invented here, so the
    /// watchdog sits above it and only fires on what nothing else catches: a connection
    /// that neither fails nor finishes.
    static let defaultStallAfter: TimeInterval = 210

    /// Long enough that a slow page doesn't nag, short enough that nobody sits in front of
    /// a frozen screen wondering whether the app died.
    static let defaultWarnAfter: TimeInterval = 60

    let warnAfter: TimeInterval
    let stallAfter: TimeInterval
    private var lastSample: LibraryLoadProgressSample
    private var lastChangeAt: Date

    init(
        start: LibraryLoadProgressSample,
        at now: Date,
        warnAfter: TimeInterval = LibraryLoadStallDetector.defaultWarnAfter,
        stallAfter: TimeInterval = LibraryLoadStallDetector.defaultStallAfter
    ) {
        self.lastSample = start
        self.lastChangeAt = now
        self.warnAfter = warnAfter
        self.stallAfter = stallAfter
    }

    mutating func evaluate(_ sample: LibraryLoadProgressSample, at now: Date) -> Verdict {
        if sample != lastSample {
            lastSample = sample
            lastChangeAt = now
            return .progressing
        }
        let idle = now.timeIntervalSince(lastChangeAt)
        if idle >= stallAfter { return .stalled(secondsWithoutProgress: idle) }
        if idle >= warnAfter { return .slow(secondsWithoutProgress: idle) }
        return .progressing
    }
}

/// Thrown when a scan is abandoned: either the watchdog saw no progress for `stallAfter`,
/// or the user chose to stop waiting.
struct LibraryLoadStalled: Error {
    let secondsWithoutProgress: TimeInterval
    let userInitiated: Bool
}

// MARK: - Running work under the watchdog

/// Runs `operation` while sampling the load's progress counters alongside it, and abandons
/// it once `LibraryLoadStallDetector` calls the load stalled, or `abortRequested` returns
/// true (the user taking the way out).
///
/// The operation gets its own task so it can be cancelled out from under a wedged network
/// read. Two things keep that honest under structured concurrency: the caller's
/// cancellation is forwarded to it, and the watcher is cancelled on every exit path, so a
/// load that finishes normally leaves nothing running.
///
/// After a stall the operation's *own* error wins over `LibraryLoadStalled` whenever it has
/// something to say: backends throw `LibraryScanInterrupted` carrying the sections they had
/// already read, which is how a stalled load still produces a guide. Only a bare
/// cancellation, which carries nothing, is replaced by the stall.
///
/// `LibraryScanInterrupted` itself can't say *why* it was cancelled, the backend that
/// throws it only sees `Task.isCancelled`, not the watchdog's verdict. Before re-throwing
/// it, this stamps it with the same `userInitiated` the watcher resolved to, so a user who
/// tapped "Stop Waiting" on a section that had already read some pages isn't silently
/// recorded (and treated) the same as an automatic stall.
@MainActor
func withLibraryLoadStallWatch<T: Sendable>(
    warnAfter: TimeInterval = LibraryLoadStallDetector.defaultWarnAfter,
    stallAfter: TimeInterval = LibraryLoadStallDetector.defaultStallAfter,
    pollInterval: TimeInterval = 2,
    sample: @escaping @MainActor () -> LibraryLoadProgressSample,
    onVerdict: @escaping @MainActor (LibraryLoadStallDetector.Verdict) -> Void,
    abortRequested: @escaping @MainActor () -> Bool,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let work = Task { try await operation() }

    let watcher = Task { @MainActor () -> LibraryLoadStalled? in
        var detector = LibraryLoadStallDetector(
            start: sample(),
            at: Date(),
            warnAfter: warnAfter,
            stallAfter: stallAfter
        )
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                return nil
            }
            if abortRequested() {
                print("[Plex90] STALL: user stopped waiting on the library scan")
                work.cancel()
                return LibraryLoadStalled(secondsWithoutProgress: 0, userInitiated: true)
            }
            let verdict = detector.evaluate(sample(), at: Date())
            onVerdict(verdict)
            if case .stalled(let seconds) = verdict {
                print("[Plex90] STALL: no scan progress for \(Int(seconds))s, abandoning this scan")
                work.cancel()
                return LibraryLoadStalled(secondsWithoutProgress: seconds, userInitiated: false)
            }
        }
        return nil
    }
    defer { watcher.cancel() }

    do {
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    } catch {
        watcher.cancel()
        let verdict = await watcher.value
        if isBareCancellation(error), let stall = verdict {
            throw stall
        }
        if var interrupted = error as? LibraryScanInterrupted, let stall = verdict {
            interrupted.userInitiated = stall.userInitiated
            throw interrupted
        }
        throw error
    }
}

/// A cancellation with nothing else to say. `LibraryScanInterrupted` and real transport
/// failures carry information worth keeping; these don't.
private func isBareCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
}
