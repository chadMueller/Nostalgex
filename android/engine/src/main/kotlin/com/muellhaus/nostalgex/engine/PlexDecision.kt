package com.muellhaus.nostalgex.engine

/**
 * Plex's answer to `/video/:/transcode/universal/decision`, as far as the server stream needs
 * it (#193): the transcode decision's code and text, read from the MediaContainer's attributes.
 */
object PlexDecision {
    /**
     * `videoDecision` is what the server does with the video stream (#291): "copy" (a remux, the
     * picture as stored, repackaged) or "transcode" (re-encoded); null when the answer has none.
     */
    data class Answer(val transcodeCode: String?, val transcodeText: String?, val videoDecision: String? = null) {
        /** True for a remux, false for a re-encode, null when the answer doesn't say. */
        val videoCopied: Boolean? get() = when (videoDecision) {
            "copy" -> true
            "transcode" -> false
            else -> null
        }
    }

    private val CONTAINER = Regex("<MediaContainer\\b[^>]*>")
    private val STREAM = Regex("<Stream\\b[^>]*>")

    private fun attribute(tag: String, name: String) =
        Regex("\\s$name=\"([^\"]*)\"").find(tag)?.groupValues?.get(1)

    /** The answer's decision, or null when the body isn't a Plex decision. */
    fun parse(body: String?): Answer? {
        val tag = CONTAINER.find(body ?: return null)?.value ?: return null
        // The first video stream (streamType 1) of the media the server picked.
        val video = STREAM.findAll(body).map { it.value }.firstOrNull { attribute(it, "streamType") == "1" }
        return Answer(attribute(tag, "transcodeDecisionCode"), attribute(tag, "transcodeDecisionText"), video?.let { attribute(it, "decision") })
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
