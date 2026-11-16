package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant

/**
 * The weather channel (I-016, CH 299) held to the shared golden, scripts/weather-golden.json, written from the web tuner's
 * nostalgex-weather.js. The web tuner is the reference; the Apple TV, the Roku and this app read the same file.
 * The place finder is held to the real shards the app ships (public/weather/places).
 */
class WeatherGoldenTest {
    private val root = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private val golden = Json.parseToJsonElement(root.resolve("scripts/weather-golden.json").readText()).jsonObject

    private fun arr(key: String) = golden[key]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonObject.d(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull
    private fun JsonObject.i(k: String) = d(k)?.toInt()
    private fun JsonObject.b(k: String) = this[k]!!.jsonPrimitive.content == "true"
    private fun ms(iso: String) = Instant.parse(iso).toEpochMilli()

    private fun place(o: JsonObject) = Weather.normalizePlace(o.s("name"), o.s("region"), o.s("cc"), o.d("lat"), o.d("lon"), o.s("tz"), o.s("kind"), o.s("code"))!!

    private fun near(expected: Double?, actual: Double?, what: String) {
        if (expected == null) assertNull(what, actual) else {
            assertNotNull(what, actual)
            assertEquals(what, expected, actual!!, 1e-9)
        }
    }

    @Test fun modelsMatchTheGolden() {
        val met = golden["met"]!!.jsonObject
        for (c in arr("cases")) {
            val name = c.s("name")!!
            val p = place(c["place"]!!.jsonObject)
            val now = ms(c.s("now")!!)
            val expect = c["expect"]!!.jsonObject
            val units = Weather.unitsFor(p, c.s("units")!!)
            assertEquals("$name units", expect.s("units"), units)
            val m = Weather.buildModel(met, p, now)
            val want = expect["model"]!!.jsonObject
            assertEquals("$name updatedMs", want.d("updatedMs")!!.toLong(), m.updatedMs)
            assertEquals("$name tz", want.s("tz"), m.tz)

            val wc = want["current"]!!.jsonObject
            val cur = m.current
            assertEquals("$name current.timeMs", wc.d("timeMs")!!.toLong(), cur.timeMs)
            near(wc.d("tempC"), cur.tempC, "$name tempC")
            near(wc.d("feelsC"), cur.feelsC, "$name feelsC")
            assertEquals("$name humidity", wc.i("humidity"), cur.humidity)
            near(wc.d("dewC"), cur.dewC, "$name dewC")
            near(wc.d("windMs"), cur.windMs, "$name windMs")
            assertEquals("$name windDir", wc.i("windDir"), cur.windDir)
            near(wc.d("pressureHpa"), cur.pressureHpa, "$name pressure")
            assertEquals("$name cloud", wc.i("cloud"), cur.cloud)
            assertEquals("$name uv", wc.i("uv"), cur.uv)
            near(wc.d("precipNextHourMm"), cur.precipNextHourMm, "$name precipNextHour")
            assertEquals("$name symbol", wc.s("symbol"), cur.symbol)
            assertEquals("$name isDay", wc.b("isDay"), cur.isDay)

            val wp = want["periods"]!!.jsonArray.map { it.jsonObject }
            assertEquals("$name period count", wp.size, m.periods.size)
            for ((i, w) in wp.withIndex()) {
                val p0 = m.periods[i]
                assertEquals("$name period $i name", w.s("name"), p0.name)
                assertEquals("$name period $i day", w.s("day"), p0.day)
                assertEquals("$name period $i start", w.d("startMs")!!.toLong(), p0.startMs)
                near(w.d("tempC"), p0.tempC, "$name period $i temp")
                assertEquals("$name period $i symbol", w.s("symbol"), p0.symbol)
                near(w.d("precipMm"), p0.precipMm, "$name period $i precip")
                near(w.d("windMs"), p0.windMs, "$name period $i wind")
                assertEquals("$name period $i windDir", w.i("windDir"), p0.windDir)
            }

            val wd = want["days"]!!.jsonArray.map { it.jsonObject }
            assertEquals("$name day count", wd.size, m.days.size)
            for ((i, w) in wd.withIndex()) {
                val d0 = m.days[i]
                assertEquals("$name day $i date", w.s("date"), d0.date)
                assertEquals("$name day $i label", w.s("label"), d0.label)
                near(w.d("highC"), d0.highC, "$name day $i high")
                near(w.d("lowC"), d0.lowC, "$name day $i low")
                assertEquals("$name day $i symbol", w.s("symbol"), d0.symbol)
                near(w.d("precipMm"), d0.precipMm, "$name day $i precip")
                near(w.d("windMaxMs"), d0.windMaxMs, "$name day $i wind")
            }

            // The strings the screens draw.
            val text = expect["text"]!!.jsonObject
            assertEquals("$name text.temp", text.s("temp"), Weather.fmtTemp(cur.tempC, units))
            assertEquals("$name text.feels", text.s("feels"), Weather.fmtTemp(cur.feelsC, units))
            assertEquals("$name text.wind", text.s("wind"), "${Weather.fmtWind(cur.windMs, units)} ${Weather.compass(cur.windDir?.toDouble())}")
            assertEquals("$name text.pressure", text.s("pressure"), Weather.fmtPressure(cur.pressureHpa, units))
            assertEquals("$name text.precipNextHour", text.s("precipNextHour"), Weather.fmtPrecip(cur.precipNextHourMm, units))
            assertEquals("$name text.condition", text.s("condition"), Weather.symbolInfo(cur.symbol).text)
            assertEquals("$name text.icon", text.s("icon"), Weather.symbolInfo(cur.symbol).icon)
            assertEquals("$name text.updated", text.s("updated"), Weather.fmtClock(m.updatedMs!!, m.tz))
            assertEquals(
                "$name text.periods", text["periods"]!!.jsonArray.map { it.jsonPrimitive.content },
                m.periods.map { "${it.name} ${it.day} ${Weather.fmtTemp(it.tempC, units)} ${Weather.symbolInfo(it.symbol).icon} ${Weather.fmtPrecip(it.precipMm, units)}" },
            )
            assertEquals(
                "$name text.days", text["days"]!!.jsonArray.map { it.jsonPrimitive.content },
                m.days.map { "${it.label} ${Weather.fmtTemp(it.highC, units)}/${Weather.fmtTemp(it.lowC, units)} ${Weather.symbolInfo(it.symbol).icon}" },
            )
        }
    }

    @Test fun symbolsUnitsFormatsAndCompassMatch() {
        for (s in arr("symbols")) {
            val code = s.s("code")
            val info = Weather.symbolInfo(code)
            assertEquals("$code icon", s.s("icon"), info.icon)
            assertEquals("$code text", s.s("text"), info.text)
            assertEquals("$code night", s.b("night"), info.night)
            assertEquals("$code day form", s.s("day"), Weather.dayForm(code))
        }
        for (u in arr("units")) {
            assertEquals("${u.s("cc")} ${u.s("setting")}", u.s("units"), Weather.unitsFor(Weather.Place("", "", u.s("cc")!!, 0.0, 0.0, "UTC"), u.s("setting")!!))
        }
        assertEquals("C", Weather.unitsFor(null, "auto"))
        for (f in arr("format")) {
            for (units in listOf("F", "C")) {
                val e = f[units]!!.jsonObject
                assertEquals("temp $units ${f.d("c")}", e.s("temp"), Weather.fmtTemp(f.d("c"), units))
                assertEquals("wind $units ${f.d("ms")}", e.s("wind"), Weather.fmtWind(f.d("ms"), units))
                assertEquals("pressure $units ${f.d("hpa")}", e.s("pressure"), Weather.fmtPressure(f.d("hpa"), units))
                assertEquals("precip $units ${f.d("mm")}", e.s("precip"), Weather.fmtPrecip(f.d("mm"), units))
            }
        }
        assertEquals("--", Weather.fmtTemp(null, "C"))
        assertEquals("--", Weather.fmtWind(Double.NaN, "F"))
        for (c in arr("compass")) assertEquals("${c.d("deg")}", c.s("dir"), Weather.compass(c.d("deg")))
    }

    @Test fun theLoopRunsOnTheWallClock() {
        val loop = golden["loop"]!!.jsonObject
        assertEquals(loop.i("seconds"), Weather.LOOP_SECONDS)
        assertEquals(65, Weather.LOOP_SECONDS)
        val screens = loop["screens"]!!.jsonArray.map { it.jsonObject }
        assertEquals(screens.map { listOf(it.s("id"), it.s("title"), it.i("seconds")) }, Weather.SCREENS.map { listOf(it.id, it.title, it.seconds) })
        for (a in loop["at"]!!.jsonArray.map { it.jsonObject }) {
            val at = Weather.screenAt((a.d("s")!! * 1000).toLong())
            assertEquals("at ${a.d("s")}", a.s("id"), at.screen.id)
            assertEquals("elapsed at ${a.d("s")}", a.d("elapsed")!!, at.elapsed, 1e-9)
        }
        // The same wall second gives the same screen on any day.
        assertEquals(Weather.screenAt(1_000_000L * 65).screen.id, Weather.screenAt(0).screen.id)
    }

    @Test fun radarMatches() {
        for (b in arr("bands")) {
            val rgb = b["rgb"]!!.jsonArray.map { it.jsonPrimitive.content.toInt() }
            assertEquals("band for $rgb", b.i("band"), Weather.radarBand(rgb[0], rgb[1], rgb[2]))
        }
        val f = golden["frames"]!!.jsonObject
        val times = f["times"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(f["pick"]!!.jsonArray.map { it.jsonPrimitive.content }, Weather.pickFrameTimes(times, 4, 10))
        assertEquals(f["pickNotAfter"]!!.jsonArray.map { it.jsonPrimitive.content }, Weather.pickFrameTimes(times, 3, 10, ms("2026-11-15T15:35:00Z")))
        assertEquals(
            f["range"]!!.jsonArray.map { it.jsonPrimitive.content },
            Weather.parseTimeDimension("<Dimension name=\"time\" units=\"ISO8601\" default=\"2026-11-15T17:24:00Z\" nearestValue=\"0\">2026-11-15T16:48:00Z/2026-11-15T17:24:00Z/PT6M</Dimension>"),
        )
        assertEquals(
            f["list"]!!.jsonArray.map { it.jsonPrimitive.content },
            Weather.parseTimeDimension("<Dimension name=\"time\" default=\"x\" units=\"ISO8601\" nearestValue=\"1\">2026-11-15T15:24:06.000Z,2026-11-15T15:25:58.000Z</Dimension>"),
        )
        assertEquals(emptyList<String>(), Weather.parseTimeDimension("<nothing/>"))
        for (b in arr("bbox")) {
            val got = Weather.radarBBox(b.d("lat")!!, b.d("lon")!!, b.d("aspect")!!, b.d("span")!!)
            val want = b["bbox"]!!.jsonArray.map { it.jsonPrimitive.content.toDouble() }
            for (i in 0..3) assertEquals("bbox $i for ${b.d("lat")}", want[i], got[i], 1e-9)
        }
        for (p in arr("providers")) {
            val place = Weather.Place("", "", p.s("cc")!!, p.d("lat")!!, p.d("lon")!!, "UTC")
            val pr = Weather.radarProvider(place)
            assertEquals("${p.s("cc")} ${p.d("lat")}", p.s("provider"), pr?.id)
            if (pr == null) continue
            assertEquals(p["layers"]!!.jsonArray.map { it.jsonPrimitive.content }, pr.layers)
            assertEquals(p.s("credit"), pr.credit)
            assertEquals(p.i("frames"), pr.frames)
            assertEquals(p.i("stepMinutes"), pr.stepMinutes)
            assertEquals(p.i("lagMinutes"), pr.lagMinutes)
            assertEquals(p["ignoreBands"]!!.jsonArray.map { it.jsonPrimitive.content.toInt() }.toSet(), pr.ignoreBands)
        }
        // The map URLs are the web's: one request, the layer and window named, our own time stamp.
        val us = Weather.radarProvider(Weather.Place("", "", "US", 40.71, -74.0, "UTC"))!!
        assertEquals(
            "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows?service=WMS&version=1.3.0&request=GetMap&layers=conus_bref_qcd&styles=&crs=CRS:84&bbox=-80,38,-70,44&width=435&height=175&format=image/png&transparent=true&time=2026-11-15T15%3A00%3A00.000Z",
            us.mapUrl("conus_bref_qcd", doubleArrayOf(-80.0, 38.0, -70.0, 44.0), 435, 175, "2026-11-15T15:00:00.000Z"),
        )
        val de = Weather.radarProvider(Weather.Place("", "", "DE", 52.5, 13.4, "UTC"))!!
        assertTrue(de.mapUrl("Niederschlagsradar", doubleArrayOf(1.5, 2.5, 3.5, 4.5), 4, 4, null).startsWith("https://maps.dwd.de/geoserver/dwd/wms?service=WMS&version=1.3.0&request=GetMap&layers=dwd:Niederschlagsradar&styles=&crs=CRS:84&bbox=1.5,2.5,3.5,4.5"))
        // Nowhere else: the card says so.
        assertNull(Weather.radarProvider(Weather.Place("", "", "GB", 51.5, -0.13, "UTC")))
        assertNull(Weather.radarProvider(null))
    }

    @Test fun postcodeKeysMatch() {
        for (p in arr("postcode")) assertEquals("${p.s("cc")} ${p.s("text")}", p.s("key"), Weather.postcodeLookup(p.s("cc")!!, p.s("text")!!))
    }

    // ── What the golden does not hold: the pieces the app puts around it ──

    @Test fun anEmptyOrOldDocumentIsRefused() {
        val met = golden["met"]!!.jsonObject
        val toronto = Weather.Place("Toronto", "ON", "CA", 43.65, -79.38, "America/Toronto")
        // Past the last step: nothing from now on.
        var refused = false
        try { Weather.buildModel(met, toronto, ms("2027-01-01T00:00:00Z")) } catch (e: Weather.EmptyForecast) { refused = true }
        assertTrue(refused)
        refused = false
        try { Weather.buildModel(JsonObject(emptyMap()), toronto, ms("2026-11-15T18:20:00Z")) } catch (e: Weather.EmptyForecast) { refused = true }
        assertTrue(refused)
    }

    @Test fun theForecastIsAskedForOnlyWhenAllowed() {
        val now = 1_000_000_000L
        assertTrue(Weather.forecastDue(null, now))
        assertTrue(Weather.forecastDue(Weather.Kept(now, now + 1, false), now))
        // Before the document's own Expires: never.
        assertEquals(false, Weather.forecastDue(Weather.Kept(now - 40 * 60000L, now + 5 * 60000L, true), now))
        // Past it, but under the 30 minute floor: not yet.
        assertEquals(false, Weather.forecastDue(Weather.Kept(now - 10 * 60000L, now - 1, true), now))
        assertTrue(Weather.forecastDue(Weather.Kept(now - 31 * 60000L, now - 1, true), now))
        // The relay call carries the town rounded to 2 decimals.
        val p = Weather.Place("Toronto", "ON", "CA", 43.6532, -79.3832, "America/Toronto")
        assertEquals("https://x/api/weather?lat=43.65&lon=-79.38", Weather.forecastUrl("https://x/api/weather", p))
        assertEquals(Weather.Age("UPDATED 8:19 AM", false), Weather.forecastAge(1794748775000, 1794748775000 + 3600000, "America/Toronto"))
        assertTrue(Weather.forecastAge(1794748775000, 1794748775000 + 7 * 3600000, "America/Toronto").stale)
    }

    @Test fun guideBlocksAreHourLong() {
        val now = ms("2026-11-15T18:20:00Z")
        val blocks = Weather.guideBlocks("TORONTO, ON, CA", now, 26)
        assertEquals(26, blocks.size)
        assertEquals(ms("2026-11-15T17:00:00Z") / 1000, blocks[0].startSec)
        assertEquals(3600, blocks[0].endSec - blocks[0].startSec)
        assertEquals(Weather.CHANNEL_NAME, blocks[0].title)
        assertTrue(blocks.any { now / 1000 in it.startSec until it.endSec })
    }

    @Test fun theInfoLineReadsLikeTheWebs() {
        val met = golden["met"]!!.jsonObject
        val c = arr("cases")[0]
        val p = place(c["place"]!!.jsonObject)
        val model = Weather.buildModel(met, p, ms(c.s("now")!!))
        assertEquals("Cloudy, 6°C. Feels like 3°. High 7°, low 5°. Wind NNW 17 km/h.", Weather.infoSummary(model, "C"))
        assertEquals("", Weather.infoSummary(null, "C"))
    }

    // ── The place finder over the shards the app ships ──

    private val shards = root.resolve("public/weather")
    private fun index() = Weather.PlaceIndex { path -> shards.resolve(path).takeIf { it.isFile }?.let { Json.parseToJsonElement(it.readText()) } }

    @Test fun placesAreFoundByCityAndByPostcode() {
        val idx = index()
        val toronto = idx.search("toronto").places.first()
        assertEquals("Toronto", toronto.name)
        assertEquals("CA", toronto.cc)
        assertEquals("America/Toronto", toronto.tz)
        assertEquals("TORONTO, ON, CA", Weather.placeLabel(toronto))
        // A postcode, and its whole-code match first.
        val beverly = idx.search("90210").places.first()
        assertEquals("postcode", beverly.kind)
        assertEquals("US", beverly.cc)
        assertEquals("90210", beverly.code)
        assertTrue(Weather.resultLabel(beverly).startsWith("90210 "))
        val ca = idx.search("M5V 3L9").places.first()
        assertEquals("CA", ca.cc)
        assertEquals("M5V", ca.code)
        assertEquals("SW1A", idx.search("SW1A 1AA").places.first().code)
        // A city with its state, accents ignored.
        val portland = idx.search("portland, or").places.first()
        assertEquals("Portland", portland.name)
        assertEquals("OR", portland.region)
        assertTrue(idx.search("zurich").places.any { it.cc == "CH" })
        assertTrue(idx.search("Münchenbuchsee").places.any { it.cc == "CH" })
        // Nothing, or too short, says so.
        assertEquals(emptyList<Weather.Place>(), idx.search("qqzzqq").places)
        assertEquals(emptyList<Weather.Place>(), idx.search("  ").places)
        assertTrue(idx.search("t").places.isEmpty())
        // Capped at eight, and no place twice.
        val many = idx.search("san")
        assertTrue(many.places.size <= Weather.MAX_RESULTS)
        assertEquals(many.places.size, many.places.map { listOf(it.kind, it.name, it.region, it.cc, it.code) }.toSet().size)
    }

    @Test fun aMissingPlaceListSaysSo() {
        assertEquals("PLACE LIST NOT AVAILABLE", Weather.PlaceIndex { null }.search("toronto").hint)
    }

    @Test fun aSavedPlaceIsCheckedBeforeItIsUsed() {
        assertNull(Weather.normalizePlace("Nowhere", "", "US", 123.0, 0.0, "UTC", "city", null))
        assertNull(Weather.normalizePlace("", "", "US", 10.0, 10.0, "UTC", "city", null))
        val p = Weather.normalizePlace("Toronto", "ON", "ca", 43.65321, -79.38329, "Not/AZone", "city", null)!!
        assertEquals("CA", p.cc)
        assertEquals(43.65, p.lat, 1e-9)
        assertEquals(-79.38, p.lon, 1e-9)
        assertEquals("UTC", p.tz)
    }
}
