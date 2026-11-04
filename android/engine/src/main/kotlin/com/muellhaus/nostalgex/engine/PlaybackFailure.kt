package com.muellhaus.nostalgex.engine

/**
 * Why a scheduled programme could not be played, in words a person can act on: the Apple TV's
 * PlaybackFailure.swift. The three common causes are a server that refuses the job, a server
 * that can't keep up, and a file the device can't render, and only the first two can be fixed
 * if the viewer is told which happened. "Apple TV" reads "this TV" here, as "this Roku" there.
 */
sealed class PlaybackFailure {
    /** The server answered the request and said no. */
    data class ServerRefused(val server: String, val status: Int) : PlaybackFailure()
    /** The server does not have the file it told us about. */
    data class FileMissing(val server: String) : PlaybackFailure()
    /** The server rejected our credentials. */
    data class NotAuthorised(val server: String) : PlaybackFailure()
    /** The server tried and could not produce video fast enough to watch. */
    data class ServerTooSlow(val server: String) : PlaybackFailure()
    /** Nothing answered at the address. */
    data class ServerUnreachable(val server: String) : PlaybackFailure()
    /** Bytes arrived; the device could not turn them into a picture. */
    data class DeviceCannotRender(val codec: String?) : PlaybackFailure()
    /** Nothing in the library row gave a stream to open. */
    data class NoPlayableSource(val server: String) : PlaybackFailure()
    /** The server won't convert this title and the device can't take it as it stands. */
    data class TranscodingUnavailable(val server: String) : PlaybackFailure()
    /** Something failed and the signals don't say what. */
    data class Unknown(val server: String) : PlaybackFailure()
    /** [CHANNEL_FAILURE_LIMIT] programmes in a row failed on this channel; never produced by [classify]. */
    data class ChannelStopped(val last: PlaybackFailure) : PlaybackFailure()

    /** What the player saw when the app gave up on an item. */
    data class Evidence(
        val httpStatuses: List<Int> = emptyList(),
        /** The player's own codes for media that arrived too late (CoreMedia's -12889 and -15628 on the Apple TV). */
        val deliveryTooSlow: Boolean = false,
        /** The player reported a decoder failure. */
        val decoderFailed: Boolean = false,
        /** Nothing answered: no host, refused, timed out, connection lost. */
        val unreachable: Boolean = false,
        val starvedAfterCappedRetry: Boolean = false,
        val everShowedPicture: Boolean = false,
        val sourceCodec: String? = null,
        val decodedAFrame: Boolean = false,
        val serverDeliveredBytes: Boolean = false,
    )

    /** One short line, the size a person reads from a sofa. */
    val headline: String
        get() = when (this) {
            is ServerRefused -> "Your server wouldn't start this one"
            is FileMissing -> "Your server can't find this file"
            is NotAuthorised -> "Your server refused the request"
            is ServerTooSlow -> "Your server couldn't keep up"
            is ServerUnreachable -> "Can't reach your server"
            is DeviceCannotRender -> "This TV couldn't play this file"
            is NoPlayableSource -> "Nothing to play for this title"
            is TranscodingUnavailable -> "Your server won't convert this one"
            is Unknown -> "This one wouldn't play"
            is ChannelStopped -> "Nothing on this channel will play right now"
        }

    /** Whose problem it is and what to do about it. */
    val detail: String
        get() = when (this) {
            is ServerRefused -> "$server answered HTTP $status before it started sending video. " +
                "That's the server, not this file and not your network. Other titles on the same server are unaffected."
            is FileMissing -> "$server listed this title but couldn't open the file. " +
                "It was probably moved or deleted since the last library scan."
            is NotAuthorised -> "$server rejected the sign-in saved on this device. Open Settings and reconnect."
            is ServerTooSlow -> "$server couldn't produce video fast enough to watch, even after " +
                "dropping to 1080p. The file is probably too heavy for it to convert."
            is ServerUnreachable -> "Nothing answered at the address saved for your $server server. " +
                "Check it's awake and on the same network."
            is DeviceCannotRender -> "${codec?.let { "This ${it.uppercase()} file" } ?: "This file"} arrived, but this TV couldn't " +
                "turn it into a picture. The server sent it in a format this device can't decode."
            is NoPlayableSource -> "$server listed this title but gave no stream to open. " +
                "A library rescan in Settings usually clears it."
            is TranscodingUnavailable -> "$server won't convert this title, and this TV can't play it as it is. " +
                "Check that transcoding is enabled on the server."
            is Unknown -> "No reason came back from $server or from the player. " +
                "Settings keeps the last few playback verdicts if it keeps happening."
            is ChannelStopped -> "$CHANNEL_FAILURE_LIMIT programmes in a row wouldn't play, so this channel " +
                "has stopped trying. Last reason: ${last.headline}."
        }

    /** The small line under the card: what happens next. */
    val nextStep: String
        get() = if (this is ChannelStopped) "Try another channel, or select this one again to retry." else "Moving on to the next programme."

    /** Amber when the server is the thing to go and look at, red when the file or the device is. */
    val isServerSide: Boolean
        get() = when (this) {
            is DeviceCannotRender, is Unknown -> false
            is ChannelStopped -> last.isServerSide
            else -> true
        }

    companion object {
        /** ChannelFailureRun.limit: this many failures in a row and the channel stops trying. */
        const val CHANNEL_FAILURE_LIMIT = 5

        /**
         * Order matters, as on the Apple TV: starvation first (the server answered and still
         * lost), then what the server said, then whether anything answered, then late media,
         * then a device that got bytes and no picture, then a server that kept sending with no
         * picture moving.
         */
        fun classify(server: String, e: Evidence): PlaybackFailure {
            if (e.starvedAfterCappedRetry) return ServerTooSlow(server)
            val statuses = e.httpStatuses.filter { it > 0 }
            if (401 in statuses || 403 in statuses) return NotAuthorised(server)
            if (404 in statuses) return FileMissing(server)
            statuses.firstOrNull { it >= 400 }?.let { return ServerRefused(server, it) }
            if (e.unreachable) return ServerUnreachable(server)
            if (e.deliveryTooSlow) return ServerTooSlow(server)
            // A decoded frame proves the device can decode the stream, so it vetoes this outright.
            if (!e.everShowedPicture && !e.decodedAFrame && e.decoderFailed) return DeviceCannotRender(e.sourceCodec)
            if (!e.everShowedPicture && e.serverDeliveredBytes) return ServerTooSlow(server)
            return Unknown(server)
        }
    }
}

/** ChannelFailureRun: failures in a row on one channel, reset by a picture or by the viewer choosing a channel. */
class ChannelFailureRun {
    var channelId: Int? = null
        private set
    var count = 0
        private set

    val isStopped get() = count >= PlaybackFailure.CHANNEL_FAILURE_LIMIT

    /** Returns true when the channel should stop. */
    fun recordFailure(onChannel: Int): Boolean {
        if (channelId != onChannel) {
            channelId = onChannel
            count = 0
        }
        count++
        return isStopped
    }

    fun reset() {
        channelId = null
        count = 0
    }
}
