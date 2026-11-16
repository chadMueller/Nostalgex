import SwiftUI
import UIKit

/// CH 299, LOCAL WEATHER, on screen (Trello I-016): the four screens drawn on a 1920 x 1080 picture, a port
/// of the web tuner's `scripts/nostalgex-weather-screens.js` (the reference). Same layout numbers, the app's
/// fonts (DM Mono 25 / 29 / 34 / 44, VT323 for the big digits) and colours. Shown in place of the video,
/// in the guide's picture and full screen; letterboxed when the box is not 16:9.
struct WeatherChannelView: View {
    @State private var weather = WeatherController.shared
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geo in
            let fit = WeatherScreens.fit(in: geo.size)
            ZStack {
                Color(red: 10 / 255, green: 10 / 255, blue: 26 / 255)
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    Canvas { gc, size in
                        WeatherScreens.render(gc, size: size, state: state(now: timeline.date))
                    }
                }
                .frame(width: fit.width, height: fit.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("Local weather")
        .accessibilityIdentifier("weatherChannel")
        .onAppear { weather.viewAppeared() }
        .onDisappear { weather.viewDisappeared() }
    }

    private func state(now: Date) -> WeatherScreens.State {
        let s = weather.status
        let st: WeatherScreens.Status
        if weather.place == nil { st = .noplace } else if weather.model != nil { st = .ready } else { st = s == .error ? .error : .loading }
        return WeatherScreens.State(
            nowMs: now.timeIntervalSince1970 * 1000,
            place: weather.place,
            units: weather.units,
            textScale: appState.guideTextSize == .large ? 1.16 : 1,
            status: st,
            model: weather.model,
            radarStatus: weather.radarStatus,
            radarProvider: weather.radarProvider,
            radarFrames: weather.radarFrames,
            basemap: weather.basemap
        )
    }
}

enum WeatherScreens {
    static let W: CGFloat = 1920
    static let H: CGFloat = 1080
    static let safeX: CGFloat = 90
    static let safeY: CGFloat = 56
    static let cardTop: CGFloat = 172
    static let cardH: CGFloat = 770
    static let frameMs: Double = 450
    static let holdMs: Double = 1500

    enum Status { case noplace, loading, error, ready }

    struct State {
        let nowMs: Double
        let place: WeatherEngine.Place?
        let units: WeatherEngine.Units
        let textScale: CGFloat
        let status: Status
        let model: WeatherEngine.Model?
        let radarStatus: WeatherController.RadarStatus
        let radarProvider: WeatherEngine.RadarProvider?
        let radarFrames: [WeatherController.RadarFrame]
        let basemap: WeatherBasemap.Prepared?
    }

    /// The 16:9 picture that fits inside `size`.
    static func fit(in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / W, size.height / H)
        return CGSize(width: W * scale, height: H * scale)
    }

    // MARK: Colours (DesignTokens and the brief's five)

    static func rgb(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: a)
    }
    static let bg0 = rgb(0x0A0A1A), bg1 = rgb(0x0D0D20)
    static let panel = rgb(0x0A0F1E), row = rgb(0x141B33), outline = rgb(0x3A4670)
    static let text = rgb(0xFFFFFF), text2 = rgb(0xB9C3DE)
    static let cyan = rgb(0x00D4FF), yellow = rgb(0xFFE500), pink = rgb(0xFF2DB4), amber = rgb(0xFFB020)
    static func accent(_ id: String) -> Color {
        switch id {
        case "today": return yellow
        case "week": return pink
        case "radar": return amber
        default: return cyan
        }
    }

    // MARK: Fonts and text

    enum Face { case mono, monoMedium, pixel }

    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var uiFonts: [String: UIFont] = [:]
    static func uiFont(_ face: Face, _ size: CGFloat) -> UIFont {
        let name: String
        switch face {
        case .mono: name = "DMMono-Regular"
        case .monoMedium: name = "DMMono-Medium"
        case .pixel: name = "VT323-Regular"
        }
        let size = size.rounded()
        let key = "\(name)|\(size)"
        fontLock.lock(); defer { fontLock.unlock() }
        if let f = uiFonts[key] { return f }
        let f = UIFont(name: name, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        uiFonts[key] = f
        return f
    }

    static func measure(_ s: String, _ face: Face, _ size: CGFloat) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: uiFont(face, size)]).width
    }

    enum Align { case left, center, right }

    /// Text with its baseline at `y`, like the canvas the web draws on. A `maxWidth` squeezes it, as `fillText` does.
    static func text(_ gc: GraphicsContext, _ s: String, _ x: CGFloat, _ y: CGFloat, _ face: Face, _ size: CGFloat,
                     _ color: Color, _ align: Align = .left, maxWidth: CGFloat? = nil) {
        guard !s.isEmpty else { return }
        let f = uiFont(face, size)
        let width = measure(s, face, size)
        let squeeze: CGFloat = (maxWidth.map { width > $0 && $0 > 0 ? $0 / width : 1 }) ?? 1
        let drawn = width * squeeze
        let left: CGFloat
        switch align {
        case .left: left = x
        case .center: left = x - drawn / 2
        case .right: left = x - drawn
        }
        let t = Text(s).font(Font(f)).foregroundColor(color)
        var g = gc
        g.translateBy(x: left, y: y - f.ascender)
        if squeeze < 1 { g.scaleBy(x: squeeze, y: 1) }
        g.draw(t, at: .zero, anchor: .topLeading)
    }

    /// Words wrapped to `maxWidth`, at most `maxLines` lines.
    static func wrap(_ s: String, _ face: Face, _ size: CGFloat, _ maxWidth: CGFloat, _ maxLines: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for w in s.split(separator: " ").map(String.init) {
            let t = line.isEmpty ? w : "\(line) \(w)"
            if measure(t, face, size) <= maxWidth || line.isEmpty { line = t } else { lines.append(line); line = w }
        }
        if !line.isEmpty { lines.append(line) }
        return Array(lines.prefix(maxLines))
    }

    static func fillRect(_ gc: GraphicsContext, _ r: CGRect, _ c: Color) { gc.fill(Path(r), with: .color(c)) }

    /// A big temperature in VT323 with a drawn degree ring (the font's own sign floats away at this size).
    static func bigTemp(_ gc: GraphicsContext, _ value: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat,
                        _ color: Color, _ align: Align, unit: String? = nil) {
        let dw = measure(value, .pixel, size)
        let ring = (size * 0.125).rounded()
        let gap = (size * 0.03).rounded()
        let usize = size * 0.42
        let uw = unit.map { measure($0, .pixel, usize) + gap } ?? 0
        let total = dw + gap + ring + uw
        let left = align == .center ? x - total / 2 : align == .right ? x - total : x
        text(gc, value, left, baseline, .pixel, size, color)
        let rx = (left + dw + gap).rounded()
        let ry = (baseline - size * 0.6).rounded()
        let t = max(2, (size * 0.035).rounded())
        fillRect(gc, CGRect(x: rx, y: ry, width: ring, height: t), color)
        fillRect(gc, CGRect(x: rx, y: ry + ring - t, width: ring, height: t), color)
        fillRect(gc, CGRect(x: rx, y: ry, width: t, height: ring), color)
        fillRect(gc, CGRect(x: rx + ring - t, y: ry, width: t, height: ring), color)
        if let unit { text(gc, unit, rx + ring + gap, baseline - size * 0.2, .pixel, usize, color) }
    }

    static func card(_ gc: GraphicsContext, _ r: CGRect, accent: Color?) {
        let shape = Path(roundedRect: r, cornerRadius: 12)
        gc.fill(shape, with: .color(row))
        gc.stroke(shape, with: .color(outline), lineWidth: 1.5)
        if let accent { fillRect(gc, CGRect(x: r.minX + 12, y: r.minY, width: r.width - 24, height: 8), accent) }
    }

    // MARK: Frame

    static func header(_ gc: GraphicsContext, _ st: State, title: String, accent: Color) {
        let x = safeX, y = safeY, w = W - 2 * safeX, h: CGFloat = 76
        let shape = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 12)
        gc.fill(shape, with: .color(panel))
        gc.stroke(shape, with: .color(outline), lineWidth: 1.5)
        fillRect(gc, CGRect(x: x, y: y + 12, width: 10, height: h - 24), accent)
        let blink = Int(st.nowMs / 1000) % 2 == 0
        // A drawn dot rather than a glyph VT323 does not have.
        let dot = CGRect(x: x + 36, y: y + 26, width: 22, height: 22)
        if blink { gc.fill(Path(ellipseIn: dot), with: .color(cyan)) } else { gc.stroke(Path(ellipseIn: dot.insetBy(dx: 1.5, dy: 1.5)), with: .color(cyan), lineWidth: 3) }
        text(gc, "CH \(WeatherEngine.channelNumber)", x + 72, y + 51, .pixel, 40, cyan)
        text(gc, title, x + 190, y + 51, .monoMedium, 40, text)
        let clock = st.place.map { WeatherEngine.fmtClock(st.nowMs, $0.tz) } ?? ""
        let placeText = st.place.map(placeTitle) ?? ""
        let clockW = clock.isEmpty ? 0 : measure(clock, .pixel, 44) + 28
        let maxPlace = max(200, w - 190 - measure(title, .monoMedium, 40) - 80 - clockW)
        if !clock.isEmpty { text(gc, clock, x + w - 24, y + 52, .pixel, 44, yellow, .right) }
        if !placeText.isEmpty {
            text(gc, placeText, x + w - 24 - clockW, y + 50, .monoMedium, (30 * min(1, st.textScale)).rounded(), text, .right, maxWidth: maxPlace)
        }
    }

    static func placeTitle(_ p: WeatherEngine.Place) -> String {
        let base = p.name.uppercased()
        let region: String
        if !p.region.isEmpty, ["US", "CA", "AU"].contains(p.cc) { region = ", \(p.region.uppercased())" }
        else if !p.cc.isEmpty { region = ", \(p.cc.uppercased())" }
        else { region = "" }
        return base + region
    }

    static func footer(_ gc: GraphicsContext, _ st: State, screenIndex: Int, extraCredit: String?) {
        let x = safeX
        let base = H - safeY - 6
        text(gc, "DATA FROM MET NORWAY", x, base, .mono, 25, text2)
        if let extraCredit { text(gc, extraCredit, x, base - 34, .mono, 25, text2) }
        let pips = WeatherEngine.screens.count
        let pw: CGFloat = 44, gap: CGFloat = 10
        let pipsW = CGFloat(pips) * pw + CGFloat(pips - 1) * gap
        var px = W - safeX - pipsW
        for i in 0..<pips {
            fillRect(gc, CGRect(x: px, y: base - 12, width: pw, height: 10), i == screenIndex ? accent(WeatherEngine.screens[i].id) : outline)
            px += pw + gap
        }
        if let u = st.model?.updatedMs, let place = st.place {
            let age = WeatherEngine.forecastAge(updatedMs: u, nowMs: st.nowMs, tz: place.tz)
            let label = age.stale ? "OLD FORECAST FROM \(age.text.replacingOccurrences(of: "UPDATED ", with: ""))" : age.text
            text(gc, label, W - safeX - pipsW - 36, base, .mono, 25, age.stale ? amber : text2, .right)
        }
    }

    static func message(_ gc: GraphicsContext, title: String, sub: String?, color: Color) {
        let w: CGFloat = 1300, h: CGFloat = 340, x = (W - w) / 2, y: CGFloat = 300
        card(gc, CGRect(x: x, y: y, width: w, height: h), accent: color)
        let lines = wrap(title, .monoMedium, 56, w - 120, 2)
        var ty = y + 130 - CGFloat(lines.count - 1) * 34
        for l in lines { text(gc, l, W / 2, ty, .monoMedium, 56, color, .center); ty += 70 }
        if let sub {
            let subLines = wrap(sub, .mono, 29, w - 140, 2)
            var sy = y + h - 80 - CGFloat(subLines.count - 1) * 20
            for l in subLines { text(gc, l, W / 2, sy, .mono, 29, text2, .center); sy += 42 }
        }
    }

    // MARK: The screens

    static func screenCurrent(_ gc: GraphicsContext, _ st: State, _ model: WeatherEngine.Model, _ place: WeatherEngine.Place) {
        let s = st.textScale
        let cur = model.current
        let u = st.units
        let info = WeatherEngine.symbolInfo(cur.symbol)
        let lx = safeX, lw: CGFloat = 860
        card(gc, CGRect(x: lx, y: cardTop, width: lw, height: cardH), accent: cyan)
        WeatherIcons.draw(gc, info.icon, x: lx + 44, y: cardTop + 80, size: 336)
        bigTemp(gc, WeatherEngine.fmtTemp(cur.tempC, u), lx + 400, cardTop + 380, 340, text, .left, unit: u.rawValue)
        let condLines = wrap(info.text, .monoMedium, 44 * s, lw - 80, 2)
        var cy = cardTop + 540
        for l in condLines { text(gc, l, lx + 40, cy, .monoMedium, 44 * s, cyan); cy += 56 * s }
        text(gc, "FEELS LIKE \(WeatherEngine.fmtTemp(cur.feelsC, u))\u{00B0}", lx + 40, max(cy + 14, cardTop + 650), .monoMedium, 34 * s, text)
        text(gc, "AS OF \(WeatherEngine.fmtClock(cur.timeMs, place.tz))", lx + 40, cardTop + cardH - 44, .mono, 25 * s, text2)

        var rows: [(String, String)] = [
            ("WIND", "\(WeatherEngine.compass(cur.windDir)) \(WeatherEngine.fmtWind(cur.windMs, u))".trimmingCharacters(in: .whitespaces)),
            ("HUMIDITY", cur.humidity.map { "\(Int($0))%" } ?? "--"),
            ("DEW POINT", "\(WeatherEngine.fmtTemp(cur.dewC, u))\u{00B0}"),
            ("PRESSURE", WeatherEngine.fmtPressure(cur.pressureHpa, u)),
            ("CLOUD COVER", cur.cloud.map { "\(Int($0))%" } ?? "--"),
        ]
        if let uv = cur.uv { rows.append(("UV INDEX", "\(Int(uv))")) }
        rows.append(("NEXT HOUR", cur.precipNextHourMm.map { WeatherEngine.fmtPrecip($0, u) } ?? "--"))
        let rx = lx + lw + 30, rw = W - safeX - rx
        let rowH: CGFloat = 88, gap: CGFloat = 14
        let total = CGFloat(rows.count) * rowH + CGFloat(rows.count - 1) * gap
        var ry = cardTop + (cardH - total) / 2
        for (label, value) in rows {
            let shape = Path(roundedRect: CGRect(x: rx, y: ry, width: rw, height: rowH), cornerRadius: 12)
            gc.fill(shape, with: .color(row))
            gc.stroke(shape, with: .color(outline), lineWidth: 1.5)
            text(gc, label, rx + 28, ry + 56, .mono, 29 * s, text2)
            text(gc, value, rx + rw - 28, ry + 56, .monoMedium, 34 * s, text, .right,
                 maxWidth: rw - 56 - measure(label, .mono, 29 * s) - 20)
            ry += rowH + gap
        }
    }

    static func screenToday(_ gc: GraphicsContext, _ st: State, _ model: WeatherEngine.Model) {
        let s = st.textScale
        let u = st.units
        let n = CGFloat(max(1, model.periods.count))
        let gap: CGFloat = 30
        let cw = (W - 2 * safeX - (n - 1) * gap) / n
        for (i, p) in model.periods.enumerated() {
            let x = safeX + CGFloat(i) * (cw + gap)
            let info = WeatherEngine.symbolInfo(p.symbol)
            card(gc, CGRect(x: x, y: cardTop, width: cw, height: cardH), accent: yellow)
            let cx = x + cw / 2
            text(gc, p.name, cx, cardTop + 76, .monoMedium, 38 * s, text, .center, maxWidth: cw - 30)
            text(gc, p.day, cx, cardTop + 118, .mono, 25 * s, text2, .center)
            WeatherIcons.draw(gc, info.icon, x: cx - 96, y: cardTop + 148, size: 192)
            bigTemp(gc, WeatherEngine.fmtTemp(p.tempC, u), cx, cardTop + 520, 200, text, .center)
            var ty = cardTop + 590
            for l in wrap(info.text, .monoMedium, 29 * s, cw - 40, 2) { text(gc, l, cx, ty, .monoMedium, 29 * s, cyan, .center); ty += 38 * s }
            let wind = "WIND \(WeatherEngine.compass(p.windDir)) \(WeatherEngine.fmtWind(p.windMs, u))"
                .split(whereSeparator: { $0 == " " }).joined(separator: " ")
            text(gc, wind, cx, cardTop + cardH - 84, .mono, 25 * s, text2, .center, maxWidth: cw - 24)
            let wet = (p.precipMm ?? 0) > 0
            text(gc, "PRECIP \(WeatherEngine.fmtPrecip(p.precipMm, u))", cx, cardTop + cardH - 40, .mono, 25 * s, wet ? yellow : text2, .center, maxWidth: cw - 24)
        }
    }

    static func screenWeek(_ gc: GraphicsContext, _ st: State, _ model: WeatherEngine.Model) {
        let s = st.textScale
        let u = st.units
        let n = CGFloat(max(1, model.days.count))
        let gap: CGFloat = 24
        let cw = (W - 2 * safeX - (n - 1) * gap) / n
        for (i, d) in model.days.enumerated() {
            let x = safeX + CGFloat(i) * (cw + gap)
            let info = WeatherEngine.symbolInfo(d.symbol)
            card(gc, CGRect(x: x, y: cardTop, width: cw, height: cardH), accent: pink)
            let cx = x + cw / 2
            text(gc, d.label, cx, cardTop + 78, .monoMedium, 40 * s, text, .center)
            WeatherIcons.draw(gc, info.icon, x: cx - 84, y: cardTop + 104, size: 168)
            text(gc, "HIGH", cx, cardTop + 336, .mono, 25 * s, text2, .center)
            bigTemp(gc, WeatherEngine.fmtTemp(d.highC, u), cx, cardTop + 440, 150, text, .center)
            text(gc, "LOW", cx, cardTop + 486, .mono, 25 * s, text2, .center)
            bigTemp(gc, WeatherEngine.fmtTemp(d.lowC, u), cx, cardTop + 566, 100, cyan, .center)
            var ty = cardTop + 630
            for l in wrap(info.text, .monoMedium, 25 * s, cw - 32, 2) { text(gc, l, cx, ty, .monoMedium, 25 * s, cyan, .center); ty += 34 * s }
            let wet = (d.precipMm ?? 0) > 0
            text(gc, wet ? WeatherEngine.fmtPrecip(d.precipMm, u) : "DRY", cx, cardTop + cardH - 36, .mono, 25 * s, wet ? yellow : text2, .center)
        }
    }

    // MARK: Radar

    static let map = WeatherController.mapRect

    static func screenRadar(_ gc: GraphicsContext, _ st: State, _ place: WeatherEngine.Place, elapsedMs: Double) -> String? {
        fillRect(gc, map, rgb(0x070C18))
        let credit = st.radarProvider?.credit
        if WeatherEngine.radarProvider(cc: place.cc, lat: place.lat, lon: place.lon) == nil {
            message(gc, title: "RADAR NOT AVAILABLE IN YOUR AREA", sub: "RADAR COVERS THE UNITED STATES, CANADA AND GERMANY", color: amber)
            return nil
        }
        let frames = st.radarFrames
        if frames.isEmpty {
            if st.radarStatus == .error {
                message(gc, title: "RADAR UNAVAILABLE RIGHT NOW", sub: "TRYING AGAIN SOON", color: amber)
            } else {
                message(gc, title: "LOADING RADAR", sub: "THE MAP DRAWS AS SOON AS THE FRAMES ARRIVE", color: amber)
            }
            return credit
        }
        var clipped = gc
        clipped.clip(to: Path(map))
        if let base = st.basemap { drawBase(clipped, base) }
        let cycle = Double(frames.count) * frameMs + holdMs
        let t = elapsedMs.truncatingRemainder(dividingBy: cycle)
        let idx = min(frames.count - 1, Int(t / frameMs))
        var img = clipped
        img.opacity = 0.9
        img.draw(Image(decorative: frames[idx].image, scale: 1).interpolation(.none), in: map)
        if let base = st.basemap {
            drawCities(clipped, base, place)
            drawPin(gc, base, place, nowMs: st.nowMs)
        }
        gc.stroke(Path(map), with: .color(outline), lineWidth: 3)
        // The legend under the map: the five bands, and the frame's time.
        let ly = map.maxY + 20
        var lx = map.minX
        text(gc, "RAIN AND SNOW", lx, ly + 24, .mono, 25, text2)
        lx += 245
        for b in WeatherEngine.radarBands {
            fillRect(gc, CGRect(x: lx, y: ly + 4, width: 26, height: 26), rgb(b.rgb))
            text(gc, b.name, lx + 38, ly + 26, .mono, 25, text)
            lx += 38 + measure(b.name, .mono, 25) + 34
        }
        let f = frames[idx]
        let ago = max(0, Int(WeatherEngine.jsRound((st.nowMs - f.timeMs) / 60000)))
        text(gc, "\(WeatherEngine.fmtClock(f.timeMs, place.tz))  \(ago) MIN AGO", map.maxX, ly + 28, .pixel, 40, yellow, .right)
        return credit
    }

    static func drawBase(_ gc: GraphicsContext, _ base: WeatherBasemap.Prepared) {
        let style: [String: (Color, CGFloat)] = [
            "lakes": (rgb(0x00D4FF, 0.45), 2), "states": (rgb(0xB9C3DE, 0.38), 1.5),
            "borders": (rgb(0xFF2DB4, 0.85), 3), "coast": (rgb(0x00D4FF, 0.95), 3),
        ]
        for (layer, path) in base.paths {
            guard let (color, width) = style[layer] else { continue }
            gc.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    static func drawCities(_ gc: GraphicsContext, _ base: WeatherBasemap.Prepared, _ place: WeatherEngine.Place) {
        var placed: [CGRect] = []
        let mine = base.project(lon: place.lon, lat: place.lat)
        var shown = 0
        for (name, p) in base.cities {
            if shown >= 9 { break }
            let label = name.uppercased()
            let w = measure(label, .pixel, 34) + 26
            let box = CGRect(x: p.x - 6, y: p.y - 30, width: w + 6, height: 40)
            if hypot(p.x - mine.x, p.y - mine.y) < 70 { continue }
            if p.x < map.minX + 20 || p.x + w > map.maxX - 10 || p.y < map.minY + 40 || p.y > map.maxY - 20 { continue }
            if placed.contains(where: { $0.intersects(box) }) { continue }
            placed.append(box)
            fillRect(gc, CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8), text2)
            text(gc, label, p.x + 14, p.y + 8, .pixel, 34, text2)
            shown += 1
        }
    }

    static func drawPin(_ gc: GraphicsContext, _ base: WeatherBasemap.Prepared, _ place: WeatherEngine.Place, nowMs: Double) {
        let p = base.project(lon: place.lon, lat: place.lat)
        let pulse = Int(nowMs / 500) % 2 == 0
        let sq = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
        fillRect(gc, sq, pink)
        gc.stroke(Path(sq), with: .color(text), lineWidth: 3)
        if pulse { gc.stroke(Path(CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)), with: .color(pink), lineWidth: 3) }
        let label = place.name.uppercased()
        let lw = measure(label, .pixel, 42)
        let right = p.x + 30 + lw < map.maxX - 10
        let lx = right ? p.x + 30 : p.x - 30
        fillRect(gc, CGRect(x: right ? lx - 8 : lx - lw - 8, y: p.y - 28, width: lw + 16, height: 40), rgb(0x0A0A1A, 0.78))
        text(gc, label, lx, p.y + 4, .pixel, 42, yellow, right ? .left : .right)
    }

    // MARK: The picture

    static func render(_ outer: GraphicsContext, size: CGSize, state st: State) {
        var gc = outer
        gc.scaleBy(x: size.width / W, y: size.height / H)
        let at = WeatherEngine.screenAt(st.nowMs)
        let screen = at.screen
        gc.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)),
                with: .linearGradient(Gradient(colors: [bg0, bg1]), startPoint: .zero, endPoint: CGPoint(x: W, y: H)))
        let hasData = st.status != .noplace && st.model != nil
        header(gc, st, title: hasData ? screen.title : WeatherEngine.channelName, accent: hasData ? accent(screen.id) : cyan)
        var extra: String?
        if st.status == .noplace || st.place == nil {
            message(gc, title: "SET YOUR LOCATION IN SETTINGS", sub: "SETTINGS, PLAYBACK & PICTURE, WEATHER, LOCATION", color: cyan)
        } else if let model = st.model, let place = st.place {
            switch screen.id {
            case "current": screenCurrent(gc, st, model, place)
            case "today": screenToday(gc, st, model)
            case "week": screenWeek(gc, st, model)
            default: extra = screenRadar(gc, st, place, elapsedMs: at.elapsed * 1000)
            }
        } else if st.status == .error {
            message(gc, title: "FORECAST UNAVAILABLE RIGHT NOW", sub: "TRYING AGAIN SOON", color: amber)
        } else {
            message(gc, title: "LOADING THE FORECAST", sub: nil, color: cyan)
        }
        footer(gc, st, screenIndex: at.index, extraCredit: screen.id == "radar" && hasData ? extra : nil)
        // The change between screens: a quick wipe from the left.
        let wipe = 0.4
        if at.elapsed < wipe {
            let x = (W * CGFloat(at.elapsed / wipe)).rounded()
            fillRect(gc, CGRect(x: x, y: 0, width: W - x, height: H), bg0)
            fillRect(gc, CGRect(x: x - 10, y: 0, width: 10, height: H), accent(screen.id))
        }
    }
}

/// The 18 weather icons: pixel pictures on a 24 x 24 grid, made by the same steps as the web tuner's.
enum WeatherIcons {
    /// Letters: . clear, Y yellow, y amber, M moon, W/w/g cloud light/mid/shadow, C cyan, c deep cyan, S snow.
    static let colors: [Character: Color] = [
        "Y": WeatherScreens.rgb(0xFFE500), "y": WeatherScreens.rgb(0xFFB020), "M": WeatherScreens.rgb(0xFFF1A8),
        "W": WeatherScreens.rgb(0xEAF0FF), "w": WeatherScreens.rgb(0xB9C3DE), "g": WeatherScreens.rgb(0x7A86AD),
        "C": WeatherScreens.rgb(0x00D4FF), "c": WeatherScreens.rgb(0x0A9FCC), "S": WeatherScreens.rgb(0xFFFFFF),
    ]

    typealias Grid = [[Character]]
    static func blank() -> Grid { Array(repeating: Array(repeating: ".", count: 24), count: 24) }
    static func put(_ g: inout Grid, _ x: Double, _ y: Double, _ ch: Character) {
        let xi = Int(WeatherEngine.jsRound(x)), yi = Int(WeatherEngine.jsRound(y))
        if xi >= 0 && xi < 24 && yi >= 0 && yi < 24 { g[yi][xi] = ch }
    }
    static func disk(_ g: inout Grid, _ cx: Double, _ cy: Double, _ r: Double, _ ch: Character) {
        for y in 0..<24 { for x in 0..<24 where pow(Double(x) + 0.5 - cx, 2) + pow(Double(y) + 0.5 - cy, 2) <= r * r { g[y][x] = ch } }
    }
    static func sun(_ g: inout Grid, _ cx: Double, _ cy: Double, _ r: Double, _ rays: Double?) {
        disk(&g, cx, cy, r, "Y")
        for k in 0..<8 {
            let a = Double(k) * .pi / 4
            let diag = k % 2 == 1
            var d = r + 1.4
            while d <= r + (rays ?? 2.6) {
                put(&g, cx - 0.5 + cos(a) * d, cy - 0.5 + sin(a) * d, diag ? "y" : "Y")
                d += 0.5
            }
        }
    }
    static func moon(_ g: inout Grid, _ cx: Double, _ cy: Double, _ r: Double) {
        var m = blank()
        disk(&m, cx, cy, r, "M")
        disk(&m, cx + r * 0.62, cy - r * 0.5, r * 0.82, ".")
        for y in 0..<24 { for x in 0..<24 where m[y][x] != "." { g[y][x] = m[y][x] } }
    }
    enum Flat { case none, flat, back }
    static func cloud(_ g: inout Grid, _ ox: Double, _ oy: Double, _ s: Double, _ flat: Flat = .none) {
        var m = blank()
        let circles: [(Double, Double, Double)] = [(10, 6.4, 5.2), (5.2, 9.2, 3.6), (15.6, 8.6, 4.3), (18.8, 10.2, 2.6), (2.8, 10.2, 2.4)]
        for (cx, cy, r) in circles { disk(&m, cx * s + ox, cy * s + oy, r * s, "x") }
        let y0 = Int(WeatherEngine.jsRound(9.4 * s + oy)), y1 = Int(WeatherEngine.jsRound(13 * s + oy)) - 1
        let x0 = Int(WeatherEngine.jsRound(2.8 * s + ox)), x1 = Int(WeatherEngine.jsRound(19.8 * s + ox))
        if y0 <= y1 && x0 <= x1 { for y in y0...y1 { for x in x0...x1 { put(&m, Double(x), Double(y), "x") } } }
        var top = 99, bottom = -1
        for y in 0..<24 { for x in 0..<24 where m[y][x] == "x" { top = min(top, y); bottom = max(bottom, y) } }
        for y in 0..<24 {
            for x in 0..<24 where m[y][x] == "x" {
                let t = Double(y - top) / Double(max(1, bottom - top))
                switch flat {
                case .back: g[y][x] = "g"
                case .flat: g[y][x] = t < 0.5 ? "w" : "g"
                case .none: g[y][x] = t < 0.45 ? "W" : t < 0.8 ? "w" : "g"
                }
            }
        }
    }
    static func drops(_ g: inout Grid, _ xs: [Int], _ y0: Int, _ len: Int, _ ch: Character, slant: Bool = false) {
        for x in xs { for i in 0..<len { put(&g, Double(x + (slant ? -(i / 2) : 0)), Double(y0 + i), ch) } }
    }
    static func flake(_ g: inout Grid, _ x: Double, _ y: Double) {
        put(&g, x, y, "S"); put(&g, x - 1, y, "S"); put(&g, x + 1, y, "S"); put(&g, x, y - 1, "S"); put(&g, x, y + 1, "S")
    }

    static func make(_ name: String) -> Grid {
        var g = blank()
        switch name {
        case "sun": sun(&g, 12, 12, 5.2, 3.2)
        case "moon": moon(&g, 12, 12, 7.4); put(&g, 4, 5, "W"); put(&g, 19, 4, "W"); put(&g, 20, 17, "W"); put(&g, 3, 17, "w")
        case "fair-day": sun(&g, 9, 9, 3.6, 2.4); cloud(&g, 9.5, 12, 0.62)
        case "fair-night": moon(&g, 9, 9, 5); cloud(&g, 9.5, 12, 0.62)
        case "partly-day": sun(&g, 8, 8, 3.8, 2.4); cloud(&g, 3, 9, 0.95)
        case "partly-night": moon(&g, 8, 8, 5.2); cloud(&g, 3, 9, 0.95)
        case "fog":
            cloud(&g, 2.5, 1.5, 0.9)
            for x in 3...20 { put(&g, Double(x), 15, "w") }
            for x in 6...22 { put(&g, Double(x), 18, "g") }
            for x in 3...17 { put(&g, Double(x), 21, "w") }
        case "drizzle": cloud(&g, 2, 1.5, 0.95); drops(&g, [8, 12, 16], 15, 2, "C"); drops(&g, [10, 14], 19, 2, "c")
        case "rain": cloud(&g, 2, 1.5, 0.95); drops(&g, [6, 10, 14, 18], 15, 3, "C", slant: true); drops(&g, [8, 12, 16], 19, 2, "c", slant: true)
        case "heavy-rain": cloud(&g, 2, 1.5, 0.95, .flat); drops(&g, [5, 8, 11, 14, 17, 20], 14, 3, "C", slant: true); drops(&g, [6, 9, 12, 15, 18], 18, 3, "c", slant: true)
        case "showers-day": sun(&g, 17, 6, 3, 2); cloud(&g, 1, 4, 0.95); drops(&g, [7, 11, 15], 16, 3, "C", slant: true)
        case "showers-night": moon(&g, 17, 6, 4.2); cloud(&g, 1, 4, 0.95); drops(&g, [7, 11, 15], 16, 3, "C", slant: true)
        case "sleet":
            cloud(&g, 2, 1.5, 0.95); drops(&g, [6, 14], 15, 3, "C", slant: true)
            put(&g, 10, 16, "S"); put(&g, 10, 19, "S"); put(&g, 18, 17, "S"); put(&g, 8, 21, "S"); put(&g, 16, 21, "S")
        case "snow": cloud(&g, 2, 1.5, 0.95); flake(&g, 6, 17); flake(&g, 12, 20); flake(&g, 18, 17)
        case "flurries-day": sun(&g, 17, 6, 3, 2); cloud(&g, 1, 4, 0.95); flake(&g, 7, 18); flake(&g, 14, 20)
        case "flurries-night": moon(&g, 17, 6, 4.2); cloud(&g, 1, 4, 0.95); flake(&g, 7, 18); flake(&g, 14, 20)
        case "thunder":
            cloud(&g, 2, 1, 0.95, .flat)
            for (x, y) in [(13, 13), (14, 13), (12, 14), (13, 14), (11, 15), (12, 15), (10, 16), (11, 16), (12, 16), (13, 16), (12, 17), (13, 17), (11, 18), (12, 18), (11, 19), (10, 20), (10, 21)] {
                put(&g, Double(x), Double(y), "Y")
            }
            drops(&g, [6, 18], 16, 3, "C", slant: true)
        default: cloud(&g, 9.5, 3, 0.62, .back); cloud(&g, 1.2, 8, 1)   // "cloud"
        }
        return g
    }

    static let names = ["sun", "moon", "fair-day", "fair-night", "partly-day", "partly-night", "cloud", "fog", "drizzle", "rain",
                        "heavy-rain", "showers-day", "showers-night", "sleet", "snow", "flurries-day", "flurries-night", "thunder"]
    static let grids: [String: Grid] = Dictionary(uniqueKeysWithValues: names.map { ($0, make($0)) })

    /// Draws an icon at (x, y), `size` square, in whole-pixel cells.
    static func draw(_ gc: GraphicsContext, _ name: String, x: CGFloat, y: CGFloat, size: CGFloat) {
        guard let grid = grids[name] ?? grids["cloud"] else { return }
        let cell = max(1, (size / 24).rounded())
        let ox = (x + (size - cell * 24) / 2).rounded()
        let oy = (y + (size - cell * 24) / 2).rounded()
        for (r, row) in grid.enumerated() {
            for (c, ch) in row.enumerated() where ch != "." {
                if let color = colors[ch] { gc.fill(Path(CGRect(x: ox + CGFloat(c) * cell, y: oy + CGFloat(r) * cell, width: cell, height: cell)), with: .color(color)) }
            }
        }
    }
}
