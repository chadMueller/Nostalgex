#!/usr/bin/env node
/**
 * The Jellyfin and Emby connect screens' logic, scripts/nostalgex-signin.js, against
 * scripts/signin-golden.json (cases written from the Apple TV app's SignInFlowTests and
 * ServerURLNormalizerTests), plus what only the web does: where FIND MY SERVER looks,
 * and the error lines a browser shows.
 *
 * Run: `npm run test:signin`
 */
import { readFileSync } from "node:fs";
import "./nostalgex-signin.js";

const S = globalThis.NostalgexSignIn;
const golden = JSON.parse(readFileSync(new URL("./signin-golden.json", import.meta.url), "utf8"));
let passed = 0;
const failures = [];
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function check(label, got, want) {
  if (same(got, want)) passed++;
  else failures.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

for (const c of golden.candidates) check(`candidates ${JSON.stringify(c.raw)}`, S.addressCandidates(c.raw, c.defaultScheme), c.out);
for (const c of golden.discoveryReplies) check(`discovery reply ${c.reply.slice(0, 40)}`, S.parseDiscoveryReply(c.reply, c.kind), c.out);
for (const c of golden.outcomes) {
  const servers = c.servers.map(([id, address]) => ({ kind: "jellyfin", name: id, address, id }));
  const o = S.discoveryOutcome(servers);
  check(`outcome ${JSON.stringify(c.servers)}`, [o.type, o.servers.map((s) => s.id)], [c.out, c.ids || []]);
  if (c.keep) check(`outcome keeps the first heard`, o.servers[0].address, c.keep);
}
for (const c of golden.publicInfo) check(`publicInfo ${c.body.slice(0, 40)}`, S.parsePublicInfo(c.body), c.out);
for (const c of golden.quickConnectEnabled) check(`quickConnectEnabled ${JSON.stringify(c.body)} ${c.status}`, S.parseQuickConnectEnabled(c.body, c.status), c.out);
for (const c of golden.publicUsers) check(`publicUsers ${c.body.slice(0, 40)}`, S.parsePublicUsers(c.body), c.out);
for (const c of golden.method) {
  check(`preferredMethod ${c.kind} ${c.quickConnectEnabled}`, S.preferredMethod(c.kind, c.quickConnectEnabled), c.preferred);
  check(`offersQuickConnect ${c.kind} ${c.quickConnectEnabled}`, S.offersQuickConnect(c.kind, c.quickConnectEnabled), c.offers);
}
for (const c of golden.quickConnectInitiate) check(`initiate ${c.status} ${c.body}`, S.quickConnectInitiateOutcome(c.status, c.body), c.out);
for (const c of golden.quickConnectPoll) check(`poll ${c.poll} ${c.body}`, S.quickConnectPollOutcome(c.poll, c.body), c.out);

// A fake server answering by full URL, as SignInFlowTests.FakeServer does.
function fakeFetch(c, asked) {
  return async (url, init) => {
    asked.push(url);
    if ((c.timeout || []).some((p) => url.startsWith(p))) {
      await new Promise((resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })));
      });
    }
    if ((c.refused || []).some((p) => url.startsWith(p))) throw new TypeError("Failed to fetch");
    const [status, body] = (c.routes || {})[url] || [404, "not found"];
    return { status, text: async () => body };
  };
}
for (const c of golden.check) {
  const asked = [];
  try {
    const got = await S.checkServer(c.address, { fetch: fakeFetch(c, asked), requestMs: 200 });
    if (c.error) { failures.push(`check ${c.name}: passed, want ${c.error}`); continue; }
    const { kind, url, name, quickConnectEnabled, users } = got;
    check(`check ${c.name}`, { kind, url, name, quickConnectEnabled, users, preferred: S.preferredMethod(kind, quickConnectEnabled) }, c.out);
    if (c.neverAsked) check(`check ${c.name} never asked ${c.neverAsked}`, asked.filter((u) => u.includes(c.neverAsked)), []);
  } catch (e) {
    check(`check ${c.name}`, e.code || e.message, c.error || "no error");
  }
  if (c.asked != null) check(`check ${c.name} requests`, asked.length, c.asked);
}

// Where FIND MY SERVER looks from a browser (web only).
check("find: an https page can't look", S.findCandidates({ pageProtocol: "https:", pageHostname: "www.nostalgex.app" }), []);
check("find: the tuner's own machine, then localhost",
  S.findCandidates({ pageProtocol: "http:", pageHostname: "192.0.2.20" }),
  ["http://192.0.2.20:8096", "http://localhost:8096"]);
check("find: the last address used comes first",
  S.findCandidates({ pageProtocol: "http:", pageHostname: "nas.local", savedAddress: "http://192.0.2.30:8096/" }),
  ["http://192.0.2.30:8096", "http://nas.local:8096", "http://localhost:8096"]);
check("find: a page on localhost asks localhost once",
  S.findCandidates({ pageProtocol: "http:", pageHostname: "localhost", savedAddress: "localhost" }),
  ["http://localhost:8096"]);

// findServers: same outcome rules, the kind looked for only, one server heard twice is one.
{
  const routes = {
    "http://192.0.2.20:8096/System/Info/Public": [200, '{"ServerName":"NAS","ProductName":"Jellyfin Server","Id":"jf1"}'],
    "http://localhost:8096/System/Info/Public": [200, '{"ServerName":"NAS","ProductName":"Jellyfin Server","Id":"jf1"}'],
  };
  const f = fakeFetch({ routes }, []);
  const one = await S.findServers("jellyfin", ["http://192.0.2.20:8096", "http://localhost:8096"], { fetch: f, windowMs: 200 });
  check("findServers: the same server on two addresses is one", [one.type, one.servers.map((s) => s.address)], ["single", ["http://192.0.2.20:8096"]]);
  const other = await S.findServers("emby", ["http://192.0.2.20:8096"], { fetch: f, windowMs: 200 });
  check("findServers: a Jellyfin is not an Emby answer", other.type, "none");
  const quiet = await S.findServers("jellyfin", ["http://192.0.2.9:8096"], { fetch: fakeFetch({ timeout: ["http://192.0.2.9"] }, []), windowMs: 100 });
  check("findServers: silence is none", quiet.type, "none");
}

// The amber line a browser shows.
const https = { protocol: "https:", online: true };
const http = { protocol: "http:", online: true };
check("error: not a server", S.checkErrorMessage({ code: "notAServer" }, "emby", http), S.COPY.notAServer);
check("error: timeout names the kind", S.checkErrorMessage({ code: "timeout" }, "emby", http), S.COPY.timeout("emby"));
check("error: offline", S.checkErrorMessage({ code: "network" }, "jellyfin", { protocol: "http:", online: false }), S.COPY.offline);
check("error: a LAN address from the secure page", S.checkErrorMessage({ code: "network", url: "http://172.16.0.10:8096" }, "jellyfin", https), S.COPY.localFromSecure);
check("error: a typed LAN IP, made https by default, from the secure page", S.checkErrorMessage({ code: "network", url: "https://172.16.0.10" }, "emby", https), S.COPY.localFromSecure);
check("error: localhost from the secure page", S.checkErrorMessage({ code: "network", url: "http://localhost:8096" }, "jellyfin", https), S.COPY.localFromSecure);
check("error: a public name that merely starts with localhost is not local", S.checkErrorMessage({ code: "network", url: "https://localhost.example.com" }, "jellyfin", https), S.COPY.nothingAnswered);
check("error: plain http from the secure page", S.checkErrorMessage({ code: "network", url: "http://media.example.com:8096" }, "jellyfin", https), S.COPY.mixedContent);
check("error: nothing answered", S.checkErrorMessage({ code: "network", url: "https://media.example.com" }, "jellyfin", https), S.COPY.nothingAnswered);
check("error: nothing answered on the Docker page", S.checkErrorMessage({ code: "network", url: "http://192.0.2.10:8096" }, "jellyfin", http), S.COPY.nothingAnswered);

// Every C.<name> the connect page uses is in COPY. A missing one is a TypeError the
// page swallows: an unreachable shared Plex server sat on FINDING YOUR SERVERS forever.
const page = readFileSync(new URL("../web-tuner.html", import.meta.url), "utf8");
function missingCopy(html) {
  const used = new Set([...html.matchAll(/\bC\.([A-Za-z_$][\w$]*)/g)].map((m) => m[1]));
  return { used: used.size, missing: [...used].filter((name) => !(name in S.COPY)) };
}
{
  const r = missingCopy(page);
  check(`page copy: all ${r.used} names the page uses exist`, r.missing, []);
  check("page copy: the page uses the shared-server line", /C\.plexSharedUnreachable\(/.test(page), true);
  check("negative control: a name COPY lacks is caught", missingCopy(page + "\n C.noSuchLine(1);").missing, ["noSuchLine"]);
}

// Copy: no em dashes, no emoji, nothing empty.
const strings = Object.entries(S.COPY).map(([k, v]) => [k, typeof v === "function" ? v("jellyfin") : v]);
for (const [k, v] of strings) {
  if (!v || /—/.test(v) || /\p{Extended_Pictographic}/u.test(v)) failures.push(`copy ${k}: ${JSON.stringify(v)}`);
  else passed++;
}

if (failures.length) {
  console.error(`signin: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`signin: ${passed} checks passed (golden file, find, error lines, copy)`);
