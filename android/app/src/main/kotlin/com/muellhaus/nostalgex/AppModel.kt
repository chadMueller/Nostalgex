package com.muellhaus.nostalgex

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.StreamQuality
import com.muellhaus.nostalgex.playback.PlaybackInfo
import okhttp3.Request
import java.util.Locale
import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.muellhaus.nostalgex.engine.ChannelConfig
import com.muellhaus.nostalgex.engine.GuideChannel
import com.muellhaus.nostalgex.engine.Lineup
import com.muellhaus.nostalgex.engine.DailyManifest
import com.muellhaus.nostalgex.engine.ChannelFailureRun
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.engine.PlaybackFailure
import com.muellhaus.nostalgex.engine.Pick
import com.muellhaus.nostalgex.mediabrowser.CheckedServer
import com.muellhaus.nostalgex.mediabrowser.DiscoveredServer
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserClient
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserHttpException
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserServer
import com.muellhaus.nostalgex.playback.Delivery
import com.muellhaus.nostalgex.playback.Playback
import com.muellhaus.nostalgex.plex.PlexClient
import com.muellhaus.nostalgex.plex.PlexHttpException
import com.muellhaus.nostalgex.plex.PlexLibrary
import com.muellhaus.nostalgex.plex.PlexPin
import com.muellhaus.nostalgex.plex.PlexServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import java.time.ZoneId

sealed interface Screen {
    /** Plex's code, after CONNECT TO PLEX. */
    data class SignIn(val pin: PlexPin?, val error: String? = null) : Screen
    /** The connect screens: the backend picker, then Jellyfin or Emby: find, check and sign in. */
    data class Connect(val step: ConnectStep, val message: String? = null, val error: String? = null) : Screen
    data class Loading(val headline: String, val detail: String = "") : Screen
    data class Failed(val message: String) : Screen
    data object NoChannels : Screen
    data object Watching : Screen
}

/** Where the connect screens are, as SettingsView.Screen and its waiting states. */
sealed interface ConnectStep {
    data object Picker : ConnectStep
    data class Find(val kind: String, val discovery: Discovery = Discovery.Idle) : ConnectStep
    data class TypeAddress(val kind: String) : ConnectStep
    data class Checking(val kind: String, val label: String) : ConnectStep
    data class SignIn(val server: CheckedServer) : ConnectStep
    data class QuickConnect(val server: CheckedServer, val code: String?) : ConnectStep
    data class SigningIn(val server: CheckedServer) : ConnectStep
}

/** LAN discovery on the find screen. */
sealed interface Discovery {
    data object Idle : Discovery
    data object Searching : Discovery
    data object NothingFound : Discovery
    data class Several(val servers: List<DiscoveredServer>) : Discovery
}

/** Everything the screens show, and every action the remote takes. One per activity. */
class AppModel(private val context: Context) : Playback.Listener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val prefs = Prefs(context)
    private val versionName = context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"
    private val plex = PlexClient(prefs.clientId, versionName)
    private val mediaBrowser = MediaBrowserClient(prefs.clientId, versionName)
    val playback = Playback(context, plex, mediaBrowser, this)

    /** The Jellyfin or Emby server signed in to, read once from Prefs; null on Plex. */
    private var mbServer: MediaBrowserServer? = prefs.mediaBrowser
        set(value) {
            field = value
            prefs.mediaBrowser = value
            playback.mediaBrowserServer = value
        }

    /** "Plex", "Jellyfin" or "Emby": the Apple TV's backendDisplayName, in its copy. */
    val backendName: String get() = mbServer?.let { MediaBrowserClient.displayName(it.kind) } ?: "Plex"

    var screen: Screen by mutableStateOf(Screen.Loading("NOSTALGEX"))
        private set
    var lineup: Lineup? by mutableStateOf(null)
        private set
    var channel: GuideChannel? by mutableStateOf(null)
        private set
    var item: MediaItem? by mutableStateOf(null)
        private set
    var delivery: Delivery? by mutableStateOf(null)
        private set
    /** Full screen, or the tuner (info panel, picture and guide), which the app opens on as the Apple TV's does. */
    var fullScreen: Boolean
        get() = fullScreenState
        set(value) {
            fullScreenState = value
            applySubtitles()
        }
    private var fullScreenState by mutableStateOf(false)

    // ── The Now Playing panel's settings and the player's tracks ─────────

    /** RETRO MODE: the CRT look, and the picture filling its frame, cropped (AppState.retroMode). */
    var retroMode by mutableStateOf(prefs.retroMode)
        private set

    fun toggleRetroMode() {
        retroMode = !retroMode
        prefs.retroMode = retroMode
    }

    /** STREAM QUALITY: read as each programme starts, so a change reaches the next one. */
    var streamQuality by mutableStateOf(StreamQuality.fromId(prefs.streamQuality))
        private set

    fun chooseStreamQuality(q: StreamQuality) {
        streamQuality = q
        prefs.streamQuality = q.id
        playback.quality = q
    }

    /** CC: subtitles, shown in full screen only (AppState.subtitlesInFullscreenEnabled). */
    var subtitlesInFullScreen by mutableStateOf(prefs.subtitlesInFullScreen)
        private set

    fun toggleSubtitles() {
        if (!hasSubtitleTracks) return
        subtitlesInFullScreen = !subtitlesInFullScreen
        prefs.subtitlesInFullScreen = subtitlesInFullScreen
        applySubtitles()
    }

    /** AUTO SUBTITLES (FOREIGN AUDIO): on by default. */
    var autoSubtitles by mutableStateOf(prefs.autoSubtitles)
        private set

    fun toggleAutoSubtitles() {
        autoSubtitles = !autoSubtitles
        prefs.autoSubtitles = autoSubtitles
        applySubtitles()
    }

    /** SUBTITLE LANGUAGE and AUDIO LANGUAGE, as stored (LanguageChoice.SYSTEM follows the TV). */
    var subtitleLanguage by mutableStateOf(prefs.subtitleLanguage)
        private set
    var audioLanguage by mutableStateOf(prefs.audioLanguage)
        private set

    fun chooseSubtitleLanguage(code: String) {
        subtitleLanguage = code
        prefs.subtitleLanguage = code
        applySubtitles()
    }

    /** Applies to the programme playing as well as the next (Roku #118, AppState's didSet). */
    fun chooseAudioLanguage(code: String) {
        audioLanguage = code
        prefs.audioLanguage = code
        audioChosenFor = null
        lastTracks?.let(::onTracks)
    }

    data class AudioTrack(val name: String, val selected: Boolean, internal val group: Tracks.Group, internal val index: Int)

    var audioTracks: List<AudioTrack> by mutableStateOf(emptyList())
        private set
    /** A real subtitle track, not only forced ones (they show anyway, so CC has nothing to switch). */
    var hasSubtitleTracks by mutableStateOf(false)
        private set
    var playbackInfo: PlaybackInfo? by mutableStateOf(null)
        private set
    var videoSize: Pair<Int, Int>? by mutableStateOf(null)
        private set

    private var lastTracks: Tracks? = null
    /** The programme the preferred audio language was last applied to, so it is applied once and a choice in Now Playing stands. */
    private var audioChosenFor: MediaItem? = null

    /** One track for this programme only, as AppState.selectAudioTrack: the next starts from its own default. */
    fun selectAudioTrack(track: AudioTrack) {
        val p = playback.player
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(track.group.mediaTrackGroup, track.index))
            .build()
    }

    private data class Option(val group: Tracks.Group, val index: Int, val format: Format) {
        val tag get() = LanguageChoice.tag(format.language)
        val forced get() = format.selectionFlags and C.SELECTION_FLAG_FORCED != 0
    }

    private fun options(tracks: Tracks, type: Int) = tracks.groups.filter { it.type == type }.flatMap { g ->
        (0 until g.length).filter { g.isTrackSupported(it) }.map { Option(g, it, g.getTrackFormat(it)) }
    }

    private fun onTracks(tracks: Tracks) {
        lastTracks = tracks
        val audio = options(tracks, C.TRACK_TYPE_AUDIO)
        audioTracks = audio.mapIndexed { i, o -> AudioTrack(audioTrackName(o.format, i), o.group.isTrackSelected(o.index), o.group, o.index) }
        hasSubtitleTracks = options(tracks, C.TRACK_TYPE_TEXT).any { !it.forced }
        // The preferred audio language, once per programme; the default track if none matches.
        val current = item
        if (current != null && audioChosenFor != current && audio.isNotEmpty()) {
            audioChosenFor = current
            val preferred = LanguageChoice.resolved(audioLanguage).lowercase()
            val pick = audio[LanguageChoice.preferredTrackIndex(audio.map { it.tag }, preferred)]
            if (!pick.group.isTrackSelected(pick.index)) selectAudioTrack(AudioTrack("", false, pick.group, pick.index))
        }
        applySubtitles()
    }

    /**
     * AppState.applySubtitleSelection: in full screen, the preferred-language subtitles when CC
     * is on, or when AUTO SUBTITLES finds no audio in the preferred language (and then only a
     * matching track: wrong-language subtitles are worse than none). Otherwise a forced track in
     * the preferred language (a film's foreign dialogue), else none.
     */
    private fun applySubtitles() {
        val p = playback.player
        val tracks = lastTracks
        val texts = tracks?.let { options(it, C.TRACK_TYPE_TEXT) } ?: emptyList()
        val preferred = LanguageChoice.resolved(subtitleLanguage).lowercase()
        val preferredAudio = LanguageChoice.resolved(audioLanguage).lowercase()
        val forced = texts.firstOrNull { it.forced && LanguageChoice.matches(it.tag, preferred) }

        var enable = subtitlesInFullScreen && fullScreenState
        var auto = false
        if (!enable && autoSubtitles && fullScreenState && tracks != null) {
            enable = LanguageChoice.shouldAutoEnableSubtitles(options(tracks, C.TRACK_TYPE_AUDIO).map { it.tag }, preferredAudio)
            auto = enable
        }
        val choice = if (!enable || texts.isEmpty()) {
            forced
        } else {
            val pick = texts.firstOrNull { !it.forced && LanguageChoice.matches(it.tag, preferred) }
                ?: texts[LanguageChoice.preferredTrackIndex(texts.map { it.tag }, preferred)]
            if (auto && !LanguageChoice.matches(pick.tag, preferred)) forced else pick
        }
        val params = p.trackSelectionParameters.buildUpon()
        if (choice == null) {
            params.clearOverridesOfType(C.TRACK_TYPE_TEXT).setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        } else {
            params.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                .setOverrideForType(TrackSelectionOverride(choice.group.mediaTrackGroup, choice.index))
        }
        p.trackSelectionParameters = params.build()
    }

    /** AudioTrackDescriptorBuilder: the track's name, else its language, else "Track N". */
    private fun audioTrackName(format: Format, index: Int): String {
        format.label?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        val lang = format.language?.takeIf { it.isNotEmpty() && it != "und" }
        if (lang != null) {
            val name = Locale.forLanguageTag(lang).getDisplayLanguage(Locale.getDefault())
            return if (name.isNotEmpty() && name != lang) name else lang.uppercase()
        }
        return "Track ${index + 1}"
    }

    override fun onInfo(info: PlaybackInfo) {
        playbackInfo = info
    }

    // ── The sleep timer (AppState+Playback.swift) ────────────────────────

    /** When an armed timer runs out, and the preset it was armed with. */
    var sleepEndMs: Long? by mutableStateOf(null)
        private set
    var sleepMinutes: Int? by mutableStateOf(null)
        private set
    /** "STILL WATCHING?": the next key keeps watching; 20 s with none stops playback. */
    var sleepGrace by mutableStateOf(false)
        private set
    private var sleepJob: Job? = null

    fun startSleepTimer(minutes: Int) {
        sleepJob?.cancel()
        sleepGrace = false
        if (minutes <= 0) {
            sleepEndMs = null
            sleepMinutes = null
            return
        }
        sleepEndMs = System.currentTimeMillis() + minutes * 60_000L
        sleepMinutes = minutes
        sleepJob = scope.launch {
            delay(minutes * 60_000L)
            sleepGrace = true
            delay(20_000)
            // AppState.expireSleepTimer: pause, drop the transcode, back to the guide; the sign-in stays.
            playback.pause()
            cancelSleepTimer()
            fullScreen = false
        }
    }

    fun cancelSleepTimer() {
        sleepJob?.cancel()
        sleepJob = null
        sleepEndMs = null
        sleepMinutes = null
        sleepGrace = false
    }

    /** An answer to "STILL WATCHING?": keep playing, the timer is used up. */
    fun keepAwake() = cancelSleepTimer()

    // ── Posters (PlexAPIService.thumbnailURL, 300 wide) ──────────────────

    private val posters = object : LinkedHashMap<String, ImageBitmap>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ImageBitmap>?) = size > 12
    }

    suspend fun poster(item: MediaItem): ImageBitmap? {
        // Plex only, as on the Apple TV.
        if (mbServer != null) return null
        val thumb = item.thumb ?: return null
        val server = item.serverUrl ?: return null
        val url = Uri.parse("$server/photo/:/transcode").buildUpon()
            .appendQueryParameter("url", thumb)
            .appendQueryParameter("width", "300")
            .appendQueryParameter("height", "450")
            .appendQueryParameter("X-Plex-Token", item.serverToken ?: "")
            .build().toString()
        posters[url]?.let { return it }
        return withContext(Dispatchers.IO) {
            runCatching {
                plex.http.newCall(Request.Builder().url(url).build()).execute().use { res ->
                    if (!res.isSuccessful) return@use null
                    BitmapFactory.decodeStream(res.body.byteStream())?.asImageBitmap()
                }
            }.getOrNull()
        }?.also { posters[url] = it }
    }
    /** Bumped on each tune, so the channel banner shows again. */
    var tuneCount by mutableStateOf(0)
        private set
    /** The card over the picture when a programme won't play (PlaybackFailureCard). */
    var failure: PlaybackFailure? by mutableStateOf(null)
        private set
    /** Failures in a row on this channel; at the limit the channel stops trying. */
    private val failureRun = ChannelFailureRun()
    val channelStopped get() = failureRun.isStopped
    private var skipJob: Job? = null
    /** The guide rebuilds on the minute; this changes so it redraws. */
    var scheduleTick by mutableStateOf(0L)
        private set

    /** True while the servers are read again behind the guide. */
    var refreshing by mutableStateOf(false)
        private set

    private val libraryStore = LibraryStore(context)

    /**
     * channels.json and channels-memberships.json (1.3 MB), parsed once per launch and started
     * at once, so the parse overlaps the library read instead of following it.
     */
    private val channelData: Deferred<Pair<ChannelConfig, JsonObject?>> = scope.async(Dispatchers.Default) {
        val t0 = SystemClock.elapsedRealtime()
        val config = ChannelConfig(Json.parseToJsonElement(asset("channels.json")).jsonObject)
        val memberships = runCatching { Json.parseToJsonElement(asset("channels-memberships.json")).jsonObject }.getOrNull()
        Log.i(TAG, "CONFIG channels.json v${config.version} and memberships parsed in ${SystemClock.elapsedRealtime() - t0} ms")
        config to memberships
    }
    private val manifestStore = FileManifestStore(context)
    private var signInJob: Job? = null
    private var clockJob: Job? = null

    init {
        playback.quality = streamQuality
        playback.mediaBrowserServer = mbServer
        playback.player.addListener(object : Player.Listener {
            override fun onTracksChanged(tracks: Tracks) = onTracks(tracks)
            override fun onVideoSizeChanged(size: VideoSize) {
                videoSize = if (size.width > 0 && size.height > 0) size.width to size.height else null
            }
        })
        applySubtitles()
    }

    fun start() {
        if (mbServer != null || (prefs.plexToken != null && prefs.servers.isNotEmpty())) loadLibrary() else showPicker()
    }

    // ── Sign-in ──────────────────────────────────────────────────────────

    /** The first connect screen: CONNECT TO PLEX, or Jellyfin or Emby. */
    fun showPicker(error: String? = null) {
        signInJob?.cancel()
        connectJob?.cancel()
        screen = Screen.Connect(ConnectStep.Picker, error = error)
    }

    /** CONNECT TO PLEX: the plex.tv/link code. */
    fun signIn() {
        signInJob?.cancel()
        screen = Screen.SignIn(null)
        signInJob = scope.launch {
            try {
                val pin = plex.createPin()
                screen = Screen.SignIn(pin)
                // Every 2 s for 5 minutes, as the web tuner.
                repeat(150) {
                    delay(2000)
                    val token = runCatching { plex.pollPin(pin) }.getOrNull()
                    if (token != null) {
                        mbServer = null
                        prefs.plexToken = token
                        screen = Screen.Loading("FINDING YOUR SERVERS")
                        val servers = try {
                            plex.discoverServers(token)
                        } catch (e: Exception) {
                            Log.w(TAG, "Server discovery failed", e)
                            screen = Screen.Failed("Signed in, but couldn't reach plex.tv to find your servers. Check your connection and Retry.")
                            return@launch
                        }
                        // AppState.recoverPlexServersIfNeeded's words.
                        if (servers.isEmpty()) {
                            screen = Screen.Failed(
                                if (plex.lastServerCount == 0) "Signed in, but no Plex Media Server was found on your account."
                                else "Signed in, but couldn't reach your Plex server from this network (${plex.lastServerCount} found, none reachable). Make sure it's running, then Retry.",
                            )
                            return@launch
                        }
                        prefs.servers = servers
                        loadLibrary()
                        return@launch
                    }
                }
                signIn()
            } catch (e: Exception) {
                Log.w(TAG, "Sign-in failed", e)
                screen = Screen.SignIn(null, "COULD NOT REACH PLEX.TV. CHECK YOUR CONNECTION")
            }
        }
    }

    fun signOut() {
        closeSettings()
        playback.stop()
        prefs.signOut()
        mbServer = null
        libraryStore.clear()
        lineup = null
        showPicker()
    }

    // ── Jellyfin and Emby sign-in (SettingsView.swift and SignInFlow) ────

    private var connectJob: Job? = null
    private val connect get() = screen as? Screen.Connect

    /** What was typed last, so a wrong address or password needn't be typed again in full. */
    var lastAddress = ""
    var lastUsername = ""

    /** Back on a connect screen goes one step back; on the picker it leaves the app. */
    val connectCanGoBack get() = screen is Screen.SignIn || (connect != null && connect?.step != ConnectStep.Picker)

    fun connectBack() {
        when (val step = connect?.step) {
            null -> if (screen is Screen.SignIn) showPicker()
            ConnectStep.Picker -> {}
            is ConnectStep.Find -> showPicker()
            is ConnectStep.TypeAddress -> backToFind(step.kind)
            is ConnectStep.Checking -> backToFind(step.kind)
            is ConnectStep.SignIn -> backToFind(step.server.kind)
            is ConnectStep.QuickConnect -> backToFind(step.server.kind)
            is ConnectStep.SigningIn -> usePassword(step.server)
        }
    }

    private fun go(step: ConnectStep, message: String? = null, error: String? = null) {
        screen = Screen.Connect(step, message, error)
    }

    /** JELLYFIN on the picker: the find screen, already searching. */
    fun connectTo(kind: String) {
        go(ConnectStep.Find(kind))
        findServers(kind)
    }

    /** FIND MY SERVER, or SEARCH AGAIN. One answer goes straight to it. */
    fun findServers(kind: String) {
        connectJob?.cancel()
        go(ConnectStep.Find(kind, Discovery.Searching))
        connectJob = scope.launch {
            val found = mediaBrowser.discover(kind)
            when (found.size) {
                0 -> go(ConnectStep.Find(kind, Discovery.NothingFound))
                1 -> checkServer(kind, found[0].address, found[0].name)
                else -> go(ConnectStep.Find(kind, Discovery.Several(found)))
            }
        }
    }

    fun typeAddress(kind: String) {
        connectJob?.cancel()
        go(ConnectStep.TypeAddress(kind))
    }

    /**
     * Who is at this address, then the shortest way in it allows (SettingsView.checkServer and
     * open). A failure says why on the screen the check started from.
     */
    fun checkServer(kind: String, address: String, label: String) {
        val trimmed = address.trim()
        if (trimmed.isEmpty()) return
        connectJob?.cancel()
        val from = (connect?.step as? ConnectStep.TypeAddress) ?: ConnectStep.Find(kind)
        go(ConnectStep.Checking(kind, label))
        connectJob = scope.launch {
            val server = try {
                mediaBrowser.check(trimmed)
            } catch (e: java.io.IOException) {
                go(from, message = unreachableMessage(e, MediaBrowserClient.displayName(kind)))
                return@launch
            }
            if (server == null) {
                go(from, message = "That address answered, but it isn't a Jellyfin or Emby server. Check the port (both use 8096 unless you changed it).")
                return@launch
            }
            val switched = if (server.kind != kind) MediaBrowserClient.displayName(server.kind).let { "That address is a $it server, so this is a $it sign-in." } else null
            go(ConnectStep.SignIn(server), message = switched)
            if (server.prefersQuickConnect) startQuickConnect(server)
        }
    }

    /** CANCEL while checking, or BACK: the find screen for this kind. */
    fun backToFind(kind: String) {
        connectJob?.cancel()
        go(ConnectStep.Find(kind))
    }

    /** USE QUICK CONNECT: a code to approve in Jellyfin, polled every 2 s for 5 minutes. */
    fun startQuickConnect(server: CheckedServer) {
        connectJob?.cancel()
        val message = connect?.message
        go(ConnectStep.QuickConnect(server, null), message)
        connectJob = scope.launch {
            val qc = try {
                mediaBrowser.quickConnectInitiate(server)
            } catch (e: Exception) {
                Log.w(TAG, "Quick Connect failed to start", e)
                go(ConnectStep.SignIn(server), message, error = quickConnectFailure(e))
                return@launch
            }
            go(ConnectStep.QuickConnect(server, qc.code), message)
            repeat(150) {
                delay(2000)
                if (mediaBrowser.quickConnectApproved(server, qc)) {
                    val signedIn = runCatching { mediaBrowser.quickConnectSignIn(server, qc) }.getOrNull()
                    if (signedIn != null) finishSignIn(signedIn)
                    else go(ConnectStep.SignIn(server), message, error = "Could not start Quick Connect. Check the server address, or sign in with your password.")
                    return@launch
                }
            }
            go(ConnectStep.SignIn(server), message, error = "The code expired. Press USE QUICK CONNECT for a new one, or sign in with your password.")
        }
    }

    /** SIGN IN WITH A PASSWORD, or CANCEL while signing in. */
    fun usePassword(server: CheckedServer) {
        connectJob?.cancel()
        go(ConnectStep.SignIn(server), connect?.message)
    }

    /** SIGN IN, or a user tile with no password. */
    fun signInWithPassword(server: CheckedServer, username: String, password: String) {
        if (username.isBlank()) {
            go(ConnectStep.SignIn(server), connect?.message, error = "Enter your ${MediaBrowserClient.displayName(server.kind)} username.")
            return
        }
        connectJob?.cancel()
        val message = connect?.message
        go(ConnectStep.SigningIn(server), message)
        connectJob = scope.launch {
            try {
                val signedIn = mediaBrowser.signIn(server, username.trim(), password)
                if (signedIn == null) go(ConnectStep.SignIn(server), message, error = "Incorrect username or password.")
                else finishSignIn(signedIn)
            } catch (e: Exception) {
                Log.w(TAG, "Sign-in failed", e)
                go(ConnectStep.SignIn(server), message, error = unreachableMessage(e, MediaBrowserClient.displayName(server.kind)))
            }
        }
    }

    private fun finishSignIn(server: MediaBrowserServer) {
        prefs.signOut()
        libraryStore.clear()
        mbServer = server
        loadLibrary()
    }

    /** AppState.serverUnreachableMessage, for the errors the JVM gives. */
    private fun unreachableMessage(e: Throwable, backend: String): String = when (e) {
        is java.net.UnknownHostException -> "Could not find that host. Check the address."
        is java.net.ConnectException -> "Nothing answered at that address and port. Check the port (Jellyfin and Emby default to 8096)."
        is java.net.SocketTimeoutException, is java.io.InterruptedIOException -> "The $backend server took too long to answer. Check the address, or that the TV can reach it."
        is javax.net.ssl.SSLException -> "The server's HTTPS certificate is not trusted by this TV."
        else -> "Could not reach the $backend server. Check the address."
    }

    /** AppState.quickConnectFailureMessage. */
    private fun quickConnectFailure(e: Throwable): String = when {
        e is MediaBrowserHttpException && e.code == 401 ->
            "Quick Connect is off on this server. Turn it on in Jellyfin (Dashboard, then General), or sign in with your password."
        e is MediaBrowserHttpException && e.code == 404 -> "That address answered, but it isn't Jellyfin. Check the address and port (Jellyfin uses 8096)."
        e is java.io.IOException && e !is MediaBrowserHttpException -> unreachableMessage(e, "Jellyfin")
        else -> "Could not start Quick Connect. Check the server address, or sign in with your password."
    }

    // ── Settings (BundleManagerView.swift's SettingsPageView) ────────────

    /** The settings page, over the tuner. The picture plays on, muted, as on the Apple TV. */
    var settingsOpen by mutableStateOf(false)
        private set
    /** A picker page over Settings: "stream_quality", "sub_lang" or "audio_lang". */
    var settingsPicker: String? by mutableStateOf(null)

    fun openSettings() {
        settingsOpen = true
        settingsPicker = null
        playback.player.volume = 0f
        refreshServers()
    }

    fun closeSettings() {
        settingsOpen = false
        settingsPicker = null
        playback.player.volume = 1f
    }

    /** Every package in channels.json, in its order. */
    var bundles: List<ChannelConfig.Bundle> by mutableStateOf(emptyList())
        private set

    /** CHANNEL PACKAGES: the packages on, and the ones whose channels are being built. */
    var enabledBundles by mutableStateOf(prefs.enabledBundles)
        private set
    var buildingBundles by mutableStateOf(emptySet<String>())
        private set

    /** As AppState.toggleBundle: the last package on can't be switched off. */
    fun toggleBundle(id: String) {
        val l = lineup ?: return
        val on = id in enabledBundles
        if (on && enabledBundles.size <= 1) return
        val next = if (on) enabledBundles - id else enabledBundles + id
        enabledBundles = next
        prefs.enabledBundles = next
        if (!on) buildingBundles = buildingBundles + id
        scope.launch {
            withContext(Dispatchers.Default) {
                l.setBundles(next)
                l.rebuildSchedules()
            }
            buildingBundles = buildingBundles - id
            // The channel on keeps playing even if its package went; the guide just no longer lists it.
            scheduleTick++
            // From NO CHANNELS FOUND, a package with content brings the guide up.
            if (screen == Screen.NoChannels && l.channels.isNotEmpty()) {
                closeSettings()
                show(l)
            }
        }
    }

    /** SERVERS: every server the account can reach, plus any switched on that didn't answer this time. */
    var availableServers: List<PlexServer> by mutableStateOf(emptyList())
        private set
    /** On Jellyfin and Emby, the one server signed in to, shown as the Apple TV does: a single row with no switch. */
    val selectedServers: List<PlexServer>
        get() = mbServer?.let { listOf(PlexServer(it.name, "${it.serverId}/${it.userId}", it.url, it.token)) } ?: prefs.servers
    val serversForSettings: List<PlexServer>
        get() = (availableServers + selectedServers).distinctBy { it.machineIdentifier }

    private fun refreshServers() {
        if (mbServer != null) return
        val token = prefs.plexToken ?: return
        scope.launch {
            availableServers = runCatching { plex.discoverServers(token, includeShared = true) }.getOrDefault(availableServers)
        }
    }

    /** Switches a server's library in or out of the lineup; the last one stays. The library is then read again. */
    fun toggleServer(server: PlexServer) {
        if (loadingLibrary || refreshing || mbServer != null) return
        val current = prefs.servers
        val included = current.any { it.machineIdentifier == server.machineIdentifier }
        if (included && current.size <= 1) return
        prefs.servers = if (included) current.filterNot { it.machineIdentifier == server.machineIdentifier } else current + server
        closeSettings()
        playback.stop()
        loadLibrary()
    }

    /** RESCAN LIBRARY: read every server again behind the guide, as the launch refresh does. */
    fun rescanLibrary() {
        if (loadingLibrary || refreshing) return
        refreshInBackground(selectedServers, libraryItems)
    }

    /** What the app holds, for the RESCAN LIBRARY row (LibraryDiagnostics.summary). */
    var libraryItems: List<MediaItem> = emptyList()
        private set
    var libraryUpdatedMs: Long? by mutableStateOf(null)
        private set
    private var loadingLibrary = false

    fun librarySummary(): String {
        val items = libraryItems
        if (items.isEmpty()) return "No titles loaded. The scan came back empty."
        val fmt = java.text.NumberFormat.getIntegerInstance()
        fun pct(n: Int) = Math.round(n * 100.0 / items.size).toInt()
        val movies = items.count { it.type == "movie" }
        val episodes = items.filter { it.type == "episode" }
        val parts = mutableListOf("${fmt.format(items.size)} titles")
        if (movies > 0) parts += "${fmt.format(movies)} movies"
        if (episodes.isNotEmpty()) parts += "${fmt.format(episodes.size)} episodes from ${fmt.format(episodes.map { it.title }.toSet().size)} shows"
        parts += "${pct(items.count { it.genres.isNotEmpty() })}% with genres"
        parts += "${pct(items.count { it.tmdbID != null })}% matched to TMDB"
        return parts.joinToString(" \u00B7 ")
    }

    /** SUBTITLES: off, then foreign audio only, then always, then off again (cycleSubtitleMode). */
    fun cycleSubtitleMode() {
        when {
            subtitlesInFullScreen -> {
                subtitlesInFullScreen = false
                autoSubtitles = false
            }
            autoSubtitles -> subtitlesInFullScreen = true
            else -> autoSubtitles = true
        }
        prefs.subtitlesInFullScreen = subtitlesInFullScreen
        prefs.autoSubtitles = autoSubtitles
        applySubtitles()
    }

    val versionLabel: String = context.packageManager.getPackageInfo(context.packageName, 0).let {
        "VERSION ${it.versionName} (${androidx.core.content.pm.PackageInfoCompat.getLongVersionCode(it)})"
    }

    // ── The library and the lineup ───────────────────────────────────────

    /**
     * Opens on the library saved at the last load when there is one, so the guide is up in
     * seconds, then reads the servers again behind it and swaps the lineup in only if the
     * library changed: the Roku port's start-up. With nothing saved, the first read happens
     * in front of a loading screen.
     */
    private fun loadLibrary() {
        loadingLibrary = true
        scope.launch {
            try {
                val servers = selectedServers
                val t0 = SystemClock.elapsedRealtime()
                val saved = withContext(Dispatchers.IO) { libraryStore.load(servers) }
                if (saved != null) {
                    Log.i(TAG, "SAVED LIBRARY ${saved.size} items read in ${SystemClock.elapsedRealtime() - t0} ms")
                    libraryItems = saved
                    libraryUpdatedMs = libraryStore.savedAtMs()
                    if (!show(buildLineup(saved, "saved"))) return@launch
                    refreshInBackground(servers, saved)
                } else {
                    val headline = "READING YOUR ${backendName.uppercase()} LIBRARY"
                    screen = Screen.Loading(headline)
                    val items = scan(servers) { detail -> screen = Screen.Loading(headline, detail) }
                    Log.i(TAG, "LIBRARY ${items.size} items from ${servers.size} server(s) read in ${SystemClock.elapsedRealtime() - t0} ms")
                    withContext(Dispatchers.IO) { libraryStore.save(servers, items) }
                    libraryItems = items
                    libraryUpdatedMs = System.currentTimeMillis()
                    screen = Screen.Loading("BUILDING CHANNELS")
                    show(buildLineup(items, "read"))
                }
            } catch (e: Exception) {
                Log.w(TAG, "Library load failed", e)
                screen = Screen.Failed(connectionFailure(e))
            } finally {
                loadingLibrary = false
            }
        }
    }

    /** AppState.userFacingPlexAPIServiceError: what CONNECTION FAILED says for each way a load fails. */
    private fun connectionFailure(e: Throwable): String = when {
        e is PlexHttpException && e.code == 401 -> "Session expired. Please reconnect in Settings."
        e is MediaBrowserHttpException && e.code == 401 -> "Session expired. Please reconnect in Settings."
        e is MediaBrowserHttpException -> "$backendName returned HTTP ${e.code}. Check the server is running, then try again."
        mbServer != null && e is kotlinx.serialization.SerializationException -> "Invalid reply from $backendName. Disconnect and reconnect in Settings."
        mbServer != null -> unreachableMessage(e, backendName)
        e is PlexHttpException -> "Plex (or your network path) returned HTTP ${e.code}. If you use a reverse proxy or custom domain, " +
            "confirm it proxies /library and /identity without injecting a login page. Then reconnect."
        e is kotlinx.serialization.SerializationException -> "Invalid reply from Plex. Disconnect and reconnect in Settings."
        else -> "Signed in, but no Plex server was reachable. Confirm Plex is running and Remote Access is enabled, then try again."
    }

    private suspend fun scan(servers: List<PlexServer>, onProgress: (String) -> Unit): List<MediaItem> {
        mbServer?.let { mb ->
            return mediaBrowser.scan(mb) { text, count -> scope.launch { onProgress("${mb.name} · $text · $count ITEMS") } }
        }
        val library = PlexLibrary(plex)
        val items = ArrayList<MediaItem>()
        for (server in servers) {
            items += library.scan(server, { text, count ->
                scope.launch { onProgress("${server.name} · $text · $count ITEMS") }
            }, items.size)
        }
        return items
    }

    /** Reads every server again while the guide is up. The guide changes only if the library did. */
    private fun refreshInBackground(servers: List<PlexServer>, saved: List<MediaItem>) {
        scope.launch {
            refreshing = true
            try {
                val t0 = SystemClock.elapsedRealtime()
                val items = scan(servers) {}
                val took = SystemClock.elapsedRealtime() - t0
                libraryUpdatedMs = System.currentTimeMillis()
                if (items == saved) {
                    Log.i(TAG, "REFRESH ${items.size} items read in $took ms; unchanged")
                    return@launch
                }
                libraryItems = items
                Log.i(TAG, "REFRESH ${items.size} items read in $took ms; changed (was ${saved.size}), rebuilding")
                withContext(Dispatchers.IO) { libraryStore.save(servers, items) }
                val fresh = buildLineup(items, "refreshed")
                if (fresh.channels.isEmpty()) return@launch
                // What is on keeps playing; the channel now airs from its new pool from the next programme.
                val id = channel?.id
                lineup = fresh
                channel = fresh.channels.firstOrNull { it.id == id } ?: channel
                scheduleTick++
            } catch (e: Exception) {
                Log.w(TAG, "Background refresh failed; keeping the saved library", e)
            } finally {
                refreshing = false
            }
        }
    }

    private suspend fun buildLineup(items: List<MediaItem>, source: String): Lineup = withContext(Dispatchers.Default) {
        val t0 = SystemClock.elapsedRealtime()
        val (config, memberships) = channelData.await()
        withContext(Dispatchers.Main) { bundles = config.bundles }
        // Only the wait: the parse itself runs while the library is read.
        val configMs = SystemClock.elapsedRealtime() - t0
        val serverKey = (mbServer?.let { "${it.kind}_${it.serverId}" } ?: ("plex_" + prefs.servers.joinToString("_") { it.machineIdentifier }))
            .replace(Regex("[^A-Za-z0-9]"), "_").take(60)
        val lineup = Lineup(config, memberships, DailyManifest(ZoneId.systemDefault(), manifestStore), serverKey)
        var built = 0
        val switchedOn = lineup.build(items, prefs.enabledBundles) { done, _ -> built = maxOf(built, done) }
        if (switchedOn.isNotEmpty()) {
            prefs.enabledBundles = prefs.enabledBundles + switchedOn
            withContext(Dispatchers.Main) { enabledBundles = prefs.enabledBundles }
        }
        val tFilter = SystemClock.elapsedRealtime()
        lineup.rebuildSchedules()
        Log.i(TAG, "LINEUP ($source) ${items.size} items; $built channels in ${tFilter - t0} ms (config ${configMs}, item facts ${lineup.prepareMs}, filter ${tFilter - t0 - configMs - lineup.prepareMs}); " +
            "${lineup.channels.size} in the guide; schedules in ${SystemClock.elapsedRealtime() - tFilter} ms; channels.json v${config.version}")
        lineup
    }

    /** Puts the lineup on screen and tunes in. False when it has no channels. */
    private fun show(built: Lineup): Boolean {
        lineup = built
        if (built.channels.isEmpty()) {
            screen = Screen.NoChannels
            return false
        }
        screen = Screen.Watching
        startClock()
        // The first channel, as the Apple TV tunes at launch (it keeps no last channel).
        tune(built.channels.first())
        return true
    }

    private fun asset(name: String) = context.assets.open(name).bufferedReader().use { it.readText() }

    /** The guide's schedules follow the clock: rebuilt each minute, off the main thread. */
    private fun startClock() {
        clockJob?.cancel()
        clockJob = scope.launch {
            while (isActive) {
                delay(60_000 - System.currentTimeMillis() % 60_000)
                lineup?.let { l -> withContext(Dispatchers.Default) { l.rebuildSchedules() } }
                scheduleTick++
            }
        }
    }

    // ── Watching ─────────────────────────────────────────────────────────

    fun tune(ch: GuideChannel) {
        val l = lineup ?: return
        channel = ch
        // The viewer chose a channel: count again (ChannelFailureRun.reset).
        failureRun.reset()
        tuneCount++
        play(l.tune(ch))
    }

    private fun play(pick: Pick?) {
        audioChosenFor = null
        lastTracks = null
        // An audio track chosen in Now Playing was for that programme only.
        playback.player.trackSelectionParameters = playback.player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO).build()
        skipJob?.cancel()
        failure = null
        item = pick?.item
        delivery = null
        if (pick == null) {
            playback.stop()
            failure = PlaybackFailure.NoPlayableSource(backendName)
            return
        }
        playback.play(pick.item, pick.seekSeconds)
    }

    /** The next channel in guide order, wrapping, as AppState.nextChannel. */
    fun nextChannel() = step(1)

    /** The previous channel in guide order, wrapping, as AppState.previousChannel. */
    fun previousChannel() = step(-1)

    private fun step(by: Int) {
        val list = lineup?.channels ?: return
        if (list.isEmpty()) return
        val i = list.indexOfFirst { it.id == channel?.id }
        tune(list[Math.floorMod(i + by, list.size)])
    }

    override fun onStarted(item: MediaItem, delivery: Delivery) {
        // A picture: count again.
        failureRun.reset()
        this.delivery = delivery
        // The guide follows what is on, as TunerView rebuilds on a change of current item.
        lineup?.let { l ->
            scope.launch {
                withContext(Dispatchers.Default) { l.rebuildSchedules() }
                scheduleTick++
            }
        }
    }

    override fun onEnded(item: MediaItem) {
        val ch = channel ?: return
        play(lineup?.next(ch, item, fromNaturalEnd = true))
    }

    /**
     * AppState.showFailureThenAdvance: the card for 5 s, then the next programme from where it
     * is now. The fifth failure in a row on a channel stops it, so a dead server isn't asked
     * again until the viewer tunes or selects the channel again.
     */
    override fun onFailed(item: MediaItem, failure: PlaybackFailure) {
        val ch = channel ?: return
        skipJob?.cancel()
        if (failureRun.recordFailure(ch.id)) {
            playback.stop()
            this.failure = PlaybackFailure.ChannelStopped(failure)
            return
        }
        this.failure = failure
        skipJob = scope.launch {
            delay(5_000)
            if (channel?.id == ch.id) play(lineup?.next(ch, item, fromNaturalEnd = false))
        }
    }

    fun release() {
        scope.cancel()
        playback.release()
    }

    companion object {
        private const val TAG = "Nostalgex"
    }
}
