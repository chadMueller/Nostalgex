// The web tuner's Plex address choice (scripts/nostalgex-server-resolve.js) on a virtual clock,
// as scripts/nostalgex-server-resolve-smoke.mjs runs it: the smoke's named cases (the Apple TV's
// ConnectionDiscoveryEarlyExitTests and Roku's ServerResolveTests) and its 400 seeded random
// servers, each with the address the module chose and when. Run by the engine's
// `genResolveVectors` task before its tests; ServerResolveTest replays every case.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");
const out = process.argv[2];
if (!out) throw new Error("usage: gen-resolve-vectors.mjs <out.json>");
await import(resolve(repoRoot, "scripts/nostalgex-server-resolve.js"));
const R = globalThis.NostalgexServerResolve;

async function flush() { for (let i = 0; i < 12; i++) await Promise.resolve(); }

/** The smoke's simulate: timers and probe answers fire in time order, ties in the order they were set. */
async function simulate(addresses, options = {}) {
  let time = 0;
  const queue = [];
  let seq = 0;
  const schedule = (fn, ms) => { const e = { t: time + ms, n: seq++, fn, live: true }; queue.push(e); return e; };
  const clock = { now: () => time, setTimeout: (fn, ms) => schedule(fn, ms), clearTimeout: (e) => { if (e) e.live = false; } };
  const byConn = new Map(addresses.map((a, i) => [a.conn, i]));
  const probe = (conn) => new Promise((done) => {
    const a = addresses[byConn.get(conn)];
    schedule(() => done(a.throws ? Promise.reject(new Error("boom")) : a.ok), a.delay);
  });
  let found;
  let at = null;
  let settled = false;
  R.resolve(addresses.map((a) => a.conn), probe, { ...clock, ...options }).then((r) => { found = r; at = time; settled = true; });
  await flush();
  while (!settled && queue.length) {
    queue.sort((a, b) => a.t - b.t || a.n - b.n);
    const e = queue.shift();
    if (!e.live) continue;
    time = e.t;
    e.fn();
    await flush();
  }
  await flush();
  return { uri: found ? found.conn.uri : null, kind: found ? found.kind : null, at };
}

const home = (uri = "https://192-168-1-5.abc.plex.direct:32400") => ({ uri, local: true, relay: false });
const remote = (uri = "https://203-0-113-9.abc.plex.direct:32400") => ({ uri, local: false, relay: false });
const relay = (uri = "https://relay.plex.direct:8443") => ({ uri, local: false, relay: true });
const at = (conn, delay, ok) => ({ conn, delay, ok });

const runs = [];
async function run(name, addresses, options = {}) {
  const want = await simulate(addresses, options);
  runs.push({
    name,
    graceMs: options.graceMs ?? R.GRACE_MS,
    deadlineMs: options.deadlineMs ?? R.DEADLINE_MS,
    // A probe that throws or answers anything but true is a failure: `ok` is what it counts as.
    addresses: addresses.map((a) => ({ ...a.conn, delay: a.delay, ok: !a.throws && a.ok === true })),
    want,
  });
}

const L = home(), M = remote(), P = remote("http://203.0.113.9:32400"), X = relay();
await run("no addresses", []);
await run("a fast home answer does not wait on a slow later address", [at(L, 50, true), at(M, 400, false), at(P, 400, false), at(X, 2000, false)]);
await run("home fails, remote answers", [at(L, 60, false), at(M, 120, true), at(P, 1500, false), at(X, 1500, true)]);
await run("nothing answers", [at(L, 30, false), at(M, 60, false), at(X, 90, false)]);
await run("a better kind inside the grace wins over an earlier answer", [at(L, 200, true), at(M, 50, true)], { graceMs: 500 });
await run("relay fast, remote slow to fail", [at(L, 2500, false), at(M, 2500, false), at(X, 50, true)]);
await run("only a home address waiting gets the short grace", [at(L, 400, false), at(M, 50, true)], { graceMs: 60 });
await run("remote inside the grace outranks an earlier relay", [at(L, 2500, false), at(M, 120, true), at(X, 50, true)], { graceMs: 200 });
await run("a dead home address costs 3 s", [at(L, 5000, false), at(M, 150, true), at(X, 5000, false)]);
await run("all dead", [at(L, 5000, false), at(M, 5000, false), at(X, 5000, false)]);
await run("a probe that throws or answers not-true fails", [{ conn: L, delay: 10, throws: true }, at(M, 20, "yes"), at(X, 30, true)]);
await run("a lone slow home address is still found", [at(L, 4200, true)]);
await run("home at 4.2 s, the rest failed", [at(L, 4200, true), at(M, 3600, false), at(X, 100, false)]);
await run("a relay at 3.9 s with home silent", [at(L, 4200, true), at(M, 3600, false), at(X, 3900, true)]);
await run("a home answer after the grace is too late", [at(L, 3500, true), at(M, 150, true)]);
await run("the deadline backs up the probes", [at(L, 60000, true), at(M, 60000, true), at(X, 100, true)], { deadlineMs: 10000 });

// The smoke's seeded random servers, the same seed and draws.
let seed = 20261102;
const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
for (let i = 0; i < 400; i++) {
  const n = 1 + Math.floor(rnd() * 6);
  const addrs = [];
  for (let k = 0; k < n; k++) {
    const kind = pick(["local", "local-http", "remote", "remote-http", "relay"]);
    const conn = kind === "local" ? home(`https://l${k}.plex.direct:32400`)
      : kind === "local-http" ? home(`http://10.0.0.${k}:32400`)
      : kind === "remote" ? remote(`https://r${k}.plex.direct:32400`)
      : kind === "remote-http" ? remote(`http://203.0.113.${k}:32400`)
      : relay(`https://x${k}.plex.direct:8443`);
    addrs.push(at(conn, 5 + Math.floor(rnd() * 4900), rnd() < 0.45));
  }
  await run(`random ${i}`, addrs);
}

// The order, and the identity check.
const orderInput = [
  { uri: "https://relay.plex.direct:8443", local: false, relay: true },
  { uri: "https://remote.plex.direct:32400", local: false, relay: false },
  { uri: "https://local.plex.direct:32400", local: true, relay: false },
  { uri: "http://10.0.0.20:32400", local: true, relay: false },
  { uri: "https://public.plex.direct:32400", local: true, relay: false },
  { uri: "http://203.0.113.9:32400", local: false, relay: false },
  { uri: "https://relay-lan.plex.direct:8443", local: true, relay: true },
];
const order = { input: orderInput, want: R.candidates(orderInput).map((c) => ({ uri: c.uri, kind: c.kind })) };
const id = (v) => ({ MediaContainer: { machineIdentifier: v } });
const identity = [
  [id("abc"), "abc"], [id("xyz"), "abc"], [id("xyz"), ""], [null, "abc"], [{}, "abc"], [{ MediaContainer: {} }, "abc"],
].map(([json, expected]) => ({ answered: json && json.MediaContainer ? json.MediaContainer.machineIdentifier ?? null : null, expected, want: R.identityMatches(json, expected) }));

mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify({ runs, order, identity }, null, 1));
console.log(`resolve vectors: ${runs.length} runs (${runs.filter((r) => r.want.uri).length} with an answer)`);
