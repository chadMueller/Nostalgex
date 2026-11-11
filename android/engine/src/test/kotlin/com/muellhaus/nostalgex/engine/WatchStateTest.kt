package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The watch state against scripts/watch-cleanup-golden.json (the Apple TV's WatchStateGuardTests
 * read it too) and the web tuner's own answers over the Roku port's scripts (gen-watch.mjs).
 */
class WatchStateTest {
    private val root = File(System.getProperty("nostalgex.repoRoot"))
    private val vectors = Json.parseToJsonElement(File(System.getProperty("nostalgex.watchVectors")).readText()).jsonObject

    private fun prior(e: kotlinx.serialization.json.JsonElement?): WatchState.Prior? {
        val o = e as? JsonObject ?: return null
        fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
        return WatchState.Prior(
            o["resumePosition"]!!.jsonPrimitive.long, o["playCount"]!!.jsonPrimitive.int, o["played"]!!.jsonPrimitive.boolean,
            s("lastPlayedDate"), s("showKey"), (o["showInContinueWatching"] as? JsonPrimitive)?.booleanOrNull == true,
        )
    }

    private fun plan(backend: String, p: WatchState.Prior?, counted: Boolean) =
        (if (backend == "plex") WatchState.plexPlan(p, counted) else WatchState.mediaServerPlan(p, counted)).map(WatchState::describe)

    @Test fun everyGoldenCaseMatchesTheAppleTv() {
        val cases = Json.parseToJsonElement(File(root, "scripts/watch-cleanup-golden.json").readText()).jsonObject["cases"]!!.jsonArray
        assertTrue(cases.size >= 16)
        for (c in cases.map { it.jsonObject }) {
            val want = c["steps"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(c["name"]!!.jsonPrimitive.content, want,
                plan(c["backend"]!!.jsonPrimitive.content, prior(c["prior"]), c["counted"]!!.jsonPrimitive.boolean))
        }
    }

    @Test fun thePlansMatchTheWebTunersForEveryOtherPrior() {
        for (c in vectors["plans"]!!.jsonArray.map { it.jsonObject }) {
            val backend = c["backend"]!!.jsonPrimitive.content
            assertEquals("$backend ${c["prior"]} ${c["counted"]}", c["steps"]!!.jsonArray.map { it.jsonPrimitive.content },
                plan(backend, prior(c["prior"]), c["counted"]!!.jsonPrimitive.boolean))
        }
    }

    @Test fun theBackoffAnswersAsTheWebTuners() {
        for (c in vectors["backoff"]!!.jsonArray.map { it.jsonObject }) {
            val b = WatchState.PulseBackoff()
            val answers = ArrayList<Boolean>()
            for (step in c["steps"]!!.jsonArray.map { it.jsonPrimitive.content }) {
                if (step == "pulse") answers += b.allowPulse() else b.record(step == "ok")
            }
            assertEquals(c["name"]!!.jsonPrimitive.content, c["answers"]!!.jsonArray.map { it.jsonPrimitive.boolean }, answers)
        }
    }

    @Test fun theGatesAreFifteenAndSeventyFivePercent() {
        assertTrue(WatchState.eligibleEntry(900, 6000))
        assertFalse(WatchState.eligibleEntry(901, 6000))
        assertFalse(WatchState.eligibleEntry(0, 0))
        assertTrue(WatchState.watchedEnough(4500.0, 6000))
        assertFalse(WatchState.watchedEnough(4499.0, 6000))
        assertEquals("never past 89%", 5340L * 10_000_000, WatchState.stopTicks(6000L * 10_000_000, 6000))
        assertEquals(10L, WatchState.stopTicks(10, 6000))
    }

    /** Turning a choice off revokes what an earlier tracker queued; turning it on again doesn't restore it. */
    @Test fun theScopesEpochsRevokeQueuedWork() {
        val scope = WatchState.ReportingScope(nowPlaying = true, markWatched = true)
        val a = scope.activityEpoch
        val m = scope.markEpoch
        assertTrue(scope.allowsActivity(a) && scope.allowsMark(m))
        scope.update(nowPlaying = false, markWatched = true)
        assertFalse(scope.allowsActivity(a))
        scope.update(nowPlaying = true, markWatched = true)
        assertFalse("an old epoch stays revoked", scope.allowsActivity(a))
        assertTrue(scope.allowsActivity(scope.activityEpoch))
        assertTrue(scope.allowsMark(m))
    }
}
