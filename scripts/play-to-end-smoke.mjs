#!/usr/bin/env node
/**
 * A file plays to its own end (#315), in the web tuner's engine (scripts/nostalgex-daily-manifest.js), the contract the Apple TV
 * has in PlexMediaItem.slotSeconds / DailyManifestScheduler. The parity golden (npm run test:schedule-parity) holds the packing to
 * the Apple TV's, byte for byte; this file holds what the golden cannot say.
 *
 *   1. slotSeconds: the file's real runtime rounded up to a second; the floored minutes when there is no runtime or it is a minute
 *      or more (61 s) from them. A 4:11 music video (4 minutes floored) is a 251 s slot.
 *   2. A day of 4:11 music videos: every block is 251 s, they tile with no gap or overlap, and the next day starts when the last
 *      block of this one ends, which may be after midnight (only that block runs over). The guide's window has yesterday's block
 *      still on air after midnight, once, and the tiling holds across midnight.
 *   3. The progress total of the programme on air is its slot, so the guide, Now Playing and the progress bar agree.
 *   4. A day packed before the runtimes arrived (a saved library, rescanned behind the guide) is packed again once they do.
 *   5. The natural-end catch-up: at a natural end the next programme starts at 0 when the guide is under 10 s ahead, and where the
 *      clock is at 10 s or more (and only then, and never into the end of anything); the Apple TV's pick is otherwise unchanged.
 *   6. A synthetic six hour walk across midnight (a file really lasts its runtime plus 0 to 0.6 s the metadata does not say; the
 *      next file starts 2 s after the last ended): nothing is cut, Now Playing names the programme the guide shows nearly all the
 *      time, and the player never falls more than 20 s behind the guide. Without the catch-up it does (the control).
 *
 * No network. Run: `npm run test:play-to-end`. PRINT=1 prints the walk's numbers.
 */
import { readFileSync } from "node:fs";
import { loadEngine } from "./schedule-parity-dump.mjs";

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };
const eq = (label, got, want) => check(label, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);

const savedTZ = process.env.TZ;
process.env.TZ = "America/New_York";
const { M, store } = loadEngine();
const SK = "p2e";

// ── 1. slotSeconds ──
const item = (duration, exact) => ({ ratingKey: "k", duration, ...(exact === undefined ? {} : { exactDurationSeconds: exact }) });
eq("4:11 is a 251 s slot", M.slotSeconds(item(4, 251)), 251);
eq("4:10.2 rounds up to 251 s", M.slotSeconds(item(4, 250.2)), 251);
eq("a whole minute is itself", M.slotSeconds(item(60, 3600)), 3600);
eq("shorter than the minutes (10 s) is believed", M.slotSeconds(item(90, 5390)), 5390);
eq("60.4 s off the minutes is believed and rounded up", M.slotSeconds(item(90, 5460.4)), 5461);
eq("61 s off the minutes is a bad value: the minutes", M.slotSeconds(item(90, 5461)), 5400);
eq("no runtime: the minutes", M.slotSeconds(item(95)), 5700);
eq("a runtime that is not a number: the minutes", [M.slotSeconds(item(4, NaN)), M.slotSeconds(item(4, null)), M.slotSeconds(item(4, "251"))], [240, 240, 240]);
eq("under a second: the minutes", M.slotSeconds(item(4, 0.5)), 240);
eq("the loaders' conversions: Plex ms, Jellyfin and Emby ticks", [M.exactSecondsFromPlexMs(251000), M.exactSecondsFromTicks(2510000000), M.exactSecondsFromPlexMs(0), M.exactSecondsFromTicks(null)], [251, 251, undefined, undefined]);

// ── 2. A day of 4:11 music videos ──
const clip = (i, exact) => ({ ratingKey: `mv${i}`, title: `Video ${i}`, type: "movie", duration: 4, ...(exact === undefined ? {} : { exactDurationSeconds: exact }), addedAt: 0 });
const pool = Array.from({ length: 10 }, (_, i) => clip(i, 251));
const channel = { id: 40, number: 40, isPremiereChannel: false, timeRestrictions: null };
M.setLineup([{ channel, pool }]);
const local = (y, mo, d, h = 0, mi = 0, s = 0) => new Date(y, mo - 1, d, h, mi, s).getTime() / 1000;
const day1 = local(2026, 11, 3, 12), day2 = local(2026, 11, 4, 12);
const d1 = M.getManifestBlocks(channel, pool, day1 * 1000, SK);
check("a day of music videos has blocks", d1.length > 300, String(d1.length));
check("every block is 251 s", d1.every((b) => b.endSec - b.startSec === 251), [...new Set(d1.map((b) => b.endSec - b.startSec))].join(","));
check("the blocks tile with no gap or overlap", d1.every((b, i) => i === 0 || b.startSec === d1[i - 1].endSec));
const mid2 = local(2026, 11, 4);
check("the day starts at its midnight", d1[0].startSec === local(2026, 11, 3));
const overran = d1.filter((b) => b.endSec > mid2);
check("only the last block runs past midnight (whole)", overran.length === 1 && overran[0] === d1.at(-1) && d1.at(-1).startSec < mid2, `${overran.length} past midnight`);
const d2 = M.getManifestBlocks(channel, pool, day2 * 1000, SK);
check("the next day starts when the programme running over midnight ends", d2[0].startSec === d1.at(-1).endSec, `${d2[0].startSec} vs ${d1.at(-1).endSec}`);
check("and is whole blocks too", d2.every((b) => b.endSec - b.startSec === 251) && d2.every((b, i) => i === 0 || b.startSec === d2[i - 1].endSec));

// The guide's window just after midnight holds yesterday's programme still on air, once; the window tiles across midnight.
const over = d1.at(-1);
const justAfter = mid2 + 1;
const win = M.blocksInRange(channel, pool, mid2, mid2 + 3600, SK);
check("the window from midnight starts with yesterday's block still on air", win[0].startSec === over.startSec && win[0].endSec === over.endSec, JSON.stringify(win.slice(0, 2).map((b) => [b.startSec, b.endSec])));
check("that block is in the window once", win.filter((b) => b.startSec === over.startSec).length === 1);
check("the window tiles across midnight", win.every((b, i) => i === 0 || b.startSec === win[i - 1].endSec));
const sched = M.buildSchedule(channel, pool, justAfter, SK);
check("just after midnight the guide's now playing is yesterday's last programme", sched.nowPlaying.startSec === over.startSec && sched.upNext.startSec === over.endSec, `${sched.nowPlaying.startSec} ${sched.upNext && sched.upNext.startSec}`);
const early = M.buildSchedule(channel, pool, over.startSec + 10, SK);
const total = Math.max(1, M.slotSeconds(early.nowPlaying.item));
eq("the total the progress bar is drawn against is the slot", total, 251);
eq("elapsed is capped at the slot, not at the floored minutes", M.liveElapsedSeconds(early, over.startSec + 250.9), 250);

// ── 4. Runtimes that arrive after the first pack ──
store.clear();
const bare = Array.from({ length: 10 }, (_, i) => clip(i));
M.setLineup([{ channel, pool: bare }]);
const before = M.getManifestBlocks(channel, bare, day1 * 1000, SK);
check("with no runtimes the slots are the minutes", before.every((b) => b.endSec - b.startSec === 240));
M.setLineup([{ channel, pool }]);
const after = M.getManifestBlocks(channel, pool, day1 * 1000, SK);
check("a day packed before the runtimes arrived is packed again when they do", after.every((b) => b.endSec - b.startSec === 251), [...new Set(after.map((b) => b.endSec - b.startSec))].join(","));
store.clear();
const saved = M.getManifestBlocks(channel, pool, day1 * 1000, SK);
M.setLineup([{ channel, pool }]);
const again = M.getManifestBlocks(channel, pool, day1 * 1000, SK);
check("a day whose pool did not change is read back, not packed again", JSON.stringify(saved.map((b) => [b.item.ratingKey, b.startSec])) === JSON.stringify(again.map((b) => [b.item.ratingKey, b.startSec])));
const storedKey = [...store.keys()].find((k) => k.endsWith(`_${channel.id}_${M.localDayKey(day1 * 1000)}`));
const stored = JSON.parse(store.get(storedKey));
check("a packed day is stored at schema 5", stored.schemaVersion === 5, String(stored.schemaVersion));
store.set(storedKey, JSON.stringify({ ...stored, schemaVersion: 3, blocks: stored.blocks.map((b) => ({ ...b, endSec: b.startSec + 240 })) }));
const repacked = M.getManifestBlocks(channel, pool, day1 * 1000, SK);
check("a day stored at schema 3 (minute slots) is packed again, once", repacked.every((b) => b.endSec - b.startSec === 251) && JSON.parse(store.get(storedKey)).schemaVersion === 5);

// A library refresh just after midnight forgets the stored days but keeps yesterday's: the programme running over midnight is
// on air from it, and the day packed again starts when it ends.
store.clear();
M.setLineup([{ channel, pool }]);
const yb = M.getManifestBlocks(channel, pool, day1 * 1000, SK);
M.getManifestBlocks(channel, pool, day2 * 1000, SK);
const yesterdayKey = M.localDayKey(day1 * 1000);
M.clearManifests(SK, { keepDayKey: yesterdayKey });
const keys = [...store.keys()];
check("a refresh keeps yesterday's stored day and forgets the rest", keys.length === 1 && keys[0].endsWith(`_${yesterdayKey}`), keys.join(","));
const winAfterRefresh = M.blocksInRange(channel, pool, mid2, mid2 + 3600, SK);
check("the programme running over midnight is still on air after the refresh", winAfterRefresh[0].startSec === yb.at(-1).startSec && winAfterRefresh[0].endSec === yb.at(-1).endSec);
check("and today is packed again after it, not under it", winAfterRefresh[1].startSec === yb.at(-1).endSec);
M.clearManifests(SK);
check("a full clear (sign out, the refresh button) forgets everything", [...store.keys()].length === 0);
check("the tracker reads the slot, as the Apple TV's PlaybackTracker", /const totalSec = NostalgexDailyManifest\.slotSeconds\(item\);/.test(readFileSync(new URL("../plex-tuner.html", import.meta.url), "utf8")));

// ── 5. The natural-end catch-up ──
store.clear();
M.setLineup([{ channel, pool }]);
const start = local(2026, 11, 3, 15);
const blocks = M.getManifestBlocks(channel, pool, start * 1000, SK);
const a = blocks.find((b) => b.startSec > start + 600);
const prev = blocks[blocks.indexOf(a) - 1];
const next = a;
const lineup = [{ channel, pool }];
const pick = (nowSec, catchUp) => M.advancePick(channel, pool, prev.item.ratingKey, nowSec, lineup, SK, true, catchUp);
const justOnTime = pick(next.startSec + 2, true);
check("a natural end 2 s into the next programme starts it at 0", justOnTime.item.ratingKey === next.item.ratingKey && justOnTime.seekSeconds === 0, JSON.stringify([justOnTime.item.ratingKey, justOnTime.seekSeconds]));
const nine = pick(next.startSec + 9, true);
check("9 s in: still at 0", nine.item.ratingKey === next.item.ratingKey && nine.seekSeconds === 0);
const ten = pick(next.startSec + 10, true);
check("10 s in: joins where the clock is", ten.item.ratingKey === next.item.ratingKey && ten.seekSeconds === 10, JSON.stringify([ten.item.ratingKey, ten.seekSeconds]));
const forty = pick(next.startSec + 40, true);
check("40 s in: joins at 40", forty.seekSeconds === 40);
const off = pick(next.startSec + 40, false);
check("without the catch-up (the parity golden's call) it is the Apple TV's pick: 0", off.seekSeconds === 0 && off.item.ratingKey === next.item.ratingKey);
const early2 = M.advancePick(channel, pool, prev.item.ratingKey, prev.endSec - 5, lineup, SK, true, true);
check("a natural end before the guide has moved on takes the next programme from 0", early2.item.ratingKey === next.item.ratingKey && early2.seekSeconds === 0, JSON.stringify([early2.item.ratingKey, early2.seekSeconds]));
const skipped = M.advancePick(channel, pool, prev.item.ratingKey, next.startSec + 40, lineup, SK, false, true);
check("a skip after a failure is not a natural end: it joins the clock as before", skipped.seekSeconds === 40);

// ── 6. A six hour walk across midnight ──
const jitter = (n) => (n * 0.37) % 0.6;
const wpool = Array.from({ length: 12 }, (_, i) => clip(i, 240 + ((i * 13) % 55) + 0.3));   // 4:00 to 4:55: all 4 minutes floored
function walk(catchUp, loadSec = 2) {
  store.clear();
  const ch = { id: 41, number: 41, isPremiereChannel: false, timeRestrictions: null };
  M.setLineup([{ channel: ch, pool: wpool }]);
  const t0 = local(2026, 11, 3, 20), t1 = local(2026, 11, 4, 2);
  const L = [{ channel: ch, pool: wpool }];
  const tuned = M.tuneIn(ch, wpool, null, t0, SK);
  let playing = tuned.item, startedAt = t0, seek = tuned.seekSeconds, n = 0;
  let endsAt = startedAt + (playing.exactDurationSeconds + jitter(n++) - seek);
  let lagMax = 0, cuts = 0, boundaries = 0, mismatches = 0, samples = 0, skippedOpening = 0;
  for (let now = t0; now < t1; now += 0.5) {
    if (now >= endsAt) {
      // The file ended on its own: the next is picked now and starts `loadSec` later, from where it was asked for.
      const p = M.advancePick(ch, wpool, playing.ratingKey, now, L, SK, true, catchUp);
      boundaries++;
      skippedOpening += p.seekSeconds;
      playing = p.item; seek = p.seekSeconds; startedAt = now + loadSec;
      endsAt = startedAt + (playing.exactDurationSeconds + jitter(n++) - seek);
      if (playing.exactDurationSeconds - seek <= 0) cuts++;
    }
    if (Math.floor(now) % 15 === 0 && now % 1 === 0) {
      const g = M.buildSchedule(ch, wpool, now, SK);
      if (g && g.nowPlaying) {
        samples++;
        if (g.nowPlaying.item.ratingKey !== playing.ratingKey) mismatches++;
        const position = Math.max(0, now - startedAt) + seek;            // where the player is in its file
        const lag = (now - g.nowPlaying.startSec) - position;            // how far behind the guide's position
        if (g.nowPlaying.item.ratingKey === playing.ratingKey) { lagMax = Math.max(lagMax, lag); }
      }
    }
  }
  return { boundaries, mismatchPct: 100 * mismatches / samples, lagMax, cuts, skippedOpening, samples };
}
const withCatchUp = walk(true), withoutCatchUp = walk(false);
if (process.env.PRINT) console.log("walk with the catch-up", JSON.stringify(withCatchUp), "\nwalk without", JSON.stringify(withoutCatchUp));
check("the walk crossed midnight and many boundaries", withCatchUp.boundaries > 60, String(withCatchUp.boundaries));
check("nothing is cut: no programme is started with nothing of it left", withCatchUp.cuts === 0);
check("Now Playing names the programme the guide shows nearly all the time (under 6%)", withCatchUp.mismatchPct < 6, `${withCatchUp.mismatchPct.toFixed(1)}%`);
check("the player never falls more than 20 s behind the guide", withCatchUp.lagMax <= 20, `${withCatchUp.lagMax.toFixed(1)} s`);
check("without the catch-up the player falls much further behind (the control)", withoutCatchUp.lagMax > 60 && withoutCatchUp.mismatchPct > withCatchUp.mismatchPct, JSON.stringify(withoutCatchUp));

// ── 7. The page uses them ──
const html = readFileSync(new URL("../plex-tuner.html", import.meta.url), "utf8");
check("the page's natural end asks for the catch-up", /advancePick\(channel, pool, endedItem \? endedItem\.ratingKey : null,\s*Date\.now\(\) \/ 1000, guideLineup\(\), manifestServerKey\(\), fromNaturalEnd, true\)/.test(html));
check("all four loaders (Plex and Jellyfin and Emby, films and episodes) keep the runtime", (html.match(/exactDurationSeconds: NostalgexDailyManifest\.exactSecondsFrom(PlexMs|Ticks)\(/g) || []).length === 4);
check("a saved library from before the runtimes is read again once", /const LIBRARY_SCAN_REVISION = 3;/.test(html));

if (savedTZ === undefined) delete process.env.TZ; else process.env.TZ = savedTZ;
if (failures.length) {
  console.error(`play to end: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`play to end: ${passed} checks passed (slot, a day across midnight, the guide's window, runtimes arriving late, the catch-up, a six hour walk)`);
