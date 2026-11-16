import Foundation
import Observation
import AVFoundation
import CoreGraphics
import ImageIO
import UIKit
import SwiftUI

/// What the guide row and the info panel show for CH 299, read by the schedule builder off the main
/// thread. The controller writes it when the place or the forecast changes.
enum WeatherGuideInfo {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _placeTitle = ""
    nonisolated(unsafe) private static var _summary = ""

    static var placeTitle: String { lock.lock(); defer { lock.unlock() }; return _placeTitle }
    static var summary: String { lock.lock(); defer { lock.unlock() }; return _summary }

    static func set(placeTitle: String, summary: String) {
        lock.lock(); defer { lock.unlock() }
        _placeTitle = placeTitle
        _summary = summary
    }
}

/// The weather channel's state (Trello I-016): the viewer's settings, the forecast, the radar frames and
/// the music. One instance for the app. Nothing is fetched unless the channel is on screen (MET Norway's
/// terms: an app must not fetch while it is not in use), except the one forecast asked for when a
/// location is picked in Settings.
@MainActor
@Observable
final class WeatherController {
    static let shared = WeatherController()

    // MARK: Settings (per Apple TV, never synced)

    static let placeKey = "nostalgex_weather_place"
    static let unitsKey = "nostalgex_weather_units"
    static let channelKey = "nostalgex_weather_channel"

    private(set) var place: WeatherEngine.Place?
    private(set) var unitsSetting: String = "auto"
    /// The channel's switch in Settings. On by default: it is in the guide until the viewer turns it off.
    private(set) var channelOn: Bool = true

    // MARK: Data

    enum Status: Equatable { case noplace, loading, error, ready }
    private(set) var model: WeatherEngine.Model?
    private(set) var status: Status = .noplace

    struct RadarFrame { let timeMs: Double; let image: CGImage }
    enum RadarStatus: Equatable { case none, loading, error, ready }
    private(set) var radarStatus: RadarStatus = .none
    private(set) var radarProvider: WeatherEngine.RadarProvider?
    private(set) var radarFrames: [RadarFrame] = []
    private(set) var basemap: WeatherBasemap.Prepared?

    @ObservationIgnored private var metData: Data?
    @ObservationIgnored private var metJSON: Any?
    @ObservationIgnored private var metKey = ""
    @ObservationIgnored private var savedMs: Double = 0
    @ObservationIgnored private var expiresMs: Double = 0
    @ObservationIgnored private var failedMs: Double = 0
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var lastBuildMs: Double = 0
    @ObservationIgnored private var lastCheckMs: Double = 0
    @ObservationIgnored private var radarKey = ""
    @ObservationIgnored private var radarLoadedMs: Double = 0
    @ObservationIgnored private var radarLoading = false
    @ObservationIgnored private var activeViews = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var music: AVAudioPlayer?
    @ObservationIgnored private var placeIndex: WeatherPlaceIndex?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var inForeground = true
    /// Set by the sleep timer: the music stays off until the channel is tuned again.
    @ObservationIgnored private var musicStoppedBySleep = false

    private init() {
        loadSettings()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWentToBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appCameToForeground() }
        })
    }

    // MARK: Addresses

    /// The site the relay and the place list are on. A DEBUG run can point it at a local copy with
    /// `-weatherBase http://<mac>:<port>` (the simulator walk); a release build always uses nostalgex.app.
    static var siteBase: String {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-weatherBase"), args.indices.contains(i + 1) { return args[i + 1] }
        #endif
        return "https://www.nostalgex.app"
    }
    static var relayURL: String { "\(siteBase)/api/weather" }

    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Nostalgex/\(version) tvOS https://nostalgex.app support@nostalgex.app"
    }

    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        return URLSession(configuration: config)
    }()

    // MARK: Settings

    private func loadSettings() {
        let d = AppDefaults.standard
        if let data = d.data(forKey: Self.placeKey),
           let p = try? JSONDecoder().decode(WeatherEngine.Place.self, from: data) {
            place = WeatherEngine.normalizePlace(p)
        }
        let u = d.string(forKey: Self.unitsKey)
        unitsSetting = (u == "F" || u == "C") ? u! : "auto"
        channelOn = d.object(forKey: Self.channelKey) == nil ? true : d.bool(forKey: Self.channelKey)
        #if DEBUG
        // `-uiTestWeatherPlace "Toronto|CA|ON|43.65|-79.38|America/Toronto"`: a place for the simulator walk, in memory
        // only (nothing is saved).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uiTestWeatherPlace"), args.indices.contains(i + 1) {
            let f = args[i + 1].split(separator: "|").map(String.init)
            if f.count == 6, let lat = Double(f[3]), let lon = Double(f[4]) {
                place = WeatherEngine.normalizePlace(.init(name: f[0], region: f[2], cc: f[1], lat: lat, lon: lon, tz: f[5],
                                                           kind: "city", code: nil, label: nil))
            }
        }
        #endif
        status = place == nil ? .noplace : .loading
        publishGuideInfo()
    }

    var units: WeatherEngine.Units { WeatherEngine.unitsFor(cc: place?.cc, setting: unitsSetting) }

    var placeTitle: String { place.map(WeatherEngine.placeLabel) ?? "" }

    func setUnits(_ u: String) {
        unitsSetting = (u == "F" || u == "C") ? u : "auto"
        AppDefaults.standard.set(unitsSetting, forKey: Self.unitsKey)
        publishGuideInfo()
    }

    /// AUTO, then °F, then °C, then AUTO.
    func cycleUnits() {
        setUnits(unitsSetting == "auto" ? "F" : unitsSetting == "F" ? "C" : "auto")
    }

    func setChannelOn(_ on: Bool) {
        channelOn = on
        AppDefaults.standard.set(on, forKey: Self.channelKey)
        if !on { stopMusic() }
    }

    func pick(_ p: WeatherEngine.Place) {
        guard let n = WeatherEngine.normalizePlace(p) else { return }
        place = n
        if let data = try? JSONEncoder().encode(n) { AppDefaults.standard.set(data, forKey: Self.placeKey) }
        resetData()
        status = .loading
        publishGuideInfo()
        Task { await ensureForecast(force: true) }
    }

    func clearPlace() {
        place = nil
        AppDefaults.standard.removeObject(forKey: Self.placeKey)
        resetData()
        status = .noplace
        Self.removeCachedForecast()
        publishGuideInfo()
    }

    private func resetData() {
        metData = nil; metJSON = nil; metKey = ""; savedMs = 0; expiresMs = 0; failedMs = 0; model = nil
        radarKey = ""; radarFrames = []; radarStatus = .none; radarProvider = nil; basemap = nil
    }

    private func publishGuideInfo() {
        let summary: String
        if place == nil {
            summary = "Set your location in Settings to see the forecast."
        } else if let model {
            summary = WeatherEngine.infoSummary(model, units)
        } else {
            summary = "Current conditions, today\u{2019}s forecast, the 5-day forecast and radar, in a loop."
        }
        WeatherGuideInfo.set(placeTitle: placeTitle, summary: summary)
    }

    // MARK: Places

    func search(_ text: String) async -> WeatherPlaceIndex.Result {
        if placeIndex == nil {
            let base = Self.siteBase
            let session = self.session
            placeIndex = WeatherPlaceIndex { path in
                guard let url = URL(string: "\(base)/weather/\(path)") else { return nil }
                guard let result = try? await session.data(from: url),
                      (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return result.0
            }
        }
        return await placeIndex!.search(text)
    }

    // MARK: On screen

    /// A weather view came on screen. The first one starts the loop and the music.
    func viewAppeared() {
        activeViews += 1
        guard activeViews == 1 else { return }
        musicStoppedBySleep = false
        startLoop()
        syncMusic()
    }

    func viewDisappeared() {
        activeViews = max(0, activeViews - 1)
        guard activeViews == 0 else { return }
        loopTask?.cancel()
        loopTask = nil
        syncMusic()
    }

    var isOnScreen: Bool { activeViews > 0 }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            // A small random wait so a room full of TVs does not ask at the same second.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 0...800)))
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func tick() async {
        guard inForeground, activeViews > 0 else { return }
        let now = Date().timeIntervalSince1970 * 1000
        if now - lastBuildMs > 60_000 { rebuildModel() }
        if now - lastCheckMs > 20_000 {
            lastCheckMs = now
            Task { await self.ensureForecast(force: false) }
        }
        // The radar frames load from the TODAY screen on, so they are there when the radar comes up.
        if WeatherEngine.screenAt(now).index >= 1 { Task { await self.ensureRadar() } }
    }

    private func appWentToBackground() {
        inForeground = false
        music?.pause()
    }

    private func appCameToForeground() {
        inForeground = true
        syncMusic()
    }

    // MARK: Music

    /// The bundled original loop (local-forecast.m4a), quietly under the screens while the channel is up.
    func syncMusic() {
        let shouldPlay = activeViews > 0 && inForeground && !musicStoppedBySleep && channelOn
        if shouldPlay {
            if music == nil, let url = Bundle.main.url(forResource: "local-forecast", withExtension: "m4a") {
                music = try? AVAudioPlayer(contentsOf: url)
                music?.numberOfLoops = -1
                music?.prepareToPlay()
            }
            if TestLaunchFlags.audioMuted { music?.volume = 0 }
            if music?.isPlaying == false { music?.play() }
        } else {
            music?.pause()
        }
    }

    /// The sleep timer ran out: the music stops with the video.
    func stopMusicForSleep() {
        musicStoppedBySleep = true
        syncMusic()
    }

    func stopMusic() { music?.pause() }

    // MARK: Forecast

    private static var cacheURL: URL? { LocalStore.rootDirectory?.appendingPathComponent("weather-forecast.json") }

    private struct CachedForecast: Codable {
        let key: String
        let savedMs: Double
        let expiresMs: Double
        let body: Data
    }

    private static func readCachedForecast(key: String) -> CachedForecast? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(CachedForecast.self, from: data), c.key == key else { return nil }
        return c
    }

    private static func removeCachedForecast() {
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    private static func placeKey(_ p: WeatherEngine.Place) -> String {
        "\(WeatherEngine.toFixed(p.lat, 2)),\(WeatherEngine.toFixed(p.lon, 2))"
    }

    private func rebuildModel() {
        lastBuildMs = Date().timeIntervalSince1970 * 1000
        guard let place, let metJSON else {
            model = nil
            publishGuideInfo()
            return
        }
        do {
            model = try WeatherEngine.buildModel(met: metJSON, tz: place.tz, nowMs: lastBuildMs)
            status = .ready
        } catch {
            // A document that ends before now: ask again at the next check.
            model = nil
            status = .error
            expiresMs = 0
        }
        publishGuideInfo()
    }

    func ensureForecast(force: Bool) async {
        guard let place else { status = .noplace; model = nil; return }
        let key = Self.placeKey(place)
        let now = Date().timeIntervalSince1970 * 1000
        if metKey != key {
            let saved = Self.readCachedForecast(key: key)
            metData = saved?.body
            metJSON = saved.flatMap { try? JSONSerialization.jsonObject(with: $0.body) }
            metKey = key
            savedMs = saved?.savedMs ?? 0
            expiresMs = saved?.expiresMs ?? 0
            model = nil
        }
        if !force, metJSON != nil,
           !WeatherEngine.forecastDue(hasBody: true, savedMs: savedMs, expiresMs: expiresMs, nowMs: now) {
            if model == nil { rebuildModel() }
            return
        }
        if loading || (!force && failedMs > 0 && now - failedMs < 60_000) {
            if model == nil { rebuildModel() }
            return
        }
        loading = true
        if metJSON == nil { status = .loading }
        defer { loading = false }
        do {
            guard let url = URL(string: WeatherEngine.forecastURL(base: Self.relayURL, lat: place.lat, lon: place.lon)) else { throw URLError(.badURL) }
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("tvos", forHTTPHeaderField: WeatherEngine.clientHeader)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let json = try JSONSerialization.jsonObject(with: data)
            guard !WeatherEngine.steps(fromJSON: json).steps.isEmpty else { throw URLError(.cannotParseResponse) }
            // The place may have changed while this was in flight.
            if key == metKey {
                metData = data
                metJSON = json
                savedMs = Date().timeIntervalSince1970 * 1000
                expiresMs = Self.expires(from: http) ?? (savedMs + 30 * 60_000)
                failedMs = 0
                if let cacheURL = Self.cacheURL,
                   let encoded = try? JSONEncoder().encode(CachedForecast(key: key, savedMs: savedMs, expiresMs: expiresMs, body: data)) {
                    try? encoded.write(to: cacheURL, options: .atomic)
                }
            }
        } catch {
            failedMs = Date().timeIntervalSince1970 * 1000
            if metJSON == nil { status = .error }
            print("[Plex90] WEATHER: forecast failed: \(error.localizedDescription)")
        }
        rebuildModel()
    }

    private static func expires(from http: HTTPURLResponse) -> Double? {
        guard let value = http.value(forHTTPHeaderField: "Expires") else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { $0.timeIntervalSince1970 * 1000 }
    }

    // MARK: Radar

    /// The map is the whole width inside the safe area and 700 tall, in the 1920 x 1080 picture.
    nonisolated static let mapRect = CGRect(x: 90, y: 172, width: 1920 - 180, height: 700)

    func ensureRadar() async {
        guard let place else { return }
        guard let provider = WeatherEngine.radarProvider(cc: place.cc, lat: place.lat, lon: place.lon) else {
            radarStatus = .none; radarProvider = nil; radarFrames = []; radarKey = ""
            return
        }
        let key = Self.placeKey(place)
        let now = Date().timeIntervalSince1970 * 1000
        if radarLoading { return }
        if radarKey == key && radarStatus == .ready && now - radarLoadedMs < 5 * 60_000 { return }
        if radarKey == key && radarStatus == .error && now - radarLoadedMs < 60_000 { return }
        radarLoading = true
        defer { radarLoading = false; radarLoadedMs = Date().timeIntervalSince1970 * 1000 }
        radarProvider = provider
        if radarKey != key { radarFrames = []; basemap = nil; radarStatus = .loading }
        radarKey = key
        let rect = Self.mapRect
        let bbox = WeatherEngine.radarBBox(lat: place.lat, lon: place.lon, aspect: rect.width / rect.height, spanLat: 5)
        if basemap == nil { basemap = await WeatherBasemap.prepare(bbox: bbox, map: rect) }
        // One pixel of the picture is 4 of the screen: chunky on purpose, and a quarter of the download.
        let w = Int((rect.width / 4).rounded()), h = Int((rect.height / 4).rounded())
        do {
            guard let capsURL = provider.capabilitiesURL(provider.layers[0]) else { throw URLError(.badURL) }
            let (capsData, capsResponse) = try await session.data(from: capsURL)
            guard (capsResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let stamps = WeatherEngine.pickFrameTimes(
                WeatherEngine.parseTimeDimension(String(decoding: capsData, as: UTF8.self)),
                count: provider.frames, stepMinutes: provider.stepMinutes,
                notAfterMs: Date().timeIntervalSince1970 * 1000 - Double(provider.lagMinutes) * 60_000)
            guard !stamps.isEmpty else { throw URLError(.zeroByteResource) }
            let session = self.session
            let frames = await withTaskGroup(of: (Int, RadarFrame?).self) { group -> [RadarFrame] in
                for (i, t) in stamps.enumerated() {
                    group.addTask {
                        var layers: [CGImage] = []
                        for layer in provider.layers {
                            guard let url = provider.mapURL(layer, bbox: bbox, width: w, height: h, time: t),
                                  let result = try? await session.data(from: url),
                                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                                  let image = WeatherRadarImage.recolored(png: result.0, width: w, height: h, ignoreBands: provider.ignoreBands)
                            else { continue }
                            layers.append(image)
                        }
                        guard let composed = WeatherRadarImage.compose(layers, width: w, height: h),
                              let ms = WeatherEngine.parseISO(t) else { return (i, nil) }
                        return (i, RadarFrame(timeMs: ms, image: composed))
                    }
                }
                var out: [(Int, RadarFrame)] = []
                for await (i, f) in group { if let f { out.append((i, f)) } }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if key == radarKey {
                radarFrames = frames
                radarStatus = frames.isEmpty ? .error : .ready
            }
        } catch {
            radarStatus = radarFrames.isEmpty ? .error : .ready
            print("[Plex90] WEATHER: radar failed: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// `-uiTestWeatherFixture`: a forecast and place for screenshots without a network. Simulator only.
    func installFixture(place p: WeatherEngine.Place, metJSON json: Any) {
        place = WeatherEngine.normalizePlace(p)
        metJSON = json
        metKey = place.map(Self.placeKey) ?? ""
        savedMs = Date().timeIntervalSince1970 * 1000
        expiresMs = savedMs + 3_600_000
        rebuildModel()
    }
    #endif
}

/// Radar pictures: decoded, recolored from the source's palette to our five bands, layers composed.
enum WeatherRadarImage {
    /// Recolors a radar PNG to our five bands (cyan, yellow, amber, red, pink). Anything that is not an echo becomes clear.
    static func recolored(png: Data, width: Int, height: Int, ignoreBands: [Int]) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpaceCreateDeviceRGB()
        let made: CGImage? = buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let p = raw.bindMemory(to: UInt8.self)
            let bands = WeatherEngine.radarBands.map { (UInt8(($0.rgb >> 16) & 0xFF), UInt8(($0.rgb >> 8) & 0xFF), UInt8($0.rgb & 0xFF)) }
            let outAlpha = 235
            var i = 0
            while i < p.count {
                let a = Int(p[i + 3])
                if a < 40 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0; i += 4; continue }
                // Back from premultiplied, so the colour reads as the source drew it.
                let r = min(255, Int(p[i]) * 255 / a), g = min(255, Int(p[i + 1]) * 255 / a), b = min(255, Int(p[i + 2]) * 255 / a)
                let band = WeatherEngine.radarBand(r, g, b)
                if band < 0 || ignoreBands.contains(band) { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0; i += 4; continue }
                let c = bands[band]
                p[i] = UInt8(Int(c.0) * outAlpha / 255)
                p[i + 1] = UInt8(Int(c.1) * outAlpha / 255)
                p[i + 2] = UInt8(Int(c.2) * outAlpha / 255)
                p[i + 3] = UInt8(outAlpha)
                i += 4
            }
            return ctx.makeImage()
        }
        return made
    }

    static func compose(_ layers: [CGImage], width: Int, height: Int) -> CGImage? {
        guard !layers.isEmpty else { return nil }
        if layers.count == 1 { return layers[0] }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return layers[0] }
        ctx.interpolationQuality = .none
        for l in layers { ctx.draw(l, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        return ctx.makeImage()
    }
}

/// The map under the radar: Natural Earth outlines (public domain), simplified into `weather-basemap.json`
/// by the web tuner's build script and shipped inside the app.
enum WeatherBasemap {
    struct Prepared {
        /// One path per layer, in the 1920 x 1080 picture's coordinates.
        let paths: [(layer: String, path: Path)]
        let cities: [(name: String, point: CGPoint)]
        let bbox: [Double]
        let map: CGRect

        func project(lon: Double, lat: Double) -> CGPoint {
            CGPoint(x: map.minX + (lon - bbox[0]) / (bbox[2] - bbox[0]) * map.width,
                    y: map.minY + (bbox[3] - lat) / (bbox[3] - bbox[1]) * map.height)
        }
    }

    nonisolated(unsafe) private static var raw: [String: Any]?
    private static let lock = NSLock()

    private static func load() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        if let raw { return raw }
        guard let url = Bundle.main.url(forResource: "weather-basemap", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        raw = json
        return json
    }

    static func prepare(bbox: [Double], map: CGRect) async -> Prepared? {
        await Task.detached(priority: .userInitiated) { () -> Prepared? in
            guard let base = load(), let layers = base["layers"] as? [String: Any] else { return nil }
            let unit = (base["unit"] as? NSNumber)?.doubleValue ?? 1000
            let minLon = bbox[0], minLat = bbox[1], maxLon = bbox[2], maxLat = bbox[3]
            let padLon = (maxLon - minLon) * 0.05, padLat = (maxLat - minLat) * 0.05
            func project(_ lon: Double, _ lat: Double) -> CGPoint {
                CGPoint(x: map.minX + (lon - minLon) / (maxLon - minLon) * map.width,
                        y: map.minY + (maxLat - lat) / (maxLat - minLat) * map.height)
            }
            var paths: [(String, Path)] = []
            for layer in ["lakes", "states", "borders", "coast"] {
                var path = Path()
                for flatAny in layers[layer] as? [[Any]] ?? [] {
                    let flat = flatAny.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                    guard flat.count >= 2 else { continue }
                    var x = flat[0], y = flat[1]
                    var pts: [CGPoint] = []
                    var inside = false
                    func push() {
                        let lo = x / unit, la = y / unit
                        pts.append(project(lo, la))
                        if lo >= minLon - padLon && lo <= maxLon + padLon && la >= minLat - padLat && la <= maxLat + padLat { inside = true }
                    }
                    push()
                    var i = 2
                    while i + 1 < flat.count { x += flat[i]; y += flat[i + 1]; push(); i += 2 }
                    if inside { path.addLines(pts) }
                }
                paths.append((layer, path))
            }
            var cities: [(String, CGPoint)] = []
            for c in base["cities"] as? [[Any]] ?? [] where c.count >= 3 {
                let la = (c[1] as? NSNumber)?.doubleValue ?? 0, lo = (c[2] as? NSNumber)?.doubleValue ?? 0
                if lo > minLon && lo < maxLon && la > minLat && la < maxLat { cities.append(("\(c[0])", project(lo, la))) }
            }
            return Prepared(paths: paths, cities: cities, bbox: bbox, map: map)
        }.value
    }
}
