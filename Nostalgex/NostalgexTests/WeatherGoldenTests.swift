import XCTest
@testable import Nostalgex

/// `scripts/weather-golden.json` is the weather channel's shared test vectors (Trello I-016), written by the
/// web tuner's engine (`scripts/weather-golden.mjs`) and read by this test, the web tuner's smoke test and the
/// Roku and Android ports. The Apple TV's `WeatherEngine` must give the same answers.
final class WeatherGoldenTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func golden() throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent("scripts/weather-golden.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func num(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber else { return nil }
        return n.doubleValue
    }

    private func assertNum(_ actual: Double?, _ expected: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = num(expected)
        if e == nil || expected is NSNull {
            XCTAssertNil(actual, what, file: file, line: line)
        } else {
            XCTAssertEqual(actual ?? .nan, e!, accuracy: 1e-9, what, file: file, line: line)
        }
    }

    private func assertStr(_ actual: String?, _ expected: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        if expected == nil || expected is NSNull {
            XCTAssertNil(actual, what, file: file, line: line)
        } else {
            XCTAssertEqual(actual, expected as? String, what, file: file, line: line)
        }
    }

    func testForecastCasesMatchTheWebTuner() throws {
        let g = try golden()
        let met = g["met"]
        let cases = try XCTUnwrap(g["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let place = try XCTUnwrap(c["place"] as? [String: Any])
            let now = try XCTUnwrap(WeatherEngine.parseISO(c["now"] as? String))
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let units = WeatherEngine.unitsFor(cc: place["cc"] as? String, setting: c["units"] as? String ?? "auto")
            XCTAssertEqual(units.rawValue, expect["units"] as? String, name)

            let model = try WeatherEngine.buildModel(met: met, tz: place["tz"] as? String, nowMs: now)
            let em = try XCTUnwrap(expect["model"] as? [String: Any])
            assertNum(model.updatedMs, em["updatedMs"], "\(name) updatedMs")
            XCTAssertEqual(model.tz, em["tz"] as? String, name)

            let ec = try XCTUnwrap(em["current"] as? [String: Any])
            let cur = model.current
            assertNum(cur.timeMs, ec["timeMs"], "\(name) current.timeMs")
            assertNum(cur.tempC, ec["tempC"], "\(name) current.tempC")
            assertNum(cur.feelsC, ec["feelsC"], "\(name) current.feelsC")
            assertNum(cur.humidity, ec["humidity"], "\(name) current.humidity")
            assertNum(cur.dewC, ec["dewC"], "\(name) current.dewC")
            assertNum(cur.windMs, ec["windMs"], "\(name) current.windMs")
            assertNum(cur.windDir, ec["windDir"], "\(name) current.windDir")
            assertNum(cur.pressureHpa, ec["pressureHpa"], "\(name) current.pressureHpa")
            assertNum(cur.cloud, ec["cloud"], "\(name) current.cloud")
            assertNum(cur.uv, ec["uv"], "\(name) current.uv")
            assertNum(cur.precipNextHourMm, ec["precipNextHourMm"], "\(name) current.precipNextHourMm")
            assertStr(cur.symbol, ec["symbol"], "\(name) current.symbol")
            XCTAssertEqual(cur.isDay, ec["isDay"] as? Bool, "\(name) current.isDay")

            let ep = try XCTUnwrap(em["periods"] as? [[String: Any]])
            XCTAssertEqual(model.periods.count, ep.count, "\(name) periods")
            for (p, e) in zip(model.periods, ep) {
                XCTAssertEqual(p.name, e["name"] as? String, name)
                XCTAssertEqual(p.day, e["day"] as? String, name)
                assertNum(p.startMs, e["startMs"], "\(name) period.startMs")
                assertNum(p.tempC, e["tempC"], "\(name) period.tempC")
                assertStr(p.symbol, e["symbol"], "\(name) period.symbol")
                assertNum(p.precipMm, e["precipMm"], "\(name) period.precipMm")
                assertNum(p.windMs, e["windMs"], "\(name) period.windMs")
                assertNum(p.windDir, e["windDir"], "\(name) period.windDir")
            }

            let ed = try XCTUnwrap(em["days"] as? [[String: Any]])
            XCTAssertEqual(model.days.count, ed.count, "\(name) days")
            for (d, e) in zip(model.days, ed) {
                XCTAssertEqual(d.date, e["date"] as? String, name)
                XCTAssertEqual(d.label, e["label"] as? String, name)
                assertNum(d.highC, e["highC"], "\(name) \(d.date) highC")
                assertNum(d.lowC, e["lowC"], "\(name) \(d.date) lowC")
                assertStr(d.symbol, e["symbol"], "\(name) \(d.date) symbol")
                assertNum(d.precipMm, e["precipMm"], "\(name) \(d.date) precipMm")
                assertNum(d.windMaxMs, e["windMaxMs"], "\(name) \(d.date) windMaxMs")
            }

            // What the screens print.
            let et = try XCTUnwrap(expect["text"] as? [String: Any])
            XCTAssertEqual(WeatherEngine.fmtTemp(cur.tempC, units), et["temp"] as? String, name)
            XCTAssertEqual(WeatherEngine.fmtTemp(cur.feelsC, units), et["feels"] as? String, name)
            XCTAssertEqual("\(WeatherEngine.fmtWind(cur.windMs, units)) \(WeatherEngine.compass(cur.windDir))", et["wind"] as? String, name)
            XCTAssertEqual(WeatherEngine.fmtPressure(cur.pressureHpa, units), et["pressure"] as? String, name)
            XCTAssertEqual(WeatherEngine.fmtPrecip(cur.precipNextHourMm, units), et["precipNextHour"] as? String, name)
            XCTAssertEqual(WeatherEngine.symbolInfo(cur.symbol).text, et["condition"] as? String, name)
            XCTAssertEqual(WeatherEngine.symbolInfo(cur.symbol).icon, et["icon"] as? String, name)
            XCTAssertEqual(WeatherEngine.fmtClock(model.updatedMs ?? 0, model.tz), et["updated"] as? String, name)
            let periods = model.periods.map {
                "\($0.name) \($0.day) \(WeatherEngine.fmtTemp($0.tempC, units)) \(WeatherEngine.symbolInfo($0.symbol).icon) \(WeatherEngine.fmtPrecip($0.precipMm, units))"
            }
            XCTAssertEqual(periods, et["periods"] as? [String], name)
            let days = model.days.map {
                "\($0.label) \(WeatherEngine.fmtTemp($0.highC, units))/\(WeatherEngine.fmtTemp($0.lowC, units)) \(WeatherEngine.symbolInfo($0.symbol).icon)"
            }
            XCTAssertEqual(days, et["days"] as? [String], name)
        }
    }

    func testAForecastThatEndsBeforeNowIsEmpty() throws {
        let g = try golden()
        XCTAssertThrowsError(try WeatherEngine.buildModel(met: g["met"], tz: "America/Toronto",
                                                          nowMs: WeatherEngine.parseISO("2030-01-01T00:00:00Z")!))
        XCTAssertThrowsError(try WeatherEngine.buildModel(met: [String: Any](), tz: "UTC", nowMs: 0))
    }

    func testSymbolsUnitsFormatsAndCompass() throws {
        let g = try golden()
        for s in try XCTUnwrap(g["symbols"] as? [[String: Any]]) {
            let code = s["code"] as? String ?? ""
            let info = WeatherEngine.symbolInfo(code)
            XCTAssertEqual(info.icon, s["icon"] as? String, code)
            XCTAssertEqual(info.text, s["text"] as? String, code)
            XCTAssertEqual(info.night, s["night"] as? Bool, code)
            XCTAssertEqual(WeatherEngine.dayForm(code), s["day"] as? String, code)
        }
        for u in try XCTUnwrap(g["units"] as? [[String: Any]]) {
            XCTAssertEqual(WeatherEngine.unitsFor(cc: u["cc"] as? String, setting: u["setting"] as? String ?? "auto").rawValue,
                           u["units"] as? String)
        }
        for f in try XCTUnwrap(g["format"] as? [[String: Any]]) {
            for units in [WeatherEngine.Units.F, .C] {
                let e = try XCTUnwrap(f[units.rawValue] as? [String: String])
                XCTAssertEqual(WeatherEngine.fmtTemp(num(f["c"]), units), e["temp"], "temp \(f)")
                XCTAssertEqual(WeatherEngine.fmtWind(num(f["ms"]), units), e["wind"], "wind \(f)")
                XCTAssertEqual(WeatherEngine.fmtPressure(num(f["hpa"]), units), e["pressure"], "pressure \(f)")
                XCTAssertEqual(WeatherEngine.fmtPrecip(num(f["mm"]), units), e["precip"], "precip \(f)")
            }
        }
        for c in try XCTUnwrap(g["compass"] as? [[String: Any]]) {
            XCTAssertEqual(WeatherEngine.compass(num(c["deg"])), c["dir"] as? String, "\(c)")
        }
    }

    func testTheLoop() throws {
        let g = try golden()
        let loop = try XCTUnwrap(g["loop"] as? [String: Any])
        XCTAssertEqual(WeatherEngine.loopSeconds, num(loop["seconds"]))
        let screens = try XCTUnwrap(loop["screens"] as? [[String: Any]])
        XCTAssertEqual(WeatherEngine.screens.map(\.id), screens.map { $0["id"] as? String ?? "" })
        XCTAssertEqual(WeatherEngine.screens.map(\.title), screens.map { $0["title"] as? String ?? "" })
        XCTAssertEqual(WeatherEngine.screens.map(\.seconds), screens.map { num($0["seconds"]) ?? 0 })
        for a in try XCTUnwrap(loop["at"] as? [[String: Any]]) {
            let at = WeatherEngine.screenAt((num(a["s"]) ?? 0) * 1000)
            XCTAssertEqual(at.screen.id, a["id"] as? String, "\(a)")
            XCTAssertEqual(at.elapsed, num(a["elapsed"]) ?? -1, accuracy: 1e-6, "\(a)")
        }
    }

    func testRadarBandsFramesWindowAndProviders() throws {
        let g = try golden()
        for b in try XCTUnwrap(g["bands"] as? [[String: Any]]) {
            let rgb = try XCTUnwrap(b["rgb"] as? [Int])
            XCTAssertEqual(WeatherEngine.radarBand(rgb[0], rgb[1], rgb[2]), b["band"] as? Int, "\(rgb)")
        }
        let frames = try XCTUnwrap(g["frames"] as? [String: Any])
        let times = try XCTUnwrap(frames["times"] as? [String])
        XCTAssertEqual(WeatherEngine.pickFrameTimes(times, count: 4, stepMinutes: 10), frames["pick"] as? [String])
        XCTAssertEqual(WeatherEngine.pickFrameTimes(times, count: 3, stepMinutes: 10,
                                                    notAfterMs: WeatherEngine.parseISO("2026-11-15T15:35:00Z")),
                       frames["pickNotAfter"] as? [String])
        XCTAssertEqual(WeatherEngine.parseTimeDimension(
            "<Dimension name=\"time\" units=\"ISO8601\" default=\"2026-11-15T17:24:00Z\" nearestValue=\"0\">2026-11-15T16:48:00Z/2026-11-15T17:24:00Z/PT6M</Dimension>"),
            frames["range"] as? [String])
        XCTAssertEqual(WeatherEngine.parseTimeDimension(
            "<Dimension name=\"time\" default=\"x\" units=\"ISO8601\" nearestValue=\"1\">2026-11-15T15:24:06.000Z,2026-11-15T15:25:58.000Z</Dimension>"),
            frames["list"] as? [String])

        for b in try XCTUnwrap(g["bbox"] as? [[String: Any]]) {
            let box = WeatherEngine.radarBBox(lat: num(b["lat"])!, lon: num(b["lon"])!, aspect: num(b["aspect"])!, spanLat: num(b["span"]))
            let expected = try XCTUnwrap(b["bbox"] as? [Double])
            for (a, e) in zip(box, expected) { XCTAssertEqual(a, e, accuracy: 1e-9, "\(b)") }
        }

        for p in try XCTUnwrap(g["providers"] as? [[String: Any]]) {
            let pr = WeatherEngine.radarProvider(cc: p["cc"] as? String, lat: num(p["lat"])!, lon: num(p["lon"])!)
            assertStr(pr?.id, p["provider"], "\(p)")
            if let pr {
                XCTAssertEqual(pr.layers, p["layers"] as? [String], "\(p)")
                XCTAssertEqual(pr.credit, p["credit"] as? String, "\(p)")
                XCTAssertEqual(pr.frames, p["frames"] as? Int, "\(p)")
                XCTAssertEqual(pr.stepMinutes, p["stepMinutes"] as? Int, "\(p)")
                XCTAssertEqual(pr.lagMinutes, p["lagMinutes"] as? Int, "\(p)")
                XCTAssertEqual(pr.ignoreBands, p["ignoreBands"] as? [Int], "\(p)")
            }
        }
    }

    func testPostcodeKeys() throws {
        let g = try golden()
        for p in try XCTUnwrap(g["postcode"] as? [[String: Any]]) {
            let key = WeatherEngine.postcodeLookup(cc: p["cc"] as? String ?? "", text: p["text"] as? String ?? "")
            assertStr(key, p["key"], "\(p)")
        }
    }

    /// The place finder over a small stand-in for the GeoNames files: a postcode, a city, a city with its state,
    /// a whole code before the longer ones that begin with it, and the two-letter shard that needs a third.
    func testPlaceLookup() async throws {
        let files: [String: Any] = [
            "places/meta.json": ["tz": ["America/Toronto", "America/Los_Angeles", "America/Chicago", "Australia/Sydney"],
                                 "postcodes": ["US", "AU", "CA"], "split": ["sa"]],
            "places/c/to.json": [["Toronto", "CA", "ON", 43.65, -79.38, 0], ["Tokyo", "JP", "Tokyo", 35.69, 139.69, 0]],
            "places/c/sp.json": [["Springfield", "US", "IL", 39.8, -89.64, 2], ["Springfield", "US", "MO", 37.22, -93.3, 2]],
            "places/z/US/90.json": [["90210", "Beverly Hills", "CA", 34.09, -118.41, 1]],
            "places/z/US/20.json": [["20001", "Washington", "DC", 38.91, -77.02, 2]],
            "places/z/AU/20.json": [["2000", "Sydney (Haymarket / The Rocks)", "NSW", -33.87, 151.21, 3]],
            "places/z/CA/M5.json": [["M5V", "Downtown Toronto (CN Tower / King and Spadina)", "ON", 43.64, -79.39, 0]],
        ]
        let encoded = files.mapValues { try? JSONSerialization.data(withJSONObject: $0) }
        let index = WeatherPlaceIndex { path in encoded[path] ?? nil }

        let zip = await index.search("90210")
        XCTAssertEqual(zip.places.first?.label, "90210 BEVERLY HILLS, CA, US")
        XCTAssertEqual(zip.places.first?.tz, "America/Los_Angeles")

        let whole = await index.search("2000")
        XCTAssertEqual(whole.places.map { $0.code ?? "" }, ["2000", "20001"])
        XCTAssertEqual(whole.places.first?.name, "Sydney")

        let ca = await index.search("m5v 3l9")
        XCTAssertEqual(ca.places.first?.label, "M5V DOWNTOWN TORONTO, ON, CA")

        let city = await index.search("toronto")
        XCTAssertEqual(city.places.map(\.label), ["TORONTO, ON, CA"])

        let state = await index.search("springfield mo")
        XCTAssertEqual(state.places.map(\.label), ["SPRINGFIELD, MO, US"])
        let comma = await index.search("Springfield, IL")
        XCTAssertEqual(comma.places.map(\.label), ["SPRINGFIELD, IL, US"])

        let short = await index.search("sa")
        XCTAssertEqual(short.hint, "KEEP TYPING")

        let none = WeatherPlaceIndex { _ in nil }
        let missing = await none.search("toronto")
        XCTAssertEqual(missing.hint, "PLACE LIST NOT AVAILABLE")
    }

    func testTheRelayCallAndItsTiming() {
        XCTAssertEqual(WeatherEngine.forecastURL(base: WeatherEngine.relayURL, lat: 43.6532, lon: -79.3832),
                       "https://www.nostalgex.app/api/weather?lat=43.65&lon=-79.38")
        XCTAssertTrue(WeatherEngine.forecastDue(hasBody: false, savedMs: 0, expiresMs: nil, nowMs: 0))
        XCTAssertFalse(WeatherEngine.forecastDue(hasBody: true, savedMs: 0, expiresMs: 60 * 60000, nowMs: 45 * 60000))
        XCTAssertTrue(WeatherEngine.forecastDue(hasBody: true, savedMs: 0, expiresMs: 20 * 60000, nowMs: 31 * 60000))
        XCTAssertFalse(WeatherEngine.forecastDue(hasBody: true, savedMs: 0, expiresMs: 20 * 60000, nowMs: 25 * 60000))
        let place = WeatherEngine.normalizePlace(.init(name: "Toronto", region: "ON", cc: "ca", lat: 43.6532, lon: -79.3832,
                                                       tz: "Nowhere/Zone", kind: "city", code: nil, label: nil))
        XCTAssertEqual(place?.lat, 43.65)
        XCTAssertEqual(place?.cc, "CA")
        XCTAssertEqual(place?.tz, "UTC")
    }
}
