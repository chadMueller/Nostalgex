#!/usr/bin/env node
/**
 * Seasonal bundles on the web tuner and in the Docker image: when one is in season.
 *
 *   1. scripts/nostalgex-season.js against scripts/season-golden.json, the vectors
 *      NostalgexTests/SeasonGoldenTests.swift also runs, in every zone the file lists.
 *   2. plex-tuner.html's own season section (isBundleInSeason to seasonalHeadline), run
 *      in a VM over the shipped bundles with a pinned clock and an in-memory
 *      localStorage: the invite, the guide lead, the headline, and the NOT THIS YEAR and
 *      DON'T ASK AGAIN answers.
 *   3. The shipped channels.json: TIS THE SEASON starts a week before US Thanksgiving,
 *      in the month before December, every year to 2040. SCREAM is still October.
 *   4. Negative controls: the module with its early start removed fails exactly the
 *      late November vectors, and the module reading UTC instead of local time fails too.
 *
 * No network. Run: `npm run test:season`.
 */
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const root = new URL("../", import.meta.url);
const golden = JSON.parse(readFileSync(new URL("scripts/season-golden.json", root), "utf8"));
const config = JSON.parse(readFileSync(new URL("channels.json", root), "utf8"));
const seasonSrc = readFileSync(new URL("scripts/nostalgex-season.js", root), "utf8");
const tuner = readFileSync(new URL("plex-tuner.html", root), "utf8");

let passed = 0;
const failures = [];
function check(label, fn) {
  try {
    fn();
    passed += 1;
  } catch (err) {
    failures.push(`${label}\n    ${String(err.message).split("\n").join("\n    ")}`);
  }
}

// The bundles as plex-tuner.html parses them from channels.json.
function shippedBundles(cfg = config) {
  return cfg.bundles.map((b) => ({
    id: b.id,
    name: b.name,
    description: b.description || "",
    channelIDs: b.channelIDs || [],
    activeMonths: b.activeMonths || null,
    seasonStart: b.seasonStart || null,
    enabled: false,
  }));
}

/** "2026-11-19T00:00" as local wall-clock time in the current zone. */
function local(at) {
  const [d, t = "00:00"] = at.split("T");
  const [y, m, day] = d.split("-").map(Number);
  const [hh, mm] = t.split(":").map(Number);
  return new Date(y, m - 1, day, hh, mm);
}
function ymd(date) {
  const p = (n) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}`;
}

function loadSeason(src = seasonSrc) {
  const ctx = { Date };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return ctx.NostalgexSeason;
}

function bundleFor(c, bundles) {
  if (c.def) return { id: "def", name: "DEF", channelIDs: [1], ...c.def, activeMonths: c.def.activeMonths || null };
  const b = bundles.find((x) => x.id === c.bundle);
  assert(b, `no bundle ${c.bundle} in channels.json`);
  return b;
}

/** Every module-level vector in the current zone; returns the names that failed. */
function moduleVectorFailures(S, bundles = shippedBundles()) {
  const failed = [];
  const expect = (name, ok) => { if (!ok) failed.push(name); };
  for (const t of golden.thanksgiving) {
    expect(`thanksgiving ${t.year}`, ymd(S.usThanksgiving(t.year)) === t.thanksgiving);
    const start = S.seasonStartDate(bundles.find((b) => b.id === "tis-the-season"), t.year);
    expect(`TIS THE SEASON start ${t.year}`, !!start && ymd(start) === t.tisTheSeasonStart
      && start.getHours() === 0 && start.getMinutes() === 0);
  }
  for (const c of golden.inSeason) expect(c.name, S.isInSeason(bundleFor(c, bundles), local(c.at)) === c.want);
  for (const c of golden.offer) {
    const offer = S.bundleToOffer(bundles, new Set(c.on || []), local(c.at), () => false);
    expect(`offer: ${c.name}`, (offer ? offer.id : null) === c.want);
  }
  for (const c of golden.lead) {
    const want = c.want.flatMap((id) => bundles.find((b) => b.id === id).channelIDs);
    expect(`lead: ${c.name}`, JSON.stringify(S.seasonalLeadIDs(bundles, new Set(c.on), local(c.at))) === JSON.stringify(want));
  }
  for (const c of golden.headline) expect(`headline ${c.want}`, S.inviteHeadline(bundleFor(c, bundles), local(c.at)) === c.want);
  for (const c of golden.label) {
    expect(`label ${c.want || "(none)"} at ${c.at}`,
      S.seasonalSpotlightLabel(bundleFor(c, bundles), local(c.at)).toUpperCase() === c.want);
  }
  return failed;
}

// plex-tuner.html's own season section, run against a pinned clock.
function pageSeason(bundles = shippedBundles()) {
  const start = tuner.indexOf("function isBundleInSeason(bundle)");
  const end = tuner.indexOf("  function applyBundleFilter()", start);
  assert(start >= 0 && end > start, "the season section of plex-tuner.html moved");
  const store = new Map();
  const RealDate = Date;
  const ctx = {
    now: new RealDate(),
    bundles,
    enabledBundleIDs: new Set(),
    localStorage: {
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => { store.set(k, String(v)); },
      removeItem: (k) => { store.delete(k); },
    },
    renderActiveGuide() {},
  };
  // The page writes through lsSet() (scripts/nostalgex-storage.js, #152); here it is the same store.
  ctx.lsSet = (k, v) => { store.set(k, String(v)); return true; };
  ctx.toggleBundle = (id) => {
    if (ctx.enabledBundleIDs.has(id)) ctx.enabledBundleIDs.delete(id);
    else ctx.enabledBundleIDs.add(id);
  };
  ctx.Date = class extends RealDate {
    constructor(...args) { super(...(args.length ? args : [ctx.now.getTime()])); }
    static now() { return ctx.now.getTime(); }
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(seasonSrc, ctx);
  vm.runInContext(`${tuner.slice(start, end)}
this.page = { isBundleInSeason, seasonalLeadIDs, isSeasonalPromptSilenced, answerSeasonalPrompt,
  seasonalBundleOnOffer, seasonalHeadline };`, ctx);
  return { ctx, page: ctx.page, at(at) { ctx.now = local(at); } };
}

// ── 1 and 2: the vectors, in every zone ─────────────────────────────────────

const originalTZ = process.env.TZ;
const zones = golden.zones;
const caseCount = golden.thanksgiving.length * 2 + golden.inSeason.length + golden.offer.length
  + golden.lead.length + golden.headline.length + golden.label.length;
let stepCount = 0;

for (const zone of zones) {
  process.env.TZ = zone;

  check(`${zone}: the clock is in this zone`, () => {
    // Compared by wall clock, not name: ICU reports Asia/Kolkata as Asia/Calcutta.
    for (const utc of [Date.UTC(2026, 0, 15, 12), Date.UTC(2026, 6, 15, 12)]) {
      assert.equal(new Date(utc).toLocaleString("en-US"), new Date(utc).toLocaleString("en-US", { timeZone: zone }));
    }
  });

  check(`${zone}: scripts/nostalgex-season.js passes every vector`, () => {
    assert.deepEqual(moduleVectorFailures(loadSeason()), []);
  });

  check(`${zone}: plex-tuner.html offers, leads and headlines as the vectors say`, () => {
    const p = pageSeason();
    for (const c of golden.inSeason.filter((x) => x.bundle)) {
      p.at(c.at);
      assert.equal(p.page.isBundleInSeason(p.ctx.bundles.find((b) => b.id === c.bundle)), c.want, c.name);
    }
    for (const c of golden.offer) {
      p.at(c.at);
      p.ctx.enabledBundleIDs = new Set(c.on || []);
      const offer = p.page.seasonalBundleOnOffer();
      assert.equal(offer ? offer.id : null, c.want, `offer: ${c.name}`);
    }
    for (const c of golden.lead) {
      p.at(c.at);
      p.ctx.enabledBundleIDs = new Set(c.on);
      const want = c.want.flatMap((id) => p.ctx.bundles.find((b) => b.id === id).channelIDs);
      assert.deepEqual([...p.page.seasonalLeadIDs()], want, `lead: ${c.name}`);
    }
    for (const c of golden.headline.filter((x) => x.bundle)) {
      p.at(c.at);
      assert.equal(p.page.seasonalHeadline(p.ctx.bundles.find((b) => b.id === c.bundle)), c.want);
    }
  });

  for (const a of golden.answers) {
    check(`${zone}: ${a.name}`, () => {
      const p = pageSeason();
      for (const s of a.steps) {
        p.at(s.at);
        stepCount += zone === zones[0] ? 1 : 0;
        if (s.answer) {
          p.page.answerSeasonalPrompt(s.bundle, s.answer);
        } else if ("offer" in s) {
          const offer = p.page.seasonalBundleOnOffer();
          assert.equal(offer ? offer.id : null, s.offer, `offer at ${s.at}`);
        } else {
          assert.equal(p.page.isSeasonalPromptSilenced(s.silenced), s.want, `${s.silenced} silenced at ${s.at}`);
        }
      }
    });
  }
}

// ── 3: the shipped config ───────────────────────────────────────────────────

process.env.TZ = zones[0];
const S = loadSeason();
const shipped = shippedBundles();
const byID = new Map(shipped.map((b) => [b.id, b]));

check("TIS THE SEASON: December, starting a week before US Thanksgiving", () => {
  const b = byID.get("tis-the-season");
  assert.deepEqual(b.activeMonths, [12]);
  assert.deepEqual(b.seasonStart, { relativeTo: "usThanksgiving", days: -7 });
});

check("SCREAM: October, no early start", () => {
  const b = byID.get("seasonal");
  assert.deepEqual(b.activeMonths, [10]);
  assert.equal(b.seasonStart, null);
});

check("every seasonStart has a known anchor and falls in the month before the first active month, 2024 to 2040", () => {
  for (const b of shipped.filter((x) => x.seasonStart)) {
    assert.equal(b.seasonStart.relativeTo, S.US_THANKSGIVING, `${b.id}: unknown anchor`);
    for (let year = 2024; year <= 2040; year++) {
      const start = S.seasonStartDate(b, year);
      const month = start.getMonth() + 1;
      assert.equal(b.activeMonths.includes(month), false, `${b.id} ${year}: starts inside an active month`);
      assert.equal(b.activeMonths[0], (month % 12) + 1, `${b.id} ${year}: a gap before the first active month`);
    }
  }
});

check("one season per calendar year, so NOT THIS YEAR can key on the year", () => {
  for (const b of shipped.filter((x) => x.activeMonths)) {
    const months = [...b.activeMonths];
    assert.deepEqual(months, [...months].sort((x, y) => x - y), `${b.id}: months wrap the year`);
  }
});

check("plex-tuner.html loads the season module and keeps seasonStart from channels.json", () => {
  assert.match(tuner, /<script src="scripts\/nostalgex-season\.js"><\/script>/);
  assert.match(tuner, /seasonStart: b\.seasonStart \|\| null/);
});

// ── 4: negative controls ────────────────────────────────────────────────────

const earlyStartLine = "return !!start && now >= start && now.getMonth() === start.getMonth();";
// Every vector that is in season in November, which only the early start allows. The
// labels compute the start date without asking whether today is in season, so they stay.
const lateNovember = new Set([
  ...golden.inSeason.filter((c) => c.want && c.at.slice(5, 7) === "11").map((c) => c.name),
  ...golden.offer.filter((c) => c.want === "tis-the-season" && c.at.slice(5, 7) === "11").map((c) => `offer: ${c.name}`),
  ...golden.lead.filter((c) => c.want.includes("tis-the-season") && c.at.slice(5, 7) === "11").map((c) => `lead: ${c.name}`),
]);
let removedCaught = 0;
check("negative control: without the early start, exactly the November in-season vectors fail", () => {
  assert(seasonSrc.includes(earlyStartLine), "the early start line moved; update the control");
  const failed = moduleVectorFailures(loadSeason(seasonSrc.replace(earlyStartLine, "return false;")));
  removedCaught = failed.length;
  assert.deepEqual(new Set(failed), lateNovember);
});

let utcCaught = 0;
check("negative control: reading UTC instead of local time is caught", () => {
  const utc = seasonSrc
    .replace(/\.getMonth\(\)/g, ".getUTCMonth()")
    .replace(/\.getDate\(\)/g, ".getUTCDate()")
    .replace(/\.getFullYear\(\)/g, ".getUTCFullYear()")
    .replace(/\.getDay\(\)/g, ".getUTCDay()");
  assert.notEqual(utc, seasonSrc);
  for (const zone of zones) {
    process.env.TZ = zone;
    utcCaught += moduleVectorFailures(loadSeason(utc)).length;
  }
  assert(utcCaught > 0, "the vectors did not notice UTC");
});

if (originalTZ === undefined) delete process.env.TZ;
else process.env.TZ = originalTZ;

if (failures.length) {
  console.error(`season smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`season smoke: ${passed} passed (${caseCount} vectors and ${stepCount} answer steps in each of ${zones.length} zones; ` +
  `negative controls: early start removed fails ${removedCaught} vectors, UTC fails ${utcCaught})`);
