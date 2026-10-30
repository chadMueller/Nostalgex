import XCTest
@testable import Nostalgex

/// `PlexAPIService.bestReachableURI` picks the first reachable candidate from a
/// priority-ordered list (local, then remote HTTPS, then remote plain, then relay),
/// probing all of them concurrently. It used to wait for every candidate's probe to
/// finish before returning, even after the winner was already known, so a fast local
/// hit still sat blocked on a slow relay probe (up to 50s) that Plex's API almost
/// always offers as a fallback.
///
/// Two fixes landed, both found live on 2026-10-30:
/// 1. Once every candidate ranked ahead of the current best hit has reported, nothing
///    still in flight can outrank it, so stop waiting and use it now.
/// 2. That alone was not enough: a server whose only reachable path was relay (lowest
///    priority) still waited out a higher-ranked remote-HTTPS candidate's full patient
///    timeout (up to 50s) before accepting the already-known-good relay hit. Fix: once
///    there is a hit, give whatever still outranks it a grace window sized by whether
///    the outstanding candidates are `patient` (remote/relay, which can legitimately
///    take 10-20s to cold-establish and still succeed, so they get real time) or
///    local-only (which answers fast or not at all, so a short grace is safe). Chad:
///    lost/no-connection rate is a tracked metric, so this must never trade a
///    slow-but-real connection for a faster-but-worse one.
///
/// `bestReachableURI` itself is private and does real networking, so this reproduces
/// the same TaskGroup shape with synthetic timed outcomes instead of HTTP calls, to
/// prove the logic behaves correctly in bounded time rather than trusting it by
/// reading. This is the control-flow pattern copied directly from the real function.
final class ConnectionDiscoveryEarlyExitTests: XCTestCase {

    private struct Candidate {
        let delayMs: Int
        let ok: Bool
        /// Mirrors the real function's `!candidate.local || candidate.relay`: true for
        /// remote/relay candidates (can legitimately be slow), false for local ones
        /// (fast or not at all).
        let isPatient: Bool
    }

    /// Same shape as bestReachableURI's inner closure, including the tier-aware grace
    /// sizing. `gracePatientMs`/`graceLocalOnlyMs` mirror the real function's two
    /// constants (15s/3s) but scaled down so tests stay fast.
    private func pickEarly(
        _ candidates: [Candidate],
        gracePatientMs: Int = 300,
        graceLocalOnlyMs: Int = 60
    ) async -> (best: Int?, elapsedMs: Int) {
        let start = DispatchTime.now()
        let hits = await withTaskGroup(of: (idx: Int, ok: Bool).self) { group -> [Int] in
            for (idx, c) in candidates.enumerated() {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(c.delayMs) * 1_000_000)
                    return (idx, c.ok)
                }
            }
            // -1 is a sentinel for the grace timer below, never a real candidate index.
            var reported = Set<Int>()
            var hits: [Int] = []
            var graceStarted = false
            for await (idx, ok) in group {
                if idx >= 0 {
                    reported.insert(idx)
                    if ok { hits.append(idx) }
                }
                guard let best = hits.min() else { continue }
                if (0..<best).allSatisfy({ reported.contains($0) }) {
                    group.cancelAll()
                    break
                }
                if idx == -1 {
                    group.cancelAll()
                    break
                }
                if !graceStarted {
                    graceStarted = true
                    let higherPriorityIncludesPatient = candidates[0..<best].contains { $0.isPatient }
                    let graceMs = higherPriorityIncludesPatient ? gracePatientMs : graceLocalOnlyMs
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(graceMs) * 1_000_000)
                        return (-1, false)
                    }
                }
            }
            return hits
        }
        let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return (hits.min(), elapsedMs)
    }

    /// The real-world shape of the first bug: local (index 0) answers fast, relay
    /// (index 3, the lowest priority) is slow and would eventually fail. Must return
    /// near the winner's own delay, not wait out the slow one, this path doesn't even
    /// reach the grace window, since index 0 has nothing ranked ahead of it.
    func testFastLocalHitReturnsWithoutWaitingOnASlowLaterCandidate() async {
        let candidates = [
            Candidate(delayMs: 50, ok: true, isPatient: false),     // local, the winner
            Candidate(delayMs: 400, ok: false, isPatient: true),    // remote https
            Candidate(delayMs: 400, ok: false, isPatient: true),    // remote plain
            Candidate(delayMs: 2000, ok: false, isPatient: true),   // relay
        ]
        let result = await pickEarly(candidates)
        XCTAssertEqual(result.best, 0)
        XCTAssertLessThan(result.elapsedMs, 500, "should return near the winner's own delay, not the slow relay candidate's")
    }

    /// When the fast candidate fails, the next-ranked one that succeeds should still
    /// short-circuit anything ranked after it, not just anything ranked before it.
    func testSecondCandidateWinsWithoutWaitingOnLowerPriorityOnes() async {
        let candidates = [
            Candidate(delayMs: 60, ok: false, isPatient: false),
            Candidate(delayMs: 120, ok: true, isPatient: true),    // winner
            Candidate(delayMs: 1500, ok: false, isPatient: true),
            Candidate(delayMs: 1500, ok: true, isPatient: true),   // would also succeed, ranked last
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
            Candidate(delayMs: 30, ok: false, isPatient: false),
            Candidate(delayMs: 60, ok: false, isPatient: true),
            Candidate(delayMs: 90, ok: false, isPatient: true),
        ]
        let result = await pickEarly(candidates)
        XCTAssertNil(result.best)
        XCTAssertGreaterThanOrEqual(result.elapsedMs, 90)
    }

    /// A later, lower-priority candidate answering first must not jump the queue: the
    /// earlier-ranked one, even though slower, is still preferred once it reports in,
    /// as long as it reports within the grace window.
    func testEarlierRankedCandidateStillWinsIfItAnswersWithinGrace() async {
        let candidates = [
            Candidate(delayMs: 200, ok: true, isPatient: false),   // ranked first, answers second
            Candidate(delayMs: 50, ok: true, isPatient: true),     // ranked second, answers first
        ]
        let result = await pickEarly(candidates, gracePatientMs: 500, graceLocalOnlyMs: 500)
        XCTAssertEqual(result.best, 0)
    }

    /// The real shape of the second bug, found live 2026-10-30: a low-priority relay
    /// candidate answers fast, but the higher-priority candidates outranking it are
    /// patient (remote) and slow to even fail. Must return close to the patient grace
    /// window after the low-priority hit, not wait out their full delay, but the
    /// patient grace window (not the short local one) is what applies here, since what
    /// is still pending includes a patient candidate.
    func testLowPriorityHitTakenAfterPatientGraceWindowNotAfterSlowHigherPriorityFails() async {
        let candidates = [
            Candidate(delayMs: 2500, ok: false, isPatient: false),  // local, slow to fail, loses anyway
            Candidate(delayMs: 2500, ok: false, isPatient: true),   // remote https, patient, slow to fail
            Candidate(delayMs: 50, ok: true, isPatient: true),      // relay, the only real winner, fast
        ]
        let result = await pickEarly(candidates, gracePatientMs: 150, graceLocalOnlyMs: 20)
        XCTAssertEqual(result.best, 2)
        XCTAssertLessThan(result.elapsedMs, 2500, "must not wait out the slow higher-priority candidates")
        XCTAssertGreaterThanOrEqual(result.elapsedMs, 50 + 150 - 20, "must use the patient grace window, giving a real chance, not fire instantly")
    }

    /// Mirrors Chad's reliability concern directly: when everything still outstanding
    /// above the current hit is local-only (never legitimately slow-but-successful),
    /// the short local-only grace applies, not the long patient one, local really is
    /// fast or not at all, so there's no reason to wait as long.
    func testShortGraceAppliesWhenOnlyLocalCandidatesAreStillPending() async {
        let candidates = [
            Candidate(delayMs: 400, ok: false, isPatient: false),  // local, slow-ish to fail, still loses
            Candidate(delayMs: 50, ok: true, isPatient: true),     // remote https, the real winner, fast
        ]
        let result = await pickEarly(candidates, gracePatientMs: 2000, graceLocalOnlyMs: 60)
        XCTAssertEqual(result.best, 1)
        XCTAssertLessThan(result.elapsedMs, 400, "only a local candidate is still pending, so the short grace applies, not the 2000ms patient one")
    }

    /// If something higher-priority succeeds inside the grace window, it should still
    /// win over the earlier low-priority hit, not just whichever answered first.
    func testHigherPriorityHitWithinGraceWindowStillWins() async {
        let candidates = [
            Candidate(delayMs: 2500, ok: false, isPatient: false), // local, fails late, irrelevant
            Candidate(delayMs: 120, ok: true, isPatient: true),    // remote https, succeeds inside grace
            Candidate(delayMs: 50, ok: true, isPatient: true),     // relay, answers first, but ranked last
        ]
        let result = await pickEarly(candidates, gracePatientMs: 200, graceLocalOnlyMs: 200)
        XCTAssertEqual(result.best, 1, "remote https answered within the grace window and outranks relay")
    }
}
