package com.muellhaus.nostalgex.weather

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import com.muellhaus.nostalgex.R
import com.muellhaus.nostalgex.engine.Weather

/**
 * The weather channel's four screens, drawn on a 1920 x 1080 canvas: a port of scripts/nostalgex-weather-screens.js (the web tuner is the
 * reference). Coordinates are for a 1920 x 1080 picture, type sizes are the Apple TV's points (DM Mono 25 / 29 / 34 / 44, VT323 for the
 * big digits), the colours are the app's. The picture is fitted into whatever box it is given, letterboxed, as the web tuner's `contain`.
 *
 *   CURRENT CONDITIONS   an icon and the temperature on the left, rows of detail on the right
 *   TODAY'S FORECAST     four cards, the next four six-hour periods
 *   5-DAY FORECAST       five cards, a high and a low each
 *   RADAR                a drawn map (coastlines, lakes, borders) with the radar frames looping over it
 *
 * GUIDE TEXT SIZE: `textScale` (1 for SMALLER and DEFAULT, 1.16 for LARGER) grows the text and never the layout.
 */
class WeatherPainter(context: Context) {
    class Frame(
        val nowMs: Long,
        val place: Weather.Place?,
        val units: String,
        val textScale: Float,
        /** "noplace", "loading", "error" or "ready". */
        val status: String,
        val model: Weather.Model?,
        val radar: WeatherController.RadarState,
        /** Draws this screen at this many seconds in, instead of following the clock (the tests and screenshots). */
        val screenId: String? = null,
        val elapsedOverride: Double? = null,
    )

    private val regular: Typeface = context.resources.getFont(R.font.dmmono_regular)
    private val medium: Typeface = context.resources.getFont(R.font.dmmono_medium)
    private val pixel: Typeface = context.resources.getFont(R.font.vt323)

    private class Font(val face: Typeface, val px: Float)
    private fun mono(px: Number, weight: Int = 400) = Font(if (weight >= 500) medium else regular, Math.round(px.toDouble()).toFloat())
    private fun vt(px: Number) = Font(pixel, Math.round(px.toDouble()).toFloat())

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fill = Paint().apply { style = Paint.Style.FILL }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val bitmapPaint = Paint().apply { isFilterBitmap = false; isAntiAlias = false }

    // ── Icons: 18 pixel pictures on a 24 x 24 grid, each made once ──
    private val icons = HashMap<String, Bitmap>()
    private fun icon(name: String): Bitmap = icons.getOrPut(if (name in ICON_MAKERS) name else "cloud") {
        val key = if (name in ICON_MAKERS) name else "cloud"
        val g = Array(24) { CharArray(24) { '.' } }
        ICON_MAKERS.getValue(key)(g)
        val bmp = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888)
        for (y in 0 until 24) for (x in 0 until 24) {
            val ch = g[y][x]
            if (ch != '.') bmp.setPixel(x, y, ICON_COLORS.getValue(ch))
        }
        bmp
    }

    private fun drawIcon(c: Canvas, name: String, x: Float, y: Float, size: Float) {
        // Whole-pixel cells: the 24 x 24 picture scaled up without smoothing, 15% smaller than its slot (Chad, 2026-11-16: 336 draws at 288,
        // 192 at 168, 168 at 144), centred in the slot so nothing around it moves.
        val cell = Math.max(1, Math.round(size * ICON_SCALE / 24))
        val ox = Math.round(x + (size - cell * 24) / 2).toFloat()
        val oy = Math.round(y + (size - cell * 24) / 2).toFloat()
        c.drawBitmap(icon(name), null, RectF(ox, oy, ox + cell * 24, oy + cell * 24), bitmapPaint)
    }

    // ── Text ──
    private fun text(c: Canvas, s: String, x: Float, y: Float, f: Font, color: Int, align: Paint.Align = Paint.Align.LEFT, maxWidth: Float? = null) {
        paint.typeface = f.face; paint.textSize = f.px; paint.color = color; paint.textAlign = align; paint.style = Paint.Style.FILL
        if (maxWidth != null) {
            val w = paint.measureText(s)
            if (w > maxWidth && w > 0) {
                // The browser squeezes the text to fit: the same here, from the anchor.
                c.save(); c.translate(x, y); c.scale(maxWidth / w, 1f); c.drawText(s, 0f, 0f, paint); c.restore()
                return
            }
        }
        c.drawText(s, x, y, paint)
    }

    private fun measure(s: String, f: Font): Float { paint.typeface = f.face; paint.textSize = f.px; return paint.measureText(s) }

    /** Words wrapped to `maxWidth`, at most `maxLines` lines. */
    private fun wrap(s: String, f: Font, maxWidth: Float, maxLines: Int): List<String> {
        val lines = ArrayList<String>()
        var line = ""
        for (w in s.split(' ')) {
            val t = if (line.isNotEmpty()) "$line $w" else w
            if (measure(t, f) <= maxWidth || line.isEmpty()) line = t else { lines.add(line); line = w }
        }
        if (line.isNotEmpty()) lines.add(line)
        return lines.take(maxLines)
    }

    /** A big temperature in VT323 with a drawn degree ring (the font's own degree sign floats away from its digits at this size). Returns the right edge. */
    private fun bigTemp(c: Canvas, value: String, x: Float, baseline: Float, size: Float, color: Int, align: String = "left", unit: String? = null): Float {
        val font = vt(size)
        val dw = measure(value, font)
        val ring = Math.round(size * 0.125f)
        val gap = Math.round(size * 0.03f)
        val ufont = vt(size * 0.42f)
        val uw = if (unit != null) measure(unit, ufont) + gap else 0f
        val total = dw + gap + ring + uw
        val left = when (align) { "center" -> x - total / 2; "right" -> x - total; else -> x }
        text(c, value, left, baseline, font, color)
        val rx = Math.round(left + dw + gap).toFloat()
        val ry = Math.round(baseline - size * 0.6f).toFloat()
        val t = Math.max(2, Math.round(size * 0.035f)).toFloat()
        fill.color = color
        c.drawRect(rx, ry, rx + ring, ry + t, fill)
        c.drawRect(rx, ry + ring - t, rx + ring, ry + ring, fill)
        c.drawRect(rx, ry, rx + t, ry + ring, fill)
        c.drawRect(rx + ring - t, ry, rx + ring, ry + ring, fill)
        if (unit != null) text(c, unit, rx + ring + gap, baseline - size * 0.2f, ufont, color)
        return left + total
    }

    private fun rrect(c: Canvas, x: Float, y: Float, w: Float, h: Float, r: Float, fillColor: Int, line: Int? = null, lineWidth: Float = 1.5f) {
        fill.color = fillColor
        c.drawRoundRect(RectF(x, y, x + w, y + h), r, r, fill)
        if (line != null) { stroke.color = line; stroke.strokeWidth = lineWidth; c.drawRoundRect(RectF(x, y, x + w, y + h), r, r, stroke) }
    }

    private fun card(c: Canvas, x: Float, y: Float, w: Float, h: Float, accent: Int?) {
        rrect(c, x, y, w, h, 12f, ROW, OUTLINE)
        if (accent != null) { fill.color = accent; c.drawRect(x + 12, y, x + w - 12, y + 8, fill) }
    }

    // ── Frame: the header strip and the footer ──
    private fun background(c: Canvas) {
        paint.shader = LinearGradient(0f, 0f, W, H, BG0, BG1, Shader.TileMode.CLAMP)
        paint.style = Paint.Style.FILL
        c.drawRect(0f, 0f, W, H, paint)
        paint.shader = null
    }

    private fun placeTitle(p: Weather.Place): String {
        val base = p.name.uppercase()
        val region = if (p.region.isNotEmpty() && (p.cc == "US" || p.cc == "CA" || p.cc == "AU")) ", ${p.region.uppercase()}" else if (p.cc.isNotEmpty()) ", ${p.cc.uppercase()}" else ""
        return base + region
    }

    private fun header(c: Canvas, st: Frame, title: String, accent: Int) {
        val x = SAFE_X; val y = SAFE_Y; val w = W - 2 * SAFE_X; val h = 76f
        rrect(c, x, y, w, h, 12f, PANEL, OUTLINE)
        fill.color = accent
        c.drawRect(x, y + 12, x + 10, y + h - 12, fill)
        val blink = (st.nowMs / 1000) % 2 == 0L
        // The channel dot, drawn: the font has no round dot at this size.
        if (blink) { fill.color = CYAN; c.drawCircle(x + 43, y + 38, 9f, fill) } else { stroke.color = CYAN; stroke.strokeWidth = 3f; c.drawCircle(x + 43, y + 38, 8f, stroke) }
        text(c, "CH ${Weather.CHANNEL_NUMBER}", x + 72, y + 51, vt(40), CYAN)
        text(c, title, x + 190, y + 51, mono(40, 500), WHITE)
        val tz = st.place?.tz
        val clock = if (tz != null) Weather.fmtClock(st.nowMs, tz) else ""
        val place = st.place?.let { placeTitle(it) } ?: ""
        val clockW = if (clock.isNotEmpty()) measure(clock, vt(44)) + 28 else 0f
        val maxPlace = Math.max(200f, w - 190 - measure(title, mono(40, 500)) - 80 - clockW)
        if (clock.isNotEmpty()) text(c, clock, x + w - 24, y + 52, vt(44), YELLOW, Paint.Align.RIGHT)
        if (place.isNotEmpty()) text(c, place, x + w - 24 - clockW, y + 50, mono(30 * Math.min(1f, st.textScale), 500), WHITE, Paint.Align.RIGHT, maxPlace)
    }

    /**
     * The least important text on the screen, so the smallest (Chad, 2026-11-16): the source credits and the age of the forecast as one small
     * stack at the bottom left, 16 on the 1080 canvas, lines 22 apart, text2 at 70% (about 5.5:1). The credit stays on every screen
     * and stays readable (about 5.5:1 on the background), because MET Norway, GeoNames and the radar sources ask for attribution. The loop
     * pips stay at the bottom right.
     */
    private fun footer(c: Canvas, st: Frame, screenIndex: Int, extraCredit: String?) {
        val x = SAFE_X
        val base = H - SAFE_Y - 6
        val small = mono(16)
        val dim = Color.argb(178, 185, 195, 222)
        val lines = ArrayList<Pair<String, Int>>()
        if (extraCredit != null) lines.add(extraCredit to dim)
        lines.add("DATA FROM MET NORWAY" to dim)
        val updated = st.model?.updatedMs
        if (updated != null && st.place != null) {
            val age = Weather.forecastAge(updated, st.nowMs, st.place.tz)
            // An old forecast still says so, in amber: it is a warning, not a credit.
            lines.add((if (age.stale) "OLD FORECAST FROM ${age.text.replace("UPDATED ", "")}" else age.text) to (if (age.stale) AMBER else dim))
        }
        var y = base - (lines.size - 1) * 22f
        for ((t, color) in lines) { text(c, t, x, y, small, color); y += 22f }
        // Loop pips on the right.
        val pips = Weather.SCREENS.size
        val pw = 44f; val gap = 10f
        var px = W - SAFE_X - (pips * pw + (pips - 1) * gap)
        for (i in 0 until pips) {
            fill.color = if (i == screenIndex) ACCENT.getValue(Weather.SCREENS[i].id) else OUTLINE
            c.drawRect(px, base - 12, px + pw, base - 2, fill)
            px += pw + gap
        }
    }

    // ── Cards without data ──
    private fun message(c: Canvas, title: String, sub: String?, color: Int) {
        val w = 1300f; val h = 340f; val x = (W - w) / 2; val y = 300f
        card(c, x, y, w, h, color)
        val lines = wrap(title, mono(56, 500), w - 120, 2)
        var ty = y + 130 - (lines.size - 1) * 34
        for (l in lines) { text(c, l, W / 2, ty, mono(56, 500), color, Paint.Align.CENTER); ty += 70 }
        if (sub != null) {
            val subLines = wrap(sub, mono(29), w - 140, 2)
            var sy = y + h - 80 - (subLines.size - 1) * 20
            for (l in subLines) { text(c, l, W / 2, sy, mono(29), TEXT2, Paint.Align.CENTER); sy += 42 }
        }
    }

    // ── The four screens ──
    private fun screenCurrent(c: Canvas, st: Frame, m: Weather.Model) {
        val s = st.textScale
        val cur = m.current
        val u = st.units
        val info = Weather.symbolInfo(cur.symbol)
        val lx = SAFE_X; val lw = 860f
        card(c, lx, CARD_TOP, lw, CARD_H, CYAN)
        drawIcon(c, info.icon, lx + 44, CARD_TOP + 80, 336f)
        bigTemp(c, Weather.fmtTemp(cur.tempC, u), lx + 400, CARD_TOP + 380, 340f, WHITE, "left", u)
        val condLines = wrap(info.text, mono(44 * s, 500), lw - 80, 2)
        var cy = CARD_TOP + 540
        for (l in condLines) { text(c, l, lx + 40, cy, mono(44 * s, 500), CYAN); cy += 56 * s }
        text(c, "FEELS LIKE ${Weather.fmtTemp(cur.feelsC, u)}°", lx + 40, Math.max(cy + 14, CARD_TOP + 650), mono(34 * s, 500), WHITE)
        text(c, "AS OF ${Weather.fmtClock(cur.timeMs, m.tz)}", lx + 40, CARD_TOP + CARD_H - 44, mono(25 * s), TEXT2)

        val rows = listOfNotNull(
            "WIND" to "${Weather.compass(cur.windDir?.toDouble())} ${Weather.fmtWind(cur.windMs, u)}".trim(),
            "HUMIDITY" to (cur.humidity?.let { "$it%" } ?: "--"),
            "DEW POINT" to "${Weather.fmtTemp(cur.dewC, u)}°",
            "PRESSURE" to Weather.fmtPressure(cur.pressureHpa, u),
            "CLOUD COVER" to (cur.cloud?.let { "$it%" } ?: "--"),
            cur.uv?.let { "UV INDEX" to it.toString() },
            "NEXT HOUR" to (cur.precipNextHourMm?.let { Weather.fmtPrecip(it, u) } ?: "--"),
        )
        val rx = lx + lw + 30; val rw = W - SAFE_X - rx
        val rowH = 88f; val gap = 14f
        val total = rows.size * rowH + (rows.size - 1) * gap
        var ry = CARD_TOP + (CARD_H - total) / 2
        for ((label, value) in rows) {
            rrect(c, rx, ry, rw, rowH, 12f, ROW, OUTLINE)
            text(c, label, rx + 28, ry + 56, mono(29 * s), TEXT2)
            text(c, value, rx + rw - 28, ry + 56, mono(34 * s, 500), WHITE, Paint.Align.RIGHT, rw - 56 - measure(label, mono(29 * s)) - 20)
            ry += rowH + gap
        }
    }

    private fun screenToday(c: Canvas, st: Frame, m: Weather.Model) {
        val s = st.textScale
        val u = st.units
        val n = Math.max(1, m.periods.size)
        val gap = 30f
        val cw = (W - 2 * SAFE_X - (n - 1) * gap) / n
        m.periods.forEachIndexed { i, p ->
            val x = SAFE_X + i * (cw + gap)
            val info = Weather.symbolInfo(p.symbol)
            card(c, x, CARD_TOP, cw, CARD_H, YELLOW)
            val cx = x + cw / 2
            text(c, p.name, cx, CARD_TOP + 76, mono(38 * s, 500), WHITE, Paint.Align.CENTER, cw - 30)
            text(c, p.day, cx, CARD_TOP + 118, mono(25 * s), TEXT2, Paint.Align.CENTER)
            drawIcon(c, info.icon, cx - 96, CARD_TOP + 148, 192f)
            bigTemp(c, Weather.fmtTemp(p.tempC, u), cx, CARD_TOP + 520, 200f, WHITE, "center")
            val lines = wrap(info.text, mono(29 * s, 500), cw - 40, 2)
            var ty = CARD_TOP + 590
            for (l in lines) { text(c, l, cx, ty, mono(29 * s, 500), CYAN, Paint.Align.CENTER); ty += 38 * s }
            text(c, "WIND ${Weather.compass(p.windDir?.toDouble())} ${Weather.fmtWind(p.windMs, u)}".replace(Regex("\\s+"), " "), cx, CARD_TOP + CARD_H - 84, mono(25 * s), TEXT2, Paint.Align.CENTER, cw - 24)
            val wet = (p.precipMm ?: 0.0) > 0
            text(c, "PRECIP ${Weather.fmtPrecip(p.precipMm, u)}", cx, CARD_TOP + CARD_H - 40, mono(25 * s), if (wet) YELLOW else TEXT2, Paint.Align.CENTER, cw - 24)
        }
    }

    private fun screenWeek(c: Canvas, st: Frame, m: Weather.Model) {
        val s = st.textScale
        val u = st.units
        val n = Math.max(1, m.days.size)
        val gap = 24f
        val cw = (W - 2 * SAFE_X - (n - 1) * gap) / n
        m.days.forEachIndexed { i, d ->
            val x = SAFE_X + i * (cw + gap)
            val info = Weather.symbolInfo(d.symbol)
            card(c, x, CARD_TOP, cw, CARD_H, PINK)
            val cx = x + cw / 2
            text(c, d.label, cx, CARD_TOP + 78, mono(40 * s, 500), WHITE, Paint.Align.CENTER)
            drawIcon(c, info.icon, cx - 84, CARD_TOP + 104, 168f)
            text(c, "HIGH", cx, CARD_TOP + 336, mono(25 * s), TEXT2, Paint.Align.CENTER)
            bigTemp(c, Weather.fmtTemp(d.highC, u), cx, CARD_TOP + 440, 150f, WHITE, "center")
            text(c, "LOW", cx, CARD_TOP + 486, mono(25 * s), TEXT2, Paint.Align.CENTER)
            bigTemp(c, Weather.fmtTemp(d.lowC, u), cx, CARD_TOP + 566, 100f, CYAN, "center")
            val lines = wrap(info.text, mono(25 * s, 500), cw - 32, 2)
            var ty = CARD_TOP + 630
            for (l in lines) { text(c, l, cx, ty, mono(25 * s, 500), CYAN, Paint.Align.CENTER); ty += 34 * s }
            val wet = (d.precipMm ?: 0.0) > 0
            text(c, if (wet) Weather.fmtPrecip(d.precipMm, u) else "DRY", cx, CARD_TOP + CARD_H - 36, mono(25 * s), if (wet) YELLOW else TEXT2, Paint.Align.CENTER)
        }
    }

    // ── Radar ──
    private fun project(bbox: DoubleArray, lon: Double, lat: Double): FloatArray = floatArrayOf(
        (MAP_X + (lon - bbox[0]) / (bbox[2] - bbox[0]) * MAP_W).toFloat(),
        (MAP_Y + (bbox[3] - lat) / (bbox[3] - bbox[1]) * MAP_H).toFloat(),
    )

    private val path = Path()
    private fun drawBase(c: Canvas, base: Basemap.Prepared) {
        val styles = mapOf(
            "lakes" to (Color.argb(115, 0, 212, 255) to 2f), "states" to (Color.argb(97, 185, 195, 222) to 1.5f),
            "borders" to (Color.argb(217, 255, 45, 180) to 3f), "coast" to (Color.argb(242, 0, 212, 255) to 3f),
        )
        c.save()
        c.clipRect(MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y + MAP_H)
        stroke.strokeJoin = Paint.Join.ROUND; stroke.strokeCap = Paint.Cap.ROUND
        for (layer in listOf("lakes", "states", "borders", "coast")) {
            val (color, width) = styles.getValue(layer)
            stroke.color = color; stroke.strokeWidth = width
            path.reset()
            for (l in base.lines) {
                if (l.layer != layer) continue
                var i = 0
                while (i + 1 < l.pts.size) {
                    val p = project(base.bbox, l.pts[i].toDouble(), l.pts[i + 1].toDouble())
                    if (i == 0) path.moveTo(p[0], p[1]) else path.lineTo(p[0], p[1])
                    i += 2
                }
            }
            c.drawPath(path, stroke)
        }
        c.restore()
    }

    private fun drawCities(c: Canvas, base: Basemap.Prepared, place: Weather.Place) {
        val placed = ArrayList<FloatArray>()
        val mine = project(base.bbox, place.lon, place.lat)
        c.save()
        c.clipRect(MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y + MAP_H)
        var shown = 0
        for (city in base.cities) {
            if (shown >= 9) break
            val p = project(base.bbox, city.lon, city.lat)
            val w = measure(city.name.uppercase(), vt(34)) + 26
            val box = floatArrayOf(p[0] - 6, p[1] - 30, p[0] + w, p[1] + 10)
            if (Math.hypot((p[0] - mine[0]).toDouble(), (p[1] - mine[1]).toDouble()) < 70) continue
            if (p[0] < MAP_X + 20 || p[0] + w > MAP_X + MAP_W - 10 || p[1] < MAP_Y + 40 || p[1] > MAP_Y + MAP_H - 20) continue
            if (placed.any { b -> !(box[2] < b[0] || box[0] > b[2] || box[3] < b[1] || box[1] > b[3]) }) continue
            placed.add(box)
            fill.color = TEXT2
            c.drawRect(p[0] - 4, p[1] - 4, p[0] + 4, p[1] + 4, fill)
            text(c, city.name.uppercase(), p[0] + 14, p[1] + 8, vt(34), TEXT2)
            shown++
        }
        c.restore()
    }

    private fun drawPin(c: Canvas, base: Basemap.Prepared, place: Weather.Place, nowMs: Long) {
        val p = project(base.bbox, place.lon, place.lat)
        val pulse = (nowMs / 500) % 2 == 0L
        fill.color = PINK
        c.drawRect(p[0] - 9, p[1] - 9, p[0] + 9, p[1] + 9, fill)
        stroke.strokeWidth = 3f; stroke.color = WHITE
        c.drawRect(p[0] - 9, p[1] - 9, p[0] + 9, p[1] + 9, stroke)
        if (pulse) { stroke.color = PINK; c.drawRect(p[0] - 20, p[1] - 20, p[0] + 20, p[1] + 20, stroke) }
        val label = place.name.uppercase()
        val lw = measure(label, vt(42))
        val right = p[0] + 30 + lw < MAP_X + MAP_W - 10
        val lx = if (right) p[0] + 30 else p[0] - 30
        fill.color = Color.argb(199, 10, 10, 26)
        val left = if (right) lx - 8 else lx - lw - 8
        c.drawRect(left, p[1] - 28, left + lw + 16, p[1] + 12, fill)
        text(c, label, lx, p[1] + 4, vt(42), YELLOW, if (right) Paint.Align.LEFT else Paint.Align.RIGHT)
    }

    private fun screenRadar(c: Canvas, st: Frame, elapsedMs: Double): String? {
        val r = st.radar
        fill.color = Color.parseColor("#070C18")
        c.drawRect(MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y + MAP_H, fill)
        val provider = r.provider
        val frames = r.frames
        if (r.status == "none") {
            message(c, "RADAR NOT AVAILABLE IN YOUR AREA", "RADAR COVERS THE UNITED STATES, CANADA AND GERMANY", AMBER)
            return null
        }
        if (r.status == "loading" && frames.isEmpty()) { message(c, "LOADING RADAR", "THE MAP DRAWS AS SOON AS THE FRAMES ARRIVE", AMBER); return provider?.credit }
        if (r.status == "error" && frames.isEmpty()) { message(c, "RADAR UNAVAILABLE RIGHT NOW", "TRYING AGAIN SOON", AMBER); return provider?.credit }
        val place = st.place ?: return null
        val base = r.base
        if (base != null) drawBase(c, base)
        var idx = 0
        if (frames.isNotEmpty()) {
            val cycle = frames.size * FRAME_MS + HOLD_MS
            val t = elapsedMs % cycle
            idx = Math.min(frames.size - 1, Math.floor(t / FRAME_MS).toInt())
            c.save()
            c.clipRect(MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y + MAP_H)
            bitmapPaint.alpha = 230
            c.drawBitmap(frames[idx].bitmap, null, RectF(MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y + MAP_H), bitmapPaint)
            bitmapPaint.alpha = 255
            c.restore()
        }
        if (base != null) { drawCities(c, base, place); drawPin(c, base, place, st.nowMs) }
        stroke.strokeWidth = 3f; stroke.color = OUTLINE
        c.drawRect(MAP_X, MAP_Y, MAP_X + MAP_W, MAP_Y + MAP_H, stroke)
        // The legend row under the map: the five bands, and the frame's time.
        val ly = MAP_Y + MAP_H + 20
        var lx = MAP_X
        text(c, "RAIN AND SNOW", lx, ly + 24, mono(25), TEXT2)
        lx += 245
        for (b in Weather.RADAR_BANDS) {
            fill.color = Color.parseColor(b.color); c.drawRect(lx, ly + 4, lx + 26, ly + 30, fill)
            text(c, b.name, lx + 38, ly + 26, mono(25), WHITE)
            lx += 38 + measure(b.name, mono(25)) + 34
        }
        if (frames.isNotEmpty()) {
            val f = frames[idx]
            val ago = Math.max(0, Math.round((st.nowMs - f.timeMs) / 60000.0))
            text(c, "${Weather.fmtClock(f.timeMs, place.tz)}  $ago MIN AGO", MAP_X + MAP_W, ly + 28, vt(40), YELLOW, Paint.Align.RIGHT)
        }
        return provider?.credit
    }

    // ── The picture ──
    /** Draws the channel for `st.nowMs` into a box of `width` x `height` pixels, letterboxed. Returns the screen id drawn. */
    fun render(c: Canvas, width: Float, height: Float, st: Frame): String {
        val at = Weather.screenAt(st.nowMs)
        var index = at.index
        var elapsed = at.elapsed
        if (st.screenId != null) { index = Weather.SCREENS.indexOfFirst { it.id == st.screenId }.coerceAtLeast(0); elapsed = st.elapsedOverride ?: 4.0 }
        val screen = Weather.SCREENS[index]
        c.save()
        val k = Math.min(width / W, height / H)
        c.translate((width - W * k) / 2, (height - H * k) / 2)
        c.scale(k, k)
        c.clipRect(0f, 0f, W, H)
        background(c)
        // With nothing to show yet the header says what the channel is; the four screens' names come with the data.
        val m = st.model
        val hasData = st.status != "noplace" && m != null
        header(c, st, if (hasData) screen.title else Weather.CHANNEL_NAME, if (hasData) ACCENT.getValue(screen.id) else CYAN)
        var extra: String? = null
        when {
            st.status == "noplace" -> message(c, "SET YOUR LOCATION IN SETTINGS", "PRESS OK TO OPEN THE LOCATION PAGE", CYAN)
            m == null && st.status == "error" -> message(c, "FORECAST UNAVAILABLE RIGHT NOW", "TRYING AGAIN SOON", AMBER)
            m == null -> message(c, "LOADING THE FORECAST", null, CYAN)
            screen.id == "current" -> screenCurrent(c, st, m)
            screen.id == "today" -> screenToday(c, st, m)
            screen.id == "week" -> screenWeek(c, st, m)
            screen.id == "radar" && st.place != null -> extra = screenRadar(c, st, elapsed * 1000)
        }
        footer(c, st, index, if (screen.id == "radar" && st.status != "noplace") extra else null)
        // The change between screens: a quick wipe from the left.
        if (elapsed < WIPE && st.screenId == null) {
            val x = Math.round(W * (elapsed / WIPE)).toFloat()
            fill.color = BG0; c.drawRect(x, 0f, W, H, fill)
            fill.color = ACCENT.getValue(screen.id); c.drawRect(x - 10, 0f, x, H, fill)
        }
        c.restore()
        return screen.id
    }

    /** How long to wait before the next draw: the picture only moves on the radar screen and during the wipe; elsewhere twice a second keeps the clock and the pulse right. */
    fun nextDelay(nowMs: Long): Long {
        val at = Weather.screenAt(nowMs)
        if (at.elapsed < 0.45) return 50
        if (at.screen.id == "radar") return 120
        return 500
    }

    companion object {
        const val W = 1920f
        const val H = 1080f
        private const val SAFE_X = 90f
        private const val SAFE_Y = 56f
        private const val CARD_TOP = 172f
        private const val CARD_H = 770f
        const val MAP_X = SAFE_X
        const val MAP_Y = CARD_TOP
        const val MAP_W = W - 2 * SAFE_X
        const val MAP_H = 700f
        const val MAP_ASPECT = MAP_W.toDouble() / MAP_H
        /** Icons draw at about 85% of their slot. */
        private const val ICON_SCALE = 0.85f
        private const val FRAME_MS = 450
        private const val HOLD_MS = 1500
        private const val WIPE = 0.4

        private val BG0 = Color.parseColor("#0A0A1A")
        private val BG1 = Color.parseColor("#0D0D20")
        private val PANEL = Color.parseColor("#0A0F1E")
        private val ROW = Color.parseColor("#141B33")
        private val OUTLINE = Color.parseColor("#3A4670")
        private val WHITE = Color.WHITE
        private val TEXT2 = Color.parseColor("#B9C3DE")
        private val CYAN = Color.parseColor("#00D4FF")
        private val YELLOW = Color.parseColor("#FFE500")
        private val PINK = Color.parseColor("#FF2DB4")
        private val AMBER = Color.parseColor("#FFB020")
        private val ACCENT = mapOf("current" to CYAN, "today" to YELLOW, "week" to PINK, "radar" to AMBER)

        // Letters: . clear, Y yellow, y amber, M moon, W/w/g cloud light/mid/shadow, C cyan, c deep cyan, S snow.
        private val ICON_COLORS = mapOf(
            'Y' to Color.parseColor("#FFE500"), 'y' to Color.parseColor("#FFB020"), 'M' to Color.parseColor("#FFF1A8"), 'W' to Color.parseColor("#EAF0FF"),
            'w' to Color.parseColor("#B9C3DE"), 'g' to Color.parseColor("#7A86AD"), 'C' to Color.parseColor("#00D4FF"), 'c' to Color.parseColor("#0A9FCC"), 'S' to Color.WHITE,
        )

        private fun put(g: Array<CharArray>, x: Double, y: Double, ch: Char) {
            val xi = Math.round(x).toInt(); val yi = Math.round(y).toInt()
            if (xi in 0..23 && yi in 0..23) g[yi][xi] = ch
        }
        private fun disk(g: Array<CharArray>, cx: Double, cy: Double, r: Double, ch: Char) {
            for (y in 0 until 24) for (x in 0 until 24) if ((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy) <= r * r) g[y][x] = ch
        }
        private fun sun(g: Array<CharArray>, cx: Double, cy: Double, r: Double, rays: Double) {
            disk(g, cx, cy, r, 'Y')
            for (k in 0 until 8) {
                val a = k * Math.PI / 4
                val diag = k % 2 == 1
                var d = r + 1.4
                while (d <= r + rays) { put(g, cx - 0.5 + Math.cos(a) * d, cy - 0.5 + Math.sin(a) * d, if (diag) 'y' else 'Y'); d += 0.5 }
            }
        }
        private fun moon(g: Array<CharArray>, cx: Double, cy: Double, r: Double) {
            val m = Array(24) { CharArray(24) { '.' } }
            disk(m, cx, cy, r, 'M')
            disk(m, cx + r * 0.62, cy - r * 0.5, r * 0.82, '.')
            for (y in 0 until 24) for (x in 0 until 24) if (m[y][x] != '.') g[y][x] = m[y][x]
        }
        /** A cloud: a high round top, two lower shoulders and a flat base, lit from above (light, mid, shadow by row). flat: null, "back" or "flat". */
        private fun cloud(g: Array<CharArray>, ox: Double, oy: Double, s: Double, flat: String? = null) {
            val m = Array(24) { CharArray(24) { '.' } }
            val circles = listOf(doubleArrayOf(10.0, 6.4, 5.2), doubleArrayOf(5.2, 9.2, 3.6), doubleArrayOf(15.6, 8.6, 4.3), doubleArrayOf(18.8, 10.2, 2.6), doubleArrayOf(2.8, 10.2, 2.4))
            for ((cx, cy, r) in circles.map { Triple(it[0], it[1], it[2]) }) disk(m, cx * s + ox, cy * s + oy, r * s, 'x')
            for (y in Math.round(9.4 * s + oy).toInt() until Math.round(13 * s + oy).toInt()) for (x in Math.round(2.8 * s + ox).toInt()..Math.round(19.8 * s + ox).toInt()) put(m, x.toDouble(), y.toDouble(), 'x')
            var top = 99; var bottom = -1
            for (y in 0 until 24) for (x in 0 until 24) if (m[y][x] == 'x') { top = Math.min(top, y); bottom = Math.max(bottom, y) }
            for (y in 0 until 24) for (x in 0 until 24) {
                if (m[y][x] != 'x') continue
                val t = (y - top).toDouble() / Math.max(1, bottom - top)
                g[y][x] = when (flat) { "back" -> 'g'; "flat" -> if (t < 0.5) 'w' else 'g'; else -> if (t < 0.45) 'W' else if (t < 0.8) 'w' else 'g' }
            }
        }
        private fun drops(g: Array<CharArray>, xs: List<Int>, y0: Int, len: Int, ch: Char, slant: Boolean = false) {
            for (x in xs) for (i in 0 until len) put(g, (x + (if (slant) -(i / 2) else 0)).toDouble(), (y0 + i).toDouble(), ch)
        }
        private fun flake(g: Array<CharArray>, x: Int, y: Int) {
            for ((dx, dy) in listOf(0 to 0, -1 to 0, 1 to 0, 0 to -1, 0 to 1)) put(g, (x + dx).toDouble(), (y + dy).toDouble(), 'S')
        }

        private val ICON_MAKERS: Map<String, (Array<CharArray>) -> Unit> = mapOf(
            "sun" to { g -> sun(g, 12.0, 12.0, 5.2, 3.2) },
            "moon" to { g -> moon(g, 12.0, 12.0, 7.4); put(g, 4.0, 5.0, 'W'); put(g, 19.0, 4.0, 'W'); put(g, 20.0, 17.0, 'W'); put(g, 3.0, 17.0, 'w') },
            "fair-day" to { g -> sun(g, 9.0, 9.0, 3.6, 2.4); cloud(g, 9.5, 12.0, 0.62) },
            "fair-night" to { g -> moon(g, 9.0, 9.0, 5.0); cloud(g, 9.5, 12.0, 0.62) },
            "partly-day" to { g -> sun(g, 8.0, 8.0, 3.8, 2.4); cloud(g, 3.0, 9.0, 0.95) },
            "partly-night" to { g -> moon(g, 8.0, 8.0, 5.2); cloud(g, 3.0, 9.0, 0.95) },
            "cloud" to { g -> cloud(g, 9.5, 3.0, 0.62, "back"); cloud(g, 1.2, 8.0, 1.0) },
            "fog" to { g ->
                cloud(g, 2.5, 1.5, 0.9)
                for (x in 3..20) put(g, x.toDouble(), 15.0, 'w')
                for (x in 6..22) put(g, x.toDouble(), 18.0, 'g')
                for (x in 3..17) put(g, x.toDouble(), 21.0, 'w')
            },
            "drizzle" to { g -> cloud(g, 2.0, 1.5, 0.95); drops(g, listOf(8, 12, 16), 15, 2, 'C'); drops(g, listOf(10, 14), 19, 2, 'c') },
            "rain" to { g -> cloud(g, 2.0, 1.5, 0.95); drops(g, listOf(6, 10, 14, 18), 15, 3, 'C', true); drops(g, listOf(8, 12, 16), 19, 2, 'c', true) },
            "heavy-rain" to { g -> cloud(g, 2.0, 1.5, 0.95, "flat"); drops(g, listOf(5, 8, 11, 14, 17, 20), 14, 3, 'C', true); drops(g, listOf(6, 9, 12, 15, 18), 18, 3, 'c', true) },
            "showers-day" to { g -> sun(g, 17.0, 6.0, 3.0, 2.0); cloud(g, 1.0, 4.0, 0.95); drops(g, listOf(7, 11, 15), 16, 3, 'C', true) },
            "showers-night" to { g -> moon(g, 17.0, 6.0, 4.2); cloud(g, 1.0, 4.0, 0.95); drops(g, listOf(7, 11, 15), 16, 3, 'C', true) },
            "sleet" to { g ->
                cloud(g, 2.0, 1.5, 0.95); drops(g, listOf(6, 14), 15, 3, 'C', true)
                put(g, 10.0, 16.0, 'S'); put(g, 10.0, 19.0, 'S'); put(g, 18.0, 17.0, 'S'); put(g, 8.0, 21.0, 'S'); put(g, 16.0, 21.0, 'S')
            },
            "snow" to { g -> cloud(g, 2.0, 1.5, 0.95); flake(g, 6, 17); flake(g, 12, 20); flake(g, 18, 17) },
            "flurries-day" to { g -> sun(g, 17.0, 6.0, 3.0, 2.0); cloud(g, 1.0, 4.0, 0.95); flake(g, 7, 18); flake(g, 14, 20) },
            "flurries-night" to { g -> moon(g, 17.0, 6.0, 4.2); cloud(g, 1.0, 4.0, 0.95); flake(g, 7, 18); flake(g, 14, 20) },
            "thunder" to { g ->
                cloud(g, 2.0, 1.0, 0.95, "flat")
                for ((x, y) in listOf(13 to 13, 14 to 13, 12 to 14, 13 to 14, 11 to 15, 12 to 15, 10 to 16, 11 to 16, 12 to 16, 13 to 16, 12 to 17, 13 to 17, 11 to 18, 12 to 18, 11 to 19, 10 to 20, 10 to 21)) {
                    put(g, x.toDouble(), y.toDouble(), 'Y')
                }
                drops(g, listOf(6, 18), 16, 3, 'C', true)
            },
        )
    }
}
