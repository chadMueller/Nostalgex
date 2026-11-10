package com.muellhaus.nostalgex.engine

/**
 * Plex's answer to `/video/:/transcode/universal/decision`, as far as the server stream needs
 * it (#193): the transcode decision's code and text, read from the MediaContainer's attributes.
 */
object PlexDecision {
    data class Answer(val transcodeCode: String?, val transcodeText: String?)

    private val CONTAINER = Regex("<MediaContainer\\b[^>]*>")

    private fun attribute(tag: String, name: String) =
        Regex("\\s$name=\"([^\"]*)\"").find(tag)?.groupValues?.get(1)

    /** The answer's decision, or null when the body isn't a Plex decision. */
    fun parse(body: String?): Answer? {
        val tag = CONTAINER.find(body ?: return null)?.value ?: return null
        return Answer(attribute(tag, "transcodeDecisionCode"), attribute(tag, "transcodeDecisionText"))
    }

    /**
     * PlexAPIService.isDolbyVisionRefusal: Plex can't convert Dolby Vision profile 5 (it has no
     * HDR10 base layer), so a decision 2003 naming DoVi means every server stream is refused.
     * Measured on Plex 1.43.5: "File is unplayable. DoVi (Profile 5) color space is not supported."
     */
    fun isDolbyVisionRefusal(a: Answer?): Boolean =
        a != null && a.transcodeCode == "2003" && a.transcodeText?.contains("dovi", ignoreCase = true) == true

    /**
     * Programmes skipped in a row on one channel, with none starting, before the channel stops
     * with a card: a channel of nothing but profile 5 titles would otherwise skip forever.
     */
    const val SKIPS_BEFORE_STOP = 5
}
