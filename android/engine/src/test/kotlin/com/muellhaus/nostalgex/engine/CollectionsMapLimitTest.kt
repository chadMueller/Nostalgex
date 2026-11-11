package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

/** The JS's mapLimit, which reads collection members four at a time. */
class CollectionsMapLimitTest {
    @Test fun resultsKeepTheListsOrderWhateverOrderTheyFinishIn() {
        val out = Collections.mapLimit((1..20).toList(), 4) { n ->
            Thread.sleep(((20 - n) * 3).toLong())
            n * 10
        }
        assertEquals((1..20).map { it * 10 }, out)
    }

    @Test fun neverMoreThanTheLimitAtOnce() {
        val running = AtomicInteger()
        val most = AtomicInteger()
        Collections.mapLimit((1..30).toList(), Collections.COLLECTION_READS_AT_ONCE) {
            val now = running.incrementAndGet()
            most.accumulateAndGet(now, ::maxOf)
            Thread.sleep(10)
            running.decrementAndGet()
        }
        assertEquals(4, Collections.COLLECTION_READS_AT_ONCE)
        assertTrue("at most 4, saw ${most.get()}", most.get() <= 4)
        assertTrue("more than one at once, saw ${most.get()}", most.get() > 1)
    }

    @Test(expected = IOException::class)
    fun anErrorFromACallComesThrough() {
        Collections.mapLimit(listOf(1, 2, 3), 4) { if (it == 2) throw IOException("refused") else it }
    }

    @Test fun anEmptyListIsEmpty() {
        assertTrue(Collections.mapLimit(emptyList<Int>(), 4) { it }.isEmpty())
    }
}
