// UTC offsets for the zones in upstream's scripts/schedule-dst-golden.json and
// schedule-parity-golden.json, which ScheduleDSTGoldenTests.brs and
// ScheduleParityGoldenTests.brs read (copied unchanged to tests/vectors/).
// The golden file names its zones; the port pins a zone the way LineupTests
// does, as GetGlobalAA().nxTzOffsets, [{ fromSec, offsetSec }] in time order.
// The offsets come from the tz database through Intl, which node 22 has (it
// has no Temporal), not from either engine, so a wrong port can't make them
// agree with it. Called by tests/gen-vectors.mjs, which owns the output.
import { readFileSync } from "node:fs";
import { join } from "node:path";

const formats = new Map();
function offsetSec(zone, sec) {
  let f = formats.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: zone, hourCycle: "h23",
      year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric",
    });
    formats.set(zone, f);
  }
  const p = Object.fromEntries(f.formatToParts(new Date(sec * 1000)).map((x) => [x.type, Number(x.value)]));
  return Date.UTC(p.year, p.month - 1, p.day, p.hour % 24, p.minute, p.second) / 1000 - sec;
}

// Each zone's offsets from lo to hi: [{ fromSec, offsetSec }] in time order.
function zoneOffsets(zones, lo, hi) {
  const out = {};
  for (const zone of zones) {
    const offsets = [{ fromSec: 0, offsetSec: offsetSec(zone, lo) }];
    for (let t = lo; t < hi; t += 900) {
      if (offsetSec(zone, t + 900) === offsetSec(zone, t)) continue;
      // The first second on the new offset.
      let a = t, b = t + 900;
      while (b - a > 1) {
        const mid = Math.floor((a + b) / 2);
        if (offsetSec(zone, mid) === offsetSec(zone, t)) a = mid; else b = mid;
      }
      offsets.push({ fromSec: b, offsetSec: offsetSec(zone, b) });
    }
    out[zone] = offsets;
  }
  return out;
}

export function dstZones(upstream) {
  const golden = JSON.parse(readFileSync(join(upstream, "scripts", "schedule-dst-golden.json"), "utf8"));
  // Three days either side of the vectors: the tests look back to the day
  // before yesterday.
  const lo = Math.min(...golden.days.map((d) => d.start)) - 3 * 86400;
  const hi = Math.max(...golden.days.map((d) => d.nextStart)) + 3 * 86400;
  return { range: { fromSec: lo, toSec: hi }, zones: zoneOffsets([...new Set(golden.days.map((d) => d.zone))], lo, hi) };
}

// The same for scripts/schedule-parity-golden.json's zones, which
// ScheduleParityGoldenTests.brs reads: three days either side of every
// instant a case names.
export function parityZones(upstream) {
  const golden = JSON.parse(readFileSync(join(upstream, "scripts", "schedule-parity-golden.json"), "utf8"));
  const times = golden.cases.flatMap((c) => [...c.fixture.prime, ...c.fixture.days, ...c.fixture.at]);
  const lo = Math.min(...times) - 3 * 86400;
  const hi = Math.max(...times) + 3 * 86400;
  return { range: { fromSec: lo, toSec: hi }, zones: zoneOffsets([...new Set(golden.cases.map((c) => c.fixture.zone))], lo, hi) };
}
