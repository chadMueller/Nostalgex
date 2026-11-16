package com.muellhaus.nostalgex.weather

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.media.MediaPlayer
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.muellhaus.nostalgex.BuildConfig
import com.muellhaus.nostalgex.engine.Weather
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * LOCAL WEATHER, CH 299 (Trello I-016): the viewer's place and choices, the forecast, the radar frames and the music.
 * The rules and numbers are [Weather] (the web tuner's engine, held to scripts/weather-golden.json); the picture is [WeatherPainter].
 *
 * Nothing leaves the TV until the channel is on screen: [activate] starts the loop that fetches, [deactivate] ends it (another channel,
 * Settings' sleep timer, the app going to the background). What is sent: the place rounded to 2 decimals (about 1 km) to nostalgex.app's
 * relay, which asks MET Norway; and the radar picture requests to NOAA, Environment Canada or DWD for a place they cover.
 * The place, the units and the switch are kept in their own preferences file, which the settings backup never includes.
 */
class WeatherController(private val context: Context, private val scope: CoroutineScope) {
    private val prefs = context.getSharedPreferences("nostalgex_weather", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    // ── What the viewer chose (Settings > CHANNELS & BUNDLES > LOCAL WEATHER) ──
    var place: Weather.Place? by mutableStateOf(readPlace())
        private set
    /** "auto" (F in the US, C elsewhere), "F" or "C". */
    var unitsSetting: String by mutableStateOf(prefs.getString("units", "auto").takeIf { it == "F" || it == "C" } ?: "auto")
        private set
    /** Whether the channel is in the guide. On unless switched off. */
    var channelOn: Boolean by mutableStateOf(prefs.getBoolean("channel", true))
        private set

    val units: String get() = Weather.unitsFor(place, unitsSetting)

    // ── What the screens draw ──
    /** "noplace", "loading", "error" or "ready". */
    var status: String by mutableStateOf(if (place == null) "noplace" else "loading")
        private set
    var model: Weather.Model? by mutableStateOf(null)
        private set
    val radar = RadarState()

    private var met: JsonObject? = null
    private var metKey = ""
    private var savedMs = 0L
    private var expiresMs = 0L
    private var failedMs = 0L
    private var loading = false
    private var lastBuildMs = 0L
    private var lastCheckMs = 0L
    private var loop: Job? = null
    private var radarJob: Job? = null
    private var basemap: Basemap.Source? = null
    @Volatile private var active = false

    private val http = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
    private val relay = (BuildConfig.WEATHER_RELAY_URL.ifEmpty { RELAY }).trimEnd('/')

    // ── Place, units and the switch ──
    private fun readPlace(): Weather.Place? = runCatching {
        val o = json.parseToJsonElement(prefs.getString("place", null) ?: return null).jsonObject
        fun s(k: String) = (o[k] as? JsonPrimitive)?.content
        fun d(k: String) = (o[k] as? JsonPrimitive)?.doubleOrNull
        Weather.normalizePlace(s("name"), s("region"), s("cc"), d("lat"), d("lon"), s("tz"), s("kind"), s("code"))
    }.getOrNull()

    fun choosePlace(p: Weather.Place) {
        val normal = Weather.normalizePlace(p.name, p.region, p.cc, p.lat, p.lon, p.tz, p.kind, p.code) ?: return
        place = normal
        prefs.edit().putString(
            "place",
            buildJsonObject {
                put("name", normal.name); put("region", normal.region); put("cc", normal.cc); put("lat", normal.lat); put("lon", normal.lon)
                put("tz", normal.tz); put("kind", normal.kind); normal.code?.let { put("code", it) }
            }.toString(),
        ).apply()
        forgetForecast()
        status = "loading"
        if (active) scope.launch(Dispatchers.Default) { ensureForecast(force = true) }
    }

    fun clearPlace() {
        place = null
        prefs.edit().remove("place").apply()
        forgetForecast()
        status = "noplace"
    }

    fun chooseUnits(setting: String) {
        unitsSetting = if (setting == "F" || setting == "C") setting else "auto"
        prefs.edit().putString("units", unitsSetting).apply()
    }

    fun switchChannel(on: Boolean) {
        channelOn = on
        prefs.edit().putBoolean("channel", on).apply()
    }

    private fun forgetForecast() {
        met = null; metKey = ""; savedMs = 0; expiresMs = 0; failedMs = 0
        model = null
        radar.reset()
        File(context.filesDir, FORECAST_FILE).delete()
    }

    // ── On and off the air ──
    fun activate() {
        if (active) return
        active = true
        lastBuildMs = 0; lastCheckMs = 0
        startMusic()
        loop = scope.launch(Dispatchers.Default) {
            while (isActive) {
                val now = System.currentTimeMillis()
                if (now - lastCheckMs > 20_000) {
                    lastCheckMs = now
                    ensureForecast(force = false)
                } else if (now - lastBuildMs > 60_000) rebuildModel()
                // The radar frames load from the TODAY screen on, so they are there when the radar comes up.
                if (Weather.screenAt(now).index >= 1) ensureRadar()
                delay(1000)
            }
        }
    }

    fun deactivate() {
        if (!active) return
        active = false
        loop?.cancel(); loop = null
        radarJob?.cancel(); radarJob = null
        radar.loading = false
        stopMusic()
    }

    // ── The forecast: kept on this TV with its time, and asked for again only when MET's rules allow ──
    private fun placeKey(p: Weather.Place) = "%.2f,%.2f".format(java.util.Locale.US, p.lat, p.lon)

    private fun readKept(key: String) = runCatching {
        val o = json.parseToJsonElement(File(context.filesDir, FORECAST_FILE).readText()).jsonObject
        if ((o["key"] as? JsonPrimitive)?.content != key) return@runCatching null
        Triple((o["savedMs"] as JsonPrimitive).content.toLong(), (o["expiresMs"] as JsonPrimitive).content.toLong(), o["body"] as JsonObject)
    }.getOrNull()

    private fun keep() {
        val body = met ?: return
        runCatching {
            val f = File(context.filesDir, FORECAST_FILE)
            val tmp = File(f.path + ".tmp")
            tmp.writeText(buildJsonObject { put("key", metKey); put("savedMs", savedMs); put("expiresMs", expiresMs); put("body", body) }.toString())
            tmp.renameTo(f)
        }
    }

    /** Only what the channel reads, so the copy kept on this TV is a third of the size (the web tuner's wxTrim). */
    private fun trim(doc: JsonObject): JsonObject {
        val props = doc["properties"] as? JsonObject ?: return JsonObject(emptyMap())
        val series = (props["timeseries"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { e ->
            val s = e as? JsonObject ?: return@mapNotNull null
            val data = s["data"] as? JsonObject ?: return@mapNotNull null
            val details = (data["instant"] as? JsonObject)?.get("details") as? JsonObject ?: JsonObject(emptyMap())
            buildJsonObject {
                put("time", (s["time"] as? JsonPrimitive)?.content ?: return@mapNotNull null)
                put("data", buildJsonObject {
                    put("instant", buildJsonObject { put("details", JsonObject(details.filterKeys { it in KEEP })) })
                    for (k in listOf("next_1_hours", "next_6_hours", "next_12_hours")) data[k]?.let { put(k, it) }
                })
            }
        }
        val updated = ((props["meta"] as? JsonObject)?.get("updated_at") as? JsonPrimitive)?.content
        return buildJsonObject {
            put("properties", buildJsonObject {
                put("meta", buildJsonObject { if (updated != null) put("updated_at", updated) })
                put("timeseries", JsonArray(series))
            })
        }
    }

    /** Called when what the guide's row and the info panel say changed (a forecast arrived, the temperature moved a degree). */
    var onUpdated: (() -> Unit)? = null
    private var lastSummary: String? = null

    private fun rebuildModel() {
        lastBuildMs = System.currentTimeMillis()
        val p = place
        val doc = met
        if (p == null || doc == null) { model = null; return }
        try {
            model = Weather.buildModel(doc, p, System.currentTimeMillis())
            status = "ready"
        } catch (e: Weather.EmptyForecast) {
            // A document that ends before now: ask again at the next check.
            model = null
            status = "error"
            expiresMs = 0
        }
        val summary = model?.let { Weather.infoSummary(it, units) }
        if (summary != lastSummary) { lastSummary = summary; onUpdated?.invoke() }
    }

    private suspend fun ensureForecast(force: Boolean) {
        val p = place
        if (p == null) { status = "noplace"; model = null; return }
        val key = placeKey(p)
        val now = System.currentTimeMillis()
        if (metKey != key) {
            val kept = withContext(Dispatchers.IO) { readKept(key) }
            met = kept?.third; metKey = key; savedMs = kept?.first ?: 0; expiresMs = kept?.second ?: 0
            model = null
        }
        if (!force && met != null && !Weather.forecastDue(Weather.Kept(savedMs, expiresMs, true), now)) { if (model == null) rebuildModel(); return }
        if (loading || (!force && failedMs != 0L && now - failedMs < 60_000)) { if (model == null) rebuildModel(); return }
        loading = true
        if (met == null) status = "loading"
        try {
            val body = withContext(Dispatchers.IO) { fetchForecast(p) }
            if (key == metKey) {
                met = body
                savedMs = System.currentTimeMillis()
                expiresMs = savedMs + 30 * 60_000L
                failedMs = 0
                keep()
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            loading = false
            throw e
        } catch (e: Exception) {
            Log.i(TAG, "WEATHER forecast not fetched: ${e.message}")
            failedMs = System.currentTimeMillis()
            if (met == null) status = "error"
        }
        loading = false
        rebuildModel()
    }

    private fun fetchForecast(p: Weather.Place): JsonObject {
        val req = Request.Builder().url(Weather.forecastUrl(relay, p)).header("Accept", "application/json").header("X-Nostalgex-Client", CLIENT).build()
        http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) throw java.io.IOException("HTTP ${r.code}")
            val body = trim(json.parseToJsonElement(r.body.string()).jsonObject)
            if ((body["properties"] as JsonObject)["timeseries"].let { it !is JsonArray || it.isEmpty() }) throw java.io.IOException("empty forecast")
            return body
        }
    }

    // ── The radar: the frames of the last hour or so, recoloured to our five bands and kept as small bitmaps ──
    class Frame(val timeMs: Long, val bitmap: Bitmap)

    class RadarState {
        /** "none", "loading", "error" or "ready". */
        @Volatile var status = "none"
        @Volatile var provider: Weather.RadarProvider? = null
        @Volatile var frames: List<Frame> = emptyList()
        @Volatile var base: Basemap.Prepared? = null
        @Volatile var key = ""
        @Volatile var loadedMs = 0L
        @Volatile var loading = false
        fun reset() { status = "none"; frames = emptyList(); base = null; key = ""; loadedMs = 0 }
    }

    private fun ensureRadar() {
        val p = place ?: return
        val provider = Weather.radarProvider(p)
        if (provider == null) { radar.status = "none"; radar.provider = null; radar.frames = emptyList(); radar.key = ""; return }
        val key = placeKey(p)
        val now = System.currentTimeMillis()
        if (radar.loading) return
        if (radar.key == key && radar.status == "ready" && now - radar.loadedMs < 5 * 60_000) return
        if (radar.key == key && radar.status == "error" && now - radar.loadedMs < 60_000) return
        radar.loading = true
        radar.provider = provider
        if (radar.key != key) { radar.frames = emptyList(); radar.base = null; radar.status = "loading" }
        radar.key = key
        radarJob = scope.launch(Dispatchers.IO) {
            try {
                val bbox = Weather.radarBBox(p.lat, p.lon, WeatherPainter.MAP_ASPECT, 5.0)
                val src = basemap ?: Basemap.load(context)?.also { basemap = it }
                if (src != null) radar.base = Basemap.prepare(src, bbox)
                // One pixel of the picture is 4 of the screen: chunky on purpose, and a quarter of the download.
                val w = Math.round(WeatherPainter.MAP_W / 4f); val h = Math.round(WeatherPainter.MAP_H / 4f)
                val caps = get(provider.capabilitiesUrl(provider.layers[0])) ?: throw java.io.IOException("capabilities")
                // Frames end `lagMinutes` before the clock: DWD's time range runs past now, and the newest observation is minutes behind.
                val stamps = Weather.pickFrameTimes(Weather.parseTimeDimension(String(caps)), provider.frames, provider.stepMinutes, System.currentTimeMillis() - provider.lagMinutes * 60_000L)
                if (stamps.isEmpty()) throw java.io.IOException("no frames")
                val frames = coroutineScope {
                    stamps.map { t -> async { frame(provider, t, bbox, w, h) } }.awaitAll()
                }.filterNotNull()
                if (key == placeKey(place ?: p)) {
                    radar.frames = frames
                    radar.status = if (frames.isEmpty()) "error" else "ready"
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                radar.loading = false
                throw e
            } catch (e: Exception) {
                Log.i(TAG, "WEATHER radar not loaded: ${e.message}")
                radar.status = if (radar.frames.isNotEmpty()) "ready" else "error"
            }
            radar.loadedMs = System.currentTimeMillis()
            radar.loading = false
        }
    }

    private fun get(url: String): ByteArray? = http.newCall(Request.Builder().url(url).build()).execute().use { if (it.isSuccessful) it.body.bytes() else null }

    private fun frame(provider: Weather.RadarProvider, t: String, bbox: DoubleArray, w: Int, h: Int): Frame? {
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        var any = false
        for (layer in provider.layers) {
            val bytes = runCatching { get(provider.mapUrl(layer, bbox, w, h, t)) }.getOrNull() ?: continue
            val src = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: continue
            canvas.drawBitmap(RadarColour.recolour(src, provider.ignoreBands), 0f, 0f, null)
            any = true
        }
        val ms = runCatching { java.time.OffsetDateTime.parse(t).toInstant().toEpochMilli() }.getOrNull() ?: return null
        return if (any) Frame(ms, out) else null
    }

    // ── The music: one bundled, original loop, quiet, only while the channel is up ──
    private var music: MediaPlayer? = null
    private var muted = false

    @Synchronized
    private fun startMusic() {
        if (music != null) return
        music = runCatching {
            MediaPlayer().apply {
                val afd = runCatching { context.assets.openFd(MUSIC) }.getOrNull()
                if (afd != null) { setDataSource(afd.fileDescriptor, afd.startOffset, afd.length); afd.close() }
                else {
                    // An asset that was compressed in the package cannot be opened as a file descriptor: copy it out once.
                    val f = File(context.cacheDir, "local-forecast.m4a")
                    if (!f.exists()) context.assets.open(MUSIC).use { i -> f.outputStream().use { o -> i.copyTo(o) } }
                    setDataSource(f.path)
                }
                isLooping = true
                setVolume(if (muted) 0f else MUSIC_VOLUME, if (muted) 0f else MUSIC_VOLUME)
                prepare()
                start()
            }
        }.onFailure { Log.i(TAG, "WEATHER music not started: ${it.message}") }.getOrNull()
    }

    @Synchronized
    private fun stopMusic() {
        music?.let { runCatching { it.stop() }; runCatching { it.release() } }
        music = null
    }

    /** Settings is open over the channel: the programme plays on behind it, muted, and so does the loop. */
    @Synchronized
    fun mute(on: Boolean) {
        muted = on
        music?.let { runCatching { it.setVolume(if (on) 0f else MUSIC_VOLUME, if (on) 0f else MUSIC_VOLUME) } }
    }

    fun release() = deactivate()

    companion object {
        private const val TAG = "Nostalgex"
        /** The site's relay (api/weather.js): it asks MET Norway for us, with MET's identification and caching rules. */
        const val RELAY = "https://www.nostalgex.app/api/weather"
        /** The relay's own list of clients. */
        const val CLIENT = "android"
        private const val FORECAST_FILE = "weather-forecast.json"
        private const val MUSIC = "weather/music/local-forecast.m4a"
        private const val MUSIC_VOLUME = 0.6f
        private val KEEP = setOf(
            "air_pressure_at_sea_level", "air_temperature", "apparent_air_temperature", "cloud_area_fraction", "dew_point_temperature",
            "relative_humidity", "ultraviolet_index_clear_sky", "wind_from_direction", "wind_speed",
        )
    }
}
