import Foundation

/// The weather channel's rules (Trello I-016), ported from the web tuner's `scripts/nostalgex-weather.js`,
/// which is the reference. Pure logic: no network, no views. `scripts/weather-golden.json` holds the
/// web tuner, this file, Roku and Android to the same answers (`WeatherGoldenTests`).
///
/// CH 299, LOCAL WEATHER: four screens on a 65 second loop that follows the wall clock, so every viewer
/// sees the same one. CURRENT CONDITIONS, TODAY'S FORECAST, 5-DAY FORECAST, RADAR.
///
/// Numbers are rounded the way JavaScript's `Math.round` rounds (half up, towards +infinity), not the
/// way Swift's `.rounded()` does (half away from zero), so -2.5 is -2 on every platform.
enum WeatherEngine {
    // MARK: The channel

    /// CH 299: the closest number below the franchise, collection and HIGH ROTATION blocks (300-519)
    /// that nothing owns. Its id sits in the next free dynamic block (`ChannelIDSpace`), so a channel
    /// made at runtime can never take it.
    static let channelNumber = 299
    static let channelID = 1_030_000
    static let channelName = "LOCAL WEATHER"
    static let channelColorHex = "#00D4FF"

    struct Screen: Equatable {
        let id: String
        let title: String
        let seconds: Double
    }

    /// The loop, in seconds. Radar is longest: it plays its frames over and over.
    static let screens: [Screen] = [
        Screen(id: "current", title: "CURRENT CONDITIONS", seconds: 15),
        Screen(id: "today", title: "TODAY'S FORECAST", seconds: 15),
        Screen(id: "week", title: "5-DAY FORECAST", seconds: 15),
        Screen(id: "radar", title: "RADAR", seconds: 20),
    ]
    static let loopSeconds: Double = screens.reduce(0) { $0 + $1.seconds }

    struct ScreenAt: Equatable {
        let index: Int
        let screen: Screen
        let elapsed: Double
        let remaining: Double
    }

    /// Which screen is up at `nowMs` and how far into it.
    static func screenAt(_ nowMs: Double) -> ScreenAt {
        var t = jsMod(jsMod(nowMs / 1000, loopSeconds) + loopSeconds, loopSeconds)
        for (i, s) in screens.enumerated() {
            if t < s.seconds { return ScreenAt(index: i, screen: s, elapsed: t, remaining: s.seconds - t) }
            t -= s.seconds
        }
        return ScreenAt(index: 0, screen: screens[0], elapsed: 0, remaining: screens[0].seconds)
    }

    // MARK: Numbers the JavaScript way

    /// `Math.round`: half up, towards +infinity.
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
    /// `%` on numbers: the sign follows the dividend.
    static func jsMod(_ a: Double, _ b: Double) -> Double { a.truncatingRemainder(dividingBy: b) }
    static func r1(_ n: Double?) -> Double? {
        guard let n, n.isFinite else { return nil }
        return jsRound(n * 10) / 10
    }
    static func round2(_ n: Double) -> Double { jsRound(n * 100) / 100 }
    /// `String(n)` for a number: no ".0" on whole numbers, the shortest form otherwise.
    static func jsNumber(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        return "\(d)"
    }
    /// `n.toFixed(digits)`.
    static func toFixed(_ n: Double, _ digits: Int) -> String {
        let s = String(format: "%.\(digits)f", n)
        // A negative that rounds to zero prints "-0.00" in C; JavaScript prints "-0.00" too, so leave it.
        return s
    }

    // MARK: Units

    enum Units: String { case F, C }

    /// °F where the place's country is the US, otherwise °C, unless the viewer chose: "auto", "F" or "C".
    static func unitsFor(cc: String?, setting: String) -> Units {
        if setting == "F" { return .F }
        if setting == "C" { return .C }
        return (cc ?? "").uppercased() == "US" ? .F : .C
    }

    static func fmtTemp(_ c: Double?, _ units: Units) -> String {
        guard let c, c.isFinite else { return "--" }
        let v = jsRound(units == .F ? c * 9 / 5 + 32 : c)
        return String(Int(v == 0 ? 0 : v))
    }

    /// mph on °F, km/h on °C (the MET value is metres per second).
    static func fmtWind(_ ms: Double?, _ units: Units) -> String {
        guard let ms, ms.isFinite else { return "--" }
        return units == .F ? "\(Int(jsRound(ms * 2.2369363))) MPH" : "\(Int(jsRound(ms * 3.6))) KM/H"
    }

    static func fmtPressure(_ hpa: Double?, _ units: Units) -> String {
        guard let hpa, hpa.isFinite else { return "--" }
        return units == .F ? "\(toFixed(hpa * 0.0295300, 2)) IN" : "\(Int(jsRound(hpa))) HPA"
    }

    /// Rain and snow melt: inches to 2 places, or millimetres to 1 below 10 and whole above.
    static func fmtPrecip(_ mm: Double?, _ units: Units) -> String {
        guard let mm, mm.isFinite else { return "--" }
        if units == .F { return "\(toFixed(mm / 25.4, 2)) IN" }
        return mm < 10 ? "\(toFixed(mm, 1)) MM" : "\(Int(jsRound(mm))) MM"
    }

    private static let compassPoints = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    static func compass(_ deg: Double?) -> String {
        guard let deg, deg.isFinite else { return "" }
        let d = jsMod(jsMod(deg, 360) + 360, 360)
        return compassPoints[Int(jsRound(d / 22.5)) % 16]
    }

    // MARK: Symbols

    struct SymbolInfo: Equatable {
        let icon: String
        let text: String
        let night: Bool
    }

    /// MET's `symbol_code` is `<family>[_day|_night|_polartwilight]`. Unknown codes read as cloud, never as a blank.
    static func symbolInfo(_ code: String?) -> SymbolInfo {
        let raw = code ?? ""
        var base = raw
        var suffix = ""
        for s in ["day", "night", "polartwilight"] where raw.hasSuffix("_" + s) {
            base = String(raw.dropLast(s.count + 1))
            suffix = s
            break
        }
        let night = suffix == "night"
        let intensity = base.hasPrefix("light") ? "light" : base.hasPrefix("heavy") ? "heavy" : "mid"
        var family = base
        if family.hasPrefix("light") { family = String(family.dropFirst(5)) } else if family.hasPrefix("heavy") { family = String(family.dropFirst(5)) }
        func dn(_ d: String, _ n: String) -> String { night ? n : d }
        if family.contains("thunder") {
            return SymbolInfo(icon: "thunder", text: family.contains("snow") ? "THUNDER SNOW" : "THUNDERSTORMS", night: night)
        }
        switch family {
        case "clearsky": return SymbolInfo(icon: dn("sun", "moon"), text: dn("SUNNY", "CLEAR"), night: night)
        case "fair": return SymbolInfo(icon: dn("fair-day", "fair-night"), text: dn("MOSTLY SUNNY", "MOSTLY CLEAR"), night: night)
        case "partlycloudy": return SymbolInfo(icon: dn("partly-day", "partly-night"), text: "PARTLY CLOUDY", night: night)
        case "cloudy": return SymbolInfo(icon: "cloud", text: "CLOUDY", night: night)
        case "fog": return SymbolInfo(icon: "fog", text: "FOG", night: night)
        case "rain":
            return SymbolInfo(icon: intensity == "light" ? "drizzle" : intensity == "heavy" ? "heavy-rain" : "rain",
                              text: intensity == "light" ? "LIGHT RAIN" : intensity == "heavy" ? "HEAVY RAIN" : "RAIN", night: night)
        case "rainshowers":
            return SymbolInfo(icon: dn("showers-day", "showers-night"),
                              text: intensity == "light" ? "LIGHT SHOWERS" : intensity == "heavy" ? "HEAVY SHOWERS" : "SHOWERS", night: night)
        case "sleet", "sleetshowers":
            let lead = intensity == "light" ? "LIGHT " : intensity == "heavy" ? "HEAVY " : ""
            return SymbolInfo(icon: "sleet", text: lead + (family == "sleet" ? "SLEET" : "SLEET SHOWERS"), night: night)
        case "snow":
            return SymbolInfo(icon: "snow", text: intensity == "light" ? "LIGHT SNOW" : intensity == "heavy" ? "HEAVY SNOW" : "SNOW", night: night)
        case "snowshowers":
            return SymbolInfo(icon: dn("flurries-day", "flurries-night"),
                              text: intensity == "light" ? "FLURRIES" : intensity == "heavy" ? "HEAVY SNOW SHOWERS" : "SNOW SHOWERS", night: night)
        default: return SymbolInfo(icon: "cloud", text: "CLOUDY", night: night)
        }
    }

    /// The daytime form of a symbol code: the 5-day screen shows the day, so no moon on a day's icon.
    static func dayForm(_ code: String?) -> String {
        let raw = code ?? ""
        for s in ["_night", "_polartwilight"] where raw.hasSuffix(s) {
            return String(raw.dropLast(s.count)) + "_day"
        }
        return raw
    }

    // MARK: Time in the place's zone

    struct LocalParts: Equatable {
        let y: Int, mo: Int, d: Int, h: Int, mi: Int
        /// 0 Sunday to 6 Saturday.
        let dow: Int
        /// "2026-11-15"
        let key: String
    }

    private static let partsLock = NSLock()
    nonisolated(unsafe) private static var calendars: [String: Calendar] = [:]
    private static func calendar(_ tz: String) -> Calendar {
        partsLock.lock(); defer { partsLock.unlock() }
        if let c = calendars[tz] { return c }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz) ?? TimeZone(identifier: "UTC")!
        calendars[tz] = c
        return c
    }

    static func localParts(_ ms: Double, _ tz: String) -> LocalParts {
        let c = calendar(tz)
        let comps = c.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: Date(timeIntervalSince1970: ms / 1000))
        let y = comps.year ?? 1970, mo = comps.month ?? 1, d = comps.day ?? 1
        return LocalParts(y: y, mo: mo, d: d, h: (comps.hour ?? 0) % 24, mi: comps.minute ?? 0,
                          dow: ((comps.weekday ?? 1) - 1), key: String(format: "%04d-%02d-%02d", y, mo, d))
    }

    static func validZone(_ tz: String?) -> Bool {
        guard let tz, !tz.isEmpty else { return false }
        return TimeZone(identifier: tz) != nil
    }

    /// "4:00 PM", the way the guide prints times.
    static func fmtClock(_ ms: Double, _ tz: String) -> String {
        let p = localParts(ms, tz)
        let h12 = p.h % 12 == 0 ? 12 : p.h % 12
        return "\(h12):\(String(format: "%02d", p.mi)) \(p.h >= 12 ? "PM" : "AM")"
    }

    // MARK: ISO dates

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoLock = NSLock()

    /// `Date.parse` for the ISO forms MET and WMS servers send, in milliseconds.
    static func parseISO(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        isoLock.lock(); defer { isoLock.unlock() }
        if let d = isoPlain.date(from: s) ?? isoFraction.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        return nil
    }

    /// `new Date(ms).toISOString()`: "2026-11-15T16:48:00.000Z".
    static func isoString(_ ms: Double) -> String {
        isoLock.lock(); defer { isoLock.unlock() }
        return isoFraction.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // MARK: The forecast document

    struct Step {
        let t: Double
        let instant: [String: Double]
        let next1: Period?
        let next6: Period?
        let next12: Period?

        struct Period {
            let symbol: String?
            let details: [String: Double]
        }
    }

    /// The steps of a MET `complete` document (parsed JSON), sorted, with no time or no `instant` dropped.
    static func steps(fromJSON met: Any?) -> (steps: [Step], updatedMs: Double?) {
        let props = (met as? [String: Any])?["properties"] as? [String: Any]
        let series = props?["timeseries"] as? [[String: Any]] ?? []
        func numbers(_ any: Any?) -> [String: Double] {
            guard let dict = any as? [String: Any] else { return [:] }
            var out: [String: Double] = [:]
            for (k, v) in dict {
                if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { out[k] = n.doubleValue }
            }
            return out
        }
        func period(_ any: Any?) -> Step.Period? {
            guard let dict = any as? [String: Any] else { return nil }
            let summary = dict["summary"] as? [String: Any]
            return Step.Period(symbol: summary?["symbol_code"] as? String, details: numbers(dict["details"]))
        }
        var out: [Step] = []
        for s in series {
            guard let t = parseISO(s["time"] as? String),
                  let data = s["data"] as? [String: Any],
                  let instant = data["instant"] as? [String: Any] else { continue }
            out.append(Step(t: t, instant: numbers(instant["details"]), next1: period(data["next_1_hours"]),
                            next6: period(data["next_6_hours"]), next12: period(data["next_12_hours"])))
        }
        out.sort { $0.t < $1.t }
        let meta = props?["meta"] as? [String: Any]
        return (out, parseISO(meta?["updated_at"] as? String))
    }

    static func stepSymbol(_ s: Step) -> String? {
        for p in [s.next1, s.next6, s.next12] { if let c = p?.symbol, !c.isEmpty { return c } }
        return nil
    }
    /// The symbol for a period starting at a step: the 6 hour one first, then 12, then 1.
    static func periodSymbol(_ s: Step) -> String? {
        for p in [s.next6, s.next12, s.next1] { if let c = p?.symbol, !c.isEmpty { return c } }
        return nil
    }
    static func stepPrecip(_ s: Step) -> Double {
        if let v = s.next1?.details["precipitation_amount"], v.isFinite { return v }
        if let v = s.next6?.details["precipitation_amount"], v.isFinite { return v }
        return 0
    }

    struct Current: Equatable {
        let timeMs: Double
        let tempC: Double?
        let feelsC: Double?
        let humidity: Double?
        let dewC: Double?
        let windMs: Double?
        let windDir: Double?
        let pressureHpa: Double?
        let cloud: Double?
        let uv: Double?
        let precipNextHourMm: Double?
        let symbol: String?
        let isDay: Bool
    }

    struct PeriodForecast: Equatable {
        let name: String
        let day: String
        let startMs: Double
        let tempC: Double?
        let symbol: String?
        let precipMm: Double?
        let windMs: Double?
        let windDir: Double?
    }

    struct DayForecast: Equatable {
        let date: String
        let label: String
        let highC: Double?
        let lowC: Double?
        let symbol: String?
        let precipMm: Double?
        let windMaxMs: Double?
    }

    struct Model: Equatable {
        let updatedMs: Double?
        let tz: String
        let current: Current
        let periods: [PeriodForecast]
        let days: [DayForecast]
    }

    enum ModelError: Error { case empty }

    private static let periodNames = ["OVERNIGHT", "MORNING", "AFTERNOON", "EVENING"]   // local 00-06, 06-12, 12-18, 18-24
    private static let dowNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    /// The channel's numbers from one `complete` forecast document (parsed JSON). Metric; format with `fmtTemp` and the rest.
    static func buildModel(met: Any?, tz placeTZ: String?, nowMs: Double) throws -> Model {
        let tz = validZone(placeTZ) ? placeTZ! : "UTC"
        let (series, updatedMs) = steps(fromJSON: met)
        var cur = -1
        for (i, s) in series.enumerated() { if s.t <= nowMs { cur = i } else { break } }
        if cur < 0 { cur = 0 }
        guard let last = series.last, last.t >= nowMs else { throw ModelError.empty }

        // CURRENT CONDITIONS: the step the clock is in.
        let step = series[cur]
        let d = step.instant
        let sym = stepSymbol(step)
        let nowLocal = localParts(nowMs, tz)
        let info = symbolInfo(sym)
        let hasDayPart = sym.map { $0.hasSuffix("_day") || $0.hasSuffix("_night") || $0.hasSuffix("_polartwilight") } ?? false
        let isDay = hasDayPart ? !info.night : (nowLocal.h >= 6 && nowLocal.h < 18)
        let nh = step.next1?.details
        func fin(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        let current = Current(
            timeMs: step.t,
            tempC: r1(d["air_temperature"]),
            feelsC: r1(fin(d["apparent_air_temperature"]) ?? d["air_temperature"]),
            humidity: fin(d["relative_humidity"]).map(jsRound),
            dewC: r1(d["dew_point_temperature"]),
            windMs: r1(d["wind_speed"]),
            windDir: fin(d["wind_from_direction"]).map(jsRound),
            pressureHpa: r1(d["air_pressure_at_sea_level"]),
            cloud: fin(d["cloud_area_fraction"]).map(jsRound),
            uv: isDay ? fin(d["ultraviolet_index_clear_sky"]).map(jsRound) : nil,
            precipNextHourMm: fin(nh?["precipitation_amount"]).flatMap { r1($0) },
            symbol: sym,
            isDay: isDay
        )

        // TODAY'S FORECAST: the next four six-hour periods on the place's wall clock, the first from now.
        struct Group { let key: String; let date: String; let block: Int; var steps: [Step] }
        var groups: [Group] = []
        var i = cur
        while i < series.count && groups.count <= 4 {
            let p = localParts(series[i].t, tz)
            let key = "\(p.key)|\(p.h / 6)"
            if var lastGroup = groups.last, lastGroup.key == key {
                lastGroup.steps.append(series[i])
                groups[groups.count - 1] = lastGroup
            } else {
                groups.append(Group(key: key, date: p.key, block: p.h / 6, steps: [series[i]]))
            }
            i += 1
        }
        let periods: [PeriodForecast] = groups.prefix(4).map { g in
            let mid = g.steps[(g.steps.count - 1) / 2]
            let md = mid.instant
            let winds = g.steps.compactMap { fin($0.instant["wind_speed"]) }
            let first = g.steps[0]
            let hourly = g.steps.allSatisfy { $0.next1 != nil }
            let precip = hourly ? g.steps.reduce(0) { $0 + stepPrecip($1) } : stepPrecip(first)
            return PeriodForecast(
                name: periodNames[g.block],
                day: g.date == nowLocal.key ? "TODAY" : "TOMORROW",
                startMs: first.t,
                tempC: r1(md["air_temperature"]),
                symbol: periodSymbol(first),
                precipMm: r1(precip),
                windMs: winds.isEmpty ? nil : r1(winds.reduce(0, +) / Double(winds.count)),
                windDir: fin(md["wind_from_direction"]).map(jsRound)
            )
        }

        // 5-DAY FORECAST: steps grouped by the place's local date.
        struct DateGroup { let key: String; let dow: Int; var steps: [(s: Step, h: Int)] }
        var order: [String] = []
        var byDate: [String: DateGroup] = [:]
        for j in cur..<series.count {
            let p = localParts(series[j].t, tz)
            if byDate[p.key] == nil { byDate[p.key] = DateGroup(key: p.key, dow: p.dow, steps: []); order.append(p.key) }
            byDate[p.key]!.steps.append((series[j], p.h))
        }
        // A date needs two steps (past the first three days MET sends one every six hours).
        let dates = order.compactMap { byDate[$0] }.filter { $0.steps.count >= 2 }
        // Today with under six hours left (from 6 PM) is not a day of the 5 when there is a sixth day to use.
        var start = 0
        if let firstDate = dates.first, firstDate.key == nowLocal.key, nowLocal.h >= 18, dates.count > 5 { start = 1 }
        let days: [DayForecast] = dates.dropFirst(start).prefix(5).map { g in
            var temps: [Double] = []
            var winds: [Double] = []
            var precip = 0.0
            var pick: (s: Step, h: Int)?
            for (s, h) in g.steps {
                if let v = fin(s.instant["air_temperature"]) { temps.append(v) }
                if let six = s.next6?.details {
                    if let v = fin(six["air_temperature_max"]) { temps.append(v) }
                    if let v = fin(six["air_temperature_min"]) { temps.append(v) }
                }
                if let v = fin(s.instant["wind_speed"]) { winds.append(v) }
                if s.next1 != nil {
                    precip += stepPrecip(s)
                } else if let six = s.next6, let v = fin(six.details["precipitation_amount"]) {
                    precip += v
                }
                if periodSymbol(s) != nil, pick == nil || abs(h - 13) < abs(pick!.h - 13) { pick = (s, h) }
            }
            let code = pick.flatMap { periodSymbol($0.s) }
            return DayForecast(
                date: g.key,
                label: g.key == nowLocal.key ? "TODAY" : dowNames[g.dow],
                highC: temps.isEmpty ? nil : r1(temps.max()),
                lowC: temps.isEmpty ? nil : r1(temps.min()),
                symbol: g.key == nowLocal.key ? code : (code.map(dayForm) ?? dayForm(nil)),
                precipMm: r1(precip),
                windMaxMs: winds.isEmpty ? nil : r1(winds.max())
            )
        }

        return Model(updatedMs: updatedMs, tz: tz, current: current, periods: periods, days: days)
    }

    // MARK: Radar

    struct RadarProvider: Equatable {
        let id: String
        let credit: String
        let layers: [String]
        let stepMinutes: Int
        let frames: Int
        let lagMinutes: Int
        let ignoreBands: [Int]
        let workspace: String

        func capabilitiesURL(_ layer: String) -> URL? {
            switch id {
            case "noaa": return URL(string: "\(WeatherEngine.noaaHost)/\(workspace)/\(layer)/ows?service=WMS&version=1.3.0&request=GetCapabilities")
            case "eccc": return URL(string: "\(WeatherEngine.ecccHost)?service=WMS&version=1.3.0&request=GetCapabilities&layer=\(layer)")
            default: return URL(string: "\(WeatherEngine.dwdHost)/Niederschlagsradar/wms?service=WMS&version=1.3.0&request=GetCapabilities")
            }
        }

        func mapURL(_ layer: String, bbox: [Double], width: Int, height: Int, time: String?) -> URL? {
            let box = bbox.map(WeatherEngine.jsNumber).joined(separator: ",")
            // Whole seconds: Environment Canada refuses "…:00.000Z" (NoMatch, "Expecting %Y-%m-%dT%H:%M:%SZ").
            let t = time.map { "&time=\(WeatherEngine.encodeURIComponent($0.replacingOccurrences(of: ".000Z", with: "Z")))" } ?? ""
            let tail = "&styles=&crs=CRS:84&bbox=\(box)&width=\(width)&height=\(height)&format=image/png&transparent=true\(t)"
            switch id {
            case "noaa": return URL(string: "\(WeatherEngine.noaaHost)/\(workspace)/\(layer)/ows?service=WMS&version=1.3.0&request=GetMap&layers=\(layer)\(tail)")
            case "eccc": return URL(string: "\(WeatherEngine.ecccHost)?service=WMS&version=1.3.0&request=GetMap&layers=\(layer)\(tail)")
            default: return URL(string: "\(WeatherEngine.dwdHost)/wms?service=WMS&version=1.3.0&request=GetMap&layers=dwd:\(layer)\(tail)")
            }
        }
    }

    static let noaaHost = "https://opengeo.ncep.noaa.gov/geoserver"
    static let ecccHost = "https://geo.weather.gc.ca/geomet"
    static let dwdHost = "https://maps.dwd.de/geoserver/dwd"

    static func noaaWorkspace(lat: Double, lon: Double) -> String {
        if lon >= 140 && lon <= 150 && lat >= 10 && lat <= 22 { return "guam" }
        if lat >= 15 && lat <= 20 && lon >= -68 && lon <= -63 { return "carib" }
        if lat >= 18 && lat <= 23 && lon >= -161 && lon <= -154 { return "hawaii" }
        if lat > 51 && (lon <= -129 || lon >= 170) { return "alaska" }
        return "conus"
    }

    /// The radar source for a place, or nil: the card says RADAR NOT AVAILABLE IN YOUR AREA.
    static func radarProvider(cc: String?, lat: Double, lon: Double) -> RadarProvider? {
        switch (cc ?? "").uppercased() {
        case "US":
            let ws = noaaWorkspace(lat: lat, lon: lon)
            return RadarProvider(id: "noaa", credit: "RADAR: NOAA NATIONAL WEATHER SERVICE", layers: ["\(ws)_bref_qcd"],
                                 stepMinutes: 10, frames: 8, lagMinutes: 0, ignoreBands: [], workspace: ws)
        case "CA":
            return RadarProvider(id: "eccc", credit: "DATA SOURCE: ENVIRONMENT AND CLIMATE CHANGE CANADA",
                                 layers: ["RADAR_1KM_RRAI", "RADAR_1KM_RSNO"], stepMinutes: 6, frames: 6, lagMinutes: 0,
                                 ignoreBands: [], workspace: "")
        case "DE":
            // DWD's style paints the radar coverage edge magenta, our EXTREME colour, so that band is dropped.
            return RadarProvider(id: "dwd", credit: "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben",
                                 layers: ["Niederschlagsradar"], stepMinutes: 10, frames: 8, lagMinutes: 10,
                                 ignoreBands: [4], workspace: "")
        default:
            return nil
        }
    }

    /// The map window: `spanLat` degrees tall, centred on the place, as wide as the picture needs so a degree
    /// of longitude is drawn cos(latitude) as wide as a degree of latitude. [minLon, minLat, maxLon, maxLat].
    static func radarBBox(lat: Double, lon: Double, aspect: Double, spanLat: Double?) -> [Double] {
        let span = spanLat ?? 6
        let spanLon = span * aspect / max(0.2, cos(lat * .pi / 180))
        func r(_ n: Double) -> Double { jsRound(n * 1000) / 1000 }
        return [r(lon - spanLon / 2), r(lat - span / 2), r(lon + spanLon / 2), r(lat + span / 2)]
    }

    /// The times inside a WMS time dimension: "a,b,c" or "start/end/PT6M". Newest last, as ISO strings with milliseconds.
    static func parseTimeDimension(_ xml: String?) -> [String] {
        let text = xml ?? ""
        guard let re = try? NSRegularExpression(pattern: "<Dimension[^>]*name=\"time\"[^>]*>([^<]*)<"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return [] }
        let body = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return [] }
        if body.contains("/") && !body.contains(",") {
            let parts = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let start = parseISO(parts.count > 0 ? parts[0] : nil)
            let end = parseISO(parts.count > 1 ? parts[1] : nil)
            var stepMs = 0.0
            if parts.count > 2,
               let dre = try? NSRegularExpression(pattern: "^PT(?:(\\d+)H)?(?:(\\d+)M)?$"),
               let dm = dre.firstMatch(in: parts[2], range: NSRange(parts[2].startIndex..., in: parts[2])) {
                func group(_ i: Int) -> Double {
                    guard let gr = Range(dm.range(at: i), in: parts[2]) else { return 0 }
                    return Double(parts[2][gr]) ?? 0
                }
                stepMs = (group(1) * 60 + group(2)) * 60000
            }
            guard let s = start, let e = end, stepMs > 0 else { return end.map { [isoString($0)] } ?? [] }
            var out: [String] = []
            var t = s
            while t <= e { out.append(isoString(t)); t += stepMs }
            return out
        }
        return body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { parseISO($0) }.map(isoString)
    }

    /// `count` frames ending at the newest time, about `stepMinutes` apart, oldest first. Times after `notAfterMs` are not used.
    static func pickFrameTimes(_ allTimes: [String], count: Int, stepMinutes: Int, notAfterMs: Double? = nil) -> [String] {
        let times = notAfterMs.map { cut in allTimes.filter { (parseISO($0) ?? .infinity) <= cut } } ?? allTimes
        guard let newest = times.last else { return [] }
        let ms = times.map { parseISO($0) ?? .nan }
        var out = [newest]
        var want = ms[ms.count - 1]
        let step = Double(stepMinutes) * 60000
        for _ in 1..<max(1, count) {
            want -= step
            var best = -1
            for i in ms.indices where best < 0 || abs(ms[i] - want) < abs(ms[best] - want) { best = i }
            if best >= 0, times[best] != out[0], abs(ms[best] - want) <= Double(stepMinutes) * 30000 { out.insert(times[best], at: 0) }
        }
        return out
    }

    /// One radar pixel, from the source's colours to our five bands: 0 (light) to 4 (extreme), or -1 for no echo.
    static func radarBand(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let mx = max(r, g, b), mn = min(r, g, b)
        if mx - mn < 28 { return -1 }
        let d = Double(mx - mn)
        var h: Double
        if mx == r { h = jsMod(Double(g - b) / d, 6) } else if mx == g { h = Double(b - r) / d + 2 } else { h = Double(r - g) / d + 4 }
        h = jsMod(h * 60 + 360, 360)
        if h >= 190 && h < 280 { return 0 }
        if h >= 90 && h < 190 { return 1 }
        if h >= 40 && h < 90 { return 2 }
        if h >= 12 && h < 40 { return 3 }
        if h >= 280 && h < 345 { return 4 }
        return 3
    }

    struct Band { let name: String; let rgb: UInt32 }
    static let radarBands: [Band] = [
        Band(name: "LIGHT", rgb: 0x00D4FF),
        Band(name: "MODERATE", rgb: 0xFFE500),
        Band(name: "HEAVY", rgb: 0xFFB020),
        Band(name: "SEVERE", rgb: 0xFF2244),
        Band(name: "EXTREME", rgb: 0xFF2DB4),
    ]

    static func encodeURIComponent(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Places

    struct Place: Equatable, Codable {
        var name: String
        var region: String
        var cc: String
        var lat: Double
        var lon: Double
        var tz: String
        var kind: String
        var code: String?
        /// What the result list shows.
        var label: String?
    }

    /// Lower case ASCII letters and digits, accents taken off: "Montréal" is "montreal".
    static func plain(_ s: String) -> String {
        let decomposed = s.decomposedStringWithCompatibilityMapping
        var out = ""
        for u in decomposed.unicodeScalars where !(0x300...0x36F).contains(u.value) {
            out.unicodeScalars.append(u)
        }
        return String(out.lowercased().unicodeScalars.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }.map(Character.init))
    }

    static func placeLabel(_ p: Place) -> String {
        [p.name, p.region, p.cc].filter { !$0.isEmpty }.joined(separator: ", ").uppercased()
    }

    /// The key a postcode is looked up by in that country's shards, or nil when the text cannot be one of its codes.
    static func postcodeLookup(cc: String, text: String) -> String? {
        let upper = text.uppercased()
        let kept = String(upper.unicodeScalars.filter { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == " " }.map(Character.init))
        let t = kept.trimmingCharacters(in: .whitespaces)
        let squashed = t.replacingOccurrences(of: " ", with: "")
        func matches(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        switch cc {
        case "US", "DE": return matches("^[0-9]{3,5}$", squashed) ? squashed : nil
        case "AU": return matches("^[0-9]{3,4}$", squashed) ? squashed : nil
        case "CA": return matches("^[A-Z][0-9][A-Z]", squashed) ? String(squashed.prefix(3)) : nil
        case "GB":
            guard matches("^[A-Z]{1,2}[0-9]", squashed) else { return nil }
            // A full postcode ends in digit-letter-letter: the outward part is what is before it.
            if let re = try? NSRegularExpression(pattern: "^([A-Z]{1,2}[0-9][A-Z0-9]?)[0-9][A-Z]{2}$"),
               let m = re.firstMatch(in: squashed, range: NSRange(squashed.startIndex..., in: squashed)),
               let r = Range(m.range(at: 1), in: squashed) {
                return String(squashed[r])
            }
            if t.contains(" ") { return t.split(whereSeparator: { $0 == " " }).first.map(String.init) }
            return squashed
        default: return nil
        }
    }

    /// A place read back from storage, or nil if it is not usable. Coordinates are kept at 2 decimals.
    static func normalizePlace(_ p: Place?) -> Place? {
        guard let p, p.lat.isFinite, p.lon.isFinite, abs(p.lat) <= 90, abs(p.lon) <= 180, !p.name.isEmpty else { return nil }
        return Place(name: String(p.name.prefix(80)), region: String(p.region.prefix(60)), cc: String(p.cc.uppercased().prefix(2)),
                     lat: round2(p.lat), lon: round2(p.lon), tz: validZone(p.tz) ? p.tz : "UTC",
                     kind: p.kind == "postcode" ? "postcode" : "city", code: p.code.map { String($0.prefix(8)) }, label: p.label)
    }

    // MARK: The relay

    static let relayURL = "https://www.nostalgex.app/api/weather"
    static let clientHeader = "X-Nostalgex-Client"

    /// The relay call for a place. Coordinates leave the device rounded to 2 decimals, about 1 km.
    static func forecastURL(base: String, lat: Double, lon: Double) -> String {
        "\(base)?lat=\(toFixed(round2(lat), 2))&lon=\(toFixed(round2(lon), 2))"
    }

    /// Whether to ask again: never before the document's own Expires, and not more than every `minMs` after the last answer.
    static func forecastDue(hasBody: Bool, savedMs: Double, expiresMs: Double?, nowMs: Double, minMs: Double = 30 * 60000) -> Bool {
        guard hasBody else { return true }
        if let e = expiresMs, e.isFinite, nowMs < e { return false }
        return nowMs - savedMs >= minMs
    }

    /// How old the forecast is, for the card: "UPDATED 2:18 PM", stale when it is over 6 hours old.
    static func forecastAge(updatedMs: Double?, nowMs: Double, tz: String) -> (text: String, stale: Bool) {
        guard let u = updatedMs, u.isFinite else { return ("", false) }
        return ("UPDATED \(fmtClock(u, tz))", nowMs - u > 6 * 3_600_000)
    }

    // MARK: The guide row and the info panel

    /// The line the info panel shows: "Cloudy, 6°C. Feels like 3°. High 7°, low 5°. Wind NNW 17 km/h."
    static func infoSummary(_ model: Model?, _ units: Units) -> String {
        guard let model else { return "" }
        let c = model.current
        func t(_ v: Double?) -> String { "\(fmtTemp(v, units))\u{00B0}" }
        let cond = symbolInfo(c.symbol).text
        var parts = ["\(cond.prefix(1))\(cond.dropFirst().lowercased()), \(t(c.tempC))\(units.rawValue).", "Feels like \(t(c.feelsC))."]
        if let first = model.days.first, first.highC != nil { parts.append("High \(t(first.highC)), low \(t(first.lowC)).") }
        if c.windMs != nil {
            parts.append("Wind \(compass(c.windDir)) \(fmtWind(c.windMs, units).lowercased()).".replacingOccurrences(of: "Wind  ", with: "Wind "))
        }
        return parts.joined(separator: " ")
    }
}

/// A place finder over the static GeoNames place files (built by `scripts/build-weather-data.mjs`, served
/// from nostalgex.app/weather/places/). `load(path)` returns the parsed JSON of a path under `weather/`
/// (for example "places/meta.json") as bytes, or nil when there is no such file.
actor WeatherPlaceIndex {
    typealias Loader = @Sendable (String) async -> Data?
    private let load: Loader
    private var cache: [String: Any] = [:]
    private var missing: Set<String> = []
    static let maxResults = 8

    init(load: @escaping Loader) { self.load = load }

    private func file(_ path: String) async -> Any? {
        if let hit = cache[path] { return hit }
        if missing.contains(path) { return nil }
        let value = await load(path).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        if let value { cache[path] = value } else { missing.insert(path) }
        return value
    }

    struct Result: Equatable {
        let places: [WeatherEngine.Place]
        let hint: String
    }

    func search(_ query: String) async -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Result(places: [], hint: "") }
        guard let meta = await file("places/meta.json") as? [String: Any] else {
            return Result(places: [], hint: "PLACE LIST NOT AVAILABLE")
        }
        let zones = meta["tz"] as? [String] ?? []
        var out: [WeatherEngine.Place] = []
        var seen: Set<String> = []
        func push(_ p: WeatherEngine.Place) {
            let k = "\(p.kind)|\(p.name)|\(p.region)|\(p.cc)|\(p.code ?? "")"
            guard !seen.contains(k), out.count < Self.maxResults else { return }
            seen.insert(k)
            var labelled = p
            if p.kind == "postcode" {
                labelled.label = "\(p.code ?? "") \(p.name), \([p.region, p.cc].filter { !$0.isEmpty }.joined(separator: ", "))".uppercased()
            } else {
                labelled.label = WeatherEngine.placeLabel(p)
            }
            out.append(labelled)
        }
        func zone(_ any: Any?) -> String {
            let i = (any as? NSNumber)?.intValue ?? -1
            return zones.indices.contains(i) ? zones[i] : "UTC"
        }
        func num(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? .nan }

        // A postcode, looked up in every country it could belong to. A whole code comes before longer ones that begin with it.
        var zips: [(place: WeatherEngine.Place, whole: Int)] = []
        for cc in meta["postcodes"] as? [String] ?? [] {
            guard let code = WeatherEngine.postcodeLookup(cc: cc, text: q) else { continue }
            guard let rows = await file("places/z/\(cc)/\(code.prefix(2)).json") as? [[Any]] else { continue }
            for row in rows where row.count >= 6 {
                let rowCode = "\(row[0])"
                guard rowCode.hasPrefix(code) else { continue }
                var name = "\(row[1])"
                if let paren = name.range(of: #"\s*\(.*$"#, options: .regularExpression) {
                    let trimmed = String(name[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { name = trimmed }
                }
                let place = WeatherEngine.Place(name: name, region: "\(row[2])", cc: cc, lat: num(row[3]), lon: num(row[4]),
                                                tz: zone(row[5]), kind: "postcode", code: rowCode, label: nil)
                zips.append((place, rowCode == code ? 0 : 1))
            }
        }
        for z in zips.enumerated().sorted(by: { ($0.element.whole, $0.offset) < ($1.element.whole, $1.offset) }) { push(z.element.place) }

        // A city: "toronto", or "springfield il" / "portland, or" with the state, province or country after it.
        var attempts: [(String, String)] = []
        if let comma = q.firstIndex(of: ","), comma > q.startIndex {
            attempts.append((String(q[..<comma]), String(q[q.index(after: comma)...]).trimmingCharacters(in: .whitespaces)))
        }
        attempts.append((q, ""))
        let words = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1 { attempts.append((words.dropLast().joined(separator: " "), words.last!)) }
        var hint = ""
        let split = meta["split"] as? [String] ?? []
        for (nameQ, qual) in attempts {
            let key = WeatherEngine.plain(nameQ)
            if key.count < 2 { continue }
            var shard = String(key.prefix(2))
            if split.contains(shard) {
                if key.count < 3 { hint = "KEEP TYPING"; continue }
                shard = String(key.prefix(3))
            }
            guard let rows = await file("places/c/\(shard).json") as? [[Any]] else { continue }
            let qualN = WeatherEngine.plain(qual)
            for row in rows where row.count >= 6 {
                guard WeatherEngine.plain("\(row[0])").hasPrefix(key) else { continue }
                if !qualN.isEmpty && !(WeatherEngine.plain("\(row[2])").hasPrefix(qualN) || WeatherEngine.plain("\(row[1])") == qualN) { continue }
                push(WeatherEngine.Place(name: "\(row[0])", region: "\(row[2])", cc: "\(row[1])", lat: num(row[3]), lon: num(row[4]),
                                         tz: zone(row[5]), kind: "city", code: nil, label: nil))
            }
            if out.contains(where: { $0.kind == "city" }) { break }
        }
        return Result(places: out, hint: out.isEmpty ? hint : "")
    }
}
