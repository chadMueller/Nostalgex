package com.muellhaus.nostalgex.engine

import java.util.Locale

/**
 * The words of the loading pattern every platform shares (Chad, 2026-11-15): a library read says so in the guide's own empty
 * state, and says when it is done. The same lines, with a count the viewer can read, on the Apple TV, Roku, web tuner and here.
 */
object LoadNotice {
    /** The yellow title of the block in the empty guide area, after a server or library switch. */
    const val CHANGING = "CHANNEL GUIDE IS CHANGING"

    /** ...and for a first load or a rescan. */
    const val LOADING = "LOADING YOUR LIBRARY"

    /** How long GUIDE READY stays in the header. */
    const val READY_MS = 4000L

    /** 4210 reads "4,210" whatever the TV's locale: the lines are the same on every platform. */
    fun count(n: Int): String = String.format(Locale.US, "%,d", n)

    private fun titles(n: Int) = if (n == 1) "TITLE" else "TITLES"

    /** The progress line of the block: what has been read, and "OF n" only when the server gave a total. */
    fun readLine(read: Int, total: Int? = null): String =
        if (total != null && total >= read && total > 0) "READ ${count(read)} OF ${count(total)} ${titles(total)}" else "READ ${count(read)} ${titles(read)}"

    /** The library being read: its name, and how far through it when the server gave a total (a movie library's, or a TV library's shows). */
    fun libraryLine(name: String, done: Int? = null, total: Int? = null): String {
        val label = name.trim().uppercase()
        return if (done != null && total != null && total > 0 && done <= total) "$label: ${count(done)} OF ${count(total)}" else label
    }

    /**
     * The block's line while a library is scanned: which library, with the server's name first when there is more than one, and
     * how far through it when the server said (a TV library's shows, or a movie library's total).
     */
    fun scanLine(p: ScanProgress, label: String, serverName: String? = null): String {
        val progress = when {
            p.showsDone != null && p.showsTotal != null -> p.showsDone to p.showsTotal
            p.sectionDone != null && p.sectionTotal != null -> p.sectionDone to p.sectionTotal
            else -> null
        }
        return libraryLine((serverName?.let { "$it · " } ?: "") + label, progress?.first, progress?.second)
    }

    /** The header's line while the library is read again behind a guide that is already up. */
    fun updatingLine(read: Int?): String = if (read == null || read <= 0) "UPDATING LIBRARY" else "UPDATING LIBRARY: ${count(read)} ${titles(read)} READ"

    /** The header's line when it is finished, for [READY_MS]. */
    fun readyLine(n: Int): String = "GUIDE READY: ${count(n)} ${titles(n)}"

    /** The block's title: a switch changes the guide, a first load or a rescan loads the library. */
    fun title(afterSwitch: Boolean) = if (afterSwitch) CHANGING else LOADING
}

/** What the header says, if anything. */
sealed interface HeaderNotice {
    val line: String

    data class Updating(val read: Int?) : HeaderNotice {
        override val line get() = LoadNotice.updatingLine(read)
    }

    data class Ready(val titles: Int) : HeaderNotice {
        override val line get() = LoadNotice.readyLine(titles)
    }
}

/**
 * What the SERVERS & ACCOUNTS page says while a server or library change is read and built, with Settings left open (Chad, 2026-11-16: "you
 * should see some sort of progress on the server saying building channels or building schedule"). The wording is the loading pattern's: the title,
 * READ n TITLES, the library or step under it, then GUIDE READY: n TITLES for [LoadNotice.READY_MS].
 */
object SettingsLoadStatus {
    const val TITLE = "BUILDING CHANNELS"
    /** The step after the channels are matched: the schedules are packed across the lineup. */
    const val SCHEDULE = "BUILDING SCHEDULE"

    data class Lines(val title: String, val count: String?, val detail: String?, val ready: Boolean)

    /** Null when there is nothing to say: no load running and no GUIDE READY or UPDATING LIBRARY in the header. */
    fun lines(load: GuideLoad?, header: HeaderNotice?): Lines? = when {
        load != null -> Lines(TITLE, load.readLine, load.detail.ifEmpty { null }, ready = false)
        header is HeaderNotice.Ready -> Lines(header.line, null, null, ready = true)
        header is HeaderNotice.Updating -> Lines(header.line, null, null, ready = false)
        else -> null
    }
}

/** What the empty guide area shows while a library is read in front of it. */
data class GuideLoad(
    val afterSwitch: Boolean,
    /** Titles read so far across every library and server; null before the first answer. */
    val read: Int? = null,
    /** The line under the count: the library being read, or the step after the read (collections, metadata, channels). */
    val detail: String = "",
) {
    val title get() = LoadNotice.title(afterSwitch)
    val readLine get() = read?.let { LoadNotice.readLine(it) }
}

/**
 * Which finished refresh says GUIDE READY: one that read the library whole, rebuilt or not. A refresh cut short (STOP WAITING, a stall) or
 * one that failed keeps the old guide and says nothing, and one that was replaced (a new load took over) leaves the header to its owner.
 */
fun readyAfter(result: RefreshResult): Boolean = result == RefreshResult.ADOPTED || result == RefreshResult.UNCHANGED
