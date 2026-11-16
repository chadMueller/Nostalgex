package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject

/**
 * Live channels.json (Trello N-074). The app ships a copy of channels.json, and the site serves the current one
 * at https://www.nostalgex.app/channels.json, so a rule fix reaches the TV without a store release.
 *
 * The order of trust, every launch: the last good copy fetched (kept in the app's own files), then the copy
 * bundled in the build. A fetch never holds startup: [load] only reads files, and [refresh] runs behind it, on its own thread, with
 * a short timeout. A new copy is applied at the next guide rebuild the app makes anyway, never by rebuilding the guide under what is playing.
 *
 * A fetched file is taken only if all of these hold, otherwise it is thrown away and the copy in use is kept:
 *  - it parses with the same loader as the bundled one ([ChannelConfig]);
 *  - it names a `version`, and that is not older than the bundled copy's (a build never goes back before what it shipped with);
 *  - it has channels, with no id twice;
 *  - its format is one this build understands: an optional top-level `formatVersion` (absent means 1) no higher than [SUPPORTED_FORMAT].
 *    channels.json has no such field today. The day a rule needs a newer build to read it, the site raises it and older builds keep their copy.
 */
class LiveChannels(
    private val bundledText: () -> String,
    private val cache: Cache,
    private val fetch: (url: String) -> String?,
) {
    /** The last good copy, as text (the app keeps it in its files, written whole and renamed). */
    interface Cache {
        fun read(): String?
        fun write(text: String)
    }

    sealed class Verdict {
        class Accepted(val config: ChannelConfig) : Verdict()
        class Rejected(val reason: String) : Verdict()
    }

    /** What a launch reads: the config, and where it came from ("cache" or "bundled"). */
    class Loaded(val config: ChannelConfig, val source: String)

    sealed class Refresh {
        /** A new copy, now in the cache. The app applies it at its next guide rebuild. */
        class Updated(val config: ChannelConfig) : Refresh()
        /** The site's copy is the one already kept. */
        object Unchanged : Refresh()
        /** Nothing fetched, or what came was not acceptable. The copy in use stays. */
        class Kept(val reason: String) : Refresh()
    }

    /** The cache if it holds a good copy no older than the bundled one, else the bundled copy. Reads files only. */
    fun load(): Loaded {
        val bundled = bundledText()
        val kept = cache.read()
        if (kept != null) {
            val floor = versionOf(bundled)
            val v = validate(kept, floor)
            if (v is Verdict.Accepted) return Loaded(v.config, "cache")
        }
        return Loaded(ChannelConfig(Json.parseToJsonElement(bundled).jsonObject), "bundled")
    }

    /** One fetch, on the caller's thread. Writes the cache only for a copy that passes [validate] and differs from the one kept. */
    fun refresh(): Refresh {
        val text = runCatching { fetch(URL) }.getOrNull() ?: return Refresh.Kept("no answer")
        val verdict = validate(text, versionOf(bundledText()))
        if (verdict is Verdict.Rejected) return Refresh.Kept(verdict.reason)
        verdict as Verdict.Accepted
        if (text == cache.read()) return Refresh.Unchanged
        runCatching { cache.write(text) }.onFailure { return Refresh.Kept("could not keep the copy: ${it.message}") }
        return Refresh.Updated(verdict.config)
    }

    companion object {
        const val URL = "https://www.nostalgex.app/channels.json"
        /** The highest `formatVersion` this build reads. */
        const val SUPPORTED_FORMAT = 1
        /** About every 24 hours while the app runs. */
        const val REFRESH_MS = 24L * 60 * 60 * 1000
        /** The fetch gives up after this long, so it never sits on a slow network for long. */
        const val TIMEOUT_MS = 8_000L
        /** A channels.json is 130 KB today. Anything near this is not one. */
        const val MAX_CHARS = 4_000_000

        private fun versionOf(text: String): Int? =
            runCatching { (Json.parseToJsonElement(text).jsonObject["version"] as? JsonPrimitive)?.intOrNull }.getOrNull()

        /** Whether `text` is a channels.json this build may use, given the bundled copy's version. */
        fun validate(text: String, bundledVersion: Int?): Verdict {
            if (text.isBlank() || text.length > MAX_CHARS) return Verdict.Rejected("wrong size")
            val root: JsonObject = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return Verdict.Rejected("not a JSON object")
            val format = (root["formatVersion"] as? JsonPrimitive)?.let { it.intOrNull ?: return Verdict.Rejected("formatVersion is not a number") } ?: 1
            if (format > SUPPORTED_FORMAT) return Verdict.Rejected("format $format is newer than this build reads ($SUPPORTED_FORMAT)")
            val config = runCatching { ChannelConfig(root) }.getOrNull() ?: return Verdict.Rejected("does not load")
            val version = config.version ?: return Verdict.Rejected("no version")
            if (bundledVersion != null && version < bundledVersion) return Verdict.Rejected("version $version is older than the bundled $bundledVersion")
            if (config.channels.isEmpty()) return Verdict.Rejected("no channels")
            if (config.channels.map { it.id }.toSet().size != config.channels.size) return Verdict.Rejected("a channel id twice")
            return Verdict.Accepted(config)
        }
    }
}
