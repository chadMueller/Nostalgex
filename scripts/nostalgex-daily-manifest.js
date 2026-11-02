// Daily 24h EPG manifests — mirrors tvOS DailyManifestScheduler (unplayed-first per day).
//
// PARITY CONTRACT with tvOS (the Apple TV is the reference)
//   Nostalgex/Nostalgex/Models/SchedulePoolOrdering.swift
//   Nostalgex/Nostalgex/Services/DailyManifestScheduler.swift
//   Nostalgex/Nostalgex/Services/DailyManifestStore.swift
//   Nostalgex/Nostalgex/Models/ChannelSchedule.swift (guide window, conflicts)
//   Nostalgex/Nostalgex/App/AppState+Schedule.swift, AppState+Playback.swift (tune, next pick)
//
// The running order for a given (pool, channelId, local day) is reproduced
// bit-for-bit here: same splitmix64 seeding, same xorshift64 stream, same
// Swift-stdlib shuffle (Lemire nearly-divisionless bounded draw), same grouping
// key, same premiere promotion, same sequel grouping, same golden-ratio filler
// offset. So is what airs: scripts/schedule-parity-golden.json is generated from
// NostalgexTests/ScheduleParityTests.swift and npm run test:schedule-parity checks
// this file against it byte for byte.
//
// The order depends on the pool's order, so the pool must be in library order as
// the server lists it, never shuffled, with minutes truncated (minutesFromPlexMs,
// minutesFromTicks), as the Apple TV's loaders build it.
//
// A day is packed for the whole lineup at once (setLineup, packLineupDay): channels
// in priority order, each in its own running order except that a programme another
// channel already has on in the same slot waits for a later one (pickCandidate,
// LOOKAHEAD). What is stored stays put. So which channels are in the guide is an
// input too: two devices with the same library, lineup and history air the same day.
//
// KNOWN REMAINING DIFFERENCES (deliberate, they never change what airs):
//  1. `poolFingerprint` is a cheap string hash here vs SHA-256 on tvOS. It only
//     decides whether a *locally cached* manifest is still valid; it never feeds
//     the ordering. Caches are per-device anyway.
//  2. Cache storage is localStorage keyed by serverKey, not the tvOS
//     Application Support files keyed by credential fingerprint. Same role,
//     different medium. Like the Apple TV's, a day is packed with what this
//     device stored for the day before, so two devices with different histories
//     can air different days.
//  3. `localDayNumber` uses Math.floor where Swift uses Int() truncation. Identical
//     for every post-1970 timestamp; they would only diverge before the epoch.
//  4. A channel off the guide packs against the lineup's day kept in memory once it is
//     known (occupancyMemo), where the Apple TV reads the stored days again. Same answer;
//     the page builds every channel, enabled or not, and the re-read cost ten times more.
(function (global) {
  'use strict';

  const MANIFEST_PREFIX = 'plex90_manifest_';
  // 2: the schedule follows the Apple TV's (pools in library order, minutes truncated), so a
  // day stored by an older tuner is packed again rather than aired the old way until midnight.
  // 3: the lineup's days are packed together, so one title is never on two channels at once.
  // A day stored by an older tuner is packed again once, from what aired the day before.
  const SCHEMA_VERSION = 3;

  /**
   * How far down its running order a channel looks for a programme no other channel has on
   * in the same slot. Mirrors DailyManifestScheduler.lookahead.
   */
  const LOOKAHEAD = 8;
  const MASK64 = 0xFFFFFFFFFFFFFFFFn;

  /** Mirrors `splitmix64` in SchedulePoolOrdering.swift. */
  function splitmix64(x) {
    let z = (BigInt(x) + 0x9E3779B97F4A7C15n) & MASK64;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
    z = (z ^ (z >> 31n)) & MASK64;
    return z;
  }

  /**
   * Mirrors Swift `SeededRNG`: splitmix64-seeded xorshift64.
   * `boundedNext` mirrors the Swift stdlib's
   * `RandomNumberGenerator.next(upperBound:)` (Lemire nearly-divisionless), which
   * `Array.shuffle(using:)` calls. Both are required for bit-identical shuffles —
   * the previous implementation iterated splitmix64 and used a float draw, which
   * produced a completely different order from tvOS.
   */
  function makeSeededRNG(seed) {
    let state = splitmix64(seed);
    if (state === 0n) state = 1n;
    function next() {
      state = (state ^ ((state << 13n) & MASK64)) & MASK64;
      state = state ^ (state >> 7n);
      state = (state ^ ((state << 17n) & MASK64)) & MASK64;
      return state;
    }
    function boundedNext(upperBound) {
      const u = BigInt(upperBound);
      let m = next() * u;
      let low = m & MASK64;
      if (low < u) {
        const t = ((0n - u) & MASK64) % u;
        while (low < t) {
          m = next() * u;
          low = m & MASK64;
        }
      }
      return Number(m >> 64n);
    }
    return { next, boundedNext };
  }

  /** Mirrors Swift stdlib `MutableCollection.shuffle(using:)`. In place. */
  function swiftShuffle(arr, rng) {
    let amount = arr.length;
    let currentIndex = 0;
    while (amount > 1) {
      const random = rng.boundedNext(amount);
      amount -= 1;
      const j = currentIndex + random;
      const tmp = arr[currentIndex];
      arr[currentIndex] = arr[j];
      arr[j] = tmp;
      currentIndex += 1;
    }
    return arr;
  }

  function interleaveByShow(items, seed, dayNumber) {
    if (items.length <= 1) return items.slice();

    const groups = new Map();
    for (const item of items) {
      // Swift keys episodes on `item.title`, which IS the show title on a
      // PlexMediaItem (episode name lives in `episodeTitle`). The web items use
      // the same shape. The old `item.grandparentTitle` lookup was always
      // undefined here, so every episode became its own group and the
      // "max 2 in a row" interleave did nothing.
      const key = item.type === 'episode' ? item.title : `movie_${item.ratingKey}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }

    const rng = makeSeededRNG(BigInt(Math.abs(seed) + 1) + BigInt(dayNumber));

    for (const list of groups.values()) swiftShuffle(list, rng);

    const orderedGroups = [...groups.values()];
    swiftShuffle(orderedGroups, rng);

    const maxConsecutive = 2;
    const result = [];
    const positions = orderedGroups.map(() => 0);
    let groupIndex = 0;
    let exhausted = 0;

    while (exhausted < orderedGroups.length) {
      let attempts = 0;
      while (positions[groupIndex] >= orderedGroups[groupIndex].length) {
        groupIndex = (groupIndex + 1) % orderedGroups.length;
        attempts++;
        if (attempts > orderedGroups.length) break;
      }
      if (attempts > orderedGroups.length) break;

      const group = orderedGroups[groupIndex];
      const pos = positions[groupIndex];
      const take = Math.min(maxConsecutive, group.length - pos);
      for (let i = 0; i < take; i++) result.push(group[pos + i]);
      positions[groupIndex] = pos + take;
      if (positions[groupIndex] >= group.length) exhausted++;
      groupIndex = (groupIndex + 1) % orderedGroups.length;
    }

    return result;
  }

  // ── Recently-added priority ("premieres") ────────────────────────────────
  // Mirrors SchedulePoolOrdering.promoteRecentlyAdded.

  /** A week of recency earns priority placement. */
  const PREMIERE_WINDOW_SECONDS = 7 * 86400;
  /** 7 PM: where the premiere window starts (prime time, not midnight). */
  const PREMIERE_ANCHOR_SECONDS = 19 * 3600;
  /**
   * 19:00-24:00 in 15-minute steps. A constant anchor put a film added to six
   * channels at 19:00 on all six, so the guide showed it six times in the same
   * slot. Slots are derived per (channel, item) instead.
   */
  const PREMIERE_SPREAD_SECONDS = 5 * 3600;
  const PREMIERE_SLOT_SECONDS = 15 * 60;

  /** Mirrors SchedulePoolOrdering.premiereOffset: FNV-1a over the ratingKey, murmur3 finalizer. */
  function premiereOffset(channelId, ratingKey) {
    const slots = BigInt(Math.max(1, Math.floor(PREMIERE_SPREAD_SECONDS / PREMIERE_SLOT_SECONDS)));
    let x = (BigInt.asUintN(64, BigInt(channelId)) + 0x9E3779B97F4A7C15n) & MASK64;
    for (const byte of new TextEncoder().encode(ratingKey)) {
      x = ((x ^ BigInt(byte)) * 0x00000100000001B3n) & MASK64;
    }
    x = x ^ (x >> 33n);
    x = (x * 0xFF51AFD7ED558CCDn) & MASK64;
    x = x ^ (x >> 33n);
    return PREMIERE_ANCHOR_SECONDS + Number(x % slots) * PREMIERE_SLOT_SECONDS;
  }

  function promoteRecentlyAdded(items, dayStartUnix, channelId, windowSeconds) {
    if (items.length <= 1) return items;
    const window = windowSeconds == null ? PREMIERE_WINDOW_SECONDS : windowSeconds;
    const cutoff = dayStartUnix - window;
    const isRecent = (i) => (i.addedAt || 0) > 0 && (i.addedAt || 0) >= cutoff;
    const recent = items.filter(isRecent);
    if (!recent.length || recent.length >= items.length) return items;
    const rest = items.filter((i) => !isRecent(i));

    // Ascending by target so earlier premieres are placed first; the cumulative
    // walk below then counts the ones already inserted, and two premieres an hour
    // apart stay an hour apart instead of stacking. ratingKey breaks ties.
    const targets = recent.map((item) => ({ item, offset: premiereOffset(channelId, item.ratingKey) }));
    targets.sort((a, b) => {
      if (a.offset !== b.offset) return a.offset - b.offset;
      return a.item.ratingKey < b.item.ratingKey ? -1 : a.item.ratingKey > b.item.ratingKey ? 1 : 0;
    });

    const out = rest.slice();
    for (const target of targets) {
      let insertAt = out.length;
      let cumulativeSeconds = 0;
      for (let index = 0; index < out.length; index++) {
        if (cumulativeSeconds >= target.offset) { insertAt = index; break; }
        cumulativeSeconds += (out[index].duration || 0) * 60;
      }
      out.splice(insertAt, 0, target.item);
    }
    return out;
  }

  // ── Sequel-part adjacency ────────────────────────────────────────────────
  // Mirrors SchedulePoolOrdering.groupSequelParts. Anchored to the END of the
  // title so mid-title words never match.
  const SEQUEL_MARKER = /^(.*?)[\s:,-]+(?:part|pt\.?)\s*([0-9]{1,2})\s*$/i;

  function groupSequelParts(items) {
    if (items.length <= 1) return items;

    const marked = [];
    for (let index = 0; index < items.length; index++) {
      const it = items[index];
      if (it.type !== 'movie') continue;
      const match = SEQUEL_MARKER.exec(it.title || '');
      if (!match) continue;
      const ordinal = parseInt(match[2], 10);
      if (!Number.isFinite(ordinal)) continue;
      const base = match[1].toLowerCase().trim();
      if (!base) continue;
      marked.push({ index, base, ordinal });
    }

    const groups = new Map();
    for (const mark of marked) {
      if (!groups.has(mark.base)) groups.set(mark.base, []);
      groups.get(mark.base).push(mark);
    }
    // Only real multi-part stories move; a lone "Part 2" stays put.
    const families = [...groups.values()].filter((f) => f.length > 1);
    if (!families.length) return items;

    const pulled = new Set();
    const insertions = new Map();
    for (const family of families) {
      const anchor = Math.min(...family.map((m) => m.index));
      const ordered = family
        .slice()
        .sort((a, b) => a.ordinal - b.ordinal)
        .map((m) => items[m.index]);
      for (const member of family) pulled.add(member.index);
      insertions.set(anchor, ordered);
    }

    const result = [];
    for (let index = 0; index < items.length; index++) {
      if (insertions.has(index)) result.push(...insertions.get(index));
      else if (!pulled.has(index)) result.push(items[index]);
    }
    return result;
  }

  function localDayKey(dateMs) {
    const d = new Date(dateMs);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  function startOfLocalDayMs(dateMs) {
    const d = new Date(dateMs);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /**
   * The start of the local day after the one containing `dateMs`.
   *
   * Where the clocks change a day is 23 or 25 hours long (23.5 or 24.5 on Lord Howe), so
   * midnight plus 86,400 s lands an hour short of the next midnight when they go back and an
   * hour into the next day when they go forward. 36 hours after a day's start is always inside
   * the next day, and that day's start is the answer, even where midnight itself is skipped
   * (Santiago, Havana, Beirut). Mirrors DailyManifestStore.startOfNextLocalDay.
   */
  function startOfNextLocalDayMs(dateMs) {
    return startOfLocalDayMs(startOfLocalDayMs(dateMs) + 36 * 3600000);
  }

  /**
   * The key of the local day before the one containing `dateMs`. 12 hours before a day's
   * start is always inside the day before; 24 hours before the day after the clocks go
   * forward is two days back. Mirrors DailyManifestStore.previousLocalDayKey.
   */
  function previousLocalDayKey(dateMs) {
    return localDayKey(startOfLocalDayMs(dateMs) - 12 * 3600000);
  }

  /** Seconds in the local day containing `sec`: 86,400 except on the days the clocks change. */
  function localDayLengthSec(sec) {
    const start = startOfLocalDayMs(sec * 1000);
    return (startOfNextLocalDayMs(start) - start) / 1000;
  }

  function localDayNumber(dateMs) {
    return Math.floor(startOfLocalDayMs(dateMs) / 86400000);
  }

  function poolFingerprint(pool) {
    const keys = pool.map(i => i.ratingKey).sort().join(',');
    let h = 0;
    for (let i = 0; i < keys.length; i++) {
      h = ((h << 5) - h + keys.charCodeAt(i)) | 0;
    }
    return String(h);
  }

  function storageKey(serverKey, channelId, dayKey) {
    return `${MANIFEST_PREFIX}${serverKey}_${channelId}_${dayKey}`;
  }

  function loadManifest(serverKey, channelId, dayKey, poolFP) {
    try {
      const raw = localStorage.getItem(storageKey(serverKey, channelId, dayKey));
      if (!raw) return null;
      const manifest = JSON.parse(raw);
      if (manifest.schemaVersion !== SCHEMA_VERSION || manifest.poolFingerprint !== poolFP) return null;
      return manifest;
    } catch {
      return null;
    }
  }

  function saveManifest(serverKey, manifest) {
    try {
      localStorage.setItem(
        storageKey(serverKey, manifest.channelId, manifest.dayKey),
        JSON.stringify(manifest)
      );
    } catch { /* quota */ }
  }

  // ── Across channels: one title on one channel at a time ─────────────────
  // Mirrors DailyManifestScheduler's lineup packing and ScheduleOccupancy.

  /**
   * What the other channels have on, by title: key -> [{ ch, s, e }]. `overlap` is the
   * seconds of [s, e) that some other channel already airs the title for. Mirrors
   * ScheduleOccupancy.
   */
  function makeOccupancy() {
    const byKey = new Map();
    return {
      add(channelId, ratingKey, s, e) {
        if (!(e > s)) return;
        let list = byKey.get(ratingKey);
        if (!list) { list = []; byKey.set(ratingKey, list); }
        list.push({ ch: channelId, s, e });
      },
      overlap(ratingKey, s, e, channelId) {
        const list = byKey.get(ratingKey);
        if (!list) return 0;
        let sec = 0;
        for (const x of list) {
          if (x.ch === channelId) continue;
          const lo = Math.max(s, x.s), hi = Math.min(e, x.e);
          if (hi > lo) sec += hi - lo;
        }
        return sec;
      },
    };
  }

  /** The story and part of a multi-part film ("... Part 2"), or null. Same test as groupSequelParts. */
  function sequelMark(item) {
    if (!item || item.type !== 'movie') return null;
    const match = SEQUEL_MARKER.exec(item.title || '');
    if (!match) return null;
    const ordinal = parseInt(match[2], 10);
    if (!Number.isFinite(ordinal)) return null;
    const base = match[1].toLowerCase().trim();
    return base ? { base, ordinal } : null;
  }

  /** A later part may not jump ahead of an earlier part of the same story still waiting before it. */
  function waitsForEarlierPart(queue, i) {
    const mark = sequelMark(queue[i]);
    if (!mark) return false;
    for (let k = 0; k < i; k++) {
      const other = sequelMark(queue[k]);
      if (other && other.base === mark.base && other.ordinal < mark.ordinal) return true;
    }
    return false;
  }

  /**
   * Which of the first LOOKAHEAD programmes in `queue` airs at `t`: the first one no other
   * channel has on during its slot; failing that, -1 when `mustFit` (the caller has
   * something else to try), else the one that overlaps least (the earliest of those).
   * `playSec(i)` is how long candidate i would run from `t`. `avoidKey` (the title that just
   * played here) is passed over while there is anything else, and a later part of a story
   * never goes ahead of an earlier one waiting before it. With no occupancy, or nothing on
   * elsewhere, this is always 0: the channel's own order. Mirrors
   * DailyManifestScheduler.pickCandidate.
   */
  function pickCandidate(queue, t, playSec, occupancy, channelId, avoidKey, mustFit) {
    const n = Math.min(LOOKAHEAD, queue.length);
    let best = -1;
    let bestOverlap = Infinity;
    for (let i = 0; i < n; i++) {
      const item = queue[i];
      if (n > 1 && avoidKey != null && item.ratingKey === avoidKey) continue;
      if (i > 0 && waitsForEarlierPart(queue, i)) continue;
      const ov = occupancy ? occupancy.overlap(item.ratingKey, t, t + playSec(i), channelId) : 0;
      if (ov === 0) return i;
      if (ov < bestOverlap) { bestOverlap = ov; best = i; }
    }
    if (mustFit) return -1;
    return best >= 0 ? best : 0;
  }

  function packDay(pool, dayStartSec, dayNumber, channelId, yesterdayAired, isPremiereChannel, yesterdayLastRatingKey, occupancy) {
    // As long as the local day, so a 25-hour day has no empty last hour and a 23-hour day
    // doesn't run an hour into tomorrow. Same end as DailyManifestScheduler.blocks passes in.
    const dayEndSec = dayStartSec + localDayLengthSec(dayStartSec);
    const totalPoolSec = pool.reduce((s, i) => s + (i.duration || 0) * 60, 0);
    if (totalPoolSec <= 0) return [];

    const unplayed = pool.filter(i => !yesterdayAired.has(i.ratingKey));
    // Interleave for variety, then slot this week's additions at the prime-time
    // anchor so they air while people are watching, then reunite multi-part
    // stories — in that order, so a just-added Part 1 drags its Part 2 with it.
    // Same nesting as DailyManifestScheduler.packDay.
    // Premiere promotion is per-channel on purpose: promoting a new arrival on
    // every channel that carries it made one film premiere on five channels at
    // the same moment. Mirrors DailyManifestScheduler.packDay.
    const interleaved = interleaveByShow(unplayed, channelId, dayNumber);
    const promoted = isPremiereChannel
      ? promoteRecentlyAdded(interleaved, dayStartSec, channelId)
      : interleaved;
    const unplayedOrdered = groupSequelParts(promoted);

    // Cross-day seam: this function only sees one day at a time, so without this
    // guard whatever leads off today has no idea it might be the exact title that
    // finished seconds before midnight.
    if (yesterdayLastRatingKey && unplayedOrdered.length > 1 &&
        unplayedOrdered[0].ratingKey === yesterdayLastRatingKey) {
      unplayedOrdered.push(unplayedOrdered.shift());
    }
    const blocks = [];
    let t = dayStartSec;

    // In the channel's order, except that a programme another channel has on in the same
    // slot waits for a later one (pickCandidate). It stays in the queue, so it still airs
    // today if the day has room, and counts as unplayed tomorrow if not. When nothing
    // waiting fits, the day goes on with the filler loop below, which holds the whole pool.
    const queue = unplayedOrdered.filter((item) => (item.duration || 0) > 0);
    while (queue.length && t < dayEndSec) {
      const j = pickCandidate(queue, t, (i) => queue[i].duration * 60, occupancy, channelId, null, true);
      if (j < 0) break;
      const item = queue.splice(j, 1)[0];
      const dur = item.duration * 60;
      blocks.push({ ratingKey: item.ratingKey, startSec: t, endSec: t + dur });
      t += dur;
    }

    if (t < dayEndSec) {
      // Filler loop: no premiere promotion on tvOS either — sequels only.
      const orderedFull = groupSequelParts(interleaveByShow(pool, channelId, dayNumber + 1));
      const goldenShift = Math.floor(totalPoolSec * 0.6180339887);
      const offsetSec = (dayNumber * goldenShift) % totalPoolSec;

      let elapsed = 0;
      let cycleIndex = 0;
      let offsetInItem = offsetSec;
      for (let i = 0; i < orderedFull.length; i++) {
        const d = (orderedFull[i].duration || 0) * 60;
        if (elapsed + d > offsetSec) {
          cycleIndex = i;
          offsetInItem = offsetSec - elapsed;
          break;
        }
        elapsed += d;
      }

      // Wraparound seam: the cycle can land on the very item that just played.
      if (orderedFull.length > 1) {
        const lastPlayed = blocks.length ? blocks[blocks.length - 1].ratingKey : yesterdayLastRatingKey;
        if (lastPlayed && orderedFull[cycleIndex].ratingKey === lastPlayed) {
          cycleIndex = (cycleIndex + 1) % orderedFull.length;
          offsetInItem = 0;
        }
      }

      // The loop as a queue from the cycle's start: what airs goes to the back, so with
      // nothing on elsewhere this is the cycle in order. The first programme starts part
      // way in (offsetInItem) only if it airs first; one picked ahead of it starts at 0.
      const loop = orderedFull.slice(cycleIndex).concat(orderedFull.slice(0, cycleIndex))
        .filter((item) => (item.duration || 0) > 0);
      let first = true;
      while (t < dayEndSec && loop.length) {
        const remainingDay = dayEndSec - t;
        const playFor = (i) => Math.min(loop[i].duration * 60 - (first && i === 0 ? offsetInItem : 0), remainingDay);
        const lastKey = blocks.length ? blocks[blocks.length - 1].ratingKey : yesterdayLastRatingKey;
        const j = pickCandidate(loop, t, playFor, occupancy, channelId, lastKey, false);
        const playSec = playFor(j);
        const item = loop.splice(j, 1)[0];
        loop.push(item);
        first = false;
        blocks.push({ ratingKey: item.ratingKey, startSec: t, endSec: t + playSec });
        t += playSec;
      }
    }

    return blocks;
  }

  /**
   * Packs one local day for the lineup's channels whose day isn't stored yet, together, so
   * no title is on two of them at once. Channels pack in priority order (lineupPriority):
   * each one's day is its own running order (packDay) except where a programme is already on
   * another channel in that slot. Days already stored, and the programmes that run over
   * from the day before, are fixed: what airs now never moves because another channel's
   * pool changed. Writes every day it packs. Mirrors DailyManifestScheduler.packLineupDay.
   *
   * `entries`: [{ channel, pool }] with pools already valid (duration > 0, non-empty).
   * `extra`: one more { channel, pool } that is not in the guide, packed after the lineup
   * against it and seen by nothing, or null. Returns channel id -> the blocks it packed.
   */
  function packLineupDay(entries, extra, atMs, serverKey) {
    const dayStartSec = Math.floor(startOfLocalDayMs(atMs) / 1000);
    const dayKey = localDayKey(atMs);
    const dayNumber = localDayNumber(atMs);
    const yesterdayKey = previousLocalDayKey(atMs);
    const memoKey = `${serverKey}|${dayKey}`;
    // A channel off the guide, when the lineup's day is already known: pack it against that
    // and nothing else. The page builds every channel, enabled or not, and reading the
    // lineup's stored days again for each one cost ten times the whole lineup's pack.
    if (extra && occupancyMemo && occupancyMemo.key === memoKey && occupancyMemo.generation === lineupGeneration) {
      const prev = storedBlocks(serverKey, extra.channel.id, yesterdayKey);
      const packed = packDay(extra.pool, dayStartSec, dayNumber, extra.channel.id, new Set(prev.map((b) => b.ratingKey)),
                             Boolean(extra.channel.isPremiereChannel), prev.length ? prev[prev.length - 1].ratingKey : null,
                             occupancyMemo.occupancy);
      saveManifest(serverKey, { schemaVersion: SCHEMA_VERSION, channelId: extra.channel.id, dayKey,
        poolFingerprint: poolFingerprint(extra.pool), blocks: packed });
      return new Map([[extra.channel.id, packed]]);
    }
    const occupancy = makeOccupancy();
    const toPack = [];
    const packedBy = new Map();
    const all = sortByLineupPriority(entries);
    if (extra) all.push(extra);
    const yesterday = new Map();
    for (const entry of all) {
      const id = entry.channel.id;
      const prev = storedBlocks(serverKey, id, yesterdayKey);
      yesterday.set(id, prev);
      // What runs past midnight from yesterday is on air today too (the guide's channels'
      // only: one off the guide is seen by nothing).
      if (entry !== extra) for (const b of prev) if (b.endSec > dayStartSec) occupancy.add(id, b.ratingKey, b.startSec, b.endSec);
    }
    for (const entry of all) {
      const fp = poolFingerprint(entry.pool);
      const cached = loadManifest(serverKey, entry.channel.id, dayKey, fp);
      if (cached) {
        if (entry !== extra) for (const b of cached.blocks) occupancy.add(entry.channel.id, b.ratingKey, b.startSec, b.endSec);
      } else {
        toPack.push({ entry, fp });
      }
    }
    for (const { entry, fp } of toPack) {
      const { channel, pool } = entry;
      const prev = yesterday.get(channel.id);
      const aired = new Set(prev.map((b) => b.ratingKey));
      const last = prev.length ? prev[prev.length - 1].ratingKey : null;
      const packed = packDay(pool, dayStartSec, dayNumber, channel.id, aired,
                             Boolean(channel.isPremiereChannel), last, occupancy);
      saveManifest(serverKey, { schemaVersion: SCHEMA_VERSION, channelId: channel.id, dayKey, poolFingerprint: fp, blocks: packed });
      packedBy.set(channel.id, packed);
      if (entry !== extra) {
        for (const b of packed) occupancy.add(channel.id, b.ratingKey, b.startSec, b.endSec);
        lineupGeneration += 1;
      }
    }
    // Everything the guide's channels air this day, for the next channel off the guide. The
    // memo goes stale the moment one of them is packed again (lineupGeneration).
    occupancyMemo = { key: memoKey, generation: lineupGeneration, occupancy };
    return packedBy;
  }

  // The lineup's day as packLineupDay last saw it, for channels off the guide only.
  let occupancyMemo = null;
  let lineupGeneration = 0;

  /**
   * The order channels claim programmes in: channels whose pool changes with the hour
   * (timeRestrictions) last, so the others' days never depend on when a device first built
   * them; then by channel id, so the lowest keeps a title, as resolveConflicts does. Stable.
   * Mirrors DailyManifestScheduler.lineupPriority.
   */
  function sortByLineupPriority(entries) {
    const rank = (e) => (e.channel.timeRestrictions ? 1 : 0);
    return entries.slice().sort((a, b) => (rank(a) - rank(b)) || (a.channel.id - b.channel.id));
  }

  /** The stored day's blocks, whatever version stored them ([] if none). */
  function storedBlocks(serverKey, channelId, dayKey) {
    try {
      const raw = localStorage.getItem(storageKey(serverKey, channelId, dayKey));
      if (!raw) return [];
      return JSON.parse(raw).blocks || [];
    } catch {
      return [];
    }
  }

  // The guide's channels with the pools they air from, for packing a day across them:
  // a function returning [{ channel, pool }], or an array. Unset, a channel packs alone.
  let lineupSource = null;

  /** Registers the guide's lineup ({ channel, pool } pairs, or a function returning them). */
  function setLineup(source) {
    lineupSource = source || null;
    occupancyMemo = null;
  }

  function currentLineup() {
    const raw = typeof lineupSource === 'function' ? lineupSource() : lineupSource;
    const seen = new Set();
    const out = [];
    for (const entry of raw || []) {
      if (!entry || !entry.channel || seen.has(entry.channel.id)) continue;
      seen.add(entry.channel.id);
      const pool = (entry.pool || []).filter((i) => i && (i.duration || 0) > 0);
      if (pool.length) out.push({ channel: entry.channel, pool });
    }
    return out;
  }

  function resolveBlocks(storedBlocks, pool) {
    const lookup = new Map(pool.map(i => [i.ratingKey, i]));
    return storedBlocks
      .map(b => {
        const item = lookup.get(b.ratingKey);
        if (!item) return null;
        return { item, startSec: b.startSec, endSec: b.endSec };
      })
      .filter(Boolean);
  }

  function getManifestBlocks(channel, pool, atMs, serverKey) {
    const validPool = pool.filter(i => i && (i.duration || 0) > 0);
    if (!validPool.length) return [];

    const dayStartSec = Math.floor(startOfLocalDayMs(atMs) / 1000);
    const dayKey = localDayKey(atMs);
    const poolFP = poolFingerprint(validPool);
    const channelId = channel.id;

    const cached = loadManifest(serverKey, channelId, dayKey, poolFP);
    if (cached) return resolveBlocks(cached.blocks, validPool);

    // Not stored: pack the day for the whole lineup at once. This channel takes its place
    // in the lineup with the pool it was asked with; one the guide doesn't carry packs after
    // the lineup, against it, so it never changes what the guide's channels air.
    const lineup = currentLineup();
    const at = lineup.findIndex((e) => e.channel.id === channelId);
    const self = { channel, pool: validPool };
    if (at >= 0) lineup[at] = self;

    const packed = packLineupDay(lineup, at >= 0 ? null : self, atMs, serverKey).get(channelId);
    return resolveBlocks(packed || [], validPool);
  }

  // ── What airs: the guide's schedule, cross-channel conflicts, the next pick ──
  // Mirrors ChannelScheduleBuilder (Models/ChannelSchedule.swift) and
  // AppState.advanceToNextItem (App/AppState+Playback.swift). The Apple TV is the
  // reference; scripts/schedule-parity-golden.json holds the two to the same answers.

  /** Minutes from a Plex duration in ms, as PlexAPIService does: integer division, truncated. */
  function minutesFromPlexMs(ms) {
    const n = Number(ms) || 0;
    return n > 0 ? Math.floor(n / 60000) : 0;
  }

  /** Minutes from Jellyfin or Emby RunTimeTicks (100 ns), as JellyfinAPIService.minutes(fromTicks:). */
  function minutesFromTicks(ticks) {
    const n = Number(ticks) || 0;
    return n > 0 ? Math.floor(n / 600000000) : 0;
  }

  /**
   * Unix seconds from a Jellyfin or Emby DateCreated, as JellyfinAPIService.unixSeconds(fromISO:).
   * 0 when it doesn't parse: an unreadable date reads as "not recent", never "added now".
   */
  function unixSecondsFromISO(iso) {
    if (!iso) return 0;
    const ms = Date.parse(iso);
    return Number.isNaN(ms) ? 0 : Math.floor(ms / 1000);
  }

  /**
   * Every block of each local day from the day of `fromSec` to the day of `toSec` that
   * overlaps [fromSec, toSec), in start order. Mirrors DailyManifestScheduler.blocksInRange,
   * which builds each day from one hour after its midnight.
   */
  function blocksInRange(channel, pool, fromSec, toSec, serverKey) {
    const result = [];
    let cursor = startOfLocalDayMs(fromSec * 1000);
    const endDay = startOfLocalDayMs(toSec * 1000);
    while (cursor <= endDay) {
      for (const b of getManifestBlocks(channel, pool, cursor + 3600000, serverKey)) {
        if (b.endSec > fromSec && b.startSec < toSec) result.push(b);
      }
      // calendar.date(byAdding: .day, value: 1, to: cursor): the same clock time a day on.
      const next = new Date(cursor);
      next.setDate(next.getDate() + 1);
      cursor = next.getTime();
    }
    return result.sort((a, b) => a.startSec - b.startSec);
  }

  /**
   * The guide's view of a channel at `nowSec` (seconds, may be fractional): a 24-hour window
   * from the current half hour, what is on now, what is next and how far in. Mirrors
   * ChannelScheduleBuilder.buildSchedule. Returns null when the channel has nothing.
   */
  function buildSchedule(channel, pool, nowSec, serverKey) {
    const nowUnix = Math.floor(nowSec);
    const windowStart = Math.floor(nowUnix / 1800) * 1800;
    const windowEnd = windowStart + 86400;
    const dayBlocks = blocksInRange(channel, pool, windowStart, windowEnd, serverKey);
    if (!dayBlocks.length) return null;
    const entries = [];
    let nowPlaying = null;
    for (const b of dayBlocks) {
      if (!(b.endSec > windowStart && b.startSec < windowEnd)) continue;
      const isNow = b.startSec <= nowSec && b.endSec > nowSec;
      const entry = { id: `${b.item.ratingKey}_${b.startSec}`, item: b.item, startSec: b.startSec, endSec: b.endSec,
        isNowPlaying: isNow, isConflict: false };
      entries.push(entry);
      if (isNow) nowPlaying = entry;
    }
    if (!nowPlaying) nowPlaying = entries.find((e) => e.startSec <= nowSec && e.endSec > nowSec) || null;
    const nowIdx = entries.findIndex((e) => e.isNowPlaying);
    const upNext = nowIdx >= 0 && nowIdx + 1 < entries.length ? entries[nowIdx + 1] : null;
    let progress = 0;
    let elapsedSeconds = 0;
    if (nowPlaying) {
      const elapsed = nowSec - nowPlaying.startSec;
      const dur = nowPlaying.endSec - nowPlaying.startSec;
      progress = dur > 0 ? elapsed / dur : 0;
      elapsedSeconds = Math.max(0, Math.trunc(elapsed));
    }
    return { entries, nowPlaying, upNext, progress, elapsedSeconds };
  }

  /** Mirrors ChannelSchedule.isCurrent: the schedule still describes what is on at `nowSec`. */
  function scheduleIsCurrent(schedule, nowSec) {
    const np = schedule && schedule.nowPlaying;
    return Boolean(np) && np.startSec <= nowSec && nowSec < np.endSec;
  }

  /**
   * Seconds into what is on now, from the clock, capped at the programme's length. Mirrors
   * ChannelSchedule.livePlayback(at:).elapsedSeconds. null when nothing is on.
   */
  function liveElapsedSeconds(schedule, nowSec) {
    const np = schedule && schedule.nowPlaying;
    if (!np) return null;
    const total = Math.max(1, (np.item.duration || 0) * 60);
    return Math.max(0, Math.min(total, Math.trunc(nowSec - np.startSec)));
  }

  /**
   * What tuning to a channel plays, and from where. Mirrors AppState.selectChannel: the
   * guide's schedule (`precomputed`, may be null) only while it still describes what is on,
   * otherwise one built now; the offset from the clock. A channel the guide shows giving way
   * to a lower one still plays the title it gave way with, as on the Apple TV, because the
   * schedule shown for it starts in the future. Returns { item, seekSeconds }, or null where
   * the Apple TV would pick at random (no schedule, or nothing on).
   */
  function tuneIn(channel, pool, precomputed, nowSec, serverKey) {
    const usable = precomputed && scheduleIsCurrent(precomputed, nowSec) ? precomputed : null;
    const schedule = usable || buildSchedule(channel, pool, nowSec, serverKey);
    if (!schedule || !schedule.nowPlaying) return null;
    const live = liveElapsedSeconds(schedule, nowSec);
    return { item: schedule.nowPlaying.item, seekSeconds: live == null ? schedule.elapsedSeconds : live };
  }

  /**
   * One title on two channels at once: the lowest channel id keeps it, every other channel
   * shows its next programme as now playing, from its start. One pass, as on the Apple TV:
   * a channel moved on is not checked again. `schedules` is a Map of channel id to the
   * result of buildSchedule; it is changed in place. Mirrors ChannelScheduleBuilder.resolveConflicts.
   */
  function resolveConflicts(schedules) {
    const byItem = new Map();
    for (const [channelId, schedule] of schedules) {
      if (!schedule || !schedule.nowPlaying) continue;
      const key = schedule.nowPlaying.item.ratingKey;
      if (!byItem.has(key)) byItem.set(key, []);
      byItem.get(key).push(channelId);
    }
    for (const ids of byItem.values()) {
      if (ids.length < 2) continue;
      const losers = [...ids].sort((a, b) => a - b).slice(1);
      for (const id of losers) {
        const old = schedules.get(id);
        const entries = old.entries.slice();
        const i = entries.findIndex((e) => e.isNowPlaying);
        if (i >= 0) entries[i] = { ...entries[i], isNowPlaying: false, isConflict: true };
        if (old.upNext) {
          const nowPlaying = { ...old.upNext, isNowPlaying: true, isConflict: false };
          const j = entries.findIndex((e) => e.id === old.upNext.id);
          const upNext = j >= 0 && j + 1 < entries.length ? entries[j + 1] : null;
          schedules.set(id, { entries, nowPlaying, upNext, progress: 0, elapsedSeconds: 0 });
        } else {
          schedules.set(id, { ...old, entries });
        }
      }
    }
    return schedules;
  }

  /**
   * The first other channel (in `channels` order) whose programme now is `item`, or null.
   * `channels` are { channel, pool } pairs. Mirrors ChannelScheduleBuilder.findConflict.
   */
  function findConflict(item, excludingChannelId, channels, nowSec, serverKey) {
    for (const { channel, pool } of channels) {
      if (channel.id === excludingChannelId) continue;
      const schedule = buildSchedule(channel, pool, nowSec, serverKey);
      if (schedule && schedule.nowPlaying && schedule.nowPlaying.item.ratingKey === item.ratingKey) return channel.id;
    }
    return null;
  }

  /**
   * What a channel plays next when its programme ends, and from where. Mirrors
   * AppState.advanceToNextItem: the schedule's programme if it has moved on, otherwise the
   * next one; never the title another channel has on right now (skip one entry); from 0 on
   * a natural end. Returns { item, seekSeconds }, or null where the Apple TV would pick at
   * random (no schedule).
   */
  function advancePick(channel, pool, prevRatingKey, nowSec, channels, serverKey, fromNaturalEnd = true) {
    const schedule = buildSchedule(channel, pool, nowSec, serverKey);
    if (!schedule) return null;
    const moved = (schedule.nowPlaying ? schedule.nowPlaying.item.ratingKey : null) !== (prevRatingKey ?? null);
    let pick = moved
      ? (schedule.nowPlaying ? schedule.nowPlaying.item : null)
      : ((schedule.upNext && schedule.upNext.item) || (schedule.nowPlaying ? schedule.nowPlaying.item : null));
    let seekSeconds = moved && pick && !fromNaturalEnd ? schedule.elapsedSeconds : 0;
    if (pick && findConflict(pick, channel.id, channels, nowSec, serverKey) != null) {
      const idx = schedule.entries.findIndex((e) => e.item.ratingKey === pick.ratingKey);
      if (idx >= 0 && idx + 1 < schedule.entries.length) {
        pick = schedule.entries[idx + 1].item;
        seekSeconds = 0;
      }
    }
    return pick ? { item: pick, seekSeconds } : null;
  }

  function clearManifests(serverKey) {
    try {
      const prefix = `${MANIFEST_PREFIX}${serverKey}_`;
      const toRemove = [];
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith(prefix)) toRemove.push(key);
      }
      toRemove.forEach(k => localStorage.removeItem(k));
      occupancyMemo = null;
      lineupGeneration += 1;
    } catch { /* ignore */ }
  }

  const api = {
    getManifestBlocks,
    setLineup,
    blocksInRange,
    buildSchedule,
    scheduleIsCurrent,
    liveElapsedSeconds,
    tuneIn,
    resolveConflicts,
    findConflict,
    advancePick,
    minutesFromPlexMs,
    minutesFromTicks,
    unixSecondsFromISO,
    clearManifests,
    interleaveByShow,
    promoteRecentlyAdded,
    premiereOffset,
    groupSequelParts,
    packDay,
    localDayNumber,
    localDayKey,
    startOfLocalDayMs,
    startOfNextLocalDayMs,
    previousLocalDayKey,
  };

  global.NostalgexDailyManifest = api;
  // Node (tests/devtools) — the browser keeps loading this as a plain script.
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
