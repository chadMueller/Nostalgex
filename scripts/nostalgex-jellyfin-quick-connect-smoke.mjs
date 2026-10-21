#!/usr/bin/env node
/**
 * Jellyfin Quick Connect in the web tuner (the Docker image serves the same page).
 *
 *   1. NostalgexJellyfinUrls.quickConnectInitiate against a recording fetch: POST first,
 *      GET again only on 405 or 404, same URL and headers, no body.
 *   2. The sign-in screens' Quick Connect (NostalgexSignIn.quickConnect, which web-tuner.html
 *      runs with quickConnectInitiate) against fake servers with each Jellyfin route table
 *      for Initiate (12.x POST only, 10.9 to 10.11 both, 10.7 and 10.8 GET only): code shown,
 *      poll, sign-in. Off, unreachable, not Jellyfin, flaky polls, expiry and cancel.
 *      Negative controls: the old GET-only initiate fails the same 12.x checks.
 *   3. Live, only when NOSTALGEX_JF_URL, NOSTALGEX_JF_APPROVER_TOKEN (admin API key or the
 *      user's own token) and NOSTALGEX_JF_USER are set: the same controller with Node's
 *      fetch against a real Jellyfin, through AuthenticateWithQuickConnect. Prints no token.
 *
 * Measured 2026-10-19 on Jellyfin 12.2.0: GET /QuickConnect/Initiate 405, POST 200.
 *
 * Run: `npm run test:jellyfin-quick-connect`
 */
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import "./nostalgex-jellyfin-urls.js";

const JU = globalThis.NostalgexJellyfinUrls;
const S = "http://192.168.1.50:8096";
const HEADERS = { Accept: "application/json", Authorization: 'MediaBrowser Client="Nostalgex", Device="Browser", DeviceId="d", Version="1.0"' };

let passed = 0;
const failures = [];
async function check(label, fn) {
  try { await fn(); passed += 1; } catch (e) { failures.push(`${label}: ${e.stack || e.message}`); }
}
async function fails(fn) {
  try { await fn(); } catch (e) { return true; }
  return false;
}

// ── 1. The module ──────────────────────────────────────────────────────────

function recordingFetch(answers) {
  const calls = [];
  const fetch = async (url, init = {}) => {
    calls.push({ url, method: init.method || "GET", headers: init.headers, body: init.body });
    const next = answers.length ? answers.shift() : 500;
    if (next === "throw") throw new TypeError("Failed to fetch");
    return { status: next, ok: next >= 200 && next < 300, json: async () => ({ Code: "123456", Secret: "s" }) };
  };
  return { calls, fetch, methods: () => calls.map((c) => c.method) };
}

// Each takes an initiate implementation so the old one can be run through them too.
const initiateChecks = {
  "initiate is one POST to /QuickConnect/Initiate, headers kept, no body": async (initiate) => {
    const r = recordingFetch([200]);
    const res = await initiate(S, HEADERS, r.fetch);
    assert.equal(res.status, 200);
    assert.deepEqual(r.methods(), ["POST"]);
    assert.equal(r.calls[0].url, `${S}/QuickConnect/Initiate`);
    assert.equal(r.calls[0].headers, HEADERS);
    assert.equal(r.calls[0].body, undefined);
  },
  "a 405 (Jellyfin 10.7, 10.8) tries GET once, same URL and headers": async (initiate) => {
    const r = recordingFetch([405, 200]);
    const res = await initiate(S, HEADERS, r.fetch);
    assert.equal(res.status, 200);
    assert.deepEqual(r.methods(), ["POST", "GET"]);
    assert.deepEqual(r.calls.map((c) => c.url), [`${S}/QuickConnect/Initiate`, `${S}/QuickConnect/Initiate`]);
    assert.equal(r.calls[1].headers, HEADERS);
  },
};

for (const [label, fn] of Object.entries(initiateChecks)) {
  await check(label, () => fn(JU.quickConnectInitiate));
}
await check("a 404 tries GET once", async () => {
  const r = recordingFetch([404, 200]);
  assert.equal((await JU.quickConnectInitiate(S, HEADERS, r.fetch)).status, 200);
  assert.deepEqual(r.methods(), ["POST", "GET"]);
});
await check("two 404s hand back the 404 (not Jellyfin)", async () => {
  const r = recordingFetch([404, 404]);
  assert.equal((await JU.quickConnectInitiate(S, HEADERS, r.fetch)).status, 404);
  assert.deepEqual(r.methods(), ["POST", "GET"]);
});
await check("Quick Connect off (401) is not retried", async () => {
  const r = recordingFetch([401, 200]);
  assert.equal((await JU.quickConnectInitiate(S, HEADERS, r.fetch)).status, 401);
  assert.deepEqual(r.methods(), ["POST"]);
});
for (const status of [400, 403, 500, 502, 503]) {
  await check(`HTTP ${status} is not retried`, async () => {
    const r = recordingFetch([status, 200]);
    assert.equal((await JU.quickConnectInitiate(S, HEADERS, r.fetch)).status, status);
    assert.deepEqual(r.methods(), ["POST"]);
  });
}
await check("a network failure rejects as fetch does, no retry", async () => {
  const r = recordingFetch(["throw", 200]);
  await assert.rejects(() => JU.quickConnectInitiate(S, HEADERS, r.fetch), /Failed to fetch/);
  assert.deepEqual(r.methods(), ["POST"]);
});
await check("retry rule: 405 and 404 only", () => {
  for (const s of [405, 404]) assert.equal(JU.quickConnectInitiateRetriesWithGet(s), true, s);
  for (const s of [200, 204, 400, 401, 403, 500]) assert.equal(JU.quickConnectInitiateRetriesWithGet(s), false, s);
});
await check("without a fetch argument it uses the page's fetch", async () => {
  const saved = globalThis.fetch;
  const r = recordingFetch([200]);
  globalThis.fetch = r.fetch;
  try { await JU.quickConnectInitiate(S, HEADERS); } finally { globalThis.fetch = saved; }
  assert.deepEqual(r.methods(), ["POST"]);
});

// The web tuner's call before this fix, through the same checks.
const oldInitiate = (serverUrl, headers, fetch) => fetch(`${serverUrl}/QuickConnect/Initiate`, { headers });
for (const label of Object.keys(initiateChecks)) {
  await check(`negative control: the old GET-only initiate fails "${label}"`, async () =>
    assert.equal(await fails(() => initiateChecks[label](oldInitiate)), true));
}

// ── 2. The sign-in screens' Quick Connect, against fake servers ────────────
// web-tuner.html runs Quick Connect through NostalgexSignIn.quickConnect
// (scripts/nostalgex-signin.js) with NostalgexJellyfinUrls.quickConnectInitiate as its
// initiate step. Each Jellyfin version's route table, start to sign-in.

await import("./nostalgex-signin.js");
const SI = globalThis.NostalgexSignIn;
const page = readFileSync(new URL("../web-tuner.html", import.meta.url), "utf8");
const AUTH = SI.authHeader("nostalgex-qc-smoke", "");

/** A fake Jellyfin with one version's route table for Initiate. */
function fakeJellyfin({ initiate, quickConnectOn = true, unreachable = false, notJellyfin = false }) {
  const calls = [];
  let approved = false;
  const json = (status, body) => ({ status, ok: status >= 200 && status < 300, text: async () => (body == null ? "" : JSON.stringify(body)) });
  const fetch = async (url, init = {}) => {
    const u = new URL(url);
    const method = init.method || "GET";
    calls.push({ method, path: u.pathname, query: Object.fromEntries(u.searchParams), body: init.body, headers: init.headers });
    if (unreachable) throw new TypeError("Failed to fetch");
    if (notJellyfin) return json(404, null);
    switch (u.pathname) {
      case "/QuickConnect/Initiate":
        if (!initiate.includes(method)) return json(405, null);
        if (!quickConnectOn) return json(401, null);
        return json(200, { Authenticated: false, Secret: "s3cr3t", Code: "123456", DeviceId: "d", DeviceName: "Browser" });
      case "/QuickConnect/Connect":
        if (method !== "GET") return json(405, null);
        return json(200, { Authenticated: approved, Secret: u.searchParams.get("Secret"), Code: "123456" });
      case "/Users/AuthenticateWithQuickConnect":
        if (method !== "POST") return json(405, null);
        if (!approved || JSON.parse(init.body).Secret !== "s3cr3t") return json(401, null);
        return json(200, { AccessToken: "tok", ServerId: "srv", User: { Id: "u1", Name: "lab", ServerName: "Lab" } });
      default:
        return json(404, null);
    }
  };
  return { fetch, calls, approve: () => { approved = true; }, log: () => calls.map((c) => `${c.method} ${c.path}`) };
}

const VERSIONS = {
  "Jellyfin 12.x": ["POST"],
  "Jellyfin 10.9 to 10.11": ["POST", "GET"],
  "Jellyfin 10.7 and 10.8": ["GET"],
};

/** Quick Connect as the page runs it. `approveAfter` polls happen before approval. */
function runQuickConnect(server, { initiate = JU.quickConnectInitiate, approveAfter = 1 } = {}) {
  let polls = 0;
  let code = null;
  const qc = SI.quickConnect({
    url: S, authorization: AUTH, fetch: server.fetch, initiate,
    onCode: (c) => { code = c; },
    sleep: async () => { polls++; if (polls > approveAfter) server.approve(); },
  });
  return { qc, code: () => code, polls: () => polls };
}

/** The whole sign-in on one fake server. Throws when anything is off. */
async function signInScenario(version, initiate) {
  const server = fakeJellyfin({ initiate: VERSIONS[version] });
  const run = runQuickConnect(server, { initiate, approveAfter: 1 });
  const r = await run.qc.done;
  assert.equal(r.status, "approved", `status ${r.status}`);
  assert.equal(run.code(), "123456", "code shown");
  assert.equal(r.result.AccessToken, "tok");
  assert.equal(r.result.User.Id, "u1");
  const init = version === "Jellyfin 10.7 and 10.8" ? ["POST /QuickConnect/Initiate", "GET /QuickConnect/Initiate"] : ["POST /QuickConnect/Initiate"];
  assert.deepEqual(server.log(), [...init, "GET /QuickConnect/Connect", "GET /QuickConnect/Connect", "POST /Users/AuthenticateWithQuickConnect"]);
  assert.equal(server.calls.find((c) => c.path === "/QuickConnect/Connect").query.Secret, "s3cr3t");
  const auth = server.calls.find((c) => c.path === "/Users/AuthenticateWithQuickConnect");
  assert.deepEqual(JSON.parse(auth.body), { Secret: "s3cr3t" });
  assert.match(auth.headers.Authorization, /^MediaBrowser Client="Nostalgex", Device="Browser", DeviceId="nostalgex-qc-smoke"/);
  return server;
}

for (const version of Object.keys(VERSIONS)) {
  await check(`sign-in screens: Quick Connect signs in on ${version}`, () => signInScenario(version));
}
await check("sign-in screens: Quick Connect off is 'off', one request, no polling", async () => {
  const server = fakeJellyfin({ initiate: ["POST"], quickConnectOn: false });
  const run = runQuickConnect(server);
  assert.equal((await run.qc.done).status, "off");
  assert.deepEqual(server.log(), ["POST /QuickConnect/Initiate"]);
  assert.equal(run.polls(), 0);
});
await check("sign-in screens: an unreachable server is 'network', no retry", async () => {
  const server = fakeJellyfin({ initiate: ["POST"], unreachable: true });
  assert.equal((await runQuickConnect(server).qc.done).status, "network");
  assert.deepEqual(server.log(), ["POST /QuickConnect/Initiate"]);
});
await check("sign-in screens: a server that isn't Jellyfin (404 both ways) is 'notJellyfin', not a code", async () => {
  const server = fakeJellyfin({ initiate: [], notJellyfin: true });
  const run = runQuickConnect(server);
  assert.equal((await run.qc.done).status, "notJellyfin");
  assert.deepEqual(server.log(), ["POST /QuickConnect/Initiate", "GET /QuickConnect/Initiate"]);
  assert.equal(run.code(), null);
});
await check("sign-in screens: polls that fail on the network keep polling", async () => {
  const server = fakeJellyfin({ initiate: ["POST"] });
  let failNext = 2;
  const flaky = async (url, init) => {
    if (url.includes("/QuickConnect/Connect") && failNext-- > 0) throw new TypeError("Failed to fetch");
    return server.fetch(url, init);
  };
  let polls = 0;
  const qc = SI.quickConnect({ url: S, authorization: AUTH, fetch: flaky, initiate: JU.quickConnectInitiate,
    sleep: async () => { polls++; if (polls > 2) server.approve(); } });
  assert.equal((await qc.done).status, "approved");
});
await check("sign-in screens: the code expires after 150 polls", async () => {
  const server = fakeJellyfin({ initiate: ["POST"] });
  let polls = 0;
  const qc = SI.quickConnect({ url: S, authorization: AUTH, fetch: server.fetch, initiate: JU.quickConnectInitiate, sleep: async () => { polls++; } });
  assert.equal((await qc.done).status, "expired");
  assert.equal(polls, 150);
});
await check("sign-in screens: cancel stops it", async () => {
  const server = fakeJellyfin({ initiate: ["POST"] });
  let qc;
  qc = SI.quickConnect({ url: S, authorization: AUTH, fetch: server.fetch, initiate: JU.quickConnectInitiate, sleep: async () => { qc.cancel(); } });
  assert.equal((await qc.done).status, "cancelled");
  assert.equal(server.log().includes("POST /Users/AuthenticateWithQuickConnect"), false);
});
await check("the page starts Quick Connect with quickConnectInitiate", () =>
  assert.match(page, /S\.quickConnect\(\{[\s\S]{0,200}initiate: NostalgexJellyfinUrls\.quickConnectInitiate/));

// The old GET-only start, through the same checks.
await check("negative control: a GET-only initiate fails the Jellyfin 12.x sign-in", async () =>
  assert.equal(await fails(() => signInScenario("Jellyfin 12.x", oldInitiate)), true));
await check("negative control: a GET-only initiate on Jellyfin 12.x comes back 'failed' after a GET 405", async () => {
  const server = fakeJellyfin({ initiate: ["POST"] });
  assert.equal((await runQuickConnect(server, { initiate: oldInitiate }).qc.done).status, "failed");
  assert.deepEqual(server.log(), ["GET /QuickConnect/Initiate"]);
});

// ── 3. Live, against a real Jellyfin (opt-in) ──────────────────────────────

const live = { url: process.env.NOSTALGEX_JF_URL, approver: process.env.NOSTALGEX_JF_APPROVER_TOKEN, user: process.env.NOSTALGEX_JF_USER };
let liveSummary = "live: skipped (set NOSTALGEX_JF_URL, NOSTALGEX_JF_APPROVER_TOKEN, NOSTALGEX_JF_USER)";
if (live.url && live.approver && live.user) {
  await check(`live: Quick Connect through AuthenticateWithQuickConnect on ${live.url}`, async () => {
    const log = [];
    const fetchLogged = async (url, init = {}) => {
      const res = await fetch(url, init);
      log.push(`${init.method || "GET"} ${new URL(url).pathname} ${res.status}`);
      return res;
    };
    let code = null;
    let approved = false;
    const qc = SI.quickConnect({
      url: live.url, authorization: SI.authHeader(`nostalgex-qc-live-${Date.now()}`, ""), fetch: fetchLogged,
      initiate: JU.quickConnectInitiate, onCode: (c) => { code = c; }, pollMs: 300,
      sleep: async (ms) => {
        await new Promise((r) => setTimeout(r, ms));
        if (code && !approved) {
          approved = true;
          const approve = await fetch(`${live.url}/QuickConnect/Authorize?code=${encodeURIComponent(code)}&userId=${encodeURIComponent(live.user)}`, {
            method: "POST",
            headers: { Authorization: `MediaBrowser Client="Nostalgex", Device="Smoke", DeviceId="nostalgex-qc-approver", Version="1.0", Token="${live.approver}"` },
          });
          log.push(`POST /QuickConnect/Authorize ${approve.status} (approver)`);
        }
      },
    });
    const r = await qc.done;
    assert.equal(r.status, "approved", `status ${r.status}`);
    assert.match(code, /^\d{6}$/);
    assert.equal(r.result.User.Id, live.user);
    const views = await fetch(`${live.url}/UserViews?userId=${encodeURIComponent(r.result.User.Id)}`, {
      headers: { Accept: "application/json", Authorization: SI.authHeader("nostalgex-qc-live", r.result.AccessToken) },
    });
    const libraries = views.ok ? ((await views.json()).Items || []).length : -1;
    assert.equal(views.status, 200);
    liveSummary = `live: ${log.join(" | ")} | token length ${r.result.AccessToken.length}`
      + ` | GET /UserViews with the new token ${views.status}, ${libraries} libraries`;
  });
}

if (failures.length) {
  console.error(`jellyfin-quick-connect: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}
console.log(`jellyfin-quick-connect: ${passed} passed`);
console.log(liveSummary);
