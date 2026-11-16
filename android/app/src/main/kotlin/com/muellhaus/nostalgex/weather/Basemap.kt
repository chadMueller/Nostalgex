package com.muellhaus.nostalgex.weather

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * The map under the radar: Natural Earth coastlines, lakes and borders (public domain), simplified into weather/basemap.json. Each line is
 * delta-coded in thousandths of a degree. [prepare] cuts them to one window, the way the web tuner's prepareBasemap does.
 */
object Basemap {
    class City(val name: String, val lat: Double, val lon: Double)
    class Source(val unit: Double, val layers: Map<String, List<IntArray>>, val cities: List<City>)
    class Line(val layer: String, val pts: FloatArray)
    class Prepared(val bbox: DoubleArray, val lines: List<Line>, val cities: List<City>)

    fun load(context: Context): Source? = runCatching {
        val root = Json.parseToJsonElement(context.assets.open("weather/basemap.json").bufferedReader().use { it.readText() }).jsonObject
        parse(root)
    }.getOrNull()

    fun parse(root: JsonObject): Source {
        val layers = (root["layers"] as JsonObject).mapValues { (_, v) ->
            (v as JsonArray).map { line -> (line as JsonArray).map { (it as JsonPrimitive).intOrNull ?: 0 }.toIntArray() }
        }
        val cities = (root["cities"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { c ->
            val a = c as? JsonArray ?: return@mapNotNull null
            City((a[0] as JsonPrimitive).content, (a[1] as JsonPrimitive).doubleOrNull ?: return@mapNotNull null, (a[2] as JsonPrimitive).doubleOrNull ?: return@mapNotNull null)
        }
        return Source((root["unit"] as? JsonPrimitive)?.doubleOrNull ?: 1000.0, layers, cities)
    }

    /** The lines that reach the window, as [lon, lat, ...], and the cities inside it. */
    fun prepare(src: Source, bbox: DoubleArray): Prepared {
        val unit = src.unit
        val (minLon, minLat, maxLon, maxLat) = bbox.toList()
        val padLon = (maxLon - minLon) * 0.05
        val padLat = (maxLat - minLat) * 0.05
        val lines = ArrayList<Line>()
        for (layer in listOf("lakes", "states", "borders", "coast")) {
            for (flat in src.layers[layer] ?: emptyList()) {
                if (flat.size < 2) continue
                val pts = FloatArray(flat.size)
                var x = flat[0]; var y = flat[1]
                var inside = false
                fun push(i: Int) {
                    val lo = x / unit; val la = y / unit
                    pts[i] = lo.toFloat(); pts[i + 1] = la.toFloat()
                    if (lo >= minLon - padLon && lo <= maxLon + padLon && la >= minLat - padLat && la <= maxLat + padLat) inside = true
                }
                push(0)
                var i = 2
                while (i + 1 < flat.size) { x += flat[i]; y += flat[i + 1]; push(i); i += 2 }
                if (inside) lines.add(Line(layer, pts))
            }
        }
        return Prepared(bbox, lines, src.cities.filter { it.lon > minLon && it.lon < maxLon && it.lat > minLat && it.lat < maxLat })
    }
}
