package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.math.BigDecimal
import java.math.RoundingMode
import java.text.Normalizer
import java.time.DayOfWeek
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

/**
 * The weather channel's rules (Trello I-016), LOCAL WEATHER at CH 299. A port of scripts/nostalgex-weather.js,
 * the web tuner's engine, which is the reference: scripts/weather-golden.json holds this and the JS to the same
 * answers (WeatherGoldenTest). Pure logic, no network and no Android: the app passes in the forecast document,
 * the place files and the clock.
 *
 * A 24/7 local forecast the app draws itself, four screens on a 65 second wall-clock loop: CURRENT CONDITIONS,
 * TODAY'S FORECAST, 5-DAY FORECAST, RADAR. Forecast: MET Norway (CC BY 4.0) through nostalgex.app/api/weather.
 * Places: GeoNames (CC BY 4.0) as static shards. Radar: NOAA (US), Environment Canada, DWD (Germany).
 */
object Weather {
    // ── The channel ────────────────────────────────────────────────────────────
    const val CHANNEL_NUMBER = 299
    /** In the next free dynamic block (found franchises 1,000,000, franchise collections 1,010,000, collections 1,020,000). */
    const val CHANNEL_ID = 1030000
    const val CHANNEL_NAME = "LOCAL WEATHER"
    const val CHANNEL_COLOR = "#00D4FF"

    data class Screen(val id: String, val title: String, val seconds: Int)

    val SCREENS = listOf(
        Screen("current", "CURRENT CONDITIONS", 15),
        Screen("today", "TODAY'S FORECAST", 15),
        Screen("week", "5-DAY FORECAST", 15),
        Screen("radar", "RADAR", 20),
    )
    val LOOP_SECONDS = SCREENS.sumOf { it.seconds }

    data class ScreenAt(val index: Int, val screen: Screen, val elapsed: Double, val remaining: Double)

    /** Which screen is up at `nowMs` and how far into it: the loop runs on the wall clock, so every viewer sees the same one. */
    fun screenAt(nowMs: Long): ScreenAt {
        val loop = LOOP_SECONDS.toDouble()
        var t = ((nowMs / 1000.0) % loop + loop) % loop
        for ((i, s) in SCREENS.withIndex()) {
            if (t < s.seconds) return ScreenAt(i, s, t, s.seconds - t)
            t -= s.seconds
        }
        return ScreenAt(0, SCREENS[0], 0.0, SCREENS[0].seconds.toDouble())
    }

    // ── Units and numbers ──────────────────────────────────────────────────────
    /** F where the place's country is the US, otherwise C, unless the viewer chose: "auto", "F" or "C". */
    fun unitsFor(place: Place?, setting: String): String {
        if (setting == "F" || setting == "C") return setting
        return if (place != null && place.cc.uppercase() == "US") "F" else "C"
    }

    private fun finite(n: Double?) = n != null && !n.isNaN() && !n.isInfinite()
    private fun jsRound(x: Double): Long = Math.round(x)
    private fun toFixed(x: Double, digits: Int) = BigDecimal(x).setScale(digits, RoundingMode.HALF_UP).toPlainString()

    fun fmtTemp(c: Double?, units: String): String {
        if (!finite(c)) return "--"
        val v = jsRound(if (units == "F") c!! * 9 / 5 + 32 else c!!)
        return (if (v == 0L) 0L else v).toString()
    }

    /** mph on F, km/h on C (the MET value is metres per second). */
    fun fmtWind(ms: Double?, units: String): String {
        if (!finite(ms)) return "--"
        return if (units == "F") "${jsRound(ms!! * 2.2369363)} MPH" else "${jsRound(ms!! * 3.6)} KM/H"
    }

    fun fmtPressure(hpa: Double?, units: String): String {
        if (!finite(hpa)) return "--"
        return if (units == "F") "${toFixed(hpa!! * 0.0295300, 2)} IN" else "${jsRound(hpa!!)} HPA"
    }

    /** Rain and snow melt: inches to 2 places, or millimetres to 1 below 10 and whole above. */
    fun fmtPrecip(mm: Double?, units: String): String {
        if (!finite(mm)) return "--"
        if (units == "F") return "${toFixed(mm!! / 25.4, 2)} IN"
        return "${if (mm!! < 10) toFixed(mm, 1) else jsRound(mm).toString()} MM"
    }

    private val COMPASS = listOf("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")
    fun compass(deg: Double?): String {
        if (!finite(deg)) return ""
        return COMPASS[(jsRound((((deg!! % 360) + 360) % 360) / 22.5) % 16).toInt()]
    }

    // ── Symbols ────────────────────────────────────────────────────────────────
    data class Symbol(val icon: String, val text: String, val night: Boolean)

    private val SYMBOL_RE = Regex("^(.*?)(?:_(day|night|polartwilight))?$")

    /** The icon and words for a MET symbol code. Unknown codes read as cloud, never as a blank. */
    fun symbolInfo(code: String?): Symbol {
        val raw = code ?: ""
        val m = SYMBOL_RE.find(raw)!!
        val base = m.groupValues[1]
        val night = m.groupValues[2] == "night"
        val intensity = if (base.startsWith("light")) "light" else if (base.startsWith("heavy")) "heavy" else "mid"
        val family = base.replace(Regex("^(light|heavy)"), "")
        fun dn(d: String, n: String) = if (night) n else d
        if (family.contains("thunder")) return Symbol("thunder", if (family.contains("snow")) "THUNDER SNOW" else "THUNDERSTORMS", night)
        return when (family) {
            "clearsky" -> Symbol(dn("sun", "moon"), dn("SUNNY", "CLEAR"), night)
            "fair" -> Symbol(dn("fair-day", "fair-night"), dn("MOSTLY SUNNY", "MOSTLY CLEAR"), night)
            "partlycloudy" -> Symbol(dn("partly-day", "partly-night"), "PARTLY CLOUDY", night)
            "cloudy" -> Symbol("cloud", "CLOUDY", night)
            "fog" -> Symbol("fog", "FOG", night)
            "rain" -> Symbol(
                when (intensity) { "light" -> "drizzle"; "heavy" -> "heavy-rain"; else -> "rain" },
                when (intensity) { "light" -> "LIGHT RAIN"; "heavy" -> "HEAVY RAIN"; else -> "RAIN" }, night,
            )
            "rainshowers" -> Symbol(
                dn("showers-day", "showers-night"),
                when (intensity) { "light" -> "LIGHT SHOWERS"; "heavy" -> "HEAVY SHOWERS"; else -> "SHOWERS" }, night,
            )
            "sleet", "sleetshowers" -> Symbol(
                "sleet",
                (when (intensity) { "light" -> "LIGHT "; "heavy" -> "HEAVY "; else -> "" }) + (if (family == "sleet") "SLEET" else "SLEET SHOWERS"), night,
            )
            "snow" -> Symbol("snow", when (intensity) { "light" -> "LIGHT SNOW"; "heavy" -> "HEAVY SNOW"; else -> "SNOW" }, night)
            "snowshowers" -> Symbol(
                dn("flurries-day", "flurries-night"),
                when (intensity) { "light" -> "FLURRIES"; "heavy" -> "HEAVY SNOW SHOWERS"; else -> "SNOW SHOWERS" }, night,
            )
            else -> Symbol("cloud", "CLOUDY", night)
        }
    }

    /** The daytime form of a symbol code: the 5-day screen shows the day, so no moon on a day's icon. */
    fun dayForm(code: String?): String = (code ?: "").replace(Regex("_(night|polartwilight)$"), "_day")

    // ── Time in the place's time zone ──────────────────────────────────────────
    private val DOW = listOf("SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT")

    data class Local(val y: Int, val mo: Int, val d: Int, val h: Int, val mi: Int, val dow: Int, val key: String)

    fun validZone(tz: String?): Boolean = tz != null && runCatching { ZoneId.of(tz) }.isSuccess

    fun localParts(ms: Long, tz: String): Local {
        val z = ZonedDateTime.ofInstant(Instant.ofEpochMilli(ms), runCatching { ZoneId.of(tz) }.getOrDefault(ZoneOffset.UTC))
        val key = "%04d-%02d-%02d".format(z.year, z.monthValue, z.dayOfMonth)
        return Local(z.year, z.monthValue, z.dayOfMonth, z.hour, z.minute, z.dayOfWeek.value % 7, key)
    }

    /** "4:00 PM", the way the guide prints times. */
    fun fmtClock(ms: Long, tz: String): String {
        val p = localParts(ms, tz)
        return "${if (p.h % 12 == 0) 12 else p.h % 12}:${p.mi.toString().padStart(2, '0')} ${if (p.h >= 12) "PM" else "AM"}"
    }

    // ── The forecast document ──────────────────────────────────────────────────
    private fun r1(n: Double?): Double? = if (finite(n)) Math.round(n!! * 10) / 10.0 else null
    private val PERIOD_NAMES = listOf("OVERNIGHT", "MORNING", "AFTERNOON", "EVENING")

    data class Current(
        val timeMs: Long, val tempC: Double?, val feelsC: Double?, val humidity: Int?, val dewC: Double?, val windMs: Double?, val windDir: Int?,
        val pressureHpa: Double?, val cloud: Int?, val uv: Int?, val precipNextHourMm: Double?, val symbol: String?, val isDay: Boolean,
    )
    data class Period(
        val name: String, val day: String, val startMs: Long, val tempC: Double?, val symbol: String?, val precipMm: Double?, val windMs: Double?, val windDir: Int?,
    )
    data class Day(val date: String, val label: String, val highC: Double?, val lowC: Double?, val symbol: String?, val precipMm: Double?, val windMaxMs: Double?)
    data class Model(val updatedMs: Long?, val tz: String, val current: Current, val periods: List<Period>, val days: List<Day>)

    /** The document holds nothing from now on (or nothing at all): ask again at the next check. */
    class EmptyForecast : Exception("The forecast holds nothing from now on")

    private class Step(val t: Long, val data: JsonObject) {
        val details: JsonObject get() = data.obj("instant")?.obj("details") ?: JsonObject(emptyMap())
        fun num(key: String): Double? = details.num(key)
        fun block(name: String): JsonObject? = data.obj(name)
    }

    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
    private fun JsonObject.num(key: String): Double? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }?.doubleOrNull
    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    private fun parseInstantMs(s: String?): Long? = s?.let { runCatching { OffsetDateTime.parse(it).toInstant().toEpochMilli() }.getOrNull() }

    private fun symbolOf(step: Step, vararg keys: String): String? {
        for (k in keys) {
            val c = step.block(k)?.obj("summary")?.str("symbol_code")
            if (!c.isNullOrEmpty()) return c
        }
        return null
    }
    private fun stepSymbol(step: Step) = symbolOf(step, "next_1_hours", "next_6_hours", "next_12_hours")
    /** The symbol for a period starting at a step: the 6 hour one first, then 12, then 1. */
    private fun periodSymbol(step: Step) = symbolOf(step, "next_6_hours", "next_12_hours", "next_1_hours")

    private fun stepPrecip(step: Step): Double {
        step.block("next_1_hours")?.obj("details")?.num("precipitation_amount")?.let { if (finite(it)) return it }
        step.block("next_6_hours")?.obj("details")?.num("precipitation_amount")?.let { if (finite(it)) return it }
        return 0.0
    }

    private class Group(val key: String, val date: String, val block: Int, val steps: MutableList<Step>)

    /**
     * The channel's numbers from one `complete` forecast document, in metric: format them with [fmtTemp] and the rest.
     * Throws [EmptyForecast] when the document holds nothing from now on.
     */
    fun buildModel(met: JsonObject, place: Place?, nowMs: Long): Model {
        val tz = if (place != null && validZone(place.tz)) place.tz else "UTC"
        val props = met.obj("properties")
        val series = (props?.get("timeseries") as? JsonArray ?: JsonArray(emptyList()))
            .mapNotNull { e ->
                val o = e as? JsonObject ?: return@mapNotNull null
                val t = parseInstantMs(o.str("time")) ?: return@mapNotNull null
                val data = o.obj("data")?.takeIf { it.obj("instant") != null } ?: return@mapNotNull null
                Step(t, data)
            }
            .sortedBy { it.t }
        var cur = -1
        for (i in series.indices) if (series[i].t <= nowMs) cur = i else break
        if (cur < 0) cur = 0
        if (series.isEmpty() || series.last().t < nowMs) throw EmptyForecast()
        val meta = props?.obj("meta")

        // CURRENT CONDITIONS: the step the clock is in.
        val step = series[cur]
        val sym = stepSymbol(step)
        val nowLocal = localParts(nowMs, tz)
        val info = symbolInfo(sym)
        val isDay = if (sym != null && Regex("_(day|night|polartwilight)$").containsMatchIn(sym)) !info.night else (nowLocal.h in 6..17)
        val nh = step.block("next_1_hours")?.obj("details")
        val uvRaw = step.num("ultraviolet_index_clear_sky")
        val current = Current(
            timeMs = step.t,
            tempC = r1(step.num("air_temperature")),
            feelsC = r1(step.num("apparent_air_temperature").takeIf { finite(it) } ?: step.num("air_temperature")),
            humidity = step.num("relative_humidity")?.takeIf { finite(it) }?.let { jsRound(it).toInt() },
            dewC = r1(step.num("dew_point_temperature")),
            windMs = r1(step.num("wind_speed")),
            windDir = step.num("wind_from_direction")?.takeIf { finite(it) }?.let { jsRound(it).toInt() },
            pressureHpa = r1(step.num("air_pressure_at_sea_level")),
            cloud = step.num("cloud_area_fraction")?.takeIf { finite(it) }?.let { jsRound(it).toInt() },
            uv = if (finite(uvRaw) && isDay) jsRound(uvRaw!!).toInt() else null,
            precipNextHourMm = nh?.num("precipitation_amount")?.takeIf { finite(it) }?.let { r1(it) },
            symbol = sym,
            isDay = isDay,
        )

        // TODAY'S FORECAST: the next four six-hour periods on the place's wall clock, the first from now.
        val groups = ArrayList<Group>()
        var i = cur
        while (i < series.size && groups.size <= 4) {
            val p = localParts(series[i].t, tz)
            val key = "${p.key}|${p.h / 6}"
            val last = groups.lastOrNull()
            if (last != null && last.key == key) last.steps.add(series[i]) else groups.add(Group(key, p.key, p.h / 6, mutableListOf(series[i])))
            i++
        }
        val periods = groups.take(4).map { g ->
            val mid = g.steps[(g.steps.size - 1) / 2]
            val winds = g.steps.mapNotNull { it.num("wind_speed")?.takeIf { w -> finite(w) } }
            val first = g.steps[0]
            // Hourly steps each carry their own hour's rain; a six-hourly step carries the next six.
            val hourly = g.steps.all { it.block("next_1_hours") != null }
            val precip = if (hourly) g.steps.sumOf { stepPrecip(it) } else stepPrecip(first)
            Period(
                name = PERIOD_NAMES[g.block],
                day = if (g.date == nowLocal.key) "TODAY" else "TOMORROW",
                startMs = first.t,
                tempC = r1(mid.num("air_temperature")),
                symbol = periodSymbol(first),
                precipMm = r1(precip),
                windMs = if (winds.isNotEmpty()) r1(winds.sum() / winds.size) else null,
                windDir = mid.num("wind_from_direction")?.takeIf { finite(it) }?.let { jsRound(it).toInt() },
            )
        }

        // 5-DAY FORECAST: steps grouped by the place's local date.
        class DayGroup(val key: String, val dow: Int, val steps: MutableList<Pair<Step, Int>>)
        val byDate = LinkedHashMap<String, DayGroup>()
        for (k in cur until series.size) {
            val p = localParts(series[k].t, tz)
            byDate.getOrPut(p.key) { DayGroup(p.key, p.dow, mutableListOf()) }.steps.add(series[k] to p.h)
        }
        // A date needs two steps (past the first three days MET sends one every six hours).
        val dates = byDate.values.filter { it.steps.size >= 2 }
        // Today with under six hours left (from 6 PM) is not a day of the 5 when there is a sixth day to use: start tomorrow.
        val start = if (dates.isNotEmpty() && dates[0].key == nowLocal.key && nowLocal.h >= 18 && dates.size > 5) 1 else 0
        val days = dates.drop(start).take(5).map { g ->
            val temps = ArrayList<Double>()
            val winds = ArrayList<Double>()
            var precip = 0.0
            var pick: Pair<Step, Int>? = null
            for ((s, h) in g.steps) {
                s.num("air_temperature")?.takeIf { finite(it) }?.let { temps.add(it) }
                val six = s.block("next_6_hours")?.obj("details")
                if (six != null) {
                    six.num("air_temperature_max")?.takeIf { finite(it) }?.let { temps.add(it) }
                    six.num("air_temperature_min")?.takeIf { finite(it) }?.let { temps.add(it) }
                }
                s.num("wind_speed")?.takeIf { finite(it) }?.let { winds.add(it) }
                precip += if (s.block("next_1_hours") != null) stepPrecip(s)
                else (six?.num("precipitation_amount")?.takeIf { finite(it) } ?: 0.0)
                if (periodSymbol(s) != null && (pick == null || Math.abs(h - 13) < Math.abs(pick.second - 13))) pick = s to h
            }
            val code = pick?.let { periodSymbol(it.first) }
            Day(
                date = g.key,
                label = if (g.key == nowLocal.key) "TODAY" else DOW[g.dow],
                highC = if (temps.isNotEmpty()) r1(temps.max()) else null,
                lowC = if (temps.isNotEmpty()) r1(temps.min()) else null,
                // Today keeps its real symbol (it may be night); the days after show the daytime one.
                symbol = if (g.key == nowLocal.key) code else dayForm(code),
                precipMm = r1(precip),
                windMaxMs = if (winds.isNotEmpty()) r1(winds.max()) else null,
            )
        }
        return Model(parseInstantMs(meta?.str("updated_at")), tz, current, periods, days)
    }

    // ── Radar ──────────────────────────────────────────────────────────────────
    // Region-limited on purpose: no open source covers the world and allows commercial use without a key.
    private const val NOAA_HOST = "https://opengeo.ncep.noaa.gov/geoserver"
    private const val ECCC_HOST = "https://geo.weather.gc.ca/geomet"
    private const val DWD_HOST = "https://maps.dwd.de/geoserver/dwd"

    fun noaaLayer(lat: Double, lon: Double): String = when {
        lon in 140.0..150.0 && lat in 10.0..22.0 -> "guam"
        lat in 15.0..20.0 && lon in -68.0..-63.0 -> "carib"
        lat in 18.0..23.0 && lon in -161.0..-154.0 -> "hawaii"
        lat > 51 && (lon <= -129 || lon >= 170) -> "alaska"
        else -> "conus"
    }

    class RadarProvider(
        val id: String,
        val credit: String,
        val layers: List<String>,
        val stepMinutes: Int,
        val frames: Int,
        val lagMinutes: Int = 0,
        val ignoreBands: Set<Int> = emptySet(),
        private val caps: (String) -> String,
        private val map: (String, DoubleArray, Int, Int, String?) -> String,
    ) {
        fun capabilitiesUrl(layer: String = layers[0]) = caps(layer)
        fun mapUrl(layer: String, bbox: DoubleArray, w: Int, h: Int, time: String?) = map(layer, bbox, w, h, time)
    }

    private fun coordList(bbox: DoubleArray) = bbox.joinToString(",") { jsNum(it) }

    /** A number as JavaScript prints it in a template string: 43.65, 40, -79.38 (no trailing .0). */
    fun jsNum(d: Double): String = if (d == Math.rint(d) && Math.abs(d) < 1e15) d.toLong().toString() else d.toString()

    private fun wmsMap(baseFor: (String) -> String, layerParam: (String) -> String) = { lyr: String, bbox: DoubleArray, w: Int, h: Int, time: String? ->
        "${baseFor(lyr)}?service=WMS&version=1.3.0&request=GetMap&layers=${layerParam(lyr)}&styles=&crs=CRS:84&bbox=${coordList(bbox)}&width=$w&height=$h&format=image/png&transparent=true" +
            (if (time != null) "&time=${java.net.URLEncoder.encode(time, "UTF-8")}" else "")
    }

    /** The radar source for a place, or null: the card says RADAR NOT AVAILABLE IN YOUR AREA. */
    fun radarProvider(place: Place?): RadarProvider? {
        val cc = place?.cc?.uppercase() ?: return null
        when (cc) {
            "US" -> {
                val ws = noaaLayer(place.lat, place.lon)
                val layer = "${ws}_bref_qcd"
                return RadarProvider(
                    "noaa", "RADAR: NOAA NATIONAL WEATHER SERVICE", listOf(layer), 10, 8,
                    caps = { "$NOAA_HOST/$ws/$layer/ows?service=WMS&version=1.3.0&request=GetCapabilities" },
                    map = wmsMap({ lyr -> "$NOAA_HOST/$ws/$lyr/ows" }) { it },
                )
            }
            "CA" -> return RadarProvider(
                "eccc", "DATA SOURCE: ENVIRONMENT AND CLIMATE CHANGE CANADA", listOf("RADAR_1KM_RRAI", "RADAR_1KM_RSNO"), 6, 6,
                caps = { lyr -> "$ECCC_HOST?service=WMS&version=1.3.0&request=GetCapabilities&layer=$lyr" },
                map = wmsMap({ ECCC_HOST }) { it },
            )
            // DWD's precipitation radar composite: one layer, a 5 minute step, frames stopped 10 minutes before the clock because its time range
            // runs into the nowcast. Its style paints the edge of the radar coverage in magenta (our EXTREME band), so that band is dropped.
            "DE" -> return RadarProvider(
                "dwd", "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben", listOf("Niederschlagsradar"), 10, 8,
                lagMinutes = 10, ignoreBands = setOf(4),
                caps = { "$DWD_HOST/Niederschlagsradar/wms?service=WMS&version=1.3.0&request=GetCapabilities" },
                map = wmsMap({ "$DWD_HOST/wms" }) { "dwd:$it" },
            )
        }
        return null
    }

    /**
     * The map window: `spanLat` degrees tall, centred on the place, as wide as the picture needs so that a degree of
     * longitude is drawn cos(latitude) as wide as a degree of latitude. [minLon, minLat, maxLon, maxLat], CRS:84 order.
     */
    fun radarBBox(lat: Double, lon: Double, aspect: Double, spanLat: Double = 6.0): DoubleArray {
        val spanLon = spanLat * aspect / Math.max(0.2, Math.cos(lat * Math.PI / 180))
        fun r(n: Double) = Math.round(n * 1000) / 1000.0
        return doubleArrayOf(r(lon - spanLon / 2), r(lat - spanLat / 2), r(lon + spanLon / 2), r(lat + spanLat / 2))
    }

    private val ISO_MS: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)
    private fun iso(ms: Long) = ISO_MS.format(Instant.ofEpochMilli(ms))
    private val TIME_DIM = Regex("<Dimension[^>]*name=\"time\"[^>]*>([^<]*)<")
    private val DURATION = Regex("^PT(?:(\\d+)H)?(?:(\\d+)M)?$")

    /** The times inside a WMS time dimension: "a,b,c" or "start/end/PT6M". Newest last. */
    fun parseTimeDimension(xml: String?): List<String> {
        val m = TIME_DIM.find(xml ?: "") ?: return emptyList()
        val text = m.groupValues[1].trim()
        if (text.isEmpty()) return emptyList()
        if (text.contains('/') && !text.contains(',')) {
            val parts = text.split('/')
            val start = parseInstantMs(parts.getOrNull(0))
            val end = parseInstantMs(parts.getOrNull(1))
            val dur = DURATION.find(parts.getOrNull(2) ?: "")
            val ms = if (dur != null) ((dur.groupValues[1].toLongOrNull() ?: 0) * 60 + (dur.groupValues[2].toLongOrNull() ?: 0)) * 60000 else 0L
            if (start == null || end == null || ms == 0L) return if (end != null) listOf(iso(end)) else emptyList()
            val out = ArrayList<String>()
            var t = start
            while (t <= end) { out.add(iso(t)); t += ms }
            return out
        }
        return text.split(',').map { it.trim() }.mapNotNull { s -> parseInstantMs(s)?.let { iso(it) } }
    }

    /** `count` frames ending at the newest time, about `stepMinutes` apart, oldest first. Times after `notAfterMs` (when given) are not used. */
    fun pickFrameTimes(allTimes: List<String>, count: Int, stepMinutes: Int, notAfterMs: Long? = null): List<String> {
        val times = if (notAfterMs != null) allTimes.filter { (parseInstantMs(it) ?: Long.MAX_VALUE) <= notAfterMs } else allTimes
        if (times.isEmpty()) return emptyList()
        val ms = times.map { parseInstantMs(it) ?: 0L }
        val out = ArrayDeque<String>()
        out.addLast(times.last())
        var want = ms.last()
        for (n in 1 until count) {
            want -= stepMinutes * 60000L
            var best = -1
            for (k in ms.indices) if (best < 0 || Math.abs(ms[k] - want) < Math.abs(ms[best] - want)) best = k
            if (best >= 0 && times[best] != out.first() && Math.abs(ms[best] - want) <= stepMinutes * 30000L) out.addFirst(times[best])
        }
        return out.toList()
    }

    /**
     * One radar pixel, from the source's colours to our five bands: 0 (light) to 4 (extreme), or -1 for a pixel that is not an echo
     * (white, grey, black and near-white).
     */
    fun radarBand(r: Int, g: Int, b: Int): Int {
        val max = maxOf(r, g, b)
        val min = minOf(r, g, b)
        if (max - min < 28) return -1
        val d = (max - min).toDouble()
        var h = when (max) {
            r -> ((g - b) / d) % 6
            g -> (b - r) / d + 2
            else -> (r - g) / d + 4
        }
        h = (h * 60 + 360) % 360
        return when {
            h >= 190 && h < 280 -> 0
            h >= 90 && h < 190 -> 1
            h >= 40 && h < 90 -> 2
            h >= 12 && h < 40 -> 3
            h >= 280 && h < 345 -> 4
            else -> 3
        }
    }

    data class Band(val name: String, val color: String)
    val RADAR_BANDS = listOf(
        Band("LIGHT", "#00D4FF"), Band("MODERATE", "#FFE500"), Band("HEAVY", "#FFB020"), Band("SEVERE", "#FF2244"), Band("EXTREME", "#FF2DB4"),
    )

    // ── Places ─────────────────────────────────────────────────────────────────
    data class Place(
        val name: String,
        val region: String,
        val cc: String,
        val lat: Double,
        val lon: Double,
        val tz: String,
        /** "city" or "postcode". */
        val kind: String = "city",
        val code: String? = null,
    )

    private val COMBINING = Regex("[\\u0300-\\u036f]")
    private val NOT_PLAIN = Regex("[^a-z0-9]")
    private fun plain(s: String): String = COMBINING.replace(Normalizer.normalize(s, Normalizer.Form.NFKD), "").lowercase().replace(NOT_PLAIN, "")
    private fun round2(n: Double) = Math.round(n * 100) / 100.0
    const val MAX_RESULTS = 8

    fun placeLabel(p: Place): String = listOf(p.name, p.region, p.cc).filter { it.isNotEmpty() }.joinToString(", ").uppercase()

    /** The key a postcode is looked up by, in each country's shard set, or null when the text cannot be one of its codes. */
    fun postcodeLookup(cc: String, text: String): String? {
        val t = text.uppercase().replace(Regex("[^A-Z0-9 ]"), "").trim()
        val squashed = t.replace(Regex("\\s+"), "")
        return when (cc) {
            "US", "DE" -> squashed.takeIf { Regex("^\\d{3,5}$").matches(it) }
            "AU" -> squashed.takeIf { Regex("^\\d{3,4}$").matches(it) }
            "CA" -> if (Regex("^[A-Z]\\d[A-Z].*").matches(squashed)) squashed.take(3) else null
            "GB" -> {
                if (!Regex("^[A-Z]{1,2}\\d.*").matches(squashed)) return null
                // A full postcode ends in digit-letter-letter: the outward part is what is before it.
                val full = Regex("^([A-Z]{1,2}\\d[A-Z\\d]?)\\d[A-Z]{2}$").find(squashed)
                full?.groupValues?.get(1) ?: if (t.contains(' ')) t.split(Regex("\\s+"))[0] else squashed
            }
            else -> null
        }
    }

    /** A place read back from storage, or null if it is not usable. Coordinates are kept at 2 decimals. */
    fun normalizePlace(name: String?, region: String?, cc: String?, lat: Double?, lon: Double?, tz: String?, kind: String?, code: String?): Place? {
        if (lat == null || lon == null || !finite(lat) || !finite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null
        if (name.isNullOrEmpty()) return null
        return Place(
            name = name.take(80),
            region = (region ?: "").take(60),
            cc = (cc ?: "").uppercase().take(2),
            lat = round2(lat),
            lon = round2(lon),
            tz = if (validZone(tz)) tz!! else "UTC",
            kind = if (kind == "postcode") "postcode" else "city",
            code = code?.take(8),
        )
    }

    data class SearchResult(val places: List<Place>, val hint: String)

    /**
     * A place finder over the static place files (scripts/build-weather-data.mjs, `places/` under the weather folder).
     * `load(path)` gives the parsed JSON of a path under it (for example "places/meta.json") or null when there is no such file.
     */
    class PlaceIndex(private val load: (String) -> JsonElement?) {
        private val shards = HashMap<String, JsonElement?>()
        private fun shard(path: String): JsonElement? = shards.getOrPut(path) { runCatching { load(path) }.getOrNull() }

        private fun JsonArray.s(i: Int) = (this[i] as? JsonPrimitive)?.content ?: ""
        private fun JsonArray.d(i: Int) = (this[i] as? JsonPrimitive)?.doubleOrNull ?: 0.0

        private fun rowToPlace(row: JsonArray, tzs: List<String>, kind: String): Place {
            val tz = tzs.getOrNull(row.d(5).toInt()) ?: "UTC"
            return if (kind == "city") Place(row.s(0), row.s(2), row.s(1), row.d(3), row.d(4), tz, "city")
            // GeoNames names some codes with their landmarks in brackets ("DOWNTOWN TORONTO (CN TOWER / ...)"): keep the name.
            else Place(row.s(1).replace(Regex("\\s*\\(.*$"), "").trim().ifEmpty { row.s(1) }, row.s(2), "", row.d(3), row.d(4), tz, "postcode", row.s(0))
        }

        fun search(query: String): SearchResult {
            val q = query.trim()
            val meta = shard("places/meta.json") as? JsonObject
            if (meta == null || q.isEmpty()) return SearchResult(emptyList(), if (q.isNotEmpty()) "PLACE LIST NOT AVAILABLE" else "")
            val tzs = (meta["tz"] as? JsonArray)?.map { (it as? JsonPrimitive)?.content ?: "UTC" } ?: emptyList()
            val out = ArrayList<Place>()
            val seen = HashSet<String>()
            fun push(p: Place) {
                val k = "${p.kind}|${p.name}|${p.region}|${p.cc}|${p.code ?: ""}"
                if (!seen.add(k) || out.size >= MAX_RESULTS) return
                out.add(p)
            }

            // A postcode: digits, or a letter-digit pattern, looked up in every country it could belong to.
            // A whole code (2000 is Sydney) comes before the longer codes that only begin with it (20001 is Washington).
            val zips = ArrayList<Pair<Place, Int>>()
            for (ccEl in (meta["postcodes"] as? JsonArray) ?: JsonArray(emptyList())) {
                val cc = (ccEl as? JsonPrimitive)?.content ?: continue
                val code = postcodeLookup(cc, q) ?: continue
                val rows = shard("places/z/$cc/${code.take(2)}.json") as? JsonArray ?: continue
                for (rowEl in rows) {
                    val row = rowEl as? JsonArray ?: continue
                    if (row.s(0).startsWith(code)) zips.add(rowToPlace(row, tzs, "postcode").copy(cc = cc) to (if (row.s(0) == code) 0 else 1))
                }
            }
            for ((p, _) in zips.sortedBy { it.second }) push(p)

            // A city: "toronto", or "springfield il" / "portland, or" with the state, province or country after it.
            val attempts = ArrayList<Pair<String, String>>()
            val comma = q.indexOf(',')
            if (comma > 0) attempts.add(q.substring(0, comma) to q.substring(comma + 1).trim())
            attempts.add(q to "")
            val words = q.split(Regex("\\s+"))
            if (words.size > 1) attempts.add(words.dropLast(1).joinToString(" ") to words.last())
            var hint = ""
            val split = (meta["split"] as? JsonArray)?.map { (it as? JsonPrimitive)?.content } ?: emptyList()
            for ((nameQ, qual) in attempts) {
                val key = plain(nameQ)
                if (key.length < 2) continue
                var shardKey = key.take(2)
                if (shardKey in split) {
                    if (key.length < 3) { hint = "KEEP TYPING"; continue }
                    shardKey = key.take(3)
                }
                val rows = shard("places/c/$shardKey.json") as? JsonArray ?: continue
                val qualN = plain(qual)
                for (rowEl in rows) {
                    val row = rowEl as? JsonArray ?: continue
                    if (!plain(row.s(0)).startsWith(key)) continue
                    if (qualN.isNotEmpty() && !(plain(row.s(2)).startsWith(qualN) || plain(row.s(1)) == qualN)) continue
                    push(rowToPlace(row, tzs, "city"))
                }
                if (out.any { it.kind == "city" }) break
            }
            return SearchResult(out.toList(), if (out.isNotEmpty()) "" else hint)
        }
    }

    /** The label a result row shows in the list. */
    fun resultLabel(p: Place): String =
        if (p.kind == "postcode") "${p.code} ${p.name}, ${listOf(p.region, p.cc).filter { it.isNotEmpty() }.joinToString(", ")}".uppercase() else placeLabel(p)

    // ── The relay ──────────────────────────────────────────────────────────────
    /** The relay call for a place. Coordinates leave the device rounded to 2 decimals, about 1 km. */
    fun forecastUrl(base: String, place: Place): String =
        "$base?lat=${toFixed(round2(place.lat), 2)}&lon=${toFixed(round2(place.lon), 2)}"

    class Kept(val savedMs: Long, val expiresMs: Long?, val hasBody: Boolean)

    /** Whether to ask again: never before the document's own Expires, and not more than every `minMs` after the last answer. */
    fun forecastDue(entry: Kept?, nowMs: Long, minMs: Long = 30 * 60000L): Boolean {
        if (entry == null || !entry.hasBody) return true
        if (entry.expiresMs != null && nowMs < entry.expiresMs) return false
        return nowMs - entry.savedMs >= minMs
    }

    data class Age(val text: String, val stale: Boolean)

    /** How old the forecast is, for the card: "UPDATED 2:18 PM", or stale when it is over 6 hours old. */
    fun forecastAge(updatedMs: Long?, nowMs: Long, tz: String): Age {
        if (updatedMs == null) return Age("", false)
        return Age("UPDATED ${fmtClock(updatedMs, tz)}", nowMs - updatedMs > 6 * 3600000L)
    }

    // ── The guide row and the info panel ───────────────────────────────────────
    data class GuideBlock(val startSec: Long, val endSec: Long, val title: String, val episodeTitle: String, val summary: String)

    /** Hour-long guide blocks for the channel's row, `hours` of them from the top of the hour before now. */
    fun guideBlocks(placeName: String?, nowMs: Long, hours: Int = 26, summary: String = SUMMARY): List<GuideBlock> {
        val hourMs = 3600000L
        val start = Math.floorDiv(nowMs, hourMs) * hourMs - hourMs
        return (0 until hours).map { i ->
            val s = start + i * hourMs
            GuideBlock(s / 1000, (s + hourMs) / 1000, CHANNEL_NAME, placeName ?: "", summary)
        }
    }

    const val SUMMARY = "Current conditions, today’s forecast, the 5-day forecast and radar, in a loop."
    const val NO_PLACE_SUMMARY = "Set your location in Settings to see the forecast."

    /** The line the info panel shows under the place: "Cloudy, 6°C. Feels like 3°. High 7°, low 5°. Wind NNW 17 km/h." */
    fun infoSummary(model: Model?, units: String): String {
        if (model == null) return ""
        val c = model.current
        fun t(v: Double?) = "${fmtTemp(v, units)}°"
        val cond = symbolInfo(c.symbol).text
        val parts = ArrayList<String>()
        parts.add("${cond.take(1)}${cond.drop(1).lowercase()}, ${t(c.tempC)}$units.")
        parts.add("Feels like ${t(c.feelsC)}.")
        val first = model.days.firstOrNull()
        if (first != null && first.highC != null) parts.add("High ${t(first.highC)}, low ${t(first.lowC)}.")
        if (c.windMs != null) parts.add("Wind ${compass(c.windDir?.toDouble())} ${fmtWind(c.windMs, units).lowercase()}.".replace("Wind  ", "Wind "))
        return parts.joinToString(" ")
    }
}
