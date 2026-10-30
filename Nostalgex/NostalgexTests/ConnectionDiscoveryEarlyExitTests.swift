import XCTest
@testable import Nostalgex

/// `PlexAPIService.bestReachableURI` picks the first reachable candidate from a
/// priority-ordered list (local, then remote HTTPS, then remote plain, then relay),
/// probing all of them concurrently. It used to wait for every candidate's probe to
/// finish before returning, even after the winner was already known, so a fast local
/// hit still sat blocked on a slow relay probe (up to 50s) that Plex's API almost
/// always offers as a fallback. The fix: stop waiting once nothing still in flight
/// outranks the best hit so far.
///
/// `bestReachableURI` itself is private and does real networking, so this reproduces
/// the same TaskGroup shape with synthetic timed outcomes instead of HTTP calls, to
/// prove the early-exit logic returns in bounded time rather than trusting it by
/// reading. This is the control-flow pattern copied from the real function's fix.
final class ConnectionDiscoveryEarlyExitTests: XCTestCase {

    private struct Candidate {
        let delayMs: Int
        let ok: Bool
    }

    /// Same shape as bestReachableURI's inner closure: races candidates, returns the
    /// lowest-index success once nothing earlier-ranked can still change the answer.
    private func pickEarly(_ candidates: [Candidate]) async -> (best: Int?, elapsedMs: Int) {
        let start = DispatchTime.now()
        let hits = await withTaskGroup(of: (idx: Int, ok: Bool).self) { group -> [Int] in
            for (idx, c) in candidates.enumerated() {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(c.delayMs) * 1_000_000)
                    return (idx, c.ok)
                }
            }
            var reported = Set<Int>()
            var hits: [Int] = []
            for await (idx, ok) in group {
                reported.insert(idx)
                if ok { hits.append(idx) }
                if let best = hits.min(), (0..<best).allSatisfy({ reported.contains($0) }) {
                    group.cancelAll()
                    break
                }
            }
            return hits
        }
        let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return (hits.min(), elapsedMs)
    }

    /// The real-world shape of the bug: local (index 0) answers fast, relay (index 3,
    /// the lowest priority) is slow and would eventually fail. Must return close to the
    /// local candidate's own delay, not wait out the slow one.
    func testFastLocalHitReturnsWithoutWaitingOnASlowLaterCandidate() async {
        let candidates = [
            Candidate(delayMs: 50, ok: true),     // local — the winner
            Candidate(delayMs: 400, ok: false),   // remote https — slower, loses anyway
            Candidate(delayMs: 400, ok: false),   // remote plain
            Candidate(delayMs: 2000, ok: false),  // relay — the old 45s-class delay, scaled down
        ]
        let result = await pickEarly(candidates)
        XCTAssertEqual(result.best, 0)
        XCTAssertLessThan(result.elapsedMs, 500, "should return near the winner's own delay, not the slow relay candidate's")
    }

    /// When the fast candidate fails, the next-ranked one that succeeds should still
    /// short-circuit anything ranked after it, not just anything ranked before it.
    func testSecondCandidateWinsWithoutWaitingOnLowerPriorityOnes() async {
        let candidates = [
            Candidate(delayMs: 60, ok: false),
            Candidate(delayMs: 120, ok: true),    // winner
            Candidate(delayMs: 1500, ok: false),
            Candidate(delayMs: 1500, ok: true),   // would also succeed, but ranked last
        ]
        let result = await pickEarly(candidates)
        XCTAssertEqual(result.best, 1)
        XCTAssertLessThan(result.elapsedMs, 400)
    }

    /// Everything fails: must still wait for every candidate (there's no early exit
    /// possible, since a later one could always still be the only hit) and report no
    /// winner, not time out or hang.
    func testNoReachableCandidateWaitsForAllAndReturnsNil() async {
        let candidates = [
            Candidate(delayMs: 30, ok: false),
            Candidate(delayMs: 60, ok: false),
            Candidate(delayMs: 90, ok: false),
        ]
        let result = await pickEarly(candidates)
        XCTAssertNil(result.best)
        XCTAssertGreaterThanOrEqual(result.elapsedMs, 90)
    }

    /// A later, lower-priority candidate answering first must not jump the queue: the
    /// earlier-ranked one, even though slower, is still preferred once it reports in.
    func testEarlierRankedCandidateStillWinsEvenIfItAnswersLast() async {
        let candidates = [
            Candidate(delayMs: 200, ok: true),   // ranked first, answers second
            Candidate(delayMs: 50, ok: true),    // ranked second, answers first
        ]
        let result = await pickEarly(candidates)
        XCTAssertEqual(result.best, 0)
    }
}
