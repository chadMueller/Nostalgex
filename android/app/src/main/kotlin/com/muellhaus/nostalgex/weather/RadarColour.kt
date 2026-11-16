package com.muellhaus.nostalgex.weather

import android.graphics.Bitmap
import android.graphics.Color
import com.muellhaus.nostalgex.engine.Weather

/**
 * A radar picture from the source's colours to our five bands (the web tuner's recolorRadar): cyan, yellow, amber, red, pink.
 * Anything that is not an echo becomes clear. The band rule is [Weather.radarBand], held to the shared golden.
 */
object RadarColour {
    private val BANDS = Weather.RADAR_BANDS.map { Color.parseColor(it.color) }

    fun recolour(src: Bitmap, ignoreBands: Set<Int>): Bitmap {
        val w = src.width; val h = src.height
        val px = IntArray(w * h)
        src.getPixels(px, 0, w, 0, 0, w, h)
        for (i in px.indices) {
            val c = px[i]
            if (Color.alpha(c) < 40) { px[i] = 0; continue }
            val band = Weather.radarBand(Color.red(c), Color.green(c), Color.blue(c))
            px[i] = if (band < 0 || band in ignoreBands) 0 else Color.argb(235, Color.red(BANDS[band]), Color.green(BANDS[band]), Color.blue(BANDS[band]))
        }
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(px, 0, w, 0, 0, w, h)
        return out
    }
}
