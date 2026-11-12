// Vectors for GuideTimeoutTests.brs (issue #274): what the web tuner's own module
// (scripts/nostalgex-guide-timeout.js, parity with the Apple TV's GuideTimeout.swift) answers for the stored values,
// what one press on the row moves to, the label and the seconds, and whether a guide left alone is due.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function guideTimeoutVectors(upstream) {
  const scope = {};
  new Function("globalThis", "window", readFileSync(join(upstream, "scripts", "nostalgex-guide-timeout.js"), "utf8"))(scope, scope);
  const G = scope.NostalgexGuideTimeout;
  if (!G || typeof G.parse !== "function" || typeof G.next !== "function" || typeof G.isDue !== "function") {
    throw new Error("upstream nostalgex-guide-timeout.js changed shape: no parse, next or isDue");
  }
  // null stands for "nothing saved"; the Roku reads it as invalid.
  const stored = [null, "off", "5m", "15m", "", "10m", "OFF", "5M", "x"];
  const values = stored.map((v) => ({ stored: v, parse: G.parse(v), next: G.next(v), label: G.label(v), seconds: G.seconds(v) }));
  const due = [];
  for (const v of ["off", "5m", "15m", null, "junk"]) {
    for (const [last, now] of [[0, 0], [0, 299000], [0, 300000], [0, 300001], [0, 899999], [0, 900000], [1000, 301000], [1000, 300999]]) {
      due.push({ stored: v, lastSec: last / 1000, nowSec: now / 1000, due: G.isDue(v, last, now) });
    }
  }
  return { default: G.DEFAULT, key: G.STORAGE_KEY, values, due };
}
