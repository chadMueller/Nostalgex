#!/usr/bin/env node
/**
 * A localStorage quota hit while saving the channel config no longer shows
 * "COULD NOT LOAD LIBRARY. YOUR SERVER MAY BE UNREACHABLE" for a server that answered fine
 * (issue #152, reported by tyleerb on a ~6,220-episode, 519-movie Plex library).
 *
 * saveChannelConfig() ran right after saveLibraryCache(), which can land localStorage near
 * its quota on a large library. saveChannelConfig()'s own write had no try/catch, so a
 * QuotaExceededError there was uncaught, propagated out of fetchPlexLibrary(), and landed in
 * its catch block, which (for a Plex backend, since err.plexStatus is unset) shows the generic
 * server-unreachable message. The real cause was local storage, not the network.
 *
 * Loads the real plex-tuner.html, headless, against a Plex-shaped server with a small library.
 * A page-level override makes localStorage.setItem throw QuotaExceededError only for the
 * 'plex90_channel_config' key, standing in for the quota being exhausted by the time that
 * write runs. Negative control: the same page with saveChannelConfig() reverted to its
 * pre-fix shape (the bare, uncaught setItem), which must show the error screen instead.
 *
 * Needs Playwright (not a dependency): PLAYWRIGHT=/path/to/playwright/index.mjs, or a
 * resolvable `playwright`. Run: `npm run test:channel-config-quota`.
 */
import http from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";

const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const root = new URL("../", import.meta.url).pathname;

// VHS VAULT (minItems: 5, type movie, year 1980-1999) fills on 6 items alone, so the
// lineup is never empty and the test does not depend on any other channel's rules.
const movie = (n, title, year) => ({
  ratingKey: String(100 + n), title, summary: "", year, duration: 5400000, type: "movie",
  addedAt: Math.floor(Date.now() / 1000), Genre: [{ tag: "Action" }],
  Media: [{ container: "mp4", videoResolution: "720", bitrate: 2000, videoCodec: "h264", audioCodec: "aac", Part: [{ key: `/library/parts/${n}/file.mp4` }] }],
});
const library = Array.from({ length: 6 }, (_, i) => movie(i, `Tape ${i + 1}`, 1985 + i * 2));

const plex = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const path = req.url.split("?")[0];
  res.setHeader("Content-Type", "application/json");
  if (path === "/identity") return res.end(JSON.stringify({ MediaContainer: { machineIdentifier: "lab-plex", version: "1.43.4" } }));
  if (path === "/library/sections") return res.end(JSON.stringify({ MediaContainer: { Directory: [{ key: "1", title: "Movies", type: "movie" }] } }));
  if (path === "/library/sections/1/all") return res.end(JSON.stringify({ MediaContainer: { size: library.length, totalSize: library.length, Metadata: library } }));
  res.end(JSON.stringify({ MediaContainer: { size: 0, Metadata: [] } }));
});

// The exact pre-fix shape of saveChannelConfig (no try/catch of its own), for the negative
// control. Reverting to this text on the served page proves the test exercises the fix: the
// same thrown exception, against the old code, must surface as the error screen.
const OLD_LINE = `    localStorage.setItem('plex90_channel_config', JSON.stringify(config));\n  }`;
// The fix at the time of this test was a try/catch here; it is lsSet() now, which does the same
// and makes room by giving up caches first (scripts/nostalgex-storage.js). The negative control
// puts the bare write back, so the thrown exception is uncaught again.

const types = { ".html": "text/html", ".js": "text/javascript", ".cjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".woff2": "font/woff2" };
const files = http.createServer((req, res) => {
  const p = normalize(join(root, decodeURIComponent(req.url.split("?")[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  let body = readFileSync(p);
  if (p.endsWith("plex-tuner.html")) {
    let text = body.toString().replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/hls\.js[^>]*><\/script>/, "<script>window.Hls = { isSupported: () => false };</script>");
    // ?preFix: saveChannelConfig with the try/catch taken out, for the negative control.
    if (req.url.includes("preFix")) {
      const reverted = text.replace(
        /\n(\s*)\/\/ Channel toggles outrank every cache\.[\s\S]*?lsSet\('plex90_channel_config', JSON\.stringify\(config\)\);\n(\s*)\}/,
        `\n${OLD_LINE}`,
      );
      if (reverted === text) { res.writeHead(500); return res.end("pre-fix anchor not found"); }
      text = reverted;
    }
    body = text;
  }
  res.writeHead(200, { "Content-Type": types[extname(p)] || "application/octet-stream" });
  res.end(body);
});
await new Promise((r) => plex.listen(0, "127.0.0.1", r));
await new Promise((r) => files.listen(0, "127.0.0.1", r));
const api = `http://127.0.0.1:${plex.address().port}`;
const base = `http://127.0.0.1:${files.address().port}`;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => { if (ok) passed += 1; else failures.push(`${label}${detail ? `: ${detail}` : ""}`); };

const browser = await chromium.launch({ headless: true });

async function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((resolve) => { timer = setTimeout(() => resolve({ timedOut: true }), ms); });
  const result = await Promise.race([promise.then((v) => ({ timedOut: false, v })), timeout]);
  clearTimeout(timer);
  return result;
}

async function run({ query = "" } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.route((u) => !u.hostname.match(/^(127\.0\.0\.1|localhost)$/), (route) => route.abort());
  await ctx.addInitScript(([url]) => {
    if (location.pathname.endsWith("plex-tuner.html") && !sessionStorage.getItem("nx-seeded")) {
      sessionStorage.setItem("nx-seeded", "1");
      localStorage.setItem("plex90_saved_auth", JSON.stringify({ token: "t", serverUrl: url, serverName: "lab", backend: "plex", userToken: "t" }));
    }
    // Stand in for the real quota: the one write that matters here throws, every other
    // localStorage write (the library cache, bundle prefs, and so on) succeeds normally.
    const proto = Object.getPrototypeOf(localStorage);
    const originalSetItem = proto.setItem;
    proto.setItem = function (key, value) {
      if (key === "plex90_channel_config") {
        throw new DOMException("The quota has been exceeded.", "QuotaExceededError");
      }
      return originalSetItem.call(this, key, value);
    };
  }, [api]);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  const consoleErrors = [];
  const consoleWarnings = [];
  page.on("console", (m) => {
    if (m.type() === "error") consoleErrors.push(m.text().slice(0, 200));
    if (m.type() === "warning") consoleWarnings.push(m.text().slice(0, 200));
  });

  await page.goto(`${base}/plex-tuner.html${query}`);
  // loading-library starts hidden (inline style in the markup) and LL.show() only sets it to
  // flex once fetchPlexLibrary is under way, so waiting for "hidden" alone could resolve
  // before the fetch has even started. Wait for it to show first, then for it to finish
  // (hidden again) or fail (the error label), so the check below runs after the save that
  // matters, not before.
  await page.waitForFunction(() => document.getElementById("loading-library").style.display === "flex", null, { timeout: 10000 }).catch(() => {});
  const result = await withTimeout(
    page.waitForFunction(() => {
      const loadingDone = document.getElementById("loading-library").style.display === "none";
      const errorShown = document.getElementById("plex-error-label").style.display === "block";
      return loadingDone || errorShown;
    }, null, { timeout: 20000 }).then(() => true),
    15000,
  );
  // The console.error from the catch in saveChannelConfig() arrives as a separate CDP event;
  // give it a beat to land before reading the console below.
  await page.waitForTimeout(250);
  const state = await page.evaluate(() => ({
    loadingDone: document.getElementById("loading-library").style.display === "none",
    connectShown: document.getElementById("plex-connect").style.display === "flex",
    errorShown: document.getElementById("plex-error-label").style.display === "block",
    errorText: document.getElementById("plex-error-label").textContent,
    channelConfigSaved: localStorage.getItem("plex90_channel_config") !== null,
    someChannelEnabled: typeof CHANNELS !== "undefined" && CHANNELS.some((ch) => ch.enabled),
  }));
  await ctx.close();
  return { timedOut: result.timedOut, state, errors, consoleErrors, consoleWarnings };
}

const fixed = await run();
check("fixed: does not time out", fixed.timedOut === false, JSON.stringify(fixed.state));
check("fixed: the loading screen finishes instead of hanging", fixed.state.loadingDone === true, JSON.stringify(fixed.state));
check("fixed: the error screen never shows", fixed.state.errorShown === false, JSON.stringify(fixed.state));
check("fixed: a channel built and enabled despite the quota error", fixed.state.someChannelEnabled === true, JSON.stringify(fixed.state));
check("fixed: the channel config write did fail (the test actually hit the exception)", fixed.state.channelConfigSaved === false, JSON.stringify(fixed.state));
check("fixed: no uncaught page error", fixed.errors.length === 0, fixed.errors.join(" | "));
check("fixed: the console names the save that failed", fixed.consoleWarnings.some((m) => m.includes("plex90_channel_config")), fixed.consoleWarnings.join(" | "));

const preFix = await run({ query: "?preFix" });
check("negative control (pre-fix code): the quota error surfaces as the error screen", preFix.state.errorShown === true, JSON.stringify(preFix.state));
check("negative control (pre-fix code): the uncaught exception still shows the error screen (now saying it is storage, not the server)", preFix.state.errorText.includes("RAN OUT OF STORAGE"), preFix.state.errorText);
check("negative control (pre-fix code): the connect screen comes back instead of the guide", preFix.state.connectShown === true, JSON.stringify(preFix.state));

await browser.close();
plex.close();
files.close();
if (failures.length) {
  console.error(`channel-config-quota smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`channel-config-quota smoke: ${passed} checks passed (the fix, and the negative control against the pre-fix code)`);
