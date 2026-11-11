package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A refresh rebuilds the guide for a change in the collections, not for a new member order. */
class CollectionsSameMembersTest {
    private fun c(id: String, vararg keys: String, title: String = id, server: String = "s") = ServerCollection("$server:$id", title, keys.toList(), server)

    @Test fun aNewMemberOrderIsTheSameCollections() {
        assertTrue(Collections.sameMembers(listOf(c("1", "a", "b", "c")), listOf(c("1", "c", "a", "b"))))
        // The collections themselves in another order too.
        assertTrue(Collections.sameMembers(listOf(c("1", "a"), c("2", "b")), listOf(c("2", "b"), c("1", "a"))))
    }

    @Test fun realChangesAreChanges() {
        assertFalse("a member added", Collections.sameMembers(listOf(c("1", "a", "b")), listOf(c("1", "a", "b", "c"))))
        assertFalse("a member swapped", Collections.sameMembers(listOf(c("1", "a", "b")), listOf(c("1", "a", "x"))))
        assertFalse("a collection added", Collections.sameMembers(listOf(c("1", "a")), listOf(c("1", "a"), c("2", "b"))))
        assertFalse("renamed", Collections.sameMembers(listOf(c("1", "a", title = "Old")), listOf(c("1", "a", title = "New"))))
        assertFalse("another server", Collections.sameMembers(listOf(c("1", "a", server = "s")), listOf(c("1", "a", server = "t"))))
        assertFalse("a member listed once more", Collections.sameMembers(listOf(c("1", "a", "b")), listOf(c("1", "a", "a", "b"))))
    }

    /**
     * The comparison is by set and count, so two lists of the same length that repeat
     * different members read as the same. A server collection lists each member once, so this
     * can't come from a real server; it is pinned here so a change to it is deliberate.
     */
    @Test fun repeatsOfTheSameLengthAreNotTold() {
        assertTrue(Collections.sameMembers(listOf(c("1", "a", "a", "b")), listOf(c("1", "a", "b", "b"))))
    }
}
