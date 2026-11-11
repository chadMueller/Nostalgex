package com.muellhaus.nostalgex.engine

/**
 * Which address of a Plex server to use: every address asked at once, and no more waiting once
 * the answer cannot change. scripts/nostalgex-server-resolve.js, which is the Apple TV's
 * `PlexAPIService.bestReachableURI` and Roku's `NxResolveOutcome`; held to that file's answers
 * by `ServerResolveTest` over the vectors `gen-resolve-vectors.mjs` writes.
 *
 * The rules:
 * - Order: home network (local, not relay), then remote HTTPS, then remote plain, then relay;
 *   HTTPS first within a kind; plex.tv's order after that. The best kind that answers wins.
 * - The answer is settled once the best kind that has answered has nothing better still waiting.
 *   A home-network answer settles at once.
 * - A home address silent for [GRACE_MS] counts as failed, but only once another address has
 *   answered: with no answer anywhere, a slow home address is still waited for.
 * - At [DEADLINE_MS] everything still waiting counts as failed. Nothing answering is an answer: null.
 *
 * Pure, with no clock of its own: [Resolver] is told when a probe reports, when the grace has
 * passed and when the deadline has, and says when it is settled.
 */
object ServerResolve {
    const val GRACE_MS = 3000L
    const val DEADLINE_MS = 10000L

    data class Conn(val uri: String, val local: Boolean, val relay: Boolean)

    private val KINDS = listOf("local", "remote", "remote (plain)", "relay")

    private fun https(uri: String) = uri.startsWith("https:", ignoreCase = true)

    /** 0 home network, 1 remote HTTPS, 2 remote plain, 3 relay (a relay is a relay even on the LAN). */
    fun tierOf(c: Conn) = when {
        c.relay -> 3
        c.local -> 0
        https(c.uri) -> 1
        else -> 2
    }

    enum class Status { WAITING, OK, FAIL }

    class Candidate internal constructor(val conn: Conn, val tier: Int, val index: Int) {
        val kind get() = KINDS[tier]
        var status = Status.WAITING
    }

    /** The addresses to try, best first; one with no address is skipped. */
    fun candidates(conns: List<Conn?>): List<Candidate> =
        conns.withIndex().filter { (_, c) -> c != null && c.uri.isNotEmpty() }
            .map { (i, c) -> Candidate(c!!, tierOf(c), i) }
            .sortedWith(compareBy<Candidate>({ it.tier }, { if (https(it.conn.uri)) 0 else 1 }, { it.index }))

    data class Outcome(val settled: Boolean, val conn: Conn?, val kind: String)

    /** What the candidates say so far (outcome, NxResolveOutcome). `conn` is null when settled with no answer. */
    fun outcome(cands: List<Candidate>, elapsedMs: Long, graceMs: Long, expired: Boolean): Outcome {
        val someoneAnswered = cands.any { it.status == Status.OK }
        fun statusOf(c: Candidate) = when {
            c.status != Status.WAITING -> c.status
            expired || (someoneAnswered && c.tier == 0 && elapsedMs >= graceMs) -> Status.FAIL
            else -> Status.WAITING
        }
        for (tier in 0..3) {
            var waiting = false
            for (c in cands) {
                if (c.tier != tier) continue
                when (statusOf(c)) {
                    Status.OK -> return Outcome(true, c.conn, c.kind)
                    Status.WAITING -> waiting = true
                    Status.FAIL -> {}
                }
            }
            // A better kind may still answer; worse ones wait for it.
            if (waiting) return Outcome(false, null, "")
        }
        return Outcome(true, null, "")
    }

    /**
     * One resolution (resolve, without its timers). Feed it [report] as each probe answers,
     * [graceFired] when [GRACE_MS] has passed and [expired] at the deadline; each returns the
     * outcome once settled, and null while it is not. After that it ignores everything.
     */
    class Resolver(conns: List<Conn?>, val graceMs: Long = GRACE_MS, val deadlineMs: Long = DEADLINE_MS) {
        val candidates = candidates(conns)
        var result: Outcome? = if (candidates.isEmpty()) Outcome(true, null, "") else null
            private set
        private var graceHasFired = false
        private var hasExpired = false

        private fun check(elapsedMs: Long): Outcome? {
            if (result != null) return null
            // A timer can run a hair early; once the grace timer has fired the grace has passed.
            val elapsed = if (graceHasFired) maxOf(elapsedMs, graceMs) else elapsedMs
            val out = outcome(candidates, elapsed, graceMs, hasExpired)
            if (out.settled) result = out
            return result
        }

        /** The probe of `candidate` answered: true when the address is this server. */
        fun report(candidate: Candidate, ok: Boolean, elapsedMs: Long): Outcome? {
            if (result != null) return null
            candidate.status = if (ok) Status.OK else Status.FAIL
            return check(elapsedMs)
        }

        fun graceFired(elapsedMs: Long): Outcome? {
            graceHasFired = true
            return check(elapsedMs)
        }

        fun expired(elapsedMs: Long): Outcome? {
            hasExpired = true
            return check(elapsedMs)
        }
    }

    /**
     * Whether an /identity answer is this server's (identityMatches): its machineIdentifier is
     * the one plex.tv gave. One that can't be read, or no identifier on file, is accepted, as it
     * was before the check: only a different identifier turns an address down. A private address
     * on some other network can be another Plex server.
     */
    fun identityMatches(answered: String?, expected: String?): Boolean =
        expected.isNullOrEmpty() || answered.isNullOrEmpty() || answered == expected
}
