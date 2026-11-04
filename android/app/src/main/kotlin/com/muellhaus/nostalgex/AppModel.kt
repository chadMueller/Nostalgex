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
import com.muellhaus.nostalgex.engine.CollectionCategory
import com.muellhaus.nostalgex.engine.Collections
import com.muellhaus.nostalgex.engine.EnrichmentService
import com.muellhaus.nostalgex.engine.FranchiseBuilder
import com.muellhaus.nostalgex.engine.FranchiseDefinition
import com.muellhaus.nostalgex.engine.FranchiseLineup
import com.muellhaus.nostalgex.engine.ServerCollection
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.LibraryLoadProgressSample
import com.muellhaus.nostalgex.engine.LibraryLoadStallDetector
import com.muellhaus.nostalgex.engine.LibrarySection
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
import com.muellhaus.nostalgex.engine.ScanProgress
import com.muellhaus.nostalgex.engine.DemoData
import com.muellhaus.nostalgex.engine.Season
import java.time.LocalDateTime
import androidx.compose.runtime.mutableIntStateOf
import com.muellhaus.nostalgex.mediabrowser.CheckedServer
import com.muellhaus.nostalgex.mediabrowser.DiscoveredServer
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserClient
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserHttpException
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserServer
import com.muellhaus.nostalgex.playback.Delivery
import com.muellhaus.nostalgex.playback.Playback
import com.muellhaus.nostalgex.playback.WatchReporter
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
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import java.time.ZoneId

sealed interface Screen {
    /** Plex's code, after CONNECT TO PLEX. */
    data class SignIn(val pin: PlexPin?, val error: String? = null) : Screen
    /** After Plex sign-in, when the account reaches more than one server: which to use (ServerPickerView). */
    data class ChooseServers(val servers: List<PlexServer>) : Screen
    /** After sign-in, when the servers have more than one library: which to build channels from. */
    data class ChooseLibraries(val sections: List<LibrarySection>) : Screen
    /** The connect screens: the backend picker, then Jellyfin or Emby: find, check and sign in. */
    data class Connect(val step: ConnectStep, val message: String? = null, val error: String? = null) : Screen
    /** A short wait: the headline and detail, or the logo alone when there is nothing to say. */
    data class Loading(val headline: String, val detail: String = "") : Screen
    /**
     * A library read in front of the guide (LoadingView): the step rail, what it is doing now,
     * a progress bar where there is a count, and START OVER.
     */
    data class LibraryLoad(
        val phase: LoadPhase,
        val headline: String,
        val detail: String = "",
        val progress: Float? = null,
        val caption: String = "",
        val firstRun: Boolean = false,
    ) : Screen
    /** The last two loads never finished (LaunchGuard): TRY AGAIN or START OVER. */
    data object UnfinishedLoads : Screen
    data class Failed(val message: String) : Screen
    data object NoChannels : Screen
    data object Watching : Screen
}

/** Settings' rail (SettingsCategory.swift). SUPPORT NOSTALGEX and NOSTALGEX PRO have no counterpart here. */
enum class SettingsCategory(val title: String, val subtitle: String, val icon: Int) {
    PLAYBACK("PLAYBACK & PICTURE", "Picture, quality, subtitles and audio", R.drawable.settings_hero_playback),
    CHANNELS("CHANNELS & BUNDLES", "Packages and the schedule", R.drawable.settings_hero_channels),
    SERVERS("SERVERS & ACCOUNTS", "Servers, libraries, rescans and sign out", R.drawable.settings_hero_servers),
    ABOUT("ABOUT", "Version and links", R.drawable.settings_hero_about),
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

    /** SHOW NOW PLAYING and MARK WATCHED: what the server is told about what plays (PlaybackTracker). */
    val watchReporter = WatchReporter(plex.headers) { token -> mediaBrowser.authHeader(token) }

    /** The Jellyfin or Emby server signed in to, read once from Prefs; null on Plex. */
    private var mbServer: MediaBrowserServer? = prefs.mediaBrowser
        set(value) {
            field = value
            prefs.mediaBrowser = value
            playback.mediaBrowserServer = value
        }

    /** "Plex", "Jellyfin" or "Emby": the Apple TV's backendDisplayName, in its copy. */
    val backendName: String get() = mbServer?.let { MediaBrowserClient.displayName(it.kind) } ?: "Plex"

    var screen: Screen by mutableStateOf(Screen.Loading(""))
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

    /**
     * WATERSHED: 18, R and TV-MA titles wait for 9 PM on every channel but VHS VAULT, which
     * holds its own. A change reaches the schedules at once; what is on keeps playing, as on
     * the Apple TV, except that a channel held off the air comes back on when it's switched off.
     */
    var watershed by mutableStateOf(prefs.watershed)
        private set

    /** The channel on has nothing to show until 9 PM because of Watershed: its card is up. */
    var watershedHold by mutableStateOf(false)
        private set

    fun toggleWatershed() {
        watershed = !watershed
        prefs.watershed = watershed
        val l = lineup ?: return
        l.watershed = watershed
        scope.launch {
            withContext(Dispatchers.Default) { l.rebuildSchedules() }
            scheduleTick++
            if (watershedHold) channel?.let(::tune)
        }
    }

    /** GUIDE TEXT SIZE: NORMAL, the guide as it was, or LARGE for a couch further away (I-060). */
    var guideTextLarge by mutableStateOf(prefs.guideTextLarge)
        private set

    fun toggleGuideTextSize() {
        guideTextLarge = !guideTextLarge
        prefs.guideTextLarge = guideTextLarge
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
        .also { playback.subtitleLanguage = LanguageChoice.resolved(prefs.subtitleLanguage) }
        private set
    var audioLanguage by mutableStateOf(prefs.audioLanguage)
        .also { playback.audioLanguages = listOf(LanguageChoice.resolved(prefs.audioLanguage)) }
        private set

    fun chooseSubtitleLanguage(code: String) {
        subtitleLanguage = code
        prefs.subtitleLanguage = code
        playback.subtitleLanguage = LanguageChoice.resolved(code)
        applySubtitles()
    }

    /** Applies to the programme playing as well as the next (Roku #118, AppState's didSet). */
    // ── WATCH HISTORY (SettingsPlaybackView): both off by default ──────

    var showNowPlaying by mutableStateOf(prefs.showNowPlaying)
        private set
    var markWatched by mutableStateOf(prefs.markWatched)
        private set

    fun toggleShowNowPlaying() {
        showNowPlaying = !showNowPlaying
        prefs.showNowPlaying = showNowPlaying
        watchReporter.setChoices(showNowPlaying, markWatched)
    }

    fun toggleMarkWatched() {
        markWatched = !markWatched
        prefs.markWatched = markWatched
        watchReporter.setChoices(showNowPlaying, markWatched)
    }

    /** Where a programme's reports go: the server it came from. */
    private fun reportServer(item: MediaItem): WatchReporter.Server? {
        mbServer?.let { return WatchReporter.Server.MediaBrowser(item.serverUrl ?: it.url, it.userId, it.token) }
        val url = item.serverUrl ?: return null
        return WatchReporter.Server.Plex(url, item.serverToken ?: "")
    }

    fun chooseAudioLanguage(code: String) {
        audioLanguage = code
        prefs.audioLanguage = code
        // A transcode asks for its track when it starts; the next one carries the new language.
        playback.audioLanguages = listOf(LanguageChoice.resolved(code))
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
            watchReporter.onPause()
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

    /** TMDB and OMDb, in a build that turned them on (EnrichmentSetup); null otherwise. */
    private val enrichment = EnrichmentSetup.create(context)
    val enrichmentOn: Boolean get() = enrichment != null

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
    /** franchises.json: the dictionary the franchise builder and the fold read. */
    private val franchiseDefinitions: Deferred<List<FranchiseDefinition>> = scope.async(Dispatchers.Default) {
        runCatching { FranchiseBuilder.parseDefinitions(asset("franchises.json")) }.getOrDefault(emptyList())
    }
    private val manifestStore = FileManifestStore(context)
    private var signInJob: Job? = null
    private var clockJob: Job? = null

    init {
        watchReporter.setChoices(prefs.showNowPlaying, prefs.markWatched)
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

    private val launchGuard = LaunchGuard(context)

    fun start() {
        // Once per process: an activity recreated mid-load must not count that load as unfinished.
        if (!launchRecorded) {
            launchRecorded = true
            launchGuard.recordLaunch()
        }
        val signedIn = mbServer != null || (prefs.plexToken != null && prefs.servers.isNotEmpty())
        when {
            !signedIn -> showPicker()
            launchGuard.shouldAskBeforeLoading() -> screen = Screen.UnfinishedLoads
            else -> loadLibrary()
        }
    }

    /** TRY AGAIN after two unfinished loads: the next load gets the full allowance again. */
    fun tryLoadingAgain() {
        launchGuard.resetUnfinishedLoads()
        loadLibrary()
    }

    /** The server named in START OVER's question. */
    val serverName: String get() = selectedServers.firstOrNull()?.name ?: ""

    /**
     * START OVER (AppState.startOver): stops the load, then signs out, so a library that won't
     * finish loading is never the only way forward.
     */
    fun startOver() {
        loadJob?.cancel()
        launchGuard.loadEnded()
        Log.i(TAG, "START OVER")
        signOut()
    }

    // ── Sign-in ──────────────────────────────────────────────────────────

    /** The first connect screen: CONNECT TO PLEX, or Jellyfin or Emby. */
    fun showPicker(error: String? = null) {
        signInJob?.cancel()
        connectJob?.cancel()
        screen = Screen.Connect(ConnectStep.Picker, error = error)
    }

    /** The plex.tv token while the server picker is open; saved only with the chosen servers. */
    private var pendingPlexToken: String? = null

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
                        screen = Screen.Loading("FINDING YOUR SERVERS")
                        // Every reachable server, shared ones too, as the Apple TV finds them: with
                        // more than one, the viewer picks (ServerPickerView).
                        val servers = try {
                            plex.discoverServers(token, includeShared = true)
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
                        Log.i(TAG, "SERVERS ${servers.size} reachable (${servers.count { it.owned }} owned)")
                        if (servers.size > 1) {
                            // Held until the picker confirms, as the Apple TV does: the token is
                            // saved together with the chosen servers.
                            pendingPlexToken = token
                            screen = Screen.ChooseServers(servers)
                        } else {
                            prefs.plexToken = token
                            prefs.servers = servers
                            chooseLibrariesOrScan()
                        }
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

    // ── Demo mode (AppState.enterDemoMode) ───────────────────────────────

    /**
     * Demo mode: the Apple TV's five sample channels, no account and no server. Every channel
     * plays Apple's public sample stream. Not saved, as on the Apple TV: the next launch is the
     * sign-in screen again, and DISCONNECT leaves it.
     */
    var demoMode by mutableStateOf(false)
        private set
    private var demoJob: Job? = null
    /** When the block the clip stands in for ends, unix seconds (demoBlockEnd). */
    private var demoBlockEndSec = 0.0

    fun enterDemoMode() {
        signInJob?.cancel()
        connectJob?.cancel()
        Log.i(TAG, "DEMO MODE")
        demoMode = true
        playback.demo = true
        screen = Screen.Loading("")
        scope.launch {
            val (config, _) = channelData.await()
            bundles = config.bundles
            val l = withContext(Dispatchers.Default) {
                Lineup(config, null, DailyManifest(ZoneId.systemDefault(), manifestStore), DemoData.SERVER_KEY).apply {
                    watershed = prefs.watershed
                    airFixed(DemoData.channels())
                    rebuildSchedules()
                }
            }
            show(l)
        }
        // demoScheduleTick: the clip's length has nothing to do with the schedule, so the clock
        // says when a block ends and the next programme starts.
        demoJob?.cancel()
        demoJob = scope.launch {
            while (isActive) {
                delay(1000)
                val ch = channel ?: continue
                if (item != null && failure == null && System.currentTimeMillis() / 1000.0 >= demoBlockEndSec) {
                    Log.i(TAG, "DEMO: block ended at the clock, moving to the next programme")
                    play(lineup?.tune(ch))
                }
            }
        }
    }

    private fun leaveDemoMode() {
        if (!demoMode) return
        demoJob?.cancel()
        demoMode = false
        playback.demo = false
    }

    fun signOut() {
        closeSettings()
        playback.stop()
        leaveDemoMode()
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
        chooseLibrariesOrScan()
    }

    // ── Libraries (library selection: AppState+Auth.swift, I-054) ────────

    /** The libraries switched off, as LibrarySection ids. A library never seen before is on. */
    var deselectedSections by mutableStateOf(prefs.deselectedSections)
        private set

    /** Every library on the servers in use, for Settings' LIBRARIES list. */
    var availableSections: List<LibrarySection> by mutableStateOf(emptyList())
        private set

    private suspend fun loadAllSections(): List<LibrarySection> {
        mbServer?.let { mb ->
            return runCatching { mediaBrowser.sections(mb, selectedServers.first().machineIdentifier) }.getOrDefault(emptyList())
        }
        val library = PlexLibrary(plex)
        return prefs.servers.flatMap { server -> runCatching { library.sections(server) }.getOrDefault(emptyList()) }
    }

    /**
     * presentLibrarySelectionOrScan: the step after sign-in. Every library starts on again for
     * this sign-in; with more than one, the viewer can leave some out before the first scan
     * touches them. One library (or none readable: the scan reports its own error) scans at once.
     */
    private fun chooseLibrariesOrScan() {
        deselectedSections = emptySet()
        prefs.deselectedSections = emptySet()
        screen = Screen.Loading("READING YOUR ${backendName.uppercase()} LIBRARY")
        scope.launch {
            val sections = loadAllSections()
            availableSections = sections
            Log.i(TAG, "LIBRARIES ${sections.size} on ${selectedServers.size} server(s)")
            if (sections.size > 1) screen = Screen.ChooseLibraries(sections) else loadLibrary()
        }
    }

    /** CONTINUE on the server picker (confirmServerSelection): the chosen servers, then the libraries. */
    fun confirmServers(chosen: Set<String>) {
        val servers = (screen as? Screen.ChooseServers)?.servers ?: return
        val token = pendingPlexToken ?: return
        val picked = servers.filter { it.machineIdentifier in chosen }
        if (picked.isEmpty()) return
        Log.i(TAG, "SERVERS ${picked.size} of ${servers.size} chosen")
        pendingPlexToken = null
        prefs.plexToken = token
        prefs.servers = picked
        chooseLibrariesOrScan()
    }

    /** CONTINUE on the library-selection screen: the ones left off are never scanned. */
    fun confirmLibraries(included: Set<String>) {
        val sections = (screen as? Screen.ChooseLibraries)?.sections ?: return
        if (included.isEmpty()) return
        deselectedSections = sections.map { it.id }.filter { it !in included }.toSet()
        prefs.deselectedSections = deselectedSections
        Log.i(TAG, "LIBRARIES ${included.size} of ${sections.size} included")
        loadLibrary()
    }

    val enabledSectionCount get() = availableSections.count { it.id !in deselectedSections }

    /** A LIBRARIES row in Settings, as toggleServer: never the last one on; the library is then read again. */
    fun toggleLibrarySection(section: LibrarySection) {
        if (loadingLibrary || refreshing) return
        val on = section.id !in deselectedSections
        if (on && enabledSectionCount <= 1) return
        deselectedSections = if (on) deselectedSections + section.id else deselectedSections - section.id
        prefs.deselectedSections = deselectedSections
        libraryStore.clear()
        closeSettings()
        playback.stop()
        loadLibrary()
    }

    private fun refreshSections() {
        scope.launch { loadAllSections().takeIf { it.isNotEmpty() }?.let { availableSections = it } }
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

    // ── Settings (SettingsContainerView: a rail of categories, a pane of rows) ──

    /** Settings, over the tuner. The picture plays on, muted, as on the Apple TV. */
    var settingsOpen by mutableStateOf(false)
        private set
    /** A picker page over Settings: "stream_quality", "sub_lang" or "audio_lang". */
    var settingsPicker: String? by mutableStateOf(null)

    /** The category the pane shows. It follows focus on the rail, with no press. */
    var settingsCategory by mutableStateOf(SettingsCategory.PLAYBACK)
    /** The CHANNELS & BUNDLES sub-page on show: "packages", "missing", or null for its list. */
    var channelsPage: String? by mutableStateOf(null)
    /** Whether focus is on the rail (true) or in the pane's rows. Set by the rail's rows. */
    var settingsOnRail by mutableStateOf(true)
    /** Asks the screen to put focus on the rail's selected category, or on a pane row. */
    var railFocusTick by mutableStateOf(0)
        private set
    var paneFocusTick by mutableStateOf(0)
        private set
    /**
     * Set while the pane swaps one sub-page for another. The row that had focus goes away, and
     * Compose drops focus on the first thing it finds, a rail row; that must not switch the
     * category. Cleared when the new page's row takes focus.
     */
    var paneSwapping = false

    /** The last pane tick the pane acted on. Different from `paneFocusTick`: a pane row is waiting for focus. */
    var paneTickHandled = 0

    /** The pane row to focus at the next pane tick; null is the first row. */
    var paneFocusKey: String? = null
        private set

    fun openSettings() {
        settingsOpen = true
        settingsPicker = null
        settingsCategory = SettingsCategory.PLAYBACK
        channelsPage = null
        settingsOnRail = true
        paneSwapping = false
        paneTickHandled = paneFocusTick
        playback.player.volume = 0f
        refreshServers()
        refreshSections()
    }

    fun closeSettings() {
        settingsOpen = false
        settingsPicker = null
        playback.player.volume = 1f
    }

    /** Right or OK on the rail, or a link row: focus a pane row (`key`), or its first. */
    fun focusPane(key: String? = null) {
        paneSwapping = true
        paneFocusKey = key
        paneFocusTick++
    }

    /** Left from the rows: back to the selected category, not whichever is level with the row. */
    fun focusRail() {
        railFocusTick++
    }

    /** A link row on CHANNELS & BUNDLES: the sub-page, focus on its first row. */
    fun openChannelsPage(page: String) {
        paneSwapping = true
        channelsPage = page
        focusPane()
    }

    /**
     * Back in Settings, one step at a time: a picker closes; a sub-page goes up to the page
     * that opened it, focus on the row that did; the rows give focus to the rail; the rail
     * closes Settings. False when Settings closed, so the caller can put focus on the guide.
     */
    fun settingsBack(): Boolean {
        when {
            // The picker's row is keyed by the picker's own name.
            settingsPicker != null -> { val row = settingsPicker; settingsPicker = null; focusPane(row) }
            !settingsOnRail && channelsPage == "missing" -> { paneSwapping = true; channelsPage = "packages"; focusPane("channels_missing") }
            !settingsOnRail && channelsPage == "packages" -> { paneSwapping = true; channelsPage = null; focusPane("channels_packages") }
            !settingsOnRail && channelsPage == "franchises" -> { paneSwapping = true; channelsPage = null; focusPane("channels_franchises") }
            !settingsOnRail && channelsPage == "collections" -> { paneSwapping = true; channelsPage = null; focusPane("channels_collections") }
            !settingsOnRail -> focusRail()
            else -> { closeSettings(); return false }
        }
        return true
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
        // Demo mode's channels belong to no package; a switch here would only change the saved choice.
        if (demoMode) return
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

    // ── The seasonal invite (AppState+Channels.swift) ────────────────────

    /** Bumped when an invite is answered: the answer lives in Prefs, which Compose can't see. */
    private var seasonalRevision by mutableIntStateOf(0)

    /**
     * The seasonal package the invite above channel one offers, or null (seasonalBundleOnOffer).
     * Read with the minute's tick, so a season starting at midnight shows its invite then.
     * Seasonal packages are never switched on for anyone: only YES, TURN IT ON does that.
     */
    val seasonalOffer: ChannelConfig.Bundle?
        get() {
            seasonalRevision
            scheduleTick
            if (demoMode) return null
            val now = LocalDateTime.now()
            return Season.bundleToOffer(bundles, enabledBundles, now) { Season.isSilenced(it, now, prefs::flag) }
        }

    /**
     * The viewer's answer (answerSeasonalPrompt). YES switches the package on, and it stays on
     * until switched off; NOT THIS YEAR is quiet until the season ends; DON'T ASK AGAIN is for good.
     */
    fun answerSeasonalPrompt(answer: Season.Answer, bundle: ChannelConfig.Bundle) {
        val turnOn = Season.record(answer, bundle.id, LocalDateTime.now(), prefs::setFlag)
        Log.i(TAG, "SEASONAL INVITE ${bundle.id}: $answer")
        seasonalRevision++
        if (turnOn && bundle.id !in enabledBundles) toggleBundle(bundle.id)
    }

    // ── Franchises and collections (AppState+Franchises.swift) ──────────

    /** A row's switch in the franchise list: a classic or a found franchise, by stable id. */
    fun toggleFranchiseRow(row: FranchiseLineup.Row) {
        val on = !row.enabled
        prefs.enabledFranchises = if (on) prefs.enabledFranchises + row.id else prefs.enabledFranchises - row.id
        prefs.disabledFranchises = if (on) prefs.disabledFranchises - row.id else prefs.disabledFranchises + row.id
        applyFranchiseChoices()
    }

    /**
     * ADD ALL / REMOVE ALL (setAllFranchises): every classic, found franchise and franchise
     * collection in the list, as one choice.
     */
    fun setAllFranchises(on: Boolean) {
        val f = lineup?.franchises ?: return
        val rowIds = f.rows.map { it.id }.toSet()
        val collectionIds = f.candidates.filter { it.category == CollectionCategory.FRANCHISES && it.foldedInto == null }.map { it.id }.toSet()
        prefs.enabledFranchises = if (on) prefs.enabledFranchises + rowIds else prefs.enabledFranchises - rowIds
        prefs.disabledFranchises = if (on) prefs.disabledFranchises - rowIds else prefs.disabledFranchises + rowIds
        prefs.enabledCollections = if (on) prefs.enabledCollections + collectionIds else prefs.enabledCollections - collectionIds
        applyFranchiseChoices()
    }

    /** A server collection's switch, under FRANCHISES or MY COLLECTIONS. Every collection starts off. */
    fun toggleCollection(id: String) {
        val now = prefs.enabledCollections
        prefs.enabledCollections = if (id in now) now - id else now + id
        applyFranchiseChoices()
    }

    /** The franchise step again with the new choices, then the guide (rebuildLineupAfterBundleChange). */
    private fun applyFranchiseChoices() {
        val l = lineup ?: return
        val choices = franchiseChoices()
        scope.launch {
            withContext(Dispatchers.Default) {
                l.setFranchiseChoices(choices, enabledBundles)
                l.rebuildSchedules()
            }
            scheduleTick++
            franchiseTick++
        }
    }

    /** Bumped when the franchise list or the collections change, so Settings reads them again. */
    var franchiseTick by mutableStateOf(0)
        private set

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
        // Demo mode is fully bundled: never the network (loadLibrary's isDemoMode return).
        if (demoMode || loadingLibrary || refreshing) return
        refreshInBackground(selectedServers, scannedItems)
    }

    /** What the app holds, enrichment attached, for the RESCAN LIBRARY row (LibraryDiagnostics.summary). */
    var libraryItems: List<MediaItem> = emptyList()
        private set

    /** The same items as the servers gave them, before enrichment: what a refresh compares and saves. */
    private var scannedItems: List<MediaItem> = emptyList()

    /** The servers' collections, read with the library (CollectionScan). */
    private var serverCollections: List<ServerCollection> = emptyList()

    /** The franchise and collection switches, as Prefs keeps them. */
    private fun franchiseChoices() = Lineup.FranchiseChoices(prefs.enabledFranchises, prefs.disabledFranchises, prefs.enabledCollections)

    /**
     * Each server's collections (scanCollections): Plex's from its movie and TV sections, a
     * Jellyfin or Emby server's BoxSets. A server that fails gives none and the rest go on.
     */
    private suspend fun readCollections(servers: List<PlexServer>): List<ServerCollection> {
        val t0 = SystemClock.elapsedRealtime()
        val out = mbServer?.let { mb -> runCatching { mediaBrowser.collections(mb) }.onFailure { Log.w(TAG, "Collections failed", it) }.getOrDefault(emptyList()) }
            ?: servers.flatMap { server -> runCatching { plex.collections(server) }.onFailure { Log.w(TAG, "Collections on ${server.name} failed", it) }.getOrDefault(emptyList()) }
        Log.i(TAG, "COLLECTIONS ${out.size} read in ${SystemClock.elapsedRealtime() - t0} ms")
        return out
    }
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
    private var loadJob: Job? = null

    private fun loadLibrary() {
        loadingLibrary = true
        loadJob = scope.launch {
            // Set until the load ends any way the process lives to see (LaunchGuard).
            launchGuard.loadStarted()
            var fullLoad = false
            try {
                val servers = selectedServers
                val t0 = SystemClock.elapsedRealtime()
                val saved = withContext(Dispatchers.IO) { libraryStore.load(servers) }
                if (saved != null) {
                    Log.i(TAG, "SAVED LIBRARY ${saved.items.size} items and ${saved.collections.size} collections read in ${SystemClock.elapsedRealtime() - t0} ms")
                    prefs.initialLoadComplete = true
                    scannedItems = saved.items
                    serverCollections = saved.collections
                    // The local enrichment cache only: the network waits for the refresh behind the guide.
                    libraryItems = enrich(saved.items, remote = false)
                    libraryUpdatedMs = libraryStore.savedAtMs()
                    if (!show(buildLineup(libraryItems, "saved"))) return@launch
                    refreshInBackground(servers, saved.items)
                } else {
                    fullLoad = true
                    val firstRun = !prefs.initialLoadComplete
                    fun step(phase: LoadPhase, headline: String = phase.headline(), detail: String = "", progress: Float? = null, caption: String = "") {
                        screen = Screen.LibraryLoad(phase, headline, detail, progress, caption, firstRun)
                    }
                    step(LoadPhase.PREPARING, LoadPhase.PREPARING.headline(if (firstRun) "First setup" else "Updating lineup"), LoadPhase.PREPARING.hint.uppercase())
                    step(LoadPhase.SCANNING, LoadPhase.SCANNING.headline("Connecting to $backendName"), LoadPhase.SCANNING.hint.uppercase())
                    val scanned = scan(servers) { p, serverName ->
                        // Posted from the scan's threads: one arriving after the scan moved on is dropped.
                        if ((screen as? Screen.LibraryLoad)?.phase != LoadPhase.SCANNING) return@scan
                        // AppState+Library's scan events: the kind of library as the headline, the section under it.
                        val label = when (p.type) {
                            "show" -> "TV shows"
                            "movie" -> if ("music" in p.title.lowercase()) "Music" else "Movies"
                            "artist" -> "Music"
                            "photo" -> "Photos"
                            else -> "Library"
                        }
                        val prefix = if (servers.size > 1) "$serverName · " else ""
                        val section = "Section ${p.section + 1}/${maxOf(p.sections, 1)}"
                        if (p.showsDone != null && p.showsTotal != null) {
                            step(LoadPhase.SCANNING, LoadPhase.SCANNING.headline("$label ${p.showsDone}/${p.showsTotal}"),
                                "$prefix$section · ${p.showsDone}/${p.showsTotal} shows".uppercase(),
                                (p.section + 1f) / maxOf(p.sections, 1), "Section ${p.section + 1} of ${p.sections} · ${p.itemsSoFar} items")
                        } else {
                            step(LoadPhase.SCANNING, LoadPhase.SCANNING.headline(label), "$prefix$section · ${p.itemsSoFar} items".uppercase(),
                                (p.section + 1f) / maxOf(p.sections, 1), "Section ${p.section + 1} of ${p.sections} · ${p.itemsSoFar} items")
                        }
                    }
                    val items = scanned.items
                    // Abandoned partway: a reduced guide beats an error screen; the next launch's
                    // refresh fills in the rest (isLibraryStale).
                    if (scanned.abandoned) Log.i(TAG, "LOAD abandoned mid-scan; building from the ${items.size} items read")
                    Log.i(TAG, "LIBRARY ${items.size} items from ${servers.size} server(s) read in ${SystemClock.elapsedRealtime() - t0} ms")
                    // COLLECTIONS: the servers' own collections, before metadata (the fold reads TMDB collection ids).
                    step(LoadPhase.COLLECTIONS, LoadPhase.COLLECTIONS.headline(), LoadPhase.COLLECTIONS.hint.uppercase())
                    // Not after an abandoned scan: the server just went quiet, and the viewer has
                    // stopped waiting on it. The next refresh reads them with the rest.
                    serverCollections = if (scanned.abandoned) {
                        Log.i(TAG, "COLLECTIONS skipped: the scan was abandoned")
                        emptyList()
                    } else readCollections(servers)
                    withContext(Dispatchers.IO) { libraryStore.save(servers, items, serverCollections) }
                    scannedItems = items
                    libraryUpdatedMs = System.currentTimeMillis()
                    if (enrichment != null) {
                        val titles = items.count { it.tmdbID != null }
                        step(LoadPhase.METADATA, LoadPhase.METADATA.headline("$titles titles"), LoadPhase.METADATA.hint.uppercase())
                    }
                    libraryItems = enrich(items, remote = true) { status, done, total ->
                        if ((screen as? Screen.LibraryLoad)?.phase != LoadPhase.METADATA) return@enrich
                        val current = screen as Screen.LibraryLoad
                        screen = current.copy(
                            detail = status.uppercase(),
                            progress = if (total > 0 && done >= 0) done.toFloat() / total else null,
                            caption = if (total > 0 && done >= 0) "Metadata $done/$total" else "",
                        )
                    }
                    step(LoadPhase.BUILDING)
                    val built = buildLineup(libraryItems, "read") { done, total ->
                        if ((screen as? Screen.LibraryLoad)?.phase == LoadPhase.BUILDING) step(LoadPhase.BUILDING, progress = done.toFloat() / maxOf(total, 1), caption = "Channel $done of $total")
                    }
                    step(LoadPhase.FINISHING)
                    prefs.initialLoadComplete = true
                    show(built)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Library load failed", e)
                screen = Screen.Failed(connectionFailure(e))
            } finally {
                // Reading the saved library proves nothing about whether a full load can finish.
                launchGuard.loadEnded(resetCount = fullLoad)
                loadingLibrary = false
            }
        }
    }

    /** AppState.userFacingPlexAPIServiceError: what CONNECTION FAILED says for each way a load fails. */
    private fun connectionFailure(e: Throwable): String = when {
        // userFacingLoadLibraryError: nothing usable came back, so say what happened and what to check.
        e is LoadStalled && e.userInitiated -> "Stopped waiting. Nothing had come back from your server, so no channels were built. Retry when the connection looks better."
        e is LoadStalled -> "Your server stopped sending data partway through the scan and never resumed. Check that it is awake and reachable on this network, then Retry."
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

    /** Every library but those switched off, with where the scan has got to (on the main thread) and the server's name. */
    /** What a scan read, and whether some server's scan was abandoned (LibraryScanInterrupted). */
    private class ScanResult(val items: List<MediaItem>, val abandoned: Boolean)

    /** Nothing came back before the scan was abandoned (LibraryLoadStalled). */
    private class LoadStalled(val userInitiated: Boolean) : Exception("library scan abandoned")

    /** True while a foreground scan has gone quiet long enough to say so (isLoadStalling). */
    var loadStalling by mutableStateOf(false)
        private set

    /** STOP WAITING, read by the scan's watch on its next look (loadCancelRequested). */
    @Volatile private var stopWaitingRequested = false

    /** The scan's counters as they last moved, for the watch (libraryScanProgressSample). */
    @Volatile private var scanSample = LibraryLoadProgressSample()

    /** STOP WAITING: the same way out as the watchdog's, at once (stopWaitingForLibraryScan). */
    fun stopWaitingForLibraryScan() {
        if (loadingLibrary) stopWaitingRequested = true
    }

    /**
     * Every library but those switched off, under the stall watch, one server at a time.
     * `foreground` is a load the viewer is watching: it says when the scan goes quiet and
     * offers STOP WAITING. A server whose scan is abandoned keeps the libraries it read whole;
     * one with none counts as failed, and if every server failed that way the load fails with
     * the Apple TV's words.
     */
    private suspend fun scan(servers: List<PlexServer>, foreground: Boolean = true, onProgress: (ScanProgress, String) -> Unit): ScanResult {
        fun progress(p: ScanProgress, name: String) {
            scanSample = LibraryLoadProgressSample(1, p.section, p.sections, p.itemsSoFar, "$name|${p.title}|${p.showsDone}/${p.showsTotal}")
            scope.launch { onProgress(p, name) }
        }
        mbServer?.let { mb ->
            val excluded = LibrarySection.excludedKeys(deselectedSections, servers.first().machineIdentifier)
            val (items, abandoned) = watched(foreground, mb.name) { onSection, cancelled ->
                mediaBrowser.scan(mb, { p -> progress(p, mb.name) }, excluded, onSection, cancelled)
            }
            return ScanResult(items, abandoned)
        }
        val library = PlexLibrary(plex)
        val items = ArrayList<MediaItem>()
        var abandoned = false
        var stalled: LoadStalled? = null
        var read = 0
        for (server in servers) {
            try {
                val (got, gaveUp) = watched(foreground, server.name) { onSection, _ ->
                    library.scan(server, { p -> progress(p, server.name) }, items.size,
                        LibrarySection.excludedKeys(deselectedSections, server.machineIdentifier), onSection)
                }
                items += got
                abandoned = abandoned || gaveUp
                read++
            } catch (e: LoadStalled) {
                abandoned = true
                stalled = e
            }
        }
        if (read == 0) stalled?.let { throw it }
        return ScanResult(items, abandoned)
    }

    /**
     * One server's scan under the stall watch (withLibraryLoadStallWatch): its progress is
     * sampled every 2 s, and STOP WAITING or 210 s without progress abandons it. The scan runs
     * apart from the caller, so an abandoned one isn't waited for: its request in flight finishes
     * on its own and is dropped. Returns what it read and whether it was abandoned.
     */
    private suspend fun watched(
        foreground: Boolean,
        label: String,
        run: suspend (onSection: (List<MediaItem>) -> Unit, cancelled: () -> Boolean) -> List<MediaItem>,
    ): Pair<List<MediaItem>, Boolean> {
        // A press meant for the server before belongs to it (issue #146).
        stopWaitingRequested = false
        if (foreground) loadStalling = false
        val sections = java.util.Collections.synchronizedList(ArrayList<MediaItem>())
        val stop = java.util.concurrent.atomic.AtomicBoolean(false)
        val job = scope.async(Dispatchers.IO) { run({ sections.addAll(it) }, { stop.get() }) }
        fun now() = SystemClock.elapsedRealtime() / 1000.0
        val detector = LibraryLoadStallDetector(scanSample, now())
        try {
            while (true) {
                val done = withTimeoutOrNull(2_000) { job.await() }
                if (done != null) return done to false
                val user = stopWaitingRequested
                val verdict = detector.evaluate(scanSample, now())
                // A background refresh has no loading screen: it says nothing and keeps the guide.
                if (foreground) loadStalling = verdict !is LibraryLoadStallDetector.Verdict.Progressing
                if (user || verdict is LibraryLoadStallDetector.Verdict.Stalled) {
                    stop.set(true)
                    job.cancel()
                    val kept = sections.toList()
                    val quiet = (verdict as? LibraryLoadStallDetector.Verdict.Stalled)?.secondsWithoutProgress
                        ?: (verdict as? LibraryLoadStallDetector.Verdict.Slow)?.secondsWithoutProgress ?: 0.0
                    Log.i(TAG, "STALL ${if (user) "viewer stopped waiting on" else "no progress from"} $label after ${quiet.toInt()} s quiet; " +
                        "${kept.size} items from the libraries read whole")
                    if (kept.isEmpty()) throw LoadStalled(user)
                    return kept to true
                }
            }
        } finally {
            if (foreground) loadStalling = false
            stopWaitingRequested = false
            job.cancel()
        }
    }

    /**
     * Reads every server again while the guide is up, then asks for the enrichment the local
     * cache didn't have. The guide changes only if the library or its enrichment did.
     */
    private fun refreshInBackground(servers: List<PlexServer>, saved: List<MediaItem>) {
        scope.launch {
            refreshing = true
            try {
                val t0 = SystemClock.elapsedRealtime()
                val scanned = scan(servers, foreground = false) { _, _ -> }
                // An abandoned refresh is a subset of what is on screen: keep the guide (isLibraryStale).
                if (scanned.abandoned) {
                    Log.i(TAG, "REFRESH abandoned mid-scan; keeping the loaded lineup")
                    return@launch
                }
                val items = scanned.items
                val took = SystemClock.elapsedRealtime() - t0
                libraryUpdatedMs = System.currentTimeMillis()
                val collections = readCollections(servers)
                val collectionsChanged = collections != serverCollections
                val scanChanged = items != saved || collectionsChanged
                if (scanChanged) {
                    scannedItems = items
                    serverCollections = collections
                    withContext(Dispatchers.IO) { libraryStore.save(servers, items, collections) }
                }
                val enriched = enrich(items, remote = true)
                if (enriched == libraryItems && !collectionsChanged) {
                    Log.i(TAG, "REFRESH ${items.size} items read in $took ms; unchanged")
                    return@launch
                }
                libraryItems = enriched
                Log.i(TAG, "REFRESH ${items.size} items read in $took ms; " +
                    (when {
                    items != saved -> "library changed (was ${saved.size})"
                    collectionsChanged -> "collections changed"
                    else -> "enrichment changed"
                }) + ", rebuilding")
                val fresh = buildLineup(enriched, "refreshed")
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

    /**
     * The items with their TMDB and OMDb records attached (EnrichmentService). With `remote`
     * false only the local cache is read. `onStatus(line, done, total)` gets the Apple TV's
     * status lines, on the main thread; `done` is -1 while there is no count to show.
     * Without enrichment, the items as they came.
     */
    private suspend fun enrich(items: List<MediaItem>, remote: Boolean, onStatus: (String, Int, Int) -> Unit = { _, _, _ -> }): List<MediaItem> {
        val service = enrichment ?: return items
        val rules = channelData.await().first.channels.map { it.rules }
        val t0 = SystemClock.elapsedRealtime()
        val result = withContext(Dispatchers.IO) {
            service.enrich(items, if (remote) rules else emptyList(), remote) { done, total, phase ->
                val line = if (phase == "cache") "Checking metadata cache $done/$total" else "Fetching metadata $done/$total"
                scope.launch { onStatus(line, if (phase == "fetch") done else -1, if (phase == "fetch") total else 0) }
            }
        }
        Log.i(TAG, "ENRICHMENT (${if (remote) "full" else "local"}) ${result.stats} in ${SystemClock.elapsedRealtime() - t0} ms")
        return withContext(Dispatchers.Default) { EnrichmentService.attach(items, result.records) }
    }

    private suspend fun buildLineup(items: List<MediaItem>, source: String, onBuild: (Int, Int) -> Unit = { _, _ -> }): Lineup = withContext(Dispatchers.Default) {
        val t0 = SystemClock.elapsedRealtime()
        val (config, memberships) = channelData.await()
        withContext(Dispatchers.Main) { bundles = config.bundles }
        // Only the wait: the parse itself runs while the library is read.
        val configMs = SystemClock.elapsedRealtime() - t0
        val serverKey = (mbServer?.let { "${it.kind}_${it.serverId}" } ?: ("plex_" + prefs.servers.joinToString("_") { it.machineIdentifier }))
            .replace(Regex("[^A-Za-z0-9]"), "_").take(60)
        val lineup = Lineup(config, memberships, DailyManifest(ZoneId.systemDefault(), manifestStore), serverKey, mbServer?.kind ?: "plex", franchiseDefinitions.await())
        lineup.watershed = prefs.watershed
        lineup.franchiseChoices = franchiseChoices()
        var built = 0
        val switchedOn = lineup.build(items, prefs.enabledBundles, serverCollections) { done, total ->
            built = maxOf(built, done)
            scope.launch { onBuild(done, total) }
        }
        if (switchedOn.isNotEmpty()) {
            prefs.enabledBundles = prefs.enabledBundles + switchedOn
            withContext(Dispatchers.Main) { enabledBundles = prefs.enabledBundles }
        }
        // The Apple TV's COLLECTIONS and FRANCHISES lines: each collection's place, and the franchises found.
        lineup.franchises?.let { f ->
            for (c in f.candidates) Log.i(TAG, "COLLECTIONS: '${c.title}' -> ${Collections.memberSummary(c)} [${c.category?.wire}]" +
                (c.foldedInto?.let { " folded into $it" } ?: "") + (Collections.duplicateWarning(c)?.let { " ($it)" } ?: "") + if (c.enabled) " ON" else "")
            Log.i(TAG, "FRANCHISES: ${f.found.count { !it.isCovered }} found (${f.found.count { !it.isCovered && it.enabled }} on), " +
                "${f.found.count { it.isCovered }} on classics; ${f.channels.size} runtime channel(s)")
        }
        val tFilter = SystemClock.elapsedRealtime()
        lineup.rebuildSchedules()
        Log.i(TAG, "LINEUP ($source) ${items.size} items; $built channels in ${tFilter - t0} ms (config ${configMs}, item facts ${lineup.prepareMs}, filter ${tFilter - t0 - configMs - lineup.prepareMs}); " +
            "${lineup.channels.size} in the guide; schedules in ${SystemClock.elapsedRealtime() - tFilter} ms; " +
            lineup.doubledMinutes().let { (d, t) -> "$d of $t guide minutes on two channels at once; " } + "channels.json v${config.version}")
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
                // 9 PM lifts a Watershed hold: the channel comes on the air.
                if (watershedHold) channel?.let { ch -> if (lineup?.isWatershedHold(ch) == false) tune(ch) }
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
        watershedHold = false
        item = pick?.item
        delivery = null
        if (pick == null) {
            watchReporter.stop()
            playback.stop()
            val ch = channel
            if (ch != null && lineup?.isWatershedHold(ch) == true) {
                Log.i(TAG, "WATERSHED HOLD on CH ${ch.number}")
                watershedHold = true
            } else {
                failure = PlaybackFailure.NoPlayableSource(backendName)
            }
            return
        }
        if (demoMode) demoBlockEndSec = System.currentTimeMillis() / 1000.0 - pick.seekSeconds + pick.item.duration * 60L
        watchReporter.begin(pick.item, pick.seekSeconds, reportServer(pick.item))
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
        this.delivery = delivery
        watchReporter.onReady()
        // The guide follows what is on, as TunerView rebuilds on a change of current item.
        lineup?.let { l ->
            scope.launch {
                withContext(Dispatchers.Default) { l.rebuildSchedules() }
                scheduleTick++
            }
        }
    }

    /**
     * The startup watchdog saw a picture: count again. Reaching ready is not enough, as on the
     * Apple TV: a file the TV opens but can't decode reaches ready with a black screen.
     */
    override fun onPicture(item: MediaItem) {
        failureRun.reset()
    }

    override fun onEnded(item: MediaItem) {
        val ch = channel ?: return
        // Demo mode: the clip running out says nothing about the schedule. Stay on the block
        // that is on, at the clock's position (advanceToNextItem's demo branch).
        if (demoMode) return play(lineup?.tune(ch))
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
        watchReporter.stop()
        playback.release()
    }

    companion object {
        private const val TAG = "Nostalgex"
        /** LaunchGuard reads the last launch's marker once per process. */
        private var launchRecorded = false
    }
}
