package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Roku's DeepLinkTests for what a link names and which channel that is, plus the link's own shape. */
class DeepLinkTest {
    private data class Ch(val id: Int, val number: Int)

    /** As the Roku's case: ids and numbers that overlap, so the order matters. */
    private val channels = listOf(Ch(1, 1), Ch(3, 7), Ch(7, 21), Ch(900001, 300))

    private fun index(link: String?) = DeepLink.channelIndex(channels, Ch::id, Ch::number, DeepLink.contentId(link))

    @Test fun theLinkForAChannel() {
        assertEquals("nostalgex://channel/310", DeepLink.forChannel(310))
        assertEquals("310", DeepLink.contentId(DeepLink.forChannel(310)))
    }

    @Test fun anIdBeforeANumber() {
        assertEquals("id 7 is the third channel, not the second's number", 2, index("nostalgex://channel/7"))
    }

    @Test fun byNumber() {
        assertEquals(3, index("nostalgex://channel/300"))
    }

    @Test fun byFranchiseId() {
        assertEquals(3, index("nostalgex://channel/900001"))
    }

    @Test fun unknownAndMalformedNameNoChannel() {
        assertEquals(-1, index("nostalgex://channel/abc"))
        assertEquals(-1, index("nostalgex://channel/"))
        assertEquals(-1, index("nostalgex://other/7"))
        assertEquals(-1, index("https://channel/7"))
        assertEquals(-1, index(""))
        assertEquals(-1, index(null))
        assertEquals(-1, DeepLink.channelIndex(emptyList<Ch>(), Ch::id, Ch::number, "7"))
    }

    @Test fun theLinksShapeIsForgiving() {
        assertEquals("7", DeepLink.contentId(" NOSTALGEX://Channel/7/ "))
        assertEquals("7", DeepLink.contentId("nostalgex://channel/7?from=row"))
        assertNull(DeepLink.contentId("nostalgex://channel"))
    }
}
