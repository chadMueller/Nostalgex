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

    /**
     * ISO 639-2 to ISO 639-1, terminology and bibliographic forms. The Roku app's NxIso639Table
     * character for character, as the Apple TV's and scripts/nostalgex-language.js carry it;
     * LanguageMatchTest fails if this and the web's differ.
     */
    const val ISO639_PAIRS = "aar:aa abk:ab afr:af aka:ak alb:sq sqi:sq amh:am ara:ar arg:an arm:hy hye:hy asm:as ava:av ave:ae aym:ay aze:az bak:ba bam:bm baq:eu eus:eu bel:be ben:bn bis:bi bod:bo tib:bo bos:bs bre:br bul:bg bur:my mya:my cat:ca ces:cs cze:cs cha:ch che:ce chi:zh zho:zh chu:cu chv:cv cor:kw cos:co cre:cr cym:cy wel:cy dan:da deu:de ger:de div:dv dut:nl nld:nl dzo:dz ell:el gre:el eng:en epo:eo est:et ewe:ee fao:fo fas:fa per:fa fij:fj fin:fi fra:fr fre:fr fry:fy ful:ff geo:ka kat:ka gla:gd gle:ga glg:gl glv:gv grn:gn guj:gu hat:ht hau:ha heb:he her:hz hin:hi hmo:ho hrv:hr hun:hu ibo:ig ice:is isl:is ido:io iii:ii iku:iu ile:ie ina:ia ind:id ipk:ik ita:it jav:jv jpn:ja kal:kl kan:kn kas:ks kau:kr kaz:kk khm:km kik:ki kin:rw kir:ky kom:kv kon:kg kor:ko kua:kj kur:ku lao:lo lat:la lav:lv lim:li lin:ln lit:lt ltz:lb lub:lu lug:lg mac:mk mkd:mk mah:mh mal:ml mao:mi mri:mi mar:mr may:ms msa:ms mlg:mg mlt:mt mon:mn nau:na nav:nv nbl:nr nde:nd ndo:ng nep:ne nno:nn nob:nb nor:no nya:ny oci:oc oji:oj ori:or orm:om oss:os pan:pa pli:pi pol:pl por:pt pus:ps que:qu roh:rm ron:ro rum:ro run:rn rus:ru sag:sg san:sa sin:si slk:sk slo:sk slv:sl sme:se smo:sm sna:sn snd:sd som:so sot:st spa:es srd:sc srp:sr ssw:ss sun:su swa:sw swe:sv tah:ty tam:ta tat:tt tel:te tgk:tg tgl:tl tha:th tir:ti ton:to tsn:tn tso:ts tuk:tk tur:tr twi:tw uig:ug ukr:uk urd:ur uzb:uz ven:ve vie:vi vol:vo wln:wa wol:wo xho:xh yid:yi yor:yo zha:za zul:zu"

    private val threeToTwo = ISO639_PAIRS.split(' ').associate { it.substringBefore(':') to it.substringAfter(':') }

    /** Norwegian in every spelling: "no", "nb" (Bokmal), "nn" (Nynorsk) and their 639-2 forms. */
    val NORWEGIAN = setOf("no", "nb", "nn", "nor", "nob", "nno")

    /**
     * A tag as one comparable code (SubtitleSelectionLogic.primaryLanguage): "eng", "en-US",
     * "ger" and "deu" reduce to "en" or "de". Null for an empty tag, anything not letters, and
     * "und", "mul", "zxx" and "mis". A three-letter code the table lacks ("yue") stays itself.
     */
    fun primaryLanguage(tag: String?): String? {
        val raw = tag?.trim()?.lowercase()?.ifEmpty { null } ?: return null
        val code = raw.split('-', '_').firstOrNull { it.isNotEmpty() } ?: return null
        if (!code.all { it in 'a'..'z' } || code in setOf("und", "mul", "zxx", "mis")) return null
        return if (code.length == 3) threeToTwo[code] ?: code else code
    }

    /** The code two tags are compared by: primaryLanguage, every Norwegian code folded to "no". */
    fun languageKey(tag: String?): String? = primaryLanguage(tag)?.let { if (it in NORWEGIAN) "no" else it }

    /** Same language, whichever code each side uses. False when either side names none. */
    fun sameLanguage(a: String?, b: String?): Boolean {
        val x = languageKey(a) ?: return false
        return x == languageKey(b)
    }

    /**
     * A player's track tag against the setting (SubtitleSelectionLogic.tagMatchesPreferred):
     * the same tag, or the same language with a region ("en-us" for "en"); or both Norwegian
     * in any spelling ("nb-no" for "no", "nn" for "nb"). ExoPlayer has already reduced a
     * track's ISO 639-2 code to a two-letter one where there is one.
     */
    fun matches(tag: String?, preferredLowercased: String): Boolean {
        if (tag == null) return false
        if (tag == preferredLowercased || tag.startsWith("$preferredLowercased-")) return true
        fun primary(s: String) = s.split('-', '_').firstOrNull() ?: ""
        return primary(tag) in NORWEGIAN && primary(preferredLowercased) in NORWEGIAN
    }

    /** The track to prefer: the first that matches the setting, else the first. */
    fun preferredTrackIndex(tags: List<String?>, preferredLowercased: String): Int {
        val i = tags.indexOfFirst { matches(it, preferredLowercased) }
        return if (i >= 0) i else 0
    }

    /**
     * AUTO SUBTITLES: true when every audio track's language is known and none is the one
     * preferred. Any unknown, empty or "und" tag turns it off: never guess.
     */
    fun shouldAutoEnableSubtitles(audioTags: List<String?>, preferredAudioLowercased: String): Boolean {
        if (audioTags.isEmpty()) return false
        for (tag in audioTags) {
            val t = tag?.lowercase()
            if (t.isNullOrEmpty() || t == "und") return false
            if (matches(t, preferredAudioLowercased)) return false
        }
        return true
    }

    /**
     * Which audio track a Jellyfin or Emby transcode should carry, when the source has more
     * than one (JellyfinPlaybackResolver.preferredAudioIndex). The server sends whichever track
     * the file marks default, and plenty of files mark a dub: measured on the Apple TV, Joe Dirt
     * played in Spanish on a channel with no way to change it. In order: a track in one of
     * `preferredLanguages`, most channels first; then English, most channels first; then the
     * file's default; then the first. Null when there is nothing to choose, which leaves the
     * server's choice alone.
     *
     * This is the Roku's rule (NxMbChosenAudioIndex, issue #62): the viewer's AUDIO LANGUAGE
     * first, then the Apple TV's, where English is always one of the wanted languages. The
     * Apple TV alone differs: with English always wanted, a German viewer got an English 5.1
     * mix over the German stereo track, and on the emulator Kon-Tiki (English default first,
     * Norwegian second, both mono) was asked for in English for a Norwegian viewer.
     */
    fun preferredAudioIndex(streams: List<AudioStream>?, preferredLanguages: List<String>): Int? {
        val all = streams ?: return null
        if (all.size <= 1) return null
        // A commentary is never it while another track exists (#286, AudioPick); with only
        // commentaries, the rules below run over all of them.
        val audio = AudioPick.skippingCommentary(all) { listOf(it.title, it.rawTitle) }
        fun best(keys: Set<String>) = audio.filter { languageKey(it.lang)?.let { k -> k in keys } == true }.maxByOrNull { it.channels }
        val viewer = preferredLanguages.mapNotNull { languageKey(it) }.toSet()
        (best(viewer) ?: best(setOf("en")))?.let { return it.index }
        return (audio.firstOrNull { it.isDefault } ?: audio.first()).index
    }
}
