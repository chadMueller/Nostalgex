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
    /** One GET of the url, sent with `If-None-Match: etag` when there is one. Null when nothing answered. */
    private val fetch: (url: String, etag: String?) -> Fetched?,
) {
    /** An answer: its status (200 or 304 are the ones used), the body of a 200, and the ETag it came with. */
    class Fetched(val code: Int, val body: String?, val etag: String?)

    /** The last good copy, as text (the app keeps it in its files, written whole and renamed). */
    interface Cache {
        fun read(): String?
        fun write(text: String)
        /** The ETag of the kept copy, or null. Kept with the copy: written after it, gone with it. */
        fun readEtag(): String? = null
        fun writeEtag(etag: String?) {}
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

    /** The bundled copy's version, read once. */
    private val bundledVersion: Int? by lazy { versionOf(bundledText()) }

    /** The cache if it holds a good copy no older than the bundled one, else the bundled copy. Reads files only. */
    fun load(): Loaded {
        val kept = cache.read()
        if (kept != null) {
            val v = validate(kept, bundledVersion)
            if (v is Verdict.Accepted) return Loaded(v.config, "cache")
        }
        return Loaded(ChannelConfig(Json.parseToJsonElement(bundledText()).jsonObject), "bundled")
    }

    /**
     * One fetch, on the caller's thread, conditional: with a copy kept the request carries its ETag, and a 304 ends it with nothing downloaded or
     * parsed. A 200 is taken only if it passes [validate] and differs from the copy kept. A copy the same as the bundled one is kept (so the
     * next fetch can be a 304) but is no update.
     */
    fun refresh(): Refresh {
        val kept = cache.read()
        val etag = if (kept != null) cache.readEtag() else null
        val answer = runCatching { fetch(URL, etag) }.getOrNull() ?: return Refresh.Kept("no answer")
        if (answer.code == 304) return if (kept != null) Refresh.Unchanged else Refresh.Kept("304 with no copy kept")
        val text = answer.body
        if (answer.code !in 200..299 || text == null) return Refresh.Kept("HTTP ${answer.code}")
        val verdict = validate(text, bundledVersion)
        if (verdict is Verdict.Rejected) return Refresh.Kept(verdict.reason)
        verdict as Verdict.Accepted
        if (text == kept) {
            // The same copy with a new tag (or none yet): remember the tag.
            if (answer.etag != etag) runCatching { cache.writeEtag(answer.etag) }
            return Refresh.Unchanged
        }
        runCatching { cache.write(text); cache.writeEtag(answer.etag) }.onFailure { return Refresh.Kept("could not keep the copy: ${it.message}") }
        return if (text == bundledText()) Refresh.Unchanged else Refresh.Updated(verdict.config)
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

        private val VERSION_AT_TOP = Regex("^\\s*\\{\\s*\"version\"\\s*:\\s*(\\d+)\\s*,")

        /** The `version` of a channels.json: read off its first line when the file starts with it (it does), else by parsing it. Launch pays no parse for it. */
        private fun versionOf(text: String): Int? =
            VERSION_AT_TOP.find(text.take(200))?.groupValues?.get(1)?.toIntOrNull()
                ?: runCatching { (Json.parseToJsonElement(text).jsonObject["version"] as? JsonPrimitive)?.intOrNull }.getOrNull()

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
