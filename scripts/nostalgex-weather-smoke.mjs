#!/usr/bin/env node
/**
 * The weather channel's engine (scripts/nostalgex-weather.js) against its shared vectors
 * (scripts/weather-golden.json, which the Apple TV, Roku and Android ports read too), against the raw
 * MET document by hand, and against the real place files in public/weather/. Also holds the channel's
 * rules in place: its number and id clash with nothing, the credits are on screen, the relay logs nothing,
 * and no real weather channel's name or look is borrowed.
 * Run: `npm run test:weather`.
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import "./nostalgex-weather.js";

const W = globalThis.NostalgexWeather;
const root = fileURLToPath(new URL("../", import.meta.url));
const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const golden = JSON.parse(read("scripts/weather-golden.json"));
const failures = [];
let passed = 0;
async function check(label, fn) {
  try { await fn(); passed += 1; } catch (e) { failures.push(`${label}: ${e.message.split("\n").slice(0, 6).join(" | ")}`); }
}

// ── 1. The shared vectors ──
for (const c of golden.cases) {
  await check(`golden case: ${c.name}`, () => {
    const model = W.buildModel(golden.met, c.place, Date.parse(c.now));
    assert.deepEqual(JSON.parse(JSON.stringify(model)), c.expect.model);
    assert.equal(W.unitsFor(c.place, c.units), c.expect.units);
  });
}
await check("golden: every derived table still matches the engine", () => {
  const again = {
    symbols: golden.symbols.map(({ code }) => ({ code, ...W.symbolInfo(code), day: W.dayForm(code) })),
    units: golden.units.map((u) => ({ cc: u.cc, setting: u.setting, units: W.unitsFor({ cc: u.cc }, u.setting) })),
    compass: golden.compass.map(({ deg }) => ({ deg, dir: W.compass(deg) })),
    bands: golden.bands.map(({ rgb }) => ({ rgb, band: W.radarBand(...rgb) })),
    postcode: golden.postcode.map(({ cc, text }) => ({ cc, text, key: W.postcodeLookup(cc, text) })),
  };
  assert.deepEqual(again.symbols, golden.symbols);
  assert.deepEqual(again.units, golden.units);
  assert.deepEqual(again.compass, golden.compass);
  assert.deepEqual(again.bands, golden.bands);
  assert.deepEqual(again.postcode, golden.postcode);
  for (const v of golden.format) {
    for (const u of ["F", "C"]) {
      assert.deepEqual({ temp: W.fmtTemp(v.c, u), wind: W.fmtWind(v.ms, u), pressure: W.fmtPressure(v.hpa, u), precip: W.fmtPrecip(v.mm, u) }, v[u]);
    }
  }
  for (const a of golden.loop.at) {
    const r = W.screenAt(a.s * 1000);
    assert.equal(r.screen.id, a.id);
    assert.ok(Math.abs(r.elapsed - a.elapsed) < 1e-9);
  }
  assert.deepEqual(W.pickFrameTimes(golden.frames.times, 4, 10), golden.frames.pick);
  assert.deepEqual(W.pickFrameTimes(golden.frames.times, 3, 10, Date.parse('2026-11-15T15:35:00Z')), golden.frames.pickNotAfter);
  for (const b of golden.bbox) assert.deepEqual(W.radarBBox(b.lat, b.lon, b.aspect, b.span), b.bbox);
  for (const p of golden.providers) {
    const pr = W.radarProvider({ cc: p.cc, lat: p.lat, lon: p.lon });
    assert.equal(pr ? pr.id : null, p.provider);
    if (pr) { assert.deepEqual(pr.layers, p.layers); assert.equal(pr.credit, p.credit); }
  }
  assert.equal(W.LOOP_SECONDS, golden.loop.seconds);
  assert.deepEqual(W.SCREENS.map((s) => ({ id: s.id, title: s.title, seconds: s.seconds })), golden.loop.screens);
});

// ── 2. The raw document, read by hand ──
const series = golden.met.properties.timeseries;
const TORONTO = { name: "Toronto", cc: "CA", lat: 43.65, lon: -79.38, tz: "America/Toronto" };
await check("current conditions are the step the clock is in", () => {
  const now = Date.parse("2026-11-15T18:20:00Z");
  const m = W.buildModel(golden.met, TORONTO, now);
  const raw = series.find((s) => s.time === "2026-11-15T18:00:00Z").data;
  assert.equal(m.current.tempC, raw.instant.details.air_temperature);
  assert.equal(m.current.windMs, raw.instant.details.wind_speed);
  assert.equal(m.current.symbol, raw.next_1_hours.summary.symbol_code);
  assert.equal(m.current.humidity, Math.round(raw.instant.details.relative_humidity));
  assert.equal(m.updatedMs, Date.parse(golden.met.properties.meta.updated_at));
});
await check("today's forecast: four consecutive six-hour periods on the place's wall clock", () => {
  for (const now of ["2026-11-15T18:20:00Z", "2026-11-16T02:30:00Z", "2026-11-17T09:05:00Z", "2026-11-18T14:00:00Z"]) {
    const m = W.buildModel(golden.met, TORONTO, Date.parse(now));
    assert.equal(m.periods.length, 4);
    m.periods.forEach((p, i) => {
      const lp = W.localParts(p.startMs, TORONTO.tz);
      // From the first on, a period starts in its own six-hour block (MET's steps are hourly for 2.5 days, then every 6 hours UTC).
      if (i > 0) assert.equal(Math.floor(lp.h / 6), ["OVERNIGHT", "MORNING", "AFTERNOON", "EVENING"].indexOf(p.name), `period ${i} (${p.name}) starts at ${lp.h}`);
      if (i > 0) assert.ok(p.startMs > m.periods[i - 1].startMs);
      assert.ok(p.symbol, "a symbol");
    });
    const cycle = ["OVERNIGHT", "MORNING", "AFTERNOON", "EVENING"];
    const at = cycle.indexOf(m.periods[0].name);
    assert.deepEqual(m.periods.map((p) => p.name), [0, 1, 2, 3].map((i) => cycle[(at + i) % 4]));
    assert.equal(m.periods[0].day, "TODAY");
  }
});
await check("5-day forecast: dates in order, high at or above low, first day is today", () => {
  const m = W.buildModel(golden.met, TORONTO, Date.parse("2026-11-15T18:20:00Z"));
  assert.equal(m.days.length, 5);
  assert.equal(m.days[0].label, "TODAY");
  assert.deepEqual(m.days.map((d) => d.date), ["2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19"]);
  for (const d of m.days) assert.ok(d.highC >= d.lowC, `${d.date} high ${d.highC} low ${d.lowC}`);
  // Nov 16 by hand: the extremes of the day's instants and six-hour maxima and minima.
  const temps = [];
  for (const s of series) {
    if (W.localParts(Date.parse(s.time), TORONTO.tz).key !== "2026-11-16") continue;
    temps.push(s.data.instant.details.air_temperature);
    if (s.data.next_6_hours) temps.push(s.data.next_6_hours.details.air_temperature_max, s.data.next_6_hours.details.air_temperature_min);
  }
  assert.equal(m.days[1].highC, Math.round(Math.max(...temps) * 10) / 10);
  assert.equal(m.days[1].lowC, Math.round(Math.min(...temps) * 10) / 10);
  assert.ok(!/_night$/.test(m.days[1].symbol), "no moon on a later day's icon");
});
await check("after 6 PM the 5 days start tomorrow", () => {
  const m = W.buildModel(golden.met, TORONTO, Date.parse("2026-11-16T02:30:00Z"));
  assert.equal(m.days[0].date, "2026-11-16");
  assert.equal(m.days.length, 5);
});
await check("local dates use the place's zone, not UTC", () => {
  // 02:30Z on the 16th is still the 15th in Toronto (9:30 PM).
  assert.equal(W.localParts(Date.parse("2026-11-16T02:30:00Z"), "America/Toronto").key, "2026-11-15");
  assert.equal(W.localParts(Date.parse("2026-11-16T02:30:00Z"), "Asia/Kolkata").h, 8);
  assert.equal(W.fmtClock(Date.parse("2026-11-15T18:05:00Z"), "America/Toronto"), "1:05 PM");
  assert.equal(W.fmtClock(Date.parse("2026-11-15T05:00:00Z"), "America/Toronto"), "12:00 AM");
});
await check("an old document throws EMPTY, a bad zone falls back to UTC", () => {
  assert.throws(() => W.buildModel(golden.met, TORONTO, Date.parse("2027-01-01T00:00:00Z")), (e) => e.code === "EMPTY");
  assert.throws(() => W.buildModel({}, TORONTO, Date.now()), (e) => e.code === "EMPTY");
  const m = W.buildModel(golden.met, { ...TORONTO, tz: "Not/AZone" }, Date.parse("2026-11-15T18:20:00Z"));
  assert.equal(m.tz, "UTC");
});
await check("a step with nothing but its instant still draws", () => {
  const thin = { properties: { meta: { updated_at: "2026-11-15T12:00:00Z" }, timeseries: [
    { time: "2026-11-15T18:00:00Z", data: { instant: { details: { air_temperature: 1.25 } } } },
    { time: "2026-11-15T19:00:00Z", data: { instant: { details: { air_temperature: 0.5 } } } },
  ] } };
  const m = W.buildModel(thin, TORONTO, Date.parse("2026-11-15T18:10:00Z"));
  assert.equal(m.current.tempC, 1.3);
  assert.equal(m.current.humidity, null);
  assert.equal(W.fmtTemp(m.current.humidity, "C"), "--");
  assert.equal(W.symbolInfo(m.current.symbol).icon, "cloud");
});
await check("units: F in the US, C elsewhere, a setting wins", () => {
  assert.equal(W.unitsFor({ cc: "US" }, "auto"), "F");
  assert.equal(W.unitsFor({ cc: "us" }, "auto"), "F");
  assert.equal(W.unitsFor({ cc: "CA" }, "auto"), "C");
  assert.equal(W.unitsFor(null, "auto"), "C");
  assert.equal(W.unitsFor({ cc: "US" }, "C"), "C");
  assert.equal(W.unitsFor({ cc: "DE" }, "F"), "F");
  assert.equal(W.fmtTemp(-0.4, "C"), "0");
  assert.equal(W.fmtTemp(100, "F"), "212");
  assert.equal(W.fmtTemp(null, "F"), "--");
});

// ── 3. Radar rules ──
await check("radar: United States on NOAA, Canada on Environment Canada, Germany on DWD, nowhere else yet", () => {
  assert.equal(W.radarProvider({ cc: "US", lat: 40, lon: -74 }).id, "noaa");
  assert.equal(W.radarProvider({ cc: "CA", lat: 43, lon: -79 }).id, "eccc");
  for (const cc of ["GB", "AU", "FR", "MX", ""]) assert.equal(W.radarProvider({ cc, lat: 50, lon: 0 }), null, cc);
  assert.equal(W.radarProvider(null), null);
  const url = W.radarProvider({ cc: "US", lat: 40, lon: -74 }).mapUrl("conus_bref_qcd", [-80, 37, -68, 43], 480, 270, "2026-11-15T17:00:00Z");
  assert.ok(url.startsWith("https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows?"));
  assert.ok(url.includes("crs=CRS:84") && url.includes("bbox=-80,37,-68,43") && url.includes("time=2026-11-15T17%3A00%3A00Z"));
  assert.ok(W.radarProvider({ cc: "CA", lat: 43, lon: -79 }).mapUrl("RADAR_1KM_RRAI", [1, 2, 3, 4], 10, 10).startsWith("https://geo.weather.gc.ca/geomet?"));
  assert.equal(W.radarProvider({ cc: "CA", lat: 43, lon: -79 }).credit, "DATA SOURCE: ENVIRONMENT AND CLIMATE CHANGE CANADA");
  const de = W.radarProvider({ cc: "DE", lat: 52.5, lon: 13.4 });
  assert.equal(de.id, "dwd");
  assert.equal(de.credit, "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben", "DWD's own wording for changed data");
  assert.deepEqual([de.layers, de.stepMinutes, de.frames, de.lagMinutes, de.ignoreBands], [["Niederschlagsradar"], 10, 8, 10, [4]]);
  assert.ok(de.capabilitiesUrl().startsWith("https://maps.dwd.de/geoserver/dwd/Niederschlagsradar/wms?"), "the one layer's capabilities, not the whole server's (983 KB)");
  const u = de.mapUrl("Niederschlagsradar", [5, 50, 15, 55], 435, 175, "2026-11-15T17:00:00.000Z");
  assert.ok(u.includes("time=2026-11-15T17%3A00%3A00Z") && !u.includes(".000"), "a WMS TIME has whole seconds");
  const ca = W.radarProvider({ cc: "CA", lat: 43, lon: -79 }).mapUrl("RADAR_1KM_RRAI", [1, 2, 3, 4], 10, 10, "2026-11-15T17:00:00.000Z");
  assert.ok(ca.includes("time=2026-11-15T17%3A00%3A00Z") && !ca.includes(".000"), "Environment Canada rejects a fraction of a second in TIME");
  const us = W.radarProvider({ cc: "US", lat: 40, lon: -74 }).mapUrl("conus_bref_qcd", [-80, 37, -68, 43], 480, 270, "2026-11-15T17:00:00.000Z");
  assert.ok(us.includes("time=2026-11-15T17%3A00%3A00Z") && !us.includes(".000"));
  assert.ok(u.startsWith("https://maps.dwd.de/geoserver/dwd/wms?") && u.includes("layers=dwd:Niederschlagsradar") && u.includes("crs=CRS:84") && u.includes("bbox=5,50,15,55"));
});
await check("radar map window: a degree of longitude is drawn cos(lat) as wide", () => {
  for (const lat of [10, 43.65, 64.84]) {
    const b = W.radarBBox(lat, -100, 16 / 9, 6);
    const lonSpan = b[2] - b[0], latSpan = b[3] - b[1];
    const pxPerDegLon = 1920 / lonSpan, pxPerDegLat = 1080 / latSpan;
    assert.ok(Math.abs(pxPerDegLon / pxPerDegLat - Math.cos(lat * Math.PI / 180)) < 0.01, `lat ${lat}`);
    assert.ok(Math.abs((b[1] + b[3]) / 2 - lat) < 0.001);
  }
});
await check("WMS time dimensions: a range and a list", () => {
  assert.equal(W.parseTimeDimension('<Dimension name="time" units="ISO8601" default="x">2026-11-15T16:48:00Z/2026-11-15T17:24:00Z/PT6M</Dimension>').length, 7);
  assert.deepEqual(W.parseTimeDimension("<foo/>"), []);
  assert.deepEqual(W.parseTimeDimension(""), []);
  assert.deepEqual(W.pickFrameTimes([], 8, 10), []);
});

// ── 4. The place list, from the real files ──
const placeRoot = fileURLToPath(new URL("../public/weather/", import.meta.url));
const idx = W.createPlaceIndex({ load: async (p) => (existsSync(placeRoot + p) ? JSON.parse(readFileSync(placeRoot + p, "utf8")) : null) });
const first = async (q) => (await idx.search(q)).places[0];
await check("place files exist and are consistent", () => {
  const meta = JSON.parse(readFileSync(placeRoot + "places/meta.json", "utf8"));
  assert.ok(meta.tz.length > 300);
  for (const k of meta.split) assert.ok(!existsSync(placeRoot + `places/c/${k}.json`), `${k} is split, so it has no 2-letter file`);
  for (const cc of meta.postcodes) assert.ok(existsSync(placeRoot + `places/z/${cc}`));
  for (const z of meta.tz) assert.ok(W.validZone(z), z);
  assert.ok(existsSync(placeRoot + "basemap.json"));
});
await check("search: a city, most people first", async () => {
  const p = await first("toronto");
  assert.deepEqual([p.name, p.region, p.cc, p.tz, p.lat, p.lon], ["Toronto", "ON", "CA", "America/Toronto", 43.65, -79.38]);
  assert.equal((await first("new york")).cc, "US");
  assert.equal((await first("london")).cc, "GB");
  assert.equal((await first("sydney")).tz, "Australia/Sydney");
});
await check("search: accents and spacing", async () => {
  assert.equal((await first("zurich")).cc, "CH");
  assert.equal((await first("Zürich")).cc, "CH");
  assert.equal((await first("  TORONTO ")).name, "Toronto");
});
await check("search: a state or province after the name", async () => {
  assert.deepEqual([(await first("springfield il")).region, (await first("portland, or")).region], ["IL", "OR"]);
});
await check("search: postcodes in each country", async () => {
  const us = await first("90210"); assert.deepEqual([us.name, us.region, us.cc, us.kind, us.tz], ["Beverly Hills", "CA", "US", "postcode", "America/Los_Angeles"]);
  const ca = await first("M5V 3L9"); assert.deepEqual([ca.code, ca.cc, ca.tz], ["M5V", "CA", "America/Toronto"]);
  const gb = await first("SW1A 1AA"); assert.deepEqual([gb.code, gb.tz], ["SW1A", "Europe/London"]);
  const au = (await idx.search("2000")).places.find((p) => p.cc === "AU"); assert.ok(au && /sydney/i.test(au.name), "AU 2000 is Sydney");
  const de = (await idx.search("10115")).places.find((p) => p.cc === "DE"); assert.ok(de && /berlin/i.test(de.name));
  assert.ok(!/\(/.test(ca.name), "no landmarks in a postcode's name");
});
await check("search: a too-short key asks for more, a miss is empty", async () => {
  const r = await idx.search("ma"); assert.equal(r.places.length, 0); assert.equal(r.hint, "KEEP TYPING");
  assert.equal((await idx.search("zzzzqq")).places.length, 0);
  assert.equal((await idx.search("")).places.length, 0);
  assert.ok((await idx.search("mad")).places.length > 0);
});
await check("search: at most 36, no repeats", async () => {
  const r = (await idx.search("san")).places;
  assert.ok(r.length > 8 && r.length <= 36, `${r.length} matches`);
  assert.equal(new Set(r.map((p) => p.label)).size, r.length);
});

// ── 4b. A place list that fails to load is not remembered (the Apple TV's WeatherPlaceSearchTests, ported) ──
const fakeMeta = { tz: ["UTC"], postcodes: ["US"], split: [] };
const fakeCodes = (n) => Array.from({ length: n }, (_, i) => [`902${String(i + 10)}`, `Place ${i}`, "CA", 34.1, -118.4, 0]);
/** A loader over a map of path -> data, counting each path's calls; `fail(path, n)` says whether call n (from 1) throws. */
function fakeLoader(files, fail = () => false) {
  const calls = new Map();
  return {
    calls,
    load: async (path) => {
      const n = (calls.get(path) || 0) + 1;
      calls.set(path, n);
      if (fail(path, n)) throw new Error("offline");
      return Object.hasOwn(files, path) ? files[path] : null;
    },
  };
}
await check("place list: a load that fails once succeeds on the next search", async () => {
  const io = fakeLoader({ "places/meta.json": fakeMeta, "places/z/US/90.json": fakeCodes(3) }, (path, n) => path === "places/meta.json" && n === 1);
  const index = W.createPlaceIndex(io);
  const first = await index.search("90210");
  assert.equal(first.places.length, 0);
  assert.equal(first.hint, "PLACE LIST NOT AVAILABLE");
  const second = await index.search("90210");
  assert.equal(second.places.length, 1, "the second search asks again and finds it");
  assert.equal(io.calls.get("places/meta.json"), 2);
});
await check("place list: a shard that fails once is asked again, a shard that is a 404 is asked once", async () => {
  const io = fakeLoader({ "places/meta.json": fakeMeta, "places/z/US/90.json": fakeCodes(3) }, (path, n) => path === "places/z/US/90.json" && n === 1);
  const index = W.createPlaceIndex(io);
  assert.equal((await index.search("90210")).places.length, 0);
  assert.equal((await index.search("90210")).places.length, 1);
  assert.equal(io.calls.get("places/z/US/90.json"), 2);
  assert.equal((await index.search("55555")).places.length, 0);
  assert.equal((await index.search("55555")).places.length, 0);
  assert.equal(io.calls.get("places/z/US/55.json"), 1, "a file the server does not have (null) is remembered");
  assert.equal(io.calls.get("places/meta.json"), 1, "a file that loaded is kept");
});
await check("place list: searches that overlap share one load of a file", async () => {
  const io = fakeLoader({ "places/meta.json": fakeMeta, "places/z/US/90.json": fakeCodes(3) });
  const index = W.createPlaceIndex(io);
  const all = await Promise.all([index.search("90210"), index.search("90211"), index.search("90212")]);
  assert.deepEqual(all.map((r) => r.places.length), [1, 1, 1]);
  assert.equal(io.calls.get("places/meta.json"), 1);
  assert.equal(io.calls.get("places/z/US/90.json"), 1);
});
await check("place list: a loader that throws at once (not a rejected promise) is a failure too", async () => {
  let n = 0;
  const index = W.createPlaceIndex({ load: (path) => { n += 1; if (n === 1) throw new Error("sync"); return path === "places/meta.json" ? fakeMeta : null; } });
  assert.equal((await index.search("90210")).hint, "PLACE LIST NOT AVAILABLE");
  assert.notEqual((await index.search("90210")).hint, "PLACE LIST NOT AVAILABLE", "the second search found the list");
  assert.ok(n >= 2, "asked again");
});
await check("place list: 36 matches, the whole code first, then longer codes in file order", async () => {
  // 40 codes that begin with 902 and the whole code 902 itself, last in the file.
  const rows = [...fakeCodes(40), ["902", "The Whole Code", "CA", 34.1, -118.4, 0]];
  const index = W.createPlaceIndex(fakeLoader({ "places/meta.json": fakeMeta, "places/z/US/90.json": rows }));
  const r = (await index.search("902")).places;
  assert.equal(r.length, 36);
  assert.equal(r[0].code, "902", "the whole code first");
  assert.deepEqual(r.slice(1).map((p) => p.code), rows.slice(0, 35).map((row) => row[0]), "then the rest in file order");
});

// ── 4c. A place with no radar coverage plays a loop without the radar (GitHub #332) ──
await check("loop: the full loop is the default and the golden vectors stand", () => {
  assert.equal(W.hasRadar(null), true);
  assert.deepEqual(W.activeScreens().map((s) => s.id), ["current", "today", "week", "radar"]);
  assert.equal(W.loopSeconds(), 65);
  assert.equal(W.screenAt(50_000).screen.id, "radar");
  assert.equal(W.screenAt(50_000, true).index, 3);
});
await check("loop: hasRadar follows the radar sources (US, Canada, Germany)", () => {
  for (const cc of ["US", "CA", "DE"]) assert.equal(W.hasRadar({ cc, lat: 45, lon: -75 }), true, cc);
  for (const cc of ["GB", "AU", "FR", "MX", ""]) assert.equal(W.hasRadar({ cc, lat: 50, lon: 0 }), false, cc);
});
await check("loop: without radar it is CURRENT, TODAY, 5-DAY, 45 seconds, and the index counts within it", () => {
  assert.deepEqual(W.activeScreens(false).map((s) => s.id), ["current", "today", "week"]);
  assert.equal(W.loopSeconds(false), 45);
  for (const [s, id, index, elapsed] of [[0, "current", 0, 0], [14.9, "current", 0, 14.9], [15, "today", 1, 0], [44.9, "week", 2, 14.9], [45, "current", 0, 0], [50, "current", 0, 5], [65, "today", 1, 5], [-1, "week", 2, 14]]) {
    const r = W.screenAt(s * 1000, false);
    assert.deepEqual([r.screen.id, r.index], [id, index], `${s} s`);
    assert.ok(Math.abs(r.elapsed - elapsed) < 1e-9, `${s} s elapsed ${r.elapsed}`);
  }
  assert.equal(W.SCREENS.length, 4, "the shared loop is untouched");
});
await check("guide: the info panel line has no radar for a place without it", () => {
  assert.ok(/and radar/.test(W.guideItem("TORONTO, ON, CA", "").summary));
  const none = W.guideItem("LONDON, GB", "", false).summary;
  assert.ok(!/radar/i.test(none) && /5-day forecast/.test(none), none);
  assert.equal(W.guideItem("LONDON, GB", "Cloudy, 6\u00B0C.", false).summary, "Cloudy, 6\u00B0C.");
});
await check("saved places are checked on the way back in", () => {
  assert.equal(W.normalizePlace(null), null);
  assert.equal(W.normalizePlace({ name: "x", lat: 91, lon: 0 }), null);
  assert.equal(W.normalizePlace({ name: "", lat: 1, lon: 1 }), null);
  const p = W.normalizePlace({ name: "Toronto", cc: "ca", lat: "43.6532", lon: -79.3832, tz: "Nope", region: "ON" });
  assert.deepEqual([p.cc, p.lat, p.lon, p.tz], ["CA", 43.65, -79.38, "UTC"]);
});

// ── 5. The relay call, the forecast's age, the music ──
await check("the call leaves the device rounded to 2 decimals", () => {
  assert.equal(W.forecastUrl("/api/weather", { lat: 43.6532, lon: -79.3832 }), "/api/weather?lat=43.65&lon=-79.38");
  assert.equal(W.forecastUrl("/api/weather", { lat: 52, lon: 0 }), "/api/weather?lat=52.00&lon=0.00");
});
await check("never asked again before Expires, not more often than the window", () => {
  const e = { body: "{}", savedMs: 1_000_000, expiresMs: 1_000_000 + 30 * 60000 };
  assert.equal(W.forecastDue(null, 0), true);
  assert.equal(W.forecastDue(e, 1_000_000 + 10 * 60000), false);
  assert.equal(W.forecastDue(e, 1_000_000 + 31 * 60000), true);
  assert.equal(W.forecastDue({ body: "{}", savedMs: 1_000_000 }, 1_000_000 + 10 * 60000), false);
  assert.equal(W.forecastDue({ ...e, expiresMs: 1 }, 1_000_000 + 10 * 60000, 5 * 60000), true);
  const a = W.forecastAge(Date.parse("2026-11-15T13:19:00Z"), Date.parse("2026-11-15T14:00:00Z"), "America/Toronto");
  assert.deepEqual(a, { text: "UPDATED 8:19 AM", stale: false });
  assert.equal(W.forecastAge(Date.parse("2026-11-15T01:00:00Z"), Date.parse("2026-11-15T14:00:00Z"), "UTC").stale, true);
});
await import("./nostalgex-weather-screens.js");
await check("icons: whole-pixel cells, about 85% of what they were, centred in the old slots", () => {
  const S = globalThis.NostalgexWeatherScreens;
  const was = { current: 14, today: 8, week: 7 };
  for (const [k, cell] of Object.entries(S.ICON)) {
    assert.equal(cell.slot, was[k] * 24, `${k} keeps its old slot`);
    assert.ok(Number.isInteger(cell.cell) && cell.cell === Math.round(was[k] * 0.85), `${k} cell ${cell.cell}`);
    const ratio = (cell.cell * 24) / cell.slot;
    assert.ok(ratio >= 0.84 && ratio <= 0.89, `${k} is ${(ratio * 100).toFixed(1)}%`);
    assert.ok(Number.isInteger((cell.slot - cell.cell * 24) / 2), `${k} centres on a whole pixel`);
  }
  assert.deepEqual(S.ICON, { current: { slot: 336, cell: 12 }, today: { slot: 192, cell: 7 }, week: { slot: 168, cell: 6 } });
});
await check("the credits stack: 16 px, bottom left, text2 at 70%", () => {
  const f = globalThis.NostalgexWeatherScreens.FOOTER;
  assert.deepEqual([f.size, f.lineHeight, f.x, f.baseline, f.color], [16, 22, 90, 1018, "rgba(185,195,222,0.7)"]);
});
await check("the guide's item: one endless programme, always live, and the bar says LOCAL WEATHER and the temperature", () => {
  const it = W.guideItem("TORONTO, ON, CA", "Cloudy, 6\u00B0C.");
  assert.deepEqual([it.title, it.episodeTitle, it.summary, it.live, it.ratingKey], ["LOCAL WEATHER", "TORONTO, ON, CA", "Cloudy, 6\u00B0C.", true, null]);
  assert.ok(!("startSec" in it) && !("endSec" in it) && !("duration" in it), "no start, no end, no length");
  assert.ok(W.guideItem().summary.length > 20);
  const m = { current: { tempC: 6.4 } };
  assert.equal(W.guideBarText(m, "C"), "LOCAL WEATHER  6\u00B0C");
  assert.equal(W.guideBarText(m, "F"), "LOCAL WEATHER  44\u00B0F");
  assert.equal(W.guideBarText(null, "C"), "LOCAL WEATHER");
  assert.equal(W.guideBarText({ current: { tempC: null } }, "C"), "LOCAL WEATHER");
  assert.equal(W.guideBlocks, undefined, "the hour-long blocks are gone");
});

// ── 6. The channel's rules ──
await check("CH 299 clashes with no channel id or number, and is the closest free number below the music videos", () => {
  const data = JSON.parse(read("channels.json"));
  const ids = new Set(data.channels.map((c) => c.id));
  const numbers = new Set(data.channels.map((c) => c.number));
  assert.equal(W.CHANNEL_NUMBER, 299);
  assert.ok(!ids.has(W.CHANNEL_ID) && !numbers.has(W.CHANNEL_ID));
  assert.ok(!ids.has(W.CHANNEL_NUMBER) && !numbers.has(W.CHANNEL_NUMBER), "not an id or a number in channels.json");
  // What the Apple TV reserves (Channel.swift): packages 1-199, FRANCHISES 300-309, found franchises and franchise collections 310-399,
  // other collections 400-499, HIGH ROTATION 500-519. 299 is the highest number under all of them that nothing owns.
  const reserved = (n) => n <= 199 || (n >= 300 && n <= 519);
  assert.ok(!reserved(W.CHANNEL_NUMBER));
  for (let n = W.CHANNEL_NUMBER + 1; n < 520; n++) assert.ok(reserved(n) || numbers.has(n) || ids.has(n), `${n} is free and closer to the music videos`);
  // The dynamic id blocks: found franchises 1,000,000, franchise collections 1,010,000, collections 1,020,000 (100 each).
  assert.ok(W.CHANNEL_ID >= 1030000);
  assert.equal(W.CHANNEL_NAME, "LOCAL WEATHER");
});
await check("the music is ours: the MIDI source, the sound set's licence, files under 2 MB, no music video path", () => {
  const dir = new URL("../public/weather/music/", import.meta.url);
  for (const f of ["local-forecast.m4a", "local-forecast.mp3"]) {
    const size = readFileSync(new URL(f, dir)).length;
    assert.ok(size > 500_000 && size < 2_000_000, `${f} is ${size} bytes`);
  }
  assert.ok(readFileSync(new URL("local-forecast.mp3", dir)).subarray(0, 3).toString("latin1") === "ID3" || readFileSync(new URL("local-forecast.mp3", dir))[0] === 0xff, "an mp3");
  assert.ok(readFileSync(new URL("local-forecast.m4a", dir)).subarray(4, 8).toString("latin1") === "ftyp", "an m4a");
  const lic = readFileSync(new URL("LICENSE-FluidR3_GM.txt", dir), "utf8");
  assert.ok(/Frank Wen/.test(lic) && /License: MIT/.test(lic) && /Permission is hereby granted, free of charge/.test(lic));
  const mid = readFileSync(new URL("../scripts/weather-music/local-forecast.mid", import.meta.url));
  assert.equal(mid.subarray(0, 4).toString("latin1"), "MThd");
  assert.ok(existsSync(root + "scripts/weather-music/compose.py") && existsSync(root + "scripts/weather-music/render.sh"));
  const third = read("THIRD-PARTY-LICENSES.md");
  assert.ok(/FluidR3_GM/.test(third) && /Frank Wen/.test(third) && /local-forecast/.test(third) && /Deutscher Wetterdienst/.test(third));
  const page = read("plex-tuner.html");
  assert.ok(!/musicPool|nextTrack|_weatherBed|wxMusicLine/.test(page + read("scripts/nostalgex-weather.js")), "the library music video path is gone");
  assert.ok(page.includes('id="weather-music"') && /local-forecast\.\$\{/.test(page) && /'m4a' : 'mp3'/.test(page), "the loop's source is set when the channel is tuned");
});
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
const sources = ["scripts/nostalgex-weather.js", "scripts/nostalgex-weather-screens.js"].filter((p) => existsSync(root + p)).map((p) => [p, strip(read(p))]);
await check("no real weather channel's name, logo or look", () => {
  const banned = /\b(the weather channel|twc|accuweather|weatherscan|storm ?team|yr\.no|noaa weather radio|weather underground|wunderground)\b/i;
  for (const [p, src] of sources) assert.ok(!banned.test(src), `${p} names a real service`);
});
await check("the credits are on screen and in the licences", () => {
  const screens = read("scripts/nostalgex-weather-screens.js");
  assert.ok(screens.includes("DATA FROM MET NORWAY"));
  const page = read("plex-tuner.html");
  assert.ok(/MET Norway/.test(page) && /GeoNames/.test(page) && /Natural Earth/.test(page), "credits line in the tuner");
  const lic = read("THIRD-PARTY-LICENSES.md");
  for (const s of ["MET Norway", "GeoNames", "Natural Earth", "Environment and Climate Change Canada", "National Weather Service"]) assert.ok(lic.includes(s), s);
});
await check("the relay writes no log line", () => {
  assert.ok(!/console\./.test(strip(read("api/weather.js"))));
});
await check("the page calls the relay like the TMDB one, from every build", () => {
  const page = read("plex-tuner.html");
  assert.ok(page.includes("nostalgex-weather.js") && page.includes("nostalgex-weather-screens.js"));
  assert.ok(/api\/weather/.test(page));
});

if (failures.length) {
  console.error(`weather smoke: ${failures.length} failed, ${passed} passed\n${failures.map((f) => "  " + f).join("\n")}`);
  process.exit(1);
}
console.log(`weather smoke: ${passed} checks passed`);
