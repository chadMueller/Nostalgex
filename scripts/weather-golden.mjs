#!/usr/bin/env node
/**
 * Writes scripts/weather-golden.json: the weather channel's shared test vectors, the way
 * scripts/*-golden.json are for the other engines. The Apple TV, Roku and Android ports run the
 * same inputs through their own code and must give the same answers.
 *
 *   node scripts/weather-golden.mjs <met-complete.json> --write
 *
 * <met-complete.json> is one real MET Norway `complete` answer (api.met.no, CC BY 4.0). The
 * document is trimmed to the fields the channel reads and stored in the golden file. The answers
 * are this engine's, read by eye once (the smoke test also checks them against the raw document);
 * after that the file holds every port to them.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import './nostalgex-weather.js'

const W = globalThis.NostalgexWeather
const out = fileURLToPath(new URL('./weather-golden.json', import.meta.url))

const KEEP = ['air_pressure_at_sea_level', 'air_temperature', 'apparent_air_temperature', 'cloud_area_fraction',
  'dew_point_temperature', 'relative_humidity', 'ultraviolet_index_clear_sky', 'wind_from_direction', 'wind_speed']
function trim(met) {
  const ts = met.properties.timeseries.map((s) => {
    const details = {}
    for (const k of KEEP) if (k in s.data.instant.details) details[k] = s.data.instant.details[k]
    const data = { instant: { details } }
    for (const k of ['next_1_hours', 'next_6_hours', 'next_12_hours']) if (s.data[k]) data[k] = s.data[k]
    return { time: s.time, data }
  })
  return { type: 'Feature', geometry: met.geometry, properties: { meta: { updated_at: met.properties.meta.updated_at, units: met.properties.meta.units }, timeseries: ts } }
}

export function buildGolden(metPath) {
  const met = trim(JSON.parse(readFileSync(metPath, 'utf8')))
  const toronto = { name: 'Toronto', region: 'ON', cc: 'CA', lat: 43.65, lon: -79.38, tz: 'America/Toronto', kind: 'city' }
  const buffalo = { name: 'Buffalo', region: 'NY', cc: 'US', lat: 42.89, lon: -78.88, tz: 'America/New_York', kind: 'city' }
  const cases = [
    { name: 'toronto, early afternoon', place: toronto, now: '2026-11-15T18:20:00Z', units: 'auto' },
    { name: 'toronto, 9:30 PM (the 5 days start tomorrow)', place: toronto, now: '2026-11-16T02:30:00Z', units: 'auto' },
    { name: 'buffalo, same document, fahrenheit', place: buffalo, now: '2026-11-15T18:20:00Z', units: 'auto' },
    { name: 'toronto asked for F', place: toronto, now: '2026-11-15T18:20:00Z', units: 'F' },
    { name: 'toronto, 3 days on (six-hourly steps)', place: toronto, now: '2026-11-18T14:00:00Z', units: 'auto' },
  ].map((c) => {
    const model = W.buildModel(met, c.place, Date.parse(c.now))
    const units = W.unitsFor(c.place, c.units)
    const cur = model.current
    return {
      ...c,
      expect: {
        units,
        model,
        text: {
          temp: W.fmtTemp(cur.tempC, units),
          feels: W.fmtTemp(cur.feelsC, units),
          wind: `${W.fmtWind(cur.windMs, units)} ${W.compass(cur.windDir)}`,
          pressure: W.fmtPressure(cur.pressureHpa, units),
          precipNextHour: W.fmtPrecip(cur.precipNextHourMm, units),
          condition: W.symbolInfo(cur.symbol).text,
          icon: W.symbolInfo(cur.symbol).icon,
          updated: W.fmtClock(model.updatedMs, model.tz),
          periods: model.periods.map((p) => `${p.name} ${p.day} ${W.fmtTemp(p.tempC, units)} ${W.symbolInfo(p.symbol).icon} ${W.fmtPrecip(p.precipMm, units)}`),
          days: model.days.map((d) => `${d.label} ${W.fmtTemp(d.highC, units)}/${W.fmtTemp(d.lowC, units)} ${W.symbolInfo(d.symbol).icon}`),
        },
      },
    }
  })

  const symbols = ['clearsky_day', 'clearsky_night', 'clearsky_polartwilight', 'fair_day', 'fair_night', 'partlycloudy_day', 'partlycloudy_night',
    'cloudy', 'fog', 'lightrain', 'rain', 'heavyrain', 'lightrainshowers_day', 'rainshowers_night', 'heavyrainshowers_day',
    'lightsleet', 'sleet', 'heavysleet', 'lightsleetshowers_day', 'sleetshowers_night', 'lightsnow', 'snow', 'heavysnow',
    'lightsnowshowers_day', 'snowshowers_night', 'heavysnowshowers_day', 'rainandthunder', 'heavyrainandthunder',
    'lightrainshowersandthunder_day', 'snowandthunder', 'lightsleetandthunder', 'somethingnew_day', '']
    .map((code) => ({ code, ...W.symbolInfo(code), day: W.dayForm(code) }))

  const units = [
    { cc: 'US', setting: 'auto' }, { cc: 'CA', setting: 'auto' }, { cc: 'GB', setting: 'auto' }, { cc: 'US', setting: 'C' }, { cc: 'DE', setting: 'F' },
  ].map((u) => ({ ...u, units: W.unitsFor({ cc: u.cc }, u.setting) }))
  const format = [
    { c: 0, ms: 0, hpa: 1013.25, mm: 0 }, { c: -0.4, ms: 4.2, hpa: 994.6, mm: 0.7 }, { c: 21.5, ms: 12.9, hpa: 1031, mm: 14.2 }, { c: -17.8, ms: 28, hpa: 960.2, mm: 2.54 },
  ].map((v) => ({
    ...v,
    F: { temp: W.fmtTemp(v.c, 'F'), wind: W.fmtWind(v.ms, 'F'), pressure: W.fmtPressure(v.hpa, 'F'), precip: W.fmtPrecip(v.mm, 'F') },
    C: { temp: W.fmtTemp(v.c, 'C'), wind: W.fmtWind(v.ms, 'C'), pressure: W.fmtPressure(v.hpa, 'C'), precip: W.fmtPrecip(v.mm, 'C') },
  }))
  const compass = [0, 11, 12, 90, 221.9, 359, 360].map((deg) => ({ deg, dir: W.compass(deg) }))

  const loop = { seconds: W.LOOP_SECONDS, screens: W.SCREENS.map((s) => ({ id: s.id, title: s.title, seconds: s.seconds })),
    at: [0, 14.9, 15, 44.9, 45, 59.9, 60, 64.9].map((s) => { const r = W.screenAt(s * 1000); return { s, id: r.screen.id, elapsed: r.elapsed } }) }

  const bands = [[100, 140, 190], [0, 200, 255], [80, 220, 60], [0, 160, 0], [250, 240, 40], [255, 150, 0], [230, 20, 20], [255, 0, 255], [150, 40, 200], [255, 255, 255], [128, 128, 128], [0, 0, 0]]
    .map(([r, g, b]) => ({ rgb: [r, g, b], band: W.radarBand(r, g, b) }))

  const frames = {
    times: ['2026-11-15T15:00:00Z', '2026-11-15T15:10:00Z', '2026-11-15T15:20:00Z', '2026-11-15T15:30:00Z', '2026-11-15T15:40:00Z', '2026-11-15T15:50:00Z', '2026-11-15T16:00:00Z'],
    pick: W.pickFrameTimes(['2026-11-15T15:00:00Z', '2026-11-15T15:10:00Z', '2026-11-15T15:20:00Z', '2026-11-15T15:30:00Z', '2026-11-15T15:40:00Z', '2026-11-15T15:50:00Z', '2026-11-15T16:00:00Z'], 4, 10),
    range: W.parseTimeDimension('<Dimension name="time" units="ISO8601" default="2026-11-15T17:24:00Z" nearestValue="0">2026-11-15T16:48:00Z/2026-11-15T17:24:00Z/PT6M</Dimension>'),
    list: W.parseTimeDimension('<Dimension name="time" default="x" units="ISO8601" nearestValue="1">2026-11-15T15:24:06.000Z,2026-11-15T15:25:58.000Z</Dimension>'),
  }
  const bbox = [{ lat: 43.65, lon: -79.38, aspect: 16 / 9, span: 6 }, { lat: 64.84, lon: -147.72, aspect: 16 / 9, span: 6 }].map((b) => ({ ...b, bbox: W.radarBBox(b.lat, b.lon, b.aspect, b.span) }))
  const providers = [
    { cc: 'US', lat: 40.71, lon: -74.0 }, { cc: 'US', lat: 64.84, lon: -147.72 }, { cc: 'US', lat: 21.3, lon: -157.86 }, { cc: 'US', lat: 18.4, lon: -66.1 },
    { cc: 'US', lat: 13.47, lon: 144.75 }, { cc: 'CA', lat: 43.65, lon: -79.38 }, { cc: 'GB', lat: 51.5, lon: -0.13 }, { cc: 'DE', lat: 52.5, lon: 13.4 },
  ].map((p) => { const pr = W.radarProvider(p); return { ...p, provider: pr && pr.id, layers: pr && pr.layers, credit: pr && pr.credit, frames: pr && pr.frames, stepMinutes: pr && pr.stepMinutes } })
  const postcode = [['US', '90210'], ['US', '902'], ['US', '9021'], ['DE', '10115'], ['AU', '2000'], ['CA', 'M5V 3L9'], ['CA', 'm5v'], ['GB', 'SW1A 1AA'], ['GB', 'SW1A1AA'], ['GB', 'sw1a'], ['GB', 'EC1'], ['GB', '90210'], ['US', 'toronto']]
    .map(([cc, text]) => ({ cc, text, key: W.postcodeLookup(cc, text) }))

  return { version: 1, about: 'Weather channel vectors (I-016). Written by scripts/weather-golden.mjs. Every port must match them.',
    met, cases, symbols, units, format, compass, loop, bands, frames, bbox, providers, postcode }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const src = process.argv[2]
  if (!src || !process.argv.includes('--write')) { console.error('usage: weather-golden.mjs <met-complete.json> --write'); process.exit(2) }
  writeFileSync(out, JSON.stringify(buildGolden(src), null, 1) + '\n')
  console.log(`wrote ${out}`)
}
