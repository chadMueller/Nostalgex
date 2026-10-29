package com.muellhaus.nostalgex.engine

import java.util.Locale

/**
 * The language list every language picker offers, and the rules that pick subtitle and
 * audio tracks with it: SubtitleLanguagePreset.swift and SubtitleSelectionLogic.swift.
 */
object LanguageChoice {
    /** "Follow the TV's own language" rather than a fixed one. */
    const val SYSTEM = "__system__"

    data class Preset(val code: String, val label: String)

    /** One vocabulary for subtitles and audio alike. The Apple TV's first row says MATCH APPLE TV LANGUAGE. */
    val presets = listOf(
        Preset(SYSTEM, "MATCH TV LANGUAGE"),
        Preset("en", "ENGLISH"),
        Preset("es", "SPANISH"),
        Preset("fr", "FRENCH"),
        Preset("de", "GERMAN"),
        Preset("it", "ITALIAN"),
        Preset("pt-BR", "PORTUGUESE (BRAZIL)"),
        Preset("ja", "JAPANESE"),
        Preset("ko", "KOREAN"),
        Preset("zh-Hans", "CHINESE (SIMPLIFIED)"),
        Preset("zh-Hant", "CHINESE (TRADITIONAL)"),
        Preset("ru", "RUSSIAN"),
        Preset("ar", "ARABIC"),
        Preset("nl", "DUTCH"),
        Preset("pl", "POLISH"),
        Preset("sv", "SWEDISH"),
    )

    /** The panel's short form: the full label doesn't fit beside the row's title. */
    fun shortLabel(code: String) = if (code == SYSTEM) "SYSTEM" else code.uppercase()

    /** A stored choice made concrete: SYSTEM is the device's primary language. */
    fun resolved(stored: String, locale: Locale = Locale.getDefault()): String =
        if (stored == SYSTEM) locale.language.ifEmpty { "en" } else stored

    /** A tag as the comparisons read it: lowercased, "_" as "-". */
    fun tag(language: String?): String? = language?.trim()?.replace('_', '-')?.lowercase()?.ifEmpty { null }

    /** The track to prefer: an exact or region match on the tag, else the first. */
    fun preferredTrackIndex(tags: List<String?>, preferredLowercased: String): Int {
        val i = tags.indexOfFirst { t -> t != null && (t == preferredLowercased || t.startsWith("$preferredLowercased-")) }
        return if (i >= 0) i else 0
    }

    fun matches(tag: String?, preferredLowercased: String) =
        tag != null && (tag == preferredLowercased || tag.startsWith("$preferredLowercased-"))

    /**
     * AUTO SUBTITLES: true when every audio track's language is known and none is the one
     * preferred. Any unknown, empty or "und" tag turns it off: never guess.
     */
    fun shouldAutoEnableSubtitles(audioTags: List<String?>, preferredAudioLowercased: String): Boolean {
        if (audioTags.isEmpty()) return false
        for (tag in audioTags) {
            val t = tag?.lowercase()
            if (t.isNullOrEmpty() || t == "und") return false
            if (t == preferredAudioLowercased || t.startsWith("$preferredAudioLowercased-")) return false
        }
        return true
    }
}
