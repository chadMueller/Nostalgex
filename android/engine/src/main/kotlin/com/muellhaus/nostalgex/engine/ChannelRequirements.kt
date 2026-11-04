package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * What a channel asks of the library, as short plain-English lines for Settings' WHY AREN'T
 * THESE ON AIR? (ChannelRules.plainLanguageRequirements, I-004). Only the fields a viewer
 * can read without knowing what Plex, TMDB or OMDb are; a channel with none of them set (a
 * title list, or manifest only) gets one line, so the card is never empty.
 */
object ChannelRequirements {
    fun plainLanguage(rules: JsonObject?): List<String> {
        val r = rules ?: JsonObject(emptyMap())
        val lines = ArrayList<String>()
        fun strings(o: JsonObject?, key: String) = (o?.get(key) as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: emptyList()
        fun num(o: JsonObject?, key: String) = (o?.get(key) as? JsonPrimitive)?.doubleOrNull
        fun flag(key: String) = (r[key] as? JsonPrimitive)?.booleanOrNull == true
        fun whole(d: Double) = d.toLong().toString()
        fun oneDecimal(d: Double) = String.format(java.util.Locale.US, "%.1f", d)

        when ((r["type"] as? JsonPrimitive)?.content) {
            "movie" -> lines += "Movies only"
            "episode" -> lines += "TV episodes only"
        }
        if ((r["source"] as? JsonPrimitive)?.content == "musicVideo") lines += "Music videos only"

        val genres = r["genres"] as? JsonObject
        strings(genres, "include").takeIf { it.isNotEmpty() }?.let { lines += "Genre: ${it.joinToString(" or ")}" }
        strings(genres, "requireAll").takeIf { it.isNotEmpty() }?.let { lines += "Needs every one of these genres: ${it.joinToString(", ")}" }
        strings(genres, "exclude").takeIf { it.isNotEmpty() }?.let { lines += "Not genre: ${it.joinToString(", ")}" }

        strings(r, "studios").takeIf { it.isNotEmpty() }?.let { lines += "Studio: ${it.joinToString(" or ")}" }
        strings(r, "networks").takeIf { it.isNotEmpty() }?.let { lines += "Network: ${it.joinToString(" or ")}" }

        (r["yearRange"] as? JsonObject)?.let { y ->
            val lo = num(y, "min")
            val hi = num(y, "max")
            when {
                lo != null && hi != null -> lines += "Released ${whole(lo)} to ${whole(hi)}"
                lo != null -> lines += "Released ${whole(lo)} or later"
                hi != null -> lines += "Released before ${whole(hi)}"
            }
        }

        strings(r, "contentRatings").takeIf { it.isNotEmpty() }?.let { lines += "Rated: ${it.joinToString(", ")}" }

        num(r, "ratingMin")?.let { lines += "Plex star rating ${oneDecimal(it)} or higher" }
        num(r, "imdbRatingMin")?.let { lines += "IMDb rating ${oneDecimal(it)} or higher" }
        num(r, "rtScoreMin")?.let { lines += "Rotten Tomatoes score ${whole(it)} or higher" }
        num(r, "metacriticMin")?.let { lines += "Metacritic score ${whole(it)} or higher" }
        if (flag("wonOscar")) lines += "Won an Oscar"

        if (flag("watchedOnly")) lines += "Already watched titles only"
        if (flag("unwatchedOnly")) lines += "Unwatched titles only"
        if (flag("rewatched")) lines += "Watched three times or more"

        strings(r, "keywords").takeIf { it.isNotEmpty() }?.let { lines += "About: ${it.take(4).joinToString(", ")}" }

        (r["durationRange"] as? JsonObject)?.let { d ->
            val lo = num(d, "min")
            val hi = num(d, "max")
            when {
                lo != null && hi != null -> lines += "Runs ${whole(lo)} to ${whole(hi)} minutes"
                lo != null -> lines += "Runs ${whole(lo)} minutes or longer"
                hi != null -> lines += "Runs ${whole(hi)} minutes or shorter"
            }
        }

        if (lines.isEmpty()) lines += "A specific, curated list of titles rather than a general rule"
        return lines
    }
}
