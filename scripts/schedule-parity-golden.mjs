#!/usr/bin/env node
/**
 * Builds scripts/schedule-parity-golden.json: fixtures here, answers from the Apple TV.
 *
 *   node scripts/schedule-parity-golden.mjs cases <cases.json>
 *       writes the fixtures (inputs only) for the Swift dump
 *   xcodebuild test ... -only-testing:NostalgexTests/ScheduleParityTests/testDumpForAFixtureFile \
 *       TEST_RUNNER_NX_SCHED_FIXTURE=<cases.json> TEST_RUNNER_NX_SCHED_OUT=<swift.json>
 *   node scripts/schedule-parity-golden.mjs fold <swift.json>
 *       writes the golden file from the fixtures and the Apple TV's answers, and says
 *       whether the web engine agrees
 *
 * Never edit the golden file by hand: the Apple TV is the reference, so its answers come
 * from NostalgexTests/ScheduleParityTests.swift running the app's own code.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { loadEngine, dump, canonical, makeItem } from "./schedule-parity-dump.mjs";

const root = new URL("../", import.meta.url);
const goldenPath = new URL("scripts/schedule-parity-golden.json", root);

/** Unix seconds for a wall-clock time in `zone` (the first one, where the hour repeats). */
function local(zone, y, mo, d, h, mi = 0) {
  const saved = process.env.TZ;
  process.env.TZ = zone;
  const t = new Date(y, mo - 1, d, h, mi).getTime() / 1000;
  if (saved === undefined) delete process.env.TZ; else process.env.TZ = saved;
  return t;
}

/** A stable 32-hex id, the shape of a Jellyfin item id. */
function hexId(text) {
  let a = 0x811c9dc5, b = 0x01000193, c = 0x9e3779b9, d = 0x85ebca6b;
  for (const ch of text) {
    const x = ch.codePointAt(0);
    a = Math.imul(a ^ x, 0x01000193) >>> 0;
    b = Math.imul(b ^ x, 0x85ebca6b) >>> 0;
    c = Math.imul(c ^ x, 0xc2b2ae35) >>> 0;
    d = Math.imul(d ^ x, 0x27d4eb2f) >>> 0;
  }
  return [a, b, c, d].map((n) => n.toString(16).padStart(8, "0")).join("");
}

const FILMS = [
  "Alien", "Heat", "Jaws", "Rocky", "Dune", "Hook", "Big", "Clue", "Willow", "Tron",
  "Labyrinth", "Ghostbusters", "Gremlins", "Beetlejuice", "Speed", "Twister", "Casino",
  "Fargo", "Se7en", "Rudy",
  "Harry Potter and the Deathly Hallows: Part 1", "Harry Potter and the Deathly Hallows: Part 2",
  "The Hunger Games: Mockingjay - Part 2", "The Hunger Games: Mockingjay - Part 1",
];

/** Minutes and a remainder chosen so rounding and truncating disagree on most of them. */
const filmMinutes = (i) => 84 + ((i * 37) % 71);
const filmRemainderSec = (i) => [0, 59, 31, 30, 29, 45, 1, 50][i % 8];

function plexCase() {
  const zone = "America/New_York";
  const day = local(zone, 2026, 11, 1, 0);          // 25 hours: the clocks go back
  const items = [];
  FILMS.forEach((title, i) => {
    const recent = i % 6 === 2;
    items.push({ backend: "plex", kind: "movie", raw: {
      ratingKey: String(1001 + i), title, type: "movie",
      duration: (filmMinutes(i) * 60 + filmRemainderSec(i)) * 1000 + (i % 3) * 7,
      addedAt: recent ? day - 86400 * (1 + (i % 5)) : 1600000000 + i * 86400,
    } });
  });
  // Edge shapes: under a minute, no duration, a one-minute short, longer than a day.
  items.push({ backend: "plex", kind: "movie", raw: { ratingKey: "1101", title: "Trailer", duration: 45000, addedAt: 0 } });
  items.push({ backend: "plex", kind: "movie", raw: { ratingKey: "1102", title: "No Duration" } });
  items.push({ backend: "plex", kind: "movie", raw: { ratingKey: "1103", title: "Short One", duration: 65999, addedAt: day - 3600 } });
  items.push({ backend: "plex", kind: "movie", raw: { ratingKey: "1104", title: "The Marathon", duration: (1560 * 60 + 59) * 1000, addedAt: 0 } });
  for (let i = 0; i < 18; i++) {
    items.push({ backend: "plex", kind: "movie", raw: {
      ratingKey: String(1200 + i), title: `Clip ${i + 1}`, duration: (60 + i * 13) * 1000 + 999, addedAt: 0,
    } });
  }
  const shows = [["Cheers", 2001, 12, 1350000], ["Frasier", 2101, 9, 1360000], ["Columbo", 2201, 4, 5700000 + 30000]];
  for (const [show, base, count, ms] of shows) {
    for (let e = 0; e < count; e++) {
      items.push({ backend: "plex", kind: "episode", show: { title: show }, raw: {
        ratingKey: String(base + e), title: `${show} ${e + 1}`, type: "episode",
        duration: ms + e * 1000, addedAt: e === count - 1 ? day - 86400 * 2 : 1500000000,
      } });
    }
  }
  const keys = (pred) => items.filter((it) => pred(it.raw, it)).map((it) => String(it.raw.ratingKey));
  const film = (i) => String(1001 + i);
  const channels = [
    { id: 2, pool: [film(0)] },
    { id: 3, pool: [film(0), film(1)] },
    { id: 4, pool: keys((r, it) => it.kind === "episode" && r.ratingKey < 2200) },
    { id: 5, pool: [...keys((r, it) => it.kind === "movie" && r.ratingKey < 1100), ...keys((r) => r.ratingKey >= 2201)] },
    { id: 6, premiere: true, pool: keys((r, it) => it.kind === "movie" && r.ratingKey < 1104) },
    { id: 8, pool: ["1104"] },
    { id: 9, pool: [...keys((r) => r.ratingKey >= 1200 && r.ratingKey < 1300), "1103"] },
    { id: 11, pool: [film(2), film(3), film(4), film(0), "2001", "2002"] },
  ];
  return {
    name: "plex-new-york-clocks-go-back",
    fixture: {
      zone, fingerprint: "parity-plex",
      prime: [local(zone, 2026, 10, 31, 12)],
      days: [local(zone, 2026, 10, 31, 12), local(zone, 2026, 11, 1, 12)],
      at: [
        local(zone, 2026, 11, 1, 0, 0), local(zone, 2026, 11, 1, 1, 30), local(zone, 2026, 11, 1, 1, 30) + 3600,
        local(zone, 2026, 11, 1, 19, 7), local(zone, 2026, 11, 1, 23, 50),
      ],
      channels, items,
    },
  };
}

function jellyfinCase() {
  const zone = "America/Santiago";
  const day = local(zone, 2026, 9, 6, 1);           // midnight is skipped: the day starts at 1 AM
  const iso = (sec, frac) => new Date(sec * 1000).toISOString().replace(/\.\d{3}Z$/, frac === undefined ? "Z" : `.${frac}Z`);
  const items = [];
  FILMS.slice(0, 16).forEach((title, i) => {
    const recent = i % 5 === 1;
    const created = recent ? day - 86400 * (1 + (i % 6)) - 3600 * i : 1650000000 + i * 99991;
    items.push({ backend: "jellyfin", kind: "movie", raw: {
      Id: hexId(`jf-film-${title}`), Name: title, Type: "Movie",
      RunTimeTicks: (filmMinutes(i + 3) * 60 + filmRemainderSec(i + 1)) * 10000000 + 1234567,
      DateCreated: i % 3 === 0 ? iso(created) : iso(created, String(1000000 + i * 123457).slice(1, 8)),
    } });
  });
  items.push({ backend: "jellyfin", kind: "movie", raw: { Id: hexId("jf-zero"), Name: "Zero", Type: "Movie", RunTimeTicks: 599999999, DateCreated: iso(day) } });
  items.push({ backend: "jellyfin", kind: "movie", raw: { Id: hexId("jf-none"), Name: "Unknown Length", Type: "Movie" } });
  items.push({ backend: "jellyfin", kind: "movie", raw: { Id: hexId("jf-old"), Name: "Default Date", Type: "Movie", RunTimeTicks: 52800000000, DateCreated: "0001-01-01T00:00:00.0000000Z" } });
  for (const [show, count, minutes] of [["Bluey", 14, 7], ["Seinfeld", 10, 23], ["The Wire", 5, 58]]) {
    for (let e = 0; e < count; e++) {
      items.push({ backend: "jellyfin", kind: "episode", show: { Name: show }, raw: {
        Id: hexId(`jf-${show}-${e}`), Name: `Episode ${e + 1}`, SeriesName: show, Type: "Episode",
        RunTimeTicks: (minutes * 60 + 31 + e) * 10000000, DateCreated: iso(day - 86400 * (e % 9), "4806419"),
      } });
    }
  }
  const ids = (pred) => items.filter((it) => pred(it)).map((it) => it.raw.Id);
  const channels = [
    { id: 1, pool: ids((it) => it.kind === "movie").slice(0, 6) },
    { id: 7, premiere: true, pool: ids((it) => it.kind === "movie") },
    { id: 10, pool: ids((it) => it.show && it.show.Name !== "The Wire") },
    { id: 12, pool: [...ids((it) => it.show && it.show.Name === "Seinfeld"), ...ids((it) => it.kind === "movie").slice(4, 9)] },
    { id: 14, pool: ids((it) => it.show && it.show.Name === "Bluey").slice(0, 3) },
    { id: 15, pool: ids((it) => it.show && it.show.Name === "Bluey").slice(1, 4) },
  ];
  return {
    name: "jellyfin-santiago-midnight-skipped",
    fixture: {
      zone, fingerprint: "parity-jellyfin",
      prime: [local(zone, 2026, 9, 5, 12)],
      days: [local(zone, 2026, 9, 6, 12)],
      at: [local(zone, 2026, 9, 5, 23, 40), local(zone, 2026, 9, 6, 1, 0), local(zone, 2026, 9, 6, 12, 0), local(zone, 2026, 9, 6, 21, 15)],
      channels, items,
    },
  };
}

function embyCase() {
  const zone = "Europe/London";
  const day = local(zone, 2027, 3, 28, 0);          // 23 hours: the clocks go forward
  const items = [];
  FILMS.slice(4).forEach((title, i) => {
    items.push({ backend: "emby", kind: "movie", raw: {
      Id: String(40100 + i * 7), Name: title, Type: "Movie",
      RunTimeTicks: (filmMinutes(i + 9) * 60 + filmRemainderSec(i + 5)) * 10000000,
      DateCreated: new Date((day - 86400 * (i % 11)) * 1000).toISOString().replace(/\.\d{3}Z$/, ".0000000Z"),
    } });
  });
  for (const [show, count, minutes] of [["Only Fools and Horses", 8, 29], ["Doctor Who", 6, 44]]) {
    for (let e = 0; e < count; e++) {
      items.push({ backend: "emby", kind: "episode", show: { Name: show }, raw: {
        Id: String(50000 + show.length * 100 + e), Name: `Part ${e + 1}`, SeriesName: show, Type: "Episode",
        RunTimeTicks: (minutes * 60 + 59) * 10000000 + 9999999, DateCreated: "2025-12-24T18:00:00.0000000Z",
      } });
    }
  }
  const ids = (pred) => items.filter((it) => pred(it)).map((it) => it.raw.Id);
  const channels = [
    { id: 20, pool: ids((it) => it.kind === "movie") },
    { id: 21, premiere: true, pool: ids((it) => it.kind === "movie").slice(0, 10) },
    { id: 22, pool: ids((it) => it.kind === "episode") },
    { id: 23, pool: [...ids((it) => it.kind === "movie").slice(0, 2), ...ids((it) => it.show && it.show.Name === "Doctor Who")] },
  ];
  return {
    name: "emby-london-clocks-go-forward",
    fixture: {
      zone, fingerprint: "parity-emby",
      prime: [local(zone, 2027, 3, 27, 12)],
      days: [local(zone, 2027, 3, 28, 12)],
      at: [local(zone, 2027, 3, 28, 0, 30), local(zone, 2027, 3, 28, 3, 0), local(zone, 2027, 3, 28, 20, 0)],
      channels, items,
    },
  };
}

/**
 * One lineup, crowded: three channels share two films, so one of them always has a title
 * another has on, while the rest have room to give way. A story in three parts on two
 * channels, a premiere channel, a channel whose pool changes with the hour ("gated", which
 * packs after the rest) and one channel the guide doesn't carry ("offGuide", packed after the
 * lineup and seen by none of it). A second time-gated channel shares the first's films and
 * gives way to the ungated lineup only.
 */
function crowdedCase() {
  const zone = "America/Chicago";
  const day = local(zone, 2026, 11, 10, 0);
  const titles = [
    "Predator", "Robocop", "Total Recall", "Commando", "Die Hard", "Lethal Weapon", "Tango and Cash",
    "Road House", "Cobra", "Top Gun", "Point Break", "Speed", "True Lies", "Face Off",
    "The Long Night Part 1", "The Long Night Part 2", "The Long Night Part 3",
  ];
  const items = titles.map((title, i) => ({ backend: "plex", kind: "movie", raw: {
    ratingKey: String(3001 + i), title, type: "movie",
    duration: ((88 + ((i * 29) % 47)) * 60 + (i % 4) * 13) * 1000,
    addedAt: i % 5 === 3 ? day - 86400 * (1 + (i % 4)) : 1580000000 + i * 86400,
  } }));
  const k = (i) => String(3001 + i);
  const range = (a, b) => Array.from({ length: b - a }, (_, i) => k(a + i));
  const channels = [
    { id: 30, pool: [k(0), k(1)] },
    { id: 31, pool: [k(1), k(0)] },
    { id: 32, pool: [k(0), k(1)] },
    { id: 33, pool: range(0, 17) },
    { id: 34, pool: range(2, 14) },
    { id: 35, premiere: true, pool: range(3, 17) },
    { id: 36, gated: true, pool: range(0, 14) },
    // A second time-gated channel sharing most of the first's pool: it gives way to the
    // ungated lineup only, never to channel 36, so it can't depend on when 36 was built.
    { id: 39, gated: true, pool: range(0, 12) },
    { id: 37, offGuide: true, pool: range(2, 10) },
    { id: 38, pool: [k(16), k(14), k(4), k(15), k(5)] },
  ];
  return {
    name: "plex-chicago-crowded-lineup",
    fixture: {
      zone, fingerprint: "parity-crowded",
      prime: [local(zone, 2026, 11, 9, 12)],
      days: [local(zone, 2026, 11, 10, 12)],
      at: [local(zone, 2026, 11, 10, 0, 20), local(zone, 2026, 11, 10, 9, 45), local(zone, 2026, 11, 10, 20, 5)],
      channels, items,
    },
  };
}

/**
 * Adds instants where one title is on two channels, found by walking the main day minute by
 * minute with the web engine. They are inputs only: the answers still come from the Apple TV.
 */
function addConflictInstants(c, want = 3) {
  const engine = loadEngine();
  const { M } = engine;
  const fx = c.fixture;
  // The days the golden walk packs, across the lineup the way every surface packs them.
  const dayAt = fx.days[fx.days.length - 1];
  const { days } = dump(engine, { ...fx, at: [], days: [dayAt] });
  const saved = process.env.TZ;
  process.env.TZ = fx.zone;
  const from = M.startOfLocalDayMs(dayAt * 1000) / 1000;
  const to = M.startOfNextLocalDayMs(dayAt * 1000) / 1000;
  if (saved === undefined) delete process.env.TZ; else process.env.TZ = saved;
  const blocks = fx.channels.map((row) => [row.id, days[dayAt][row.id]]);
  const seen = new Set();
  const found = [];
  for (let t = from + 420; t < to && found.length < want; t += 60) {
    const on = new Map();
    for (const [id, bs] of blocks) {
      const b = bs.find((x) => x[1] <= t && t < x[2]);
      if (!b) continue;
      const k = b[0];
      if (!on.has(k)) { on.set(k, id); continue; }
      const pair = `${on.get(k)}-${id}-${k}`;
      if (!seen.has(pair)) { seen.add(pair); found.push(t); }
    }
  }
  fx.at = [...new Set([...fx.at, ...found])].sort((a, b) => a - b);
  return found.length;
}

const ABOUT = [
  "What airs, and when, on every surface. The Apple TV is the reference.",
  "Generated, never hand-edited: fixtures from scripts/schedule-parity-golden.mjs, answers (expect) from",
  "Nostalgex/NostalgexTests/ScheduleParityTests.swift running the app's own scheduler, guide, conflict rule,",
  "tune and advance code. Checked by that test, by scripts/nostalgex-schedule-parity-smoke.mjs",
  "(npm run test:schedule-parity, the web tuner and the Docker image) and by roku/tests.",
  "fixture: zone (every date in it is local there), fingerprint (the manifest store's key), items in the",
  "server's own shape (Plex ms and addedAt; Jellyfin and Emby RunTimeTicks and DateCreated), channels in",
  "guide order with their pools in library order, prime (days packed first, so yesterday exists), days",
  "(dumped in full) and at (instants, unix seconds). The channels are the guide's lineup, registered with",
  "the scheduler, and each day is packed across all of them so one title is not on two at once; a row",
  "with gated: true has a pool that changes with the hour (it packs after the rest and gives way to the",
  "ungated lineup only, never to another gated channel; the hour never comes),",
  "and one with offGuide: true is not in the lineup (it packs after it, against it, seen by none of it).",
  "expect.items: key -> [minutes, addedAt (0 if before 1970), title, type], null where the loader drops it.",
  "expect.days: instant -> channel -> [key, start, end] for that local day.",
  "expect.at[].ch: now [key,start,end], elapsed, next and span [entries, first start, last end] of the",
  "24-hour guide window; shown, shownNext and gaveWay after one title on two channels is resolved (the",
  "lowest channel id keeps it); tune [key, seek] (what tuning in plays); early, end, resync [key, seek]",
  "(the next pick when the programme ends before its slot, at its slot's end, and 10 minutes after).",
];

/** Objects one key per line, a block or a raw item per line: diffs stay readable, the file small. */
function pretty(value, pad = "") {
  const flat = (v) => v === null || typeof v !== "object" || (Array.isArray(v) && v.every((x) => x === null || typeof x !== "object"));
  const inner = pad + " ";
  if (Array.isArray(value) && value.length > 3 && value.every((v) => typeof v === "string" && v.includes(" "))) {
    return `[\n${value.map((v) => inner + JSON.stringify(v)).join(",\n")}\n${pad}]`;   // prose
  }
  if (flat(value)) return JSON.stringify(value);
  if (Array.isArray(value)) {
    if (value.every((v) => Array.isArray(v) && v.every((x) => x === null || typeof x !== "object"))) {
      return `[\n${value.map((v) => inner + JSON.stringify(v)).join(",\n")}\n${pad}]`;
    }
    return `[\n${value.map((v) => inner + pretty(v, inner)).join(",\n")}\n${pad}]`;
  }
  const keys = Object.keys(value);
  if (keys.length && keys.every((k) => k === "raw" || k === "show" || k === "backend" || k === "kind" || k === "compact")) {
    return JSON.stringify(value);
  }
  return `{\n${keys.map((k) => `${inner}${JSON.stringify(k)}: ${pretty(value[k], inner)}`).join(",\n")}\n${pad}}`;
}

const [, , cmd, path] = process.argv;
const build = () => {
  const cases = [plexCase(), jellyfinCase(), embyCase(), crowdedCase()];
  for (const c of cases) {
    const n = addConflictInstants(c);
    if (n === 0) console.error(`${c.name}: no instant with one title on two channels`);
  }
  return cases;
};

if (cmd === "cases" && path) {
  const cases = build();
  writeFileSync(path, JSON.stringify({ cases }, null, 1) + "\n");
  console.log(`wrote ${cases.length} cases to ${path}`);
} else if (cmd === "fold" && path) {
  const swift = JSON.parse(readFileSync(path, "utf8"));
  const cases = build().map((c) => {
    const s = swift.cases.find((x) => x.name === c.name);
    if (!s) throw new Error(`no Apple TV answers for ${c.name}`);
    return { name: c.name, fixture: c.fixture, expect: s.expect };
  });
  writeFileSync(goldenPath, pretty({ _about: ABOUT, cases }) + "\n");
  let same = 0;
  for (const c of cases) {
    const web = dump(loadEngine(), c.fixture);
    if (canonical(web) === canonical(c.expect)) same += 1;
    else console.error(`${c.name}: the web engine differs from the Apple TV`);
  }
  console.log(`wrote ${goldenPath.pathname}: ${cases.length} cases, the web engine matches ${same}`);
} else {
  console.error("usage: schedule-parity-golden.mjs cases <out.json> | fold <swift-out.json>");
  process.exit(2);
}
