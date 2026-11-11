package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * The lineup's days are packed together: one title is not on two channels at once wherever a
 * channel has something else to air. The golden file holds the engine to the Apple TV's
 * answers; these hold the answers to the properties the guide depends on, the cases of
 * scripts/nostalgex-schedule-lineup-smoke.mjs over the same generated library.
 */
class ScheduleLineupTest {
    private val zone = ZoneId.of("America/New_York")
    private val day = LocalDateTime.of(2026, 11, 12, 0, 0).atZone(zone).toInstant().toEpochMilli()
    private val sk = "lineup-smoke"

    private fun movie(key: String, title: String, minutes: Int) = MediaItem(key, title, "movie", minutes, 0)

    // The smoke's library, with its generator's arithmetic in doubles as JavaScript does it.
    private val films: List<MediaItem>
    private val episodes: List<MediaItem>

    init {
        var seed = 7.0
        fun rnd(): Double {
            seed = (seed * 1103515245.0 + 12345.0) % 2147483648.0
            return seed / 2147483648.0
        }
        val f = ArrayList<MediaItem>()
        for (i in 0 until 240) f += movie("f$i", "Film $i", 80 + Math.floor(rnd() * 70).toInt())
        for ((base, n) in listOf("Saga" to 3, "Quest" to 2)) for (p in 1..n) f += movie("$base$p", "The $base Part $p", 100 + p * 7)
        films = f
        episodes = (0 until 6).flatMap { s -> (0 until 20).map { e -> MediaItem("s${s}e$e", "Show $s", "episode", 22 + (s % 3) * 22, 0) } }
    }

    private class E(val channel: ScheduleChannel, val pool: List<MediaItem>)

    /** 24 channels whose pools overlap heavily: windows over the library, a premiere channel, a gated one. */
    private fun lineup(): MutableList<E> = (0 until 24).map { c ->
        val from = (c * 17) % 200
        val pool = films.subList(from, minOf(films.size, from + 40 + (c % 5) * 10)).toMutableList()
        if (c % 4 == 0) pool += films.filter { "Part" in it.title }
        if (c % 3 == 0) pool += episodes.subList((c % 6) * 20, (c % 6) * 20 + 20)
        E(ScheduleChannel(10 + c, isPremiereChannel = c == 5, gated = c == 7), pool)
    }.toMutableList()

    private fun engine() = DailyManifest(zone, InMemoryManifestStore())
    private fun DailyManifest.register(l: List<E>) = setLineup { l.map { it.channel to it.pool } }

    private fun dayAt(d: Int) = day + d * 86_400_000L + 3_600_000L

    private fun packDays(m: DailyManifest, entries: List<E>, order: List<Int>, days: List<Int> = listOf(0, 1, 2)) =
        days.associateWith { d ->
            order.associate { i -> entries[i].channel.id to m.getManifestBlocks(entries[i].channel, entries[i].pool, dayAt(d), sk).map { "${it.item.ratingKey}@${it.startSec}-${it.endSec}" } }
                .toSortedMap()
        }

    private fun overlaps(day: Map<Int, List<String>>): Int {
        class S(val ch: Int, val a: Long, val b: Long)
        val by = HashMap<String, MutableList<S>>()
        var n = 0
        for ((ch, blocks) in day) for (s in blocks) {
            val (k, span) = s.split("@")
            val (a, b) = span.split("-").map { it.toLong() }
            for (o in by[k] ?: emptyList<S>()) if (o.ch != ch && minOf(b, o.b) > maxOf(a, o.a)) n++
            by.getOrPut(k) { ArrayList() }.add(S(ch, a, b))
        }
        return n
    }

    private fun order(n: Int, how: String): List<Int> {
        val a = (0 until n).toMutableList()
        if (how == "reverse") a.reverse()
        if (how == "shuffle") {
            var s = 3L
            for (i in a.size - 1 downTo 1) {
                s = (s * 69069 + 1) % 4294967296L
                val j = (s % (i + 1)).toInt()
                val t = a[i]; a[i] = a[j]; a[j] = t
            }
        }
        return a
    }

    private val l = lineup()
    private val guideRun by lazy { engine().also { it.register(l) }.let { packDays(it, l, order(l.size, "guide")) } }

    @Test fun noTitleOnTwoChannelsAtOnceAndTheControlClashes() {
        for (d in 0..2) assertEquals("day $d overlaps", 0, overlaps(guideRun.getValue(d)))
        // The control: the same pools, each packed alone, clash. Otherwise the check proves nothing.
        val alone = packDays(engine(), l, order(l.size, "guide"))
        assertTrue((0..2).map { overlaps(alone.getValue(it)) }.toString(), (0..2).all { overlaps(alone.getValue(it)) > 20 })
    }

    @Test fun theSameDaysWhateverOrderTheGuideAsksIn() {
        for (how in listOf("reverse", "shuffle")) {
            val m = engine().also { it.register(l) }
            assertEquals(how, guideRun, packDays(m, l, order(l.size, how)))
        }
    }

    @Test fun aRescanThatChangedNothingPacksTheDaysAheadTheSame() {
        val store = InMemoryManifestStore()
        val m = DailyManifest(zone, store)
        m.register(l)
        val before = packDays(m, l, order(l.size, "guide"))
        val todayKey = m.localDayKey(dayAt(0))
        for (k in store.keys()) if (!k.endsWith("_$todayKey")) store.remove(k)
        val fresh = lineup()
        m.register(fresh)
        assertEquals(before, packDays(m, fresh, order(l.size, "shuffle")))
    }

    @Test fun aChangedPoolMovesOnlyItsOwnChannelsDay() {
        val m = engine().also { it.register(l) }
        val before = packDays(m, l, order(l.size, "guide"), listOf(0)).getValue(0)
        val changed = lineup()
        changed[3] = E(changed[3].channel, changed[3].pool + films[239] + films[0])
        m.register(changed)
        val after = packDays(m, changed, order(l.size, "guide"), listOf(0)).getValue(0)
        val moved = before.keys.filter { before[it] != after[it] }
        assertTrue("moved $moved", moved.size <= 1 && moved.all { it == changed[3].channel.id })
        assertEquals(0, overlaps(after))
    }

    @Test fun aChannelOffTheGuideChangesNothingTheGuideAirs() {
        val off = E(ScheduleChannel(5), films.subList(0, 60))
        val m = engine().also { it.register(l) }
        m.getManifestBlocks(off.channel, off.pool, dayAt(0), sk)
        assertEquals(guideRun, packDays(m, l, order(l.size, "guide")))
        // Asked before the guide's day is known (the full pack) or after (the kept lineup's day): the same.
        val first = engine().also { it.register(l) }.getManifestBlocks(off.channel, off.pool, dayAt(0), sk).map { "${it.item.ratingKey}@${it.startSec}" }
        val later = engine().also { it.register(l) }
        packDays(later, l, order(l.size, "guide"), listOf(0))
        assertEquals(first, later.getManifestBlocks(off.channel, off.pool, dayAt(0), sk).map { "${it.item.ratingKey}@${it.startSec}" })
    }

    /** A channel whose day was stored while off the guide, then switched on: the next off-guide channel packs against it. */
    @Test fun aChannelSwitchedOnReachesTheNextOffGuideChannelsDay() {
        val small = l.subList(0, 20).toList()
        val x = l[20]
        val y = E(ScheduleChannel(7), x.pool)
        val m = engine()
        var current = small
        m.setLineup { current.map { it.channel to it.pool } }
        packDays(m, small, order(small.size, "guide"), listOf(0))
        val xDay = m.getManifestBlocks(x.channel, x.pool, dayAt(0), sk)
        current = small + x
        m.getManifestBlocks(x.channel, x.pool, dayAt(0), sk)
        val yDay = m.getManifestBlocks(y.channel, y.pool, dayAt(0), sk)
        val clashes = yDay.sumOf { a -> xDay.count { b -> a.item.ratingKey == b.item.ratingKey && minOf(a.endSec, b.endSec) > maxOf(a.startSec, b.startSec) } }
        assertEquals(0, clashes)
    }

    @Test fun aTimeGatedChannelsDayDoesntDependOnAnothersPool() {
        fun dayOfB(poolA: List<MediaItem>): List<String>? {
            val lu = l + E(ScheduleChannel(90, gated = true), poolA) + E(ScheduleChannel(91, gated = true), films.subList(0, 60))
            val m = engine().also { it.register(lu) }
            return packDays(m, lu, order(lu.size, "guide"), listOf(0)).getValue(0)[91]
        }
        assertEquals(dayOfB(films.subList(0, 40)), dayOfB(films.subList(10, 70)))
    }

    @Test fun noLineupOrALineupOfOnePacksTheChannelsOwnOrder() {
        val one = engine().also { it.register(listOf(l[2])) }
        assertEquals(packDays(engine(), l, listOf(2)), packDays(one, l, listOf(2)))
        // The lowest channel, with nothing before it, keeps its own order when the lineup has room.
        assertEquals(guideRun.getValue(0)[l[0].channel.id], packDays(engine(), l, listOf(0)).getValue(0)[l[0].channel.id])
    }

    @Test fun aLaterPartNeverAirsRightBeforeAnEarlierOne() {
        var bad = 0
        var pairs = 0
        val part = Regex("^(Saga|Quest)(\\d)@")
        for (d in guideRun.values) for (blocks in d.values) for (i in 1 until blocks.size) {
            val a = part.find(blocks[i - 1]) ?: continue
            val b = part.find(blocks[i]) ?: continue
            if (a.groupValues[1] == b.groupValues[1]) {
                pairs++
                if (b.groupValues[2].toInt() < a.groupValues[2].toInt()) bad++
            }
        }
        assertTrue("$bad of $pairs", bad == 0 && pairs > 0)
    }

    /** A generous bound: the check is for a blow-up, as the smoke's. */
    @Test fun theLineupsDayCostsABoundedMultipleOfPackingAlone() {
        fun time(withLineup: Boolean): Double {
            val ms = (0 until 7).map {
                val m = engine()
                if (withLineup) m.register(l)
                val t0 = System.nanoTime()
                for (e in l) m.getManifestBlocks(e.channel, e.pool, dayAt(0), sk)
                (System.nanoTime() - t0) / 1e6
            }.sorted()
            return ms[3]
        }
        time(true); time(false)
        val alone = time(false)
        val together = time(true)
        println("lineup: ${l.size} channels, one day packed in ${"%.1f".format(together)} ms together, ${"%.1f".format(alone)} ms alone")
        assertTrue("$together ms vs $alone ms", together <= alone * 4 + 5)
    }
}
