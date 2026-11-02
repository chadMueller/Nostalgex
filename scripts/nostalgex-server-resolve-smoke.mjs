#!/usr/bin/env node
/**
 * Which address of a Plex server the web tuner uses, and how soon it knows.
 *
 * Runs scripts/nostalgex-server-resolve.js on a virtual clock (nothing waits in real time) with
 * the cases of the Apple TV's ConnectionDiscoveryEarlyExitTests.swift and Roku's
 * ServerResolveTests.brs, plus a seeded property check over random servers: the answer is always
 * an address that answered, from the best kind that answered, never null while any address
 * answered in time, and never later than waiting for everything would have been.
 *
 * The real page, with real sockets and real timeouts, is
 * scripts/plex-resolve-browser-smoke.mjs.
 *
 * Run: `npm run test:plex-resolve`
 */
import "./nostalgex-server-resolve.js";

const R = globalThis.NostalgexServerResolve;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

// ── A virtual clock: timers and probe answers fire in time order, microtasks drain between ──
async function flush() { for (let i = 0; i < 12; i++) await Promise.resolve(); }

/**
 * addresses: [{ conn, delay, ok }] in plex.tv's order. delay is when the probe reports.
 * Returns { found, at, aborted: [address indexes whose probe was told to stop] }.
 */
async function simulate(addresses, options = {}) {
  let time = 0;
  const queue = [];
  let seq = 0;
  const schedule = (fn, ms) => { const e = { t: time + ms, n: seq++, fn, live: true }; queue.push(e); return e; };
  const clock = {
    now: () => time,
    setTimeout: (fn, ms) => schedule(fn, ms),
    clearTimeout: (e) => { if (e) e.live = false; },
  };
  const aborted = new Set();
  const byConn = new Map(addresses.map((a, i) => [a.conn, i]));
  const probe = (conn, signal) => new Promise((resolve) => {
    const a = addresses[byConn.get(conn)];
    if (signal) signal.addEventListener("abort", () => aborted.add(byConn.get(conn)), { once: true });
    schedule(() => resolve(a.throws ? Promise.reject(new Error("boom")) : a.ok), a.delay);
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
  return { found, at, aborted, settled };
}

const home = (uri = "https://192-168-1-5.abc.plex.direct:32400") => ({ uri, local: true, relay: false, protocol: uri.split(":")[0] });
const remote = (uri = "https://203-0-113-9.abc.plex.direct:32400") => ({ uri, local: false, relay: false, protocol: uri.split(":")[0] });
const relay = (uri = "https://relay.plex.direct:8443") => ({ uri, local: false, relay: true, protocol: "https" });
const at = (conn, delay, ok) => ({ conn, delay, ok });

// ── The order: Roku's ServerResolveTests "order" case ──
{
  const order = R.candidates([
    { uri: "https://relay.plex.direct:8443", local: false, relay: true },
    { uri: "https://remote.plex.direct:32400", local: false, relay: false },
    { uri: "https://local.plex.direct:32400", local: true, relay: false },
    { uri: "http://10.0.0.20:32400", local: true, relay: false },
    { uri: "https://public.plex.direct:32400", local: true, relay: false },
    { uri: "http://203.0.113.9:32400", local: false, relay: false },
    { uri: "https://relay-lan.plex.direct:8443", local: true, relay: true },
  ]).map((c) => `${c.kind}:${c.uri.replace(/^https?:\/\//, "").split(".")[0]}`);
  check("order: home (HTTPS first), remote HTTPS, remote plain, relay",
    order.join(" ") === "local:local local:public local:10 remote:remote remote (plain):203 relay:relay relay:relay-lan", order.join(" "));
  check("a relay is a relay even with a home-network flag", R.tierOf({ uri: "https://x", local: true, relay: true }) === 3);
  check("no addresses: nothing to try", R.candidates([]).length === 0 && R.candidates(null).length === 0 && R.candidates([{}, { uri: "" }, null]).length === 0);
  const r = await simulate([]);
  check("no addresses resolves to null at once", r.found === null && r.at === 0);
}

// ── outcome(): Roku's rules, state by state ──
{
  const c = (...conns) => R.candidates(conns);
  const mark = (cands, uri, status) => { cands.find((x) => x.uri === uri).status = status; };
  const L = home(), L2 = home("http://192.168.1.5:32400"), M = remote(), M2 = remote("https://remote-b.plex.direct:32400"), X = relay();

  let cs = c(L, L2, M, X);
  check("nothing back yet: waiting", R.outcome(cs, 100, 3000, false).settled === false);
  mark(cs, M.uri, "ok");
  check("remote answers, home still inside its grace: keep waiting", R.outcome(cs, 1000, 3000, false).settled === false);
  let o = R.outcome(cs, 3000, 3000, false);
  check("after the grace the home addresses count as failed: remote settles", o.settled && o.conn.uri === M.uri && o.kind === "remote");

  cs = c(L, L2, M, X);
  mark(cs, L.uri, "ok");
  o = R.outcome(cs, 200, 3000, false);
  check("a home answer settles at once, with its siblings and the rest still waiting", o.settled && o.conn.uri === L.uri && o.kind === "local");

  cs = c(L, M, X);
  mark(cs, L.uri, "fail"); mark(cs, M.uri, "fail"); mark(cs, X.uri, "ok");
  check("relay answered, home and remote failed: settled on the relay", R.outcome(cs, 100, 3000, false).settled && R.outcome(cs, 100, 3000, false).conn.uri === X.uri);
  cs = c(L, M, X);
  mark(cs, L.uri, "fail"); mark(cs, X.uri, "ok");
  check("relay answered, remote still waiting: wait for the better kind", R.outcome(cs, 5000, 3000, false).settled === false);
  o = R.outcome(cs, 10000, 3000, true);
  check("at the deadline the waiting remote counts as failed: relay settles", o.settled && o.conn.uri === X.uri);

  cs = c(L, M, X);
  o = R.outcome(cs, 10000, 3000, true);
  check("nothing answers by the deadline: settled with no address", o.settled && o.conn === null);
  cs = c(L, M, X);
  cs.forEach((x) => { x.status = "fail"; });
  check("everything failed: settled with no address, before any deadline", R.outcome(cs, 10, 3000, false).settled && R.outcome(cs, 10, 3000, false).conn === null);

  cs = c(M, M2);
  mark(cs, M2.uri, "ok");
  o = R.outcome(cs, 400, 3000, false);
  check("two remote addresses: one answering settles while its sibling waits", o.settled && o.conn.uri === M2.uri);

  cs = c(L, L2);
  mark(cs, L2.uri, "ok");
  o = R.outcome(cs, 40, 3000, false);
  check("two home addresses: the plain one answering settles while the HTTPS one waits", o.settled && o.conn.uri === L2.uri);
}

// ── ConnectionDiscoveryEarlyExitTests.swift, on the virtual clock ──
{
  const L = home(), M = remote(), P = remote("http://203.0.113.9:32400"), X = relay();

  let r = await simulate([at(L, 50, true), at(M, 400, false), at(P, 400, false), at(X, 2000, false)]);
  check("a fast home answer does not wait on a slow later address", r.found.conn === L && r.at === 50, `${r.at}`);
  check("and the slow probes are told to stop", r.aborted.has(1) && r.aborted.has(2) && r.aborted.has(3), [...r.aborted].join(","));

  r = await simulate([at(L, 60, false), at(M, 120, true), at(P, 1500, false), at(X, 1500, true)]);
  check("home fails, remote answers: remote wins without waiting on the worse kinds", r.found.conn === M && r.at === 120, `${r.at}`);

  r = await simulate([at(L, 30, false), at(M, 60, false), at(X, 90, false)]);
  check("nothing answers: null, once every address has reported", r.found === null && r.at === 90, `${r.found} ${r.at}`);

  r = await simulate([at(L, 200, true), at(M, 50, true)], { graceMs: 500 });
  check("a better kind that answers inside the grace still wins over an earlier answer", r.found.conn === L && r.at === 200, `${r.at}`);

  r = await simulate([at(L, 2500, false), at(M, 2500, false), at(X, 50, true)]);
  check("relay answered fast, remote slow to fail: waits for the remote, then relay", r.found.conn === X && r.at === 2500, `${r.at}`);

  r = await simulate([at(L, 400, false), at(M, 50, true)], { graceMs: 60 });
  check("only a home address is still waiting: it gets the short grace, not its whole timeout", r.found.conn === M && r.at === 60, `${r.at}`);

  r = await simulate([at(L, 2500, false), at(M, 120, true), at(X, 50, true)], { graceMs: 200 });
  check("remote answers inside the grace and outranks the relay that answered first", r.found.conn === M && r.at === 200, `${r.at}`);

  // The web's own numbers: 3 s grace for home, a dead home address does not hold up a remote answer longer.
  r = await simulate([at(L, 5000, false), at(M, 150, true), at(X, 5000, false)]);
  check("a dead home address costs 3 s, not its 5 s timeout", r.found.conn === M && r.at === 3000, `${r.at}`);

  r = await simulate([at(L, 5000, false), at(M, 5000, false), at(X, 5000, false)]);
  check("all dead: null after the last timeout, as before", r.found === null && r.at === 5000, `${r.at}`);

  // A probe that throws, or answers something other than true, is a failure, not a crash.
  r = await simulate([{ conn: L, delay: 10, throws: true }, at(M, 20, "yes"), at(X, 30, true)]);
  check("a probe that throws, or answers something that is not true, fails; the next address is used", r.found.conn === X, `${r.found && r.found.conn.uri}`);

  // The grace only applies once something else has answered: a slow home address that is the
  // only way in is waited for, as it was before the early exit.
  r = await simulate([at(L, 4200, true)]);
  check("a lone home address that answers after 3 s is still found", r.found && r.found.conn === L && r.at === 4200, `${r.at}`);
  r = await simulate([at(L, 4200, true), at(M, 3600, false), at(X, 100, false)]);
  check("home answers at 4.2 s, remote and relay failed: found, not given up on at 3 s", r.found && r.found.conn === L && r.at === 4200, `${r.at}`);
  r = await simulate([at(L, 4200, true), at(M, 3600, false), at(X, 3900, true)]);
  check("a relay answers at 3.9 s with home still silent: the home address has had its 3 s, the relay is used", r.found && r.found.conn === X && r.at === 3900, `${r.at}`);

  // Home answers late (after its grace) while remote has answered: the remote stays the choice.
  r = await simulate([at(L, 3500, true), at(M, 150, true)]);
  check("a home answer after the grace is too late: the remote already settled", r.found.conn === M && r.at === 3000, `${r.at}`);

  // The deadline backs up the probes' own timeouts.
  r = await simulate([at(L, 60000, true), at(M, 60000, true), at(X, 100, true)], { deadlineMs: 10000 });
  check("a probe that never reports cannot hold the answer past the deadline", r.found.conn === X && r.at === 10000, `${r.at}`);
}

// ── identityMatches: only a different identifier turns an address down ──
{
  const id = (v) => ({ MediaContainer: { machineIdentifier: v } });
  check("same machineIdentifier matches", R.identityMatches(id("abc"), "abc") === true);
  check("another server's identifier does not", R.identityMatches(id("xyz"), "abc") === false);
  check("no identifier on file: accepted, as before", R.identityMatches(id("xyz"), "") === true);
  check("a body that is not Plex JSON: accepted, as before", R.identityMatches(null, "abc") === true && R.identityMatches("<xml/>", "abc") === true && R.identityMatches({}, "abc") === true);
  check("an answer with no identifier: accepted, as before", R.identityMatches({ MediaContainer: {} }, "abc") === true);
}

// ── A seeded property check over random servers ──
{
  let seed = 20261102;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
  const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
  const GRACE = 3000;
  let cases = 0, withAnswer = 0, lateHome = 0;
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
    const r = await simulate(addrs);
    cases += 1;
    const tierOf = (a) => R.tierOf(a.conn);
    const anyOk = addrs.some((a) => a.ok === true);
    const label = JSON.stringify(addrs.map((a) => [a.conn.uri, a.delay, a.ok]));
    // Every probe reports well inside the deadline, so something that answered is always found.
    if (!anyOk) {
      check(`property ${i}: no address answers: null`, r.found === null, label);
      continue;
    }
    withAnswer += 1;
    check(`property ${i}: an address answered, so there is an answer`, r.found !== null, label);
    if (r.found === null) continue;
    const winner = addrs.find((a) => a.conn === r.found.conn);
    check(`property ${i}: the winner is an address that answered`, !!winner && winner.ok === true, label);
    if (!winner) continue;
    check(`property ${i}: not before the winner answered`, r.at >= winner.delay, `${r.at} < ${winner.delay}`);
    check(`property ${i}: never later than waiting for everything`, r.at <= Math.max(...addrs.map((a) => a.delay)) + 1, `${r.at}`);
    // The best kind: nothing better had answered by then, and every better kind had reported
    // failure, or was a home address past its grace (answers late or never).
    const better = addrs.filter((a) => tierOf(a) < tierOf(winner));
    check(`property ${i}: no better kind had answered when it settled`, better.every((a) => !(a.ok === true && a.delay <= r.at)), label);
    check(`property ${i}: every better kind had failed, or was a home address past its grace`,
      better.every((a) => (a.delay <= r.at && a.ok === false) || (tierOf(a) === 0 && r.at >= GRACE && a.delay > r.at)), `${r.at} ${label}`);
    // The grace is for a home address with a worse answer already in hand; it never ends a wait
    // with nothing: a lone slow home address that answers is found.
    if (better.some((a) => a.ok === true)) lateHome += 1;
  }
  check("property: random servers covered a mix of outcomes", cases === 400 && withAnswer > 100 && withAnswer < 400, `${withAnswer}/${cases}`);
  check("property: some cases settled before a slower home address answered", lateHome > 0, String(lateHome));
}

if (failures.length) {
  console.error(`server resolve: ${failures.length} failed, ${passed} passed`);
  for (const f of failures.slice(0, 40)) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`server resolve: ${passed} checks passed`);
