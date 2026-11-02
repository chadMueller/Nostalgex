// Which address of a Plex server to use: ask them all at once, and stop waiting once the
// answer cannot change.
//
// PARITY with tvOS and Roku
//   Nostalgex/Nostalgex/Services/PlexAPIService.swift   bestReachableURI (the order, the early exit)
//   Nostalgex/NostalgexTests/ConnectionDiscoveryEarlyExitTests.swift   its cases
//   roku/source/plex/ServerResolve.brs                  NxResolveCandidates, NxResolveOutcome
//   roku/tests/ServerResolveTests.brs                   its cases
//
// plex.tv lists every way to reach a server: a home-network address, a remote one, relays.
// The web tuner used to test all of them with Promise.all and take the best that answered, so
// every sign-in waited for the slowest address even when the home-network one answered in 30 ms,
// and a dead remote address cost its whole 5 s timeout on every start.
//
// The rules, the Apple TV's and Roku's:
//   - Order: home network (local, not relay), then remote HTTPS, then remote plain, then relay.
//     Within one kind, HTTPS first. The best kind that answers wins.
//   - Addresses of one kind are equally good: one that answered is not held up by a sibling still
//     waiting, only by a better kind.
//   - So the answer is settled as soon as the best kind that has answered has nothing better left
//     waiting. A home-network answer settles at once.
//   - A home-network address answers fast or not at all: after graceMs (3 s) one that has not
//     answered counts as failed, so a remote answer is not held up by a dead LAN address. Only
//     when some other address has answered: with no answer anywhere yet, a slow home address is
//     still waited for (up to its own timeout), since an answer from it beats none.
//   - Remote and relay addresses can legitimately be slow, so they are waited for, up to each
//     probe's own timeout. After deadlineMs everything still waiting counts as failed.
//   - Nothing answering is a result too: null, after every probe has reported.
// What this never does: take a worse address because it was quick when a better one is only slow
// within its time, or return null while any address answered.
//
// The web differs from the apps in one way: a probe here is /identity alone (5 s timeout, no
// retry), not /identity and /library/sections with 12 s or 25 s and a retry. The page checks the
// answer is this server's (identityMatches), as Roku does, since a private address on some other
// network can be another Plex server.
//
// USAGE (browser: plain <script src="scripts/nostalgex-server-resolve.js">,
// node: `import "./nostalgex-server-resolve.js"`, then globalThis):
//
//   const R = window.NostalgexServerResolve;
//   const found = await R.resolve(server.connections, (conn, signal) => probe(conn.uri, signal));
//   found && found.conn.uri;   // the address to use, or null when none answered

(function (global) {
  'use strict';

  const GRACE_MS = 3000;       // a home-network address that has not answered by now counts as failed
  const DEADLINE_MS = 10000;   // everything still waiting counts as failed

  /** 0 home network, 1 remote HTTPS, 2 remote plain, 3 relay (a relay is a relay even on the LAN). */
  function tierOf(conn) {
    if (conn.relay) return 3;
    if (conn.local) return 0;
    return /^https:/i.test(conn.uri || '') ? 1 : 2;
  }

  const KINDS = ['local', 'remote', 'remote (plain)', 'relay'];

  /**
   * The addresses to try, best first: by kind, HTTPS before plain within a kind, plex.tv's own
   * order after that. Each starts waiting (status '').
   */
  function candidates(connections) {
    const list = [];
    (Array.isArray(connections) ? connections : []).forEach((conn, index) => {
      if (!conn || typeof conn.uri !== 'string' || !conn.uri) return;
      list.push({ conn, uri: conn.uri, tier: tierOf(conn), kind: KINDS[tierOf(conn)], index, status: '' });
    });
    const https = (c) => (/^https:/i.test(c.uri) ? 0 : 1);
    return list.sort((a, b) => a.tier - b.tier || https(a) - https(b) || a.index - b.index);
  }

  /**
   * 'ok', 'fail', or '' (still waiting). A home-network address waiting past graceMs has failed,
   * but only once another address has answered: until then nothing is a better answer than it.
   */
  function statusOf(c, elapsedMs, graceMs, expired, someoneAnswered) {
    if (c.status !== '') return c.status;
    if (expired || (someoneAnswered && c.tier === 0 && elapsedMs >= graceMs)) return 'fail';
    return '';
  }

  /**
   * What the candidates say so far: { settled, conn, kind }. Settled once nothing still waiting
   * could change the answer (NxResolveOutcome). conn is null when settled with no answer.
   */
  function outcome(cands, elapsedMs, graceMs, expired) {
    const someoneAnswered = cands.some((c) => c.status === 'ok');
    for (let tier = 0; tier <= 3; tier++) {
      let waiting = false;
      for (const c of cands) {
        if (c.tier !== tier) continue;
        const st = statusOf(c, elapsedMs, graceMs, expired, someoneAnswered);
        if (st === 'ok') return { settled: true, conn: c.conn, kind: c.kind };
        if (st === '') waiting = true;
      }
      // A better kind may still answer; worse ones wait for it.
      if (waiting) return { settled: false, conn: null, kind: '' };
    }
    return { settled: true, conn: null, kind: '' };
  }

  /**
   * Tries every address at once and resolves with { conn, kind } for the best that answers, or
   * null when none does. probe(conn, signal) resolves true when the address is this server; the
   * signal aborts when the answer is settled, so a probe still waiting stops.
   *
   * Options (for tests): graceMs, deadlineMs, now(), setTimeout, clearTimeout.
   */
  function resolve(connections, probe, options = {}) {
    const graceMs = options.graceMs == null ? GRACE_MS : options.graceMs;
    const deadlineMs = options.deadlineMs == null ? DEADLINE_MS : options.deadlineMs;
    const now = options.now || (() => Date.now());
    const later = options.setTimeout || ((fn, ms) => setTimeout(fn, ms));
    const cancel = options.clearTimeout || ((id) => clearTimeout(id));

    const cands = candidates(connections);
    if (cands.length === 0) return Promise.resolve(null);

    return new Promise((done) => {
      const started = now();
      const controller = typeof AbortController === 'function' ? new AbortController() : null;
      let finished = false;
      let graceFired = false;
      let expired = false;
      let graceTimer = null;
      let deadlineTimer = null;

      function check() {
        if (finished) return;
        // A timer can run a hair early; once the grace timer has fired the grace has passed.
        const elapsed = graceFired ? Math.max(now() - started, graceMs) : now() - started;
        const out = outcome(cands, elapsed, graceMs, expired);
        if (!out.settled) return;
        finished = true;
        cancel(graceTimer);
        cancel(deadlineTimer);
        if (controller) controller.abort();
        done(out.conn ? { conn: out.conn, kind: out.kind } : null);
      }

      graceTimer = later(() => { graceFired = true; check(); }, graceMs);
      deadlineTimer = later(() => { expired = true; check(); }, deadlineMs);

      for (const c of cands) {
        let answer;
        try {
          answer = Promise.resolve(probe(c.conn, controller ? controller.signal : undefined));
        } catch (err) {
          answer = Promise.resolve(false);
        }
        answer.then((ok) => ok === true, () => false).then((ok) => {
          if (finished) return;
          c.status = ok ? 'ok' : 'fail';
          check();
        });
      }
    });
  }

  /**
   * Whether an /identity answer is this server's: its machineIdentifier is the one plex.tv gave.
   * Anything that cannot be read (no identifier on file, a body that is not Plex JSON) is
   * accepted, as it was before this check: only a different identifier turns an address down.
   */
  function identityMatches(json, machineIdentifier) {
    if (!machineIdentifier) return true;
    const mc = json && typeof json === 'object' ? json.MediaContainer : null;
    if (!mc || typeof mc !== 'object' || !mc.machineIdentifier) return true;
    return String(mc.machineIdentifier) === String(machineIdentifier);
  }

  const api = { GRACE_MS, DEADLINE_MS, tierOf, candidates, outcome, resolve, identityMatches };

  global.NostalgexServerResolve = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
