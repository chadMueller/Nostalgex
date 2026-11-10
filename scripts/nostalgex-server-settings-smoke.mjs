#!/usr/bin/env node
// The Docker tuner's shared lineup (scripts/nostalgex-server-settings.js, I-080) without a
// browser: what is shared, what never is, the read's outcomes, the write rules, and the
// container's side (docker/40-config.sh run against a stand-in nginx, docker/nginx.conf,
// Dockerfile, compose). The page against a fake container is scripts/shared-lineup-browser-smoke.mjs.
// What this cannot run is nginx itself; docker-smoke in .github/workflows/ci.yml does, on a pull request.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, chmodSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import "./nostalgex-storage.js";
import "./nostalgex-server-settings.js";

const S = globalThis.NostalgexServerSettings;
let checks = 0;
const ok = (c, label) => { assert.ok(c, label); checks += 1; };
const eq = (a, b, label) => { assert.deepEqual(a, b, label); checks += 1; };

const store = (init = {}) => {
  const m = new Map(Object.entries(init));
  return { m, getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) };
};
const TOKEN = "TOKEN-secret-1234567890";
const lineup = () => ({
  nostalgex_enabled_bundles: JSON.stringify(["nostalgex", "sports"]),
  plex90_channel_config: JSON.stringify([{ id: 2, name: "MOVIES", enabled: true }]),
  plex90_config_version: "11",
  nostalgex_enabled_collections: JSON.stringify(["a|b"]),
  nostalgex_enabled_franchises: JSON.stringify(["bond"]),
  nostalgex_disabled_franchises: JSON.stringify([]),
});

// ---- what is shared ----
eq(S.KEYS, ["nostalgex_enabled_bundles", "plex90_channel_config", "plex90_config_version", "nostalgex_enabled_collections", "nostalgex_enabled_franchises", "nostalgex_disabled_franchises"], "the shared keys");
for (const never of ["plex90_saved_auth", "plex90_token", "plex90_user_token", "plex90_server_url", "plex90_client_id", "plex90_guide_layout", "plex90_retro_mode", "plex90_subtitle_language", "nostalgex_last_channel", "plex90_library_cache_id"]) {
  ok(!S.KEYS.includes(never), `${never} is not shared`);
}

// ---- building ----
{
  const local = store({ ...lineup(), plex90_saved_auth: JSON.stringify({ token: TOKEN, userToken: "ACCOUNT-token-98765432" }), plex90_guide_layout: "bottom", plex90_client_id: "abc" });
  const text = S.buildBlob(local, S.secretsOf(local, store()));
  const blob = JSON.parse(text);
  eq(blob.v, 1, "format 1");
  eq(Object.keys(blob.keys).sort(), [...S.KEYS].sort(), "all six, nothing else");
  ok(!text.includes(TOKEN) && !text.includes("ACCOUNT-token") && !text.includes("bottom") && !text.includes("abc"), "no token, no display preference, no install id in the text");
  eq(S.buildBlob(store(), []), null, "nothing to share: null");
  // A shared value that carries this browser's token is left out, whichever store the token is in.
  const leaky = store({ ...lineup(), plex90_channel_config: JSON.stringify([{ id: 1, name: `X ${TOKEN}` }]) });
  const sess = store({ plex90_token: TOKEN });
  const t2 = S.buildBlob(leaky, S.secretsOf(leaky, sess));
  ok(t2 && !t2.includes(TOKEN) && !JSON.parse(t2).keys.plex90_channel_config, "a value holding the session token is dropped, the rest kept");
  // A value the page would not have written is not sent.
  const bad = store({ ...lineup(), nostalgex_enabled_bundles: "not json", plex90_config_version: "abc" });
  eq(Object.keys(JSON.parse(S.buildBlob(bad, [])).keys).sort(), ["nostalgex_disabled_franchises", "nostalgex_enabled_collections", "nostalgex_enabled_franchises", "plex90_channel_config"].sort(), "invalid values are skipped");
  const huge = store({ plex90_channel_config: JSON.stringify([{ id: 1, name: "x".repeat(250000) }]) });
  eq(S.buildBlob(huge, []), null, "over 200,000 characters: not sent");
}

// ---- parsing and applying ----
eq(S.parseBlob("{").reason, "corrupt", "not json");
eq(S.parseBlob('{"v":1}').reason, "corrupt", "no keys");
eq(S.parseBlob('{"v":1,"keys":[]}').reason, "corrupt", "keys is a list");
eq(S.parseBlob('{"v":2,"keys":{}}').reason, "newer", "a newer format");
ok(S.parseBlob('{"v":1,"keys":{}}').ok, "an empty lineup is a lineup");
{
  const local = store({ nostalgex_enabled_bundles: JSON.stringify(["old"]), nostalgex_enabled_franchises: JSON.stringify(["x"]), plex90_saved_auth: "KEEP", plex90_guide_layout: "bottom" });
  const blob = { v: 1, keys: { ...lineup(), plex90_saved_auth: JSON.stringify({ token: "EVIL" }), plex90_guide_layout: "side", plex90_channel_config: "not json" } };
  delete blob.keys.nostalgex_enabled_franchises;
  S.applyBlob(blob, local);
  eq(local.getItem("nostalgex_enabled_bundles"), JSON.stringify(["nostalgex", "sports"]), "a shared key is set");
  eq(local.getItem("nostalgex_enabled_franchises"), null, "a shared key the server lacks is removed, so browsers agree");
  eq(local.getItem("plex90_channel_config"), null, "an invalid value is not applied");
  eq(local.getItem("plex90_saved_auth"), "KEEP", "a login in the blob is ignored and the browser's own is untouched");
  eq(local.getItem("plex90_guide_layout"), "bottom", "a display preference in the blob is ignored");
  eq(local.getItem("plex90_config_version"), "11", "the version travels with the channel settings");
}

// ---- the read ----
const xhr = (status, headers = {}, body = "") => () => ({
  open() {}, send() {}, status, responseText: body,
  getResponseHeader: (h) => (h.toLowerCase() in headers ? headers[h.toLowerCase()] : null),
});
const MARK = { "x-nostalgex-settings": "on" };
const GOOD = JSON.stringify({ v: 1, keys: lineup() });
const reads = [
  ["a marked 200 applies", xhr(200, MARK, GOOD), "applied", true],
  ["a marked 404 is 'nothing saved yet', writing allowed", xhr(404, MARK), "absent", true],
  ["a 404 without the mark (no feature in this image) is off", xhr(404), "off", false],
  ["a 200 without the mark (a proxy's page) is off, and not applied", xhr(200, {}, GOOD), "off", false],
  ["a marked 200 that is not a lineup is replaceable", xhr(200, MARK, "<html>"), "corrupt", true],
  ["a marked 200 from a newer format is left alone", xhr(200, MARK, '{"v":9,"keys":{}}'), "newer", false],
  ["a marked 500 (the read failed) turns writing off", xhr(500, MARK), "failed", false],
  ["a marked 403 turns writing off", xhr(403, MARK), "failed", false],
  ["a thrown request turns writing off", () => { throw new Error("blocked"); }, "failed", false],
];
for (const [label, factory, status, canWrite] of reads) {
  const local = store({ nostalgex_enabled_bundles: JSON.stringify(["mine"]) });
  const got = S.hydrate({ storage: local, xhr: factory, url: "http://x/nostalgex-settings.json" });
  eq([got, S.state.canWrite], [status, canWrite], label);
  const expectBundles = status === "applied" ? JSON.stringify(["nostalgex", "sports"]) : JSON.stringify(["mine"]);
  eq(local.getItem("nostalgex_enabled_bundles"), expectBundles, `${label}: storage ${status === "applied" ? "now holds the shared lineup" : "is untouched"}`);
}
// Hosted: the module starts itself only when the page says it is the Docker build.
{
  const meta = (content) => ({ querySelector: () => ({ getAttribute: () => content }) });
  ok(S.isSelfhost(meta("selfhost")), "the Docker build is recognised");
  ok(!S.isSelfhost(meta("hosted")) && !S.isSelfhost({ querySelector: () => null }) && !S.isSelfhost(undefined), "the hosted site, and a page with no marker, are not");
}

// ---- the write ----
function rig({ read = "applied", failPuts = 0, stored = lineup() } = {}) {
  const local = store(stored);
  const sess = store();
  const puts = [];
  let timer = null;
  const started = { value: false };
  S.hydrate({ storage: local, xhr: read === "applied" ? xhr(200, MARK, GOOD) : read === "absent" ? xhr(404, MARK) : xhr(500, MARK), url: "http://x/f" });
  let left = failPuts;
  const w = S.start({
    storage: local, session: sess, url: "http://x/f",
    setTimeout: (fn) => { timer = fn; return 1; }, clearTimeout: () => { timer = null; },
    put: async (url, text) => { puts.push(JSON.parse(text)); return left-- > 0 ? 500 : 204; },
  });
  const fire = async () => { const fn = timer; timer = null; if (fn) await fn(); await new Promise((r) => setTimeout(r, 0)); };
  return { local, puts, w, fire, pending: () => timer !== null, started };
}
{
  // The same lineup as the server holds: nothing to send.
  const r = rig();
  r.w.arm();
  r.w.changed("nostalgex_enabled_bundles");
  await r.fire();
  eq(r.puts.length, 0, "a change that leaves the lineup as the server has it sends nothing");
}
{
  const r = rig();
  r.w.changed("nostalgex_enabled_bundles");
  ok(!r.pending(), "before the first tap or key press, a save schedules nothing (the page is only loading)");
  r.w.arm();
  r.local.setItem("nostalgex_enabled_bundles", JSON.stringify(["nostalgex", "sports", "kids"]));
  r.w.changed("plex90_guide_layout");
  ok(!r.pending(), "a display preference is not a lineup change");
  r.w.changed("nostalgex_enabled_bundles");
  r.w.changed("nostalgex_enabled_bundles");
  ok(r.pending(), "a change schedules one send");
  await r.fire();
  eq(r.puts.length, 1, "two quick changes make one send");
  eq(JSON.parse(r.puts[0].keys.nostalgex_enabled_bundles), ["nostalgex", "sports", "kids"], "it carries the new lineup");
  eq(Object.keys(r.puts[0].keys).filter((k) => !S.KEYS.includes(k)), [], "and only shared keys");
  r.w.changed("nostalgex_enabled_bundles");
  await r.fire();
  eq(r.puts.length, 1, "the same lineup again is not sent twice");
}
{
  const r = rig({ read: "absent", stored: lineup() });
  r.w.arm();
  r.w.changed("plex90_channel_config");
  await r.fire();
  eq(r.puts.length, 1, "nothing saved yet on the server: the first change from a tapped-on browser saves its lineup");
}
for (const read of ["failed"]) {
  const r = rig({ read });
  r.w.arm();
  r.w.changed("nostalgex_enabled_bundles");
  ok(!r.pending(), "a read that failed: no write is even scheduled, so this browser cannot overwrite what it could not see");
  eq(r.puts.length, 0, "and nothing is sent");
}
{
  // Three failed writes in a row turn writing off for the visit; a page error is never raised.
  const r = rig({ failPuts: 99 });
  r.w.arm();
  for (let i = 0; i < 5; i++) {
    r.local.setItem("nostalgex_enabled_bundles", JSON.stringify(["a" + i]));
    r.w.changed("nostalgex_enabled_bundles");
    await r.fire();
  }
  eq(r.puts.length, 3, "after three failures it stops trying");
}
{
  const r = rig({ failPuts: 1 });
  r.w.arm();
  r.local.setItem("nostalgex_enabled_bundles", JSON.stringify(["a"]));
  r.w.changed("nostalgex_enabled_bundles"); await r.fire();
  r.local.setItem("nostalgex_enabled_bundles", JSON.stringify(["b"]));
  r.w.changed("nostalgex_enabled_bundles"); await r.fire();
  eq(r.puts.length, 2, "one failure is retried at the next change");
}
{
  // Through the page's own setter: a save of a shared key reaches the listener, others do not.
  globalThis.localStorage = store();
  globalThis.sessionStorage = store();
  const seen = [];
  globalThis.NostalgexStorage.onLocalWrite((k) => seen.push(k));
  globalThis.NostalgexStorage.onLocalWrite(() => { throw new Error("a listener that throws"); });
  ok(globalThis.NostalgexStorage.setLocal("nostalgex_enabled_bundles", "[]") === true, "a listener that throws does not fail the save");
  globalThis.NostalgexStorage.setLocal("plex90_guide_layout", "side");
  eq(seen, ["nostalgex_enabled_bundles", "plex90_guide_layout"], "the listener hears each saved key");
}

// ---- the container's side ----
const root = new URL("../", import.meta.url).pathname;
const conf = readFileSync(join(root, "docker/nginx.conf"), "utf8");
const entry = readFileSync(join(root, "docker/40-config.sh"), "utf8");
const dockerfile = readFileSync(join(root, "Dockerfile"), "utf8");
const compose = readFileSync(join(root, "docker/compose.yaml"), "utf8");
ok(/include \/tmp\/nostalgex\/\*\.conf;/.test(conf), "nginx.conf includes the generated file by a glob, so no match is not an error");
ok(!/dav_methods/.test(conf), "nginx.conf itself has no WebDAV directive (an nginx without the module would refuse to start)");
ok(/location = \/config\.json \{\s*root \/tmp\/nostalgex;/.test(conf), "config.json is still served from /tmp/nostalgex (the glob skips it: it ends .json)");
ok(/RUN mkdir -p \/data && chown 101:101 \/data/.test(dockerfile) && /USER 101/.test(dockerfile.slice(dockerfile.indexOf("mkdir -p /data"))), "the image has /data owned by 101 and still runs as 101");
ok(!/^VOLUME/m.test(dockerfile), "no VOLUME line (no anonymous volume nobody asked for)");
ok(/nostalgex-data:\/data/.test(compose) && /^volumes:\s*\n\s*nostalgex-data:/m.test(compose) && /read_only: true/.test(compose), "the compose example mounts a named volume on /data and keeps the read-only root");

// Run the real entrypoint script against a stand-in nginx, in a sandbox.
function runEntry({ dav, env = {} }) {
  const dir = mkdtempSync(join(tmpdir(), "nx-entry-"));
  mkdirSync(join(dir, "bin"));
  mkdirSync(join(dir, "html"));
  writeFileSync(join(dir, "html/config.json"), '{"tunerVersion":"1.2.3"}');
  writeFileSync(join(dir, "bin/nginx"), `#!/bin/sh\necho "configure arguments: --with-http_ssl_module ${dav ? "--with-http_dav_module " : ""}--with-threads" >&2\n`);
  chmodSync(join(dir, "bin/nginx"), 0o755);
  // The script hardcodes /tmp/nostalgex and /usr/share/nginx/html; point them into the sandbox.
  const script = entry.replaceAll("/tmp/nostalgex", join(dir, "run")).replaceAll("/usr/share/nginx/html", join(dir, "html"));
  writeFileSync(join(dir, "40-config.sh"), script);
  const out = execFileSync("sh", [join(dir, "40-config.sh")], { env: { PATH: `${join(dir, "bin")}:/usr/bin:/bin`, ...env }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const file = join(dir, "run/settings.conf");
  return { conf: existsSync(file) ? readFileSync(file, "utf8") : null, out, config: readFileSync(join(dir, "run/config.json"), "utf8") };
}
{
  const on = runEntry({ dav: true });
  ok(on.conf && /location = \/nostalgex-settings\.json \{/.test(on.conf), "with the module: the settings location is written");
  for (const want of [/root \/data;/, /dav_methods PUT;/, /create_full_put_path off;/, /client_max_body_size 256k;/, /limit_except GET HEAD PUT \{ deny all; \}/, /add_header X-Nostalgex-Settings "on" always;/, /expires -1;/]) {
    ok(want.test(on.conf), `the location has ${want}`);
  }
  ok(/^location /.test(on.conf) && (on.conf.match(/location /g) || []).length === 1, "and it is the one location");
  ok(on.config.includes('"tunerVersion":"1.2.3"') && on.config.includes('"enrichment":true'), "the existing config.json is as before");
  const none = runEntry({ dav: false });
  eq(none.conf, null, "without the module: no settings location, so nginx still starts and the page keeps per-browser settings");
  const off = runEntry({ dav: true, env: { NOSTALGEX_SHARED_SETTINGS: "off" } });
  eq(off.conf, null, "NOSTALGEX_SHARED_SETTINGS=off: no settings location");
  const typo = runEntry({ dav: true, env: { NOSTALGEX_SHARED_SETTINGS: "maybe" } });
  eq(typo.conf, null, "a typo is read as off, not as on");
}
const sh = execFileSync("sh", ["-n", join(root, "docker/40-config.sh")], { encoding: "utf8" });
ok(sh === "", "the entrypoint parses");

console.log(`server settings smoke: ${checks} checks passed (shared keys only, no login in it, the read's nine outcomes, the write rules, the container's entrypoint with and without the WebDAV module)`);
