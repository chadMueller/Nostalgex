package com.muellhaus.nostalgex.weather

import com.muellhaus.nostalgex.engine.Weather
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The map under the radar, cut to a window (the web tuner's prepareBasemap), over the real Natural Earth file the app ships. */
class BasemapTest {
    private val root = File(System.getProperty("user.dir")).resolve("..").resolve("..")
    private val source = Basemap.parse(Json.parseToJsonElement(root.resolve("public/weather/basemap.json").readText()).jsonObject)

    @Test fun aWindowOverTorontoHasTheLakesAndTheCityAndNothingFromAfar() {
        val bbox = Weather.radarBBox(43.65, -79.38, WeatherPainter.MAP_ASPECT, 5.0)
        val p = Basemap.prepare(source, bbox)
        assertTrue("coastline", p.lines.any { it.layer == "coast" })
        assertTrue("a lake", p.lines.any { it.layer == "lakes" })
        assertTrue("the US-Canada border", p.lines.any { it.layer == "borders" })
        assertTrue(p.cities.isNotEmpty())
        assertTrue(p.cities.all { it.lon > bbox[0] && it.lon < bbox[2] && it.lat > bbox[1] && it.lat < bbox[3] })
        // Every kept line has a point in or near the window.
        val padLon = (bbox[2] - bbox[0]) * 0.05; val padLat = (bbox[3] - bbox[1]) * 0.05
        for (l in p.lines) {
            var near = false
            var i = 0
            while (i + 1 < l.pts.size) {
                if (l.pts[i] >= bbox[0] - padLon && l.pts[i] <= bbox[2] + padLon && l.pts[i + 1] >= bbox[1] - padLat && l.pts[i + 1] <= bbox[3] + padLat) near = true
                i += 2
            }
            assertTrue("a ${l.layer} line with no point in the window", near)
        }
        // A window in the middle of the Pacific has no coastline and no city.
        val sea = Basemap.prepare(source, Weather.radarBBox(-30.0, -140.0, WeatherPainter.MAP_ASPECT, 5.0))
        assertEquals(0, sea.cities.size)
        assertTrue(sea.lines.none { it.layer == "coast" })
    }

    @Test fun theFileDecodesToThePointsItShouldHave() {
        // The first coast line starts at a stored absolute point and every later point is a delta from the one before.
        val flat = source.layers.getValue("coast")[0]
        val p = Basemap.prepare(source, doubleArrayOf(-180.0, -90.0, 180.0, 90.0)).lines.first { it.layer == "coast" }
        assertEquals(flat[0] / source.unit, p.pts[0].toDouble(), 1e-3)
        assertEquals((flat[1] + 0) / source.unit, p.pts[1].toDouble(), 1e-3)
        assertEquals((flat[0] + flat[2]) / source.unit, p.pts[2].toDouble(), 1e-3)
    }
}
