#!/usr/bin/env node
/**
 * Builds the weather channel's two static data sets into public/weather/:
 *
 *   places/   the place list the viewer types into (Settings > WEATHER > LOCATION), from GeoNames.
 *   basemap.json   the drawn coastlines, lakes and borders under the radar, from Natural Earth.
 *
 *   node scripts/build-weather-data.mjs --src <dir with the downloads> [--out public/weather]
 *
 * <dir> holds, unzipped or not as downloaded:
 *   cities5000.zip, admin1CodesASCII.txt     https://download.geonames.org/export/dump/   (CC BY 4.0)
 *   <CC>.zip for each postcode country       https://download.geonames.org/export/zip/    (CC BY 4.0)
 *   ne_50m_coastline.geojson, ne_50m_lakes.geojson, ne_50m_admin_0_boundary_lines_land.geojson,
 *   ne_50m_admin_1_states_provinces_lines.geojson   github.com/nvkelso/natural-earth-vector   (public domain)
 *
 * The output is committed, so a normal build never touches the network. Rebuild a couple of times a year.
 *
 * FORMAT (the Swift, Roku and Android ports read the same files)
 *
 *   places/meta.json    { version, built, tz: [IANA names], split: [two-letter keys held as three-letter shards],
 *                         postcodes: [country codes with a postcode shard set] }
 *   places/c/<key>.json cities: the first letters of the plain-ASCII name, lower case, spaces and marks dropped.
 *                         Key is 2 letters, or 3 when the 2-letter key is listed in meta.split. A row is
 *                         [name, country, region, lat, lon, tzIndex], most people first.
 *   places/z/<CC>/<key>.json   postcodes: the first 2 letters or digits of the code. A row is
 *                         [code, place, region, lat, lon, tzIndex]. GB and CA rows hold only the outward part
 *                         (SW1A, M5V): GeoNames' full UK postcodes carry Royal Mail data, so we do not ship them.
 *   basemap.json        { v, unit: 1000, layers: { coast, lakes, borders, states }: [polyline], cities: [[name,lat,lon]] }
 *                         A polyline is a flat list of integers: the first point (lon, lat in 1/1000 degree), then
 *                         the steps to each next point.
 *
 * Latitude and longitude are rounded to 2 decimals (about 1 km): the forecast call is rounded the same way.
 */
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, rmSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

const args = process.argv.slice(2)
const flag = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt }
const SRC = flag('--src')
const OUT = resolve(flag('--out', 'public/weather'))
if (!SRC) { console.error('usage: build-weather-data.mjs --src <download dir> [--out public/weather]'); process.exit(2) }

const POSTCODE_COUNTRIES = ['US', 'CA', 'GB', 'AU', 'DE']
const CA_PROVINCE = { '01': 'AB', '02': 'BC', '03': 'MB', '04': 'NB', '05': 'NL', '07': 'NS', '08': 'ON', '09': 'PE', '10': 'QC', '11': 'SK', '12': 'YT', '13': 'NT', '14': 'NU' }
const AU_STATE = { '01': 'ACT', '02': 'NSW', '03': 'NT', '04': 'QLD', '05': 'SA', '06': 'TAS', '07': 'VIC', '08': 'WA' }
const SHARD_SPLIT_BYTES = 40_000

const r2 = (n) => Math.round(Number(n) * 100) / 100
const plain = (s) => String(s).normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '')

function unzipText(zip, member) {
  return execFileSync('unzip', ['-p', zip, member], { maxBuffer: 512 * 1024 * 1024 }).toString('utf8')
}

// ── Places ──────────────────────────────────────────────────────────────────
const admin1 = new Map()
for (const line of readFileSync(join(SRC, 'admin1CodesASCII.txt'), 'utf8').split('\n')) {
  const [code, name] = line.split('\t')
  if (code && name) admin1.set(code, name)
}
function regionFor(cc, a1) {
  if (cc === 'US') return a1
  if (cc === 'CA') return CA_PROVINCE[a1] || ''
  if (cc === 'AU') return AU_STATE[a1] || ''
  return admin1.get(`${cc}.${a1}`) || ''
}

const tzList = []
const tzIndex = new Map()
const tzId = (name) => {
  if (!tzIndex.has(name)) { tzIndex.set(name, tzList.length); tzList.push(name) }
  return tzIndex.get(name)
}

const cityRows = []   // { ascii, row, pop }
const bigCities = []  // for the radar map labels
for (const line of unzipText(join(SRC, 'cities5000.zip'), 'cities5000.txt').split('\n')) {
  if (!line) continue
  const f = line.split('\t')
  // 1 name, 2 asciiname, 4 lat, 5 lon, 8 country, 10 admin1, 14 population, 17 timezone
  const [, name, ascii, , lat, lon, , , cc, , a1, , , , pop, , , tz] = f
  const key = plain(ascii || name)
  if (key.length < 2) continue
  cityRows.push({ key, pop: Number(pop) || 0, cc, tz, lat: Number(lat), lon: Number(lon),
    row: [name, cc, regionFor(cc, a1), r2(lat), r2(lon), tzId(tz)] })
  if (['US', 'CA', 'MX', 'BS', 'CU', 'DE', 'AT', 'CH', 'NL', 'BE', 'LU', 'FR', 'PL', 'CZ', 'DK'].includes(cc) && Number(pop) >= 150000) bigCities.push([name, r2(lat), r2(lon), Number(pop)])
}
cityRows.sort((a, b) => b.pop - a.pop)

// Spatial index of cities, so a postcode takes the time zone of the nearest city in its country.
const cell = (lat, lon) => `${Math.floor(lat)}:${Math.floor(lon)}`
const grid = new Map()
for (const c of cityRows) {
  const k = cell(c.lat, c.lon)
  if (!grid.has(k)) grid.set(k, [])
  grid.get(k).push(c)
}
function nearestTz(cc, lat, lon) {
  for (let ring = 0; ring <= 8; ring++) {
    let best = null, bestD = Infinity
    for (let dy = -ring; dy <= ring; dy++) for (let dx = -ring; dx <= ring; dx++) {
      if (Math.max(Math.abs(dx), Math.abs(dy)) !== ring) continue
      for (const c of grid.get(`${Math.floor(lat) + dy}:${Math.floor(lon) + dx}`) || []) {
        if (c.cc !== cc) continue
        const d = (c.lat - lat) ** 2 + ((c.lon - lon) * Math.cos(lat * Math.PI / 180)) ** 2
        if (d < bestD) { bestD = d; best = c }
      }
    }
    if (best) return tzId(best.tz)
  }
  // No city of that country nearby (a remote island): the nearest of any country.
  let best = null, bestD = Infinity
  for (const c of cityRows) {
    const d = (c.lat - lat) ** 2 + (c.lon - lon) ** 2
    if (d < bestD) { bestD = d; best = c }
  }
  return tzId(best.tz)
}

rmSync(OUT, { recursive: true, force: true })
mkdirSync(join(OUT, 'places', 'c'), { recursive: true })

// City shards: two letters, split to three where the two-letter file is too big to fetch on a TV.
const by2 = new Map()
for (const c of cityRows) {
  const k = c.key.slice(0, 2)
  if (!by2.has(k)) by2.set(k, [])
  by2.get(k).push(c)
}
const split = []
let cityFiles = 0
for (const [k, list] of by2) {
  const bytes = JSON.stringify(list.map((c) => c.row)).length
  if (bytes > SHARD_SPLIT_BYTES) {
    split.push(k)
    const by3 = new Map()
    for (const c of list) {
      const k3 = c.key.length >= 3 ? c.key.slice(0, 3) : c.key + '_'
      if (!by3.has(k3)) by3.set(k3, [])
      by3.get(k3).push(c)
    }
    for (const [k3, l3] of by3) { writeFileSync(join(OUT, 'places', 'c', `${k3}.json`), JSON.stringify(l3.map((c) => c.row))); cityFiles++ }
  } else {
    writeFileSync(join(OUT, 'places', 'c', `${k}.json`), JSON.stringify(list.map((c) => c.row)))
    cityFiles++
  }
}

// Postcode shards.
let zipRows = 0
const zipCountries = []
for (const cc of POSTCODE_COUNTRIES) {
  const zip = join(SRC, `${cc}.zip`)
  if (!existsSync(zip)) { console.warn(`no ${cc}.zip, skipped`); continue }
  const shards = new Map()
  const seen = new Set()
  for (const line of unzipText(zip, `${cc}.txt`).split('\n')) {
    if (!line) continue
    const f = line.split('\t')
    const [, code, place, a1name, a1code, , , , , lat, lon] = f
    if (!code || !lat) continue
    const norm = code.toUpperCase().replace(/\s+/g, '')
    const outward = (cc === 'GB' || cc === 'CA') ? norm.slice(0, cc === 'CA' ? 3 : (norm.length > 4 ? norm.length - 3 : norm.length)) : norm
    const dedupe = `${outward}|${place}`
    if (seen.has(dedupe)) continue
    seen.add(dedupe)
    const region = (cc === 'US' || cc === 'CA' || cc === 'AU') ? a1code : a1name
    const row = [outward, place, region, r2(lat), r2(lon), nearestTz(cc, Number(lat), Number(lon))]
    const k = outward.slice(0, 2)
    if (!shards.has(k)) shards.set(k, [])
    shards.get(k).push(row)
    zipRows++
  }
  mkdirSync(join(OUT, 'places', 'z', cc), { recursive: true })
  for (const [k, rows] of shards) writeFileSync(join(OUT, 'places', 'z', cc, `${k}.json`), JSON.stringify(rows))
  zipCountries.push(cc)
}

writeFileSync(join(OUT, 'places', 'meta.json'), JSON.stringify({
  version: 1,
  built: new Date().toISOString().slice(0, 10),
  tz: tzList,
  split: split.sort(),
  postcodes: zipCountries,
}))

// ── Basemap ─────────────────────────────────────────────────────────────────
// Only where there is radar is drawn: NOAA covers the United States, Alaska, Hawaii, the Caribbean and Guam;
// Environment Canada covers Canada; DWD covers Germany.
const REGIONS = [[-180, 5, -50, 85], [140, 10, 150, 22], [0, 44, 26, 58]]   // [minLon, minLat, maxLon, maxLat]: the Americas, Guam, Germany and its neighbours
const inRegion = (lon, lat) => REGIONS.some(([a, b, c, d]) => lon >= a && lon <= c && lat >= b && lat <= d)
const UNIT = 1000
const TOLERANCE = 0.003   // degrees, about 300 m

function simplify(pts, tol) {
  if (pts.length < 3) return pts
  const keep = new Uint8Array(pts.length)
  keep[0] = keep[pts.length - 1] = 1
  const stack = [[0, pts.length - 1]]
  while (stack.length) {
    const [a, b] = stack.pop()
    let max = 0, idx = -1
    const [ax, ay] = pts[a], [bx, by] = pts[b]
    const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
    for (let i = a + 1; i < b; i++) {
      const [px, py] = pts[i]
      let d
      if (len2 === 0) d = Math.hypot(px - ax, py - ay)
      else {
        const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
        d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy))
      }
      if (d > max) { max = d; idx = i }
    }
    if (max > tol) { keep[idx] = 1; stack.push([a, idx], [idx, b]) }
  }
  return pts.filter((_, i) => keep[i])
}

/** Cut a line into the runs that lie inside the drawn regions, so Siberia and Europe are not shipped. */
function runsInRegion(pts) {
  const runs = []
  let cur = []
  for (const p of pts) {
    if (inRegion(p[0], p[1])) cur.push(p)
    else { if (cur.length > 1) runs.push(cur); cur = [] }
  }
  if (cur.length > 1) runs.push(cur)
  return runs
}

function encode(pts) {
  const q = pts.map(([lon, lat]) => [Math.round(lon * UNIT), Math.round(lat * UNIT)])
  const out = [q[0][0], q[0][1]]
  let last = q[0]
  for (let i = 1; i < q.length; i++) {
    if (q[i][0] === last[0] && q[i][1] === last[1]) continue
    out.push(q[i][0] - last[0], q[i][1] - last[1])
    last = q[i]
  }
  return out
}

function layerFrom(file, { rings = false } = {}) {
  const gj = JSON.parse(readFileSync(join(SRC, file), 'utf8'))
  const lines = []
  const add = (coords) => {
    for (const run of runsInRegion(coords)) {
      const s = simplify(run, TOLERANCE)
      if (s.length > 1) lines.push(encode(s))
    }
  }
  for (const f of gj.features) {
    const g = f.geometry
    if (!g) continue
    if (g.type === 'LineString') add(g.coordinates)
    else if (g.type === 'MultiLineString') g.coordinates.forEach(add)
    else if (rings && g.type === 'Polygon') add(g.coordinates[0])
    else if (rings && g.type === 'MultiPolygon') g.coordinates.forEach((p) => add(p[0]))
  }
  return lines
}

const layers = {
  coast: layerFrom('ne_50m_coastline.geojson'),
  lakes: layerFrom('ne_50m_lakes.geojson', { rings: true }),
  borders: layerFrom('ne_50m_admin_0_boundary_lines_land.geojson'),
  states: layerFrom('ne_50m_admin_1_states_provinces_lines.geojson'),
}
bigCities.sort((a, b) => b[3] - a[3])
writeFileSync(join(OUT, 'basemap.json'), JSON.stringify({
  v: 1, unit: UNIT, layers, cities: bigCities.slice(0, 600).map(([n, la, lo]) => [n, la, lo]),
}))

// ── Report ──────────────────────────────────────────────────────────────────
function dirBytes(dir) {
  let total = 0, files = 0
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) { const r = dirBytes(p); total += r.total; files += r.files } else { total += statSync(p).size; files++ }
  }
  return { total, files }
}
const kb = (n) => `${Math.round(n / 1024)} KB`
console.log(`cities: ${cityRows.length} places in ${cityFiles} shards, ${split.length} two-letter keys split to three`)
console.log(`postcodes: ${zipRows} rows in ${zipCountries.join(' ')}`)
console.log(`places: ${dirBytes(join(OUT, 'places')).files} files, ${kb(dirBytes(join(OUT, 'places')).total)}`)
console.log(`basemap: ${kb(statSync(join(OUT, 'basemap.json')).size)}`)
