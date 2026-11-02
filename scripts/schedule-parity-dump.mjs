/**
 * The web engine's answers for a schedule-parity fixture, in the shape
 * Nostalgex/NostalgexTests/ScheduleParityTests.swift dumps the Apple TV's. Field for field the
 * same walk: items through the loaders' conversions, earlier days packed first, each channel's
 * day, then at each instant the guide (scheduled, then with one title on two channels
 * resolved), what tuning in plays, and what plays next when the programme ends early, on
 * time, or after a resync.
 *
 * Used by scripts/nostalgex-schedule-parity-smoke.mjs and scripts/schedule-parity-golden.mjs.
 */
import { readFileSync } from "node:fs";
import vm from "node:vm";

const root = new URL("../", import.meta.url);

/** A fresh engine over an in-memory localStorage, so cases can't see each other's manifests. */
export function loadEngine(source = readFileSync(new URL("scripts/nostalgex-daily-manifest.js", root), "utf8")) {
  const store = new Map();
  const localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => { store.set(k, String(v)); },
    removeItem: (k) => { store.delete(k); },
    key: (i) => [...store.keys()][i] ?? null,
    get length() { return store.size; },
  };
  const ctx = { Date, TextEncoder, localStorage };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(source, ctx);
  return { M: ctx.NostalgexDailyManifest, store };
}

/** Items as the web loaders build them (plex-tuner.html), through the engine's conversions. */
export function makeItem(M, spec) {
  if (spec.compact) {
    const [key, title, type, minutes, addedAt] = spec.compact;
    return [key, { ratingKey: key, title, type, duration: minutes, addedAt }];
  }
  const { backend, kind, raw, show = {} } = spec;
  if (backend === "plex") {
    const key = String(raw.ratingKey);
    const minutes = M.minutesFromPlexMs(raw.duration);
    if (minutes <= 0) return [key, null];
    const title = kind === "episode" ? (show.title ?? "") : raw.title;
    return [key, { ratingKey: key, title, type: kind, duration: minutes, addedAt: raw.addedAt || 0 }];
  }
  if (backend === "jellyfin" || backend === "emby") {
    const key = raw.Id;
    const minutes = M.minutesFromTicks(raw.RunTimeTicks);
    if (minutes <= 0) return [key, null];
    const title = kind === "episode" ? (show.Name ?? raw.SeriesName ?? "") : (raw.Name ?? "");
    return [key, { ratingKey: key, title, type: kind, duration: minutes, addedAt: M.unixSecondsFromISO(raw.DateCreated) }];
  }
  throw new Error(`unknown item ${backend} ${kind}`);
}

export function dump(engine, fx) {
  const { M, store } = engine;
  const savedTZ = process.env.TZ;
  process.env.TZ = fx.zone;
  store.clear();
  try {
    const sk = fx.fingerprint;
    const byKey = new Map();
    const items = {};
    for (const spec of fx.items || []) {
      const [key, item] = makeItem(M, spec);
      if (item) byKey.set(item.ratingKey, item);
      // addedAt as the schedule reads it: only a positive one can be recent. Before 1970 reads
      // as 0, where Foundation's dates (Julian before 1582) and JavaScript's disagree.
      if (!spec.compact) items[key] = item ? [item.duration, Math.max(0, item.addedAt), item.title, item.type] : null;
    }
    // "gated": a channel whose pool changes with the hour, which packs after the rest
    // (sortByLineupPriority); an hour no fixture reaches, so the pool itself never changes.
    const lineup = fx.channels.map((row) => ({
      channel: { id: row.id, number: row.number ?? row.id, isPremiereChannel: Boolean(row.premiere),
        timeRestrictions: row.gated ? { tvOnlyBefore: 0 } : null },
      pool: (row.pool || []).map((k) => byKey.get(k)).filter(Boolean),
    }));
    // The guide's lineup, as plex-tuner.html registers it: each day is packed across all of it.
    // An offGuide row is dumped but not registered, like a channel the guide doesn't carry.
    if (typeof M.setLineup === "function") M.setLineup(lineup.filter((_, i) => !fx.channels[i].offGuide));

    for (const t of fx.prime || []) {
      for (const { channel, pool } of lineup) M.getManifestBlocks(channel, pool, t * 1000, sk);
    }

    const days = {};
    for (const t of fx.days || []) {
      const byChannel = {};
      for (const { channel, pool } of lineup) {
        byChannel[channel.id] = M.getManifestBlocks(channel, pool, t * 1000, sk)
          .map((b) => [b.item.ratingKey, b.startSec, b.endSec]);
      }
      days[t] = byChannel;
    }

    const at = [];
    for (const t of fx.at || []) {
      const raw = new Map();
      for (const { channel, pool } of lineup) {
        const s = M.buildSchedule(channel, pool, t, sk);
        if (s) raw.set(channel.id, s);
      }
      const shown = M.resolveConflicts(new Map(raw));
      const byChannel = {};
      for (const { channel, pool } of lineup) {
        const u = raw.get(channel.id);
        const r = shown.get(channel.id);
        if (!u || !r) { byChannel[channel.id] = null; continue; }
        const tune = M.tuneIn(channel, pool, r, t, sk);
        const prev = tune ? tune.item.ratingKey : null;
        const endOfNow = u.nowPlaying ? u.nowPlaying.endSec : t;
        const adv = (now, natural) => {
          const p = M.advancePick(channel, pool, prev, now, lineup, sk, natural);
          return p ? [p.item.ratingKey, p.seekSeconds] : null;
        };
        const gaveWay = r.entries.find((e) => e.isConflict);
        byChannel[channel.id] = {
          now: u.nowPlaying ? [u.nowPlaying.item.ratingKey, u.nowPlaying.startSec, u.nowPlaying.endSec] : null,
          elapsed: u.elapsedSeconds,
          next: u.upNext ? u.upNext.item.ratingKey : null,
          span: [u.entries.length, u.entries.length ? u.entries[0].startSec : 0, u.entries.length ? u.entries.at(-1).endSec : 0],
          shown: r.nowPlaying ? [r.nowPlaying.item.ratingKey, r.nowPlaying.startSec] : null,
          shownNext: r.upNext ? r.upNext.item.ratingKey : null,
          gaveWay: gaveWay ? gaveWay.item.ratingKey : null,
          tune: tune ? [tune.item.ratingKey, tune.seekSeconds] : null,
          early: adv(t, true),
          end: adv(endOfNow, true),
          resync: adv(endOfNow + 600, false),
        };
      }
      at.push({ t, ch: byChannel });
    }
    return { items, days, at };
  } finally {
    if (typeof M.setLineup === "function") M.setLineup(null);
    if (savedTZ === undefined) delete process.env.TZ;
    else process.env.TZ = savedTZ;
  }
}

/** JSON with every object's keys sorted: the form both sides compare in. */
export function canonical(value) {
  return JSON.stringify(value, (_k, v) =>
    v && typeof v === "object" && !Array.isArray(v)
      ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, v[k]]))
      : v);
}
