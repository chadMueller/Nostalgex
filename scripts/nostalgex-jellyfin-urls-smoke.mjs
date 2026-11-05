#!/usr/bin/env node
/**
 * Jellyfin / Emby stream URLs the web tuner builds. Same rules as the Apple TV app's
 * JellyfinPlaybackResolver.staticStreamURL and JellyfinAPIService.addingApiKey.
 *
 * Run: `npm run test:jellyfin-urls`
 */
import { strictEqual } from "node:assert/strict";
import { readFileSync } from "node:fs";
import "./nostalgex-jellyfin-urls.js";

const JU = globalThis.NostalgexJellyfinUrls;
const S = "http://192.168.1.50:8096";

let passed = 0;
const failures = [];
function check(label, fn) {
  try {
    fn();
    passed += 1;
  } catch (e) {
    failures.push(`${label}: ${e.message}`);
  }
}

const direct = (container, extra = {}) =>
  JU.staticStreamUrl({ serverUrl: S, itemId: "abc", mediaSourceId: "ms 1", container, token: "TOK", ...extra });

for (const c of ["mp4", "m4v", "mov", "MP4", "mov,mp4,m4a,3gp,3g2,mj2"]) {
  check(`direct play ${c} asks for stream.mp4`, () =>
    strictEqual(direct(c), `${S}/Videos/abc/stream.mp4?Static=true&MediaSourceId=ms%201&api_key=TOK`));
}
for (const c of ["webm", "mkv", "", null, undefined]) {
  check(`direct play ${c} keeps the extensionless stream`, () =>
    strictEqual(direct(c), `${S}/Videos/abc/stream?Static=true&MediaSourceId=ms%201&api_key=TOK`));
}
check("audio stream index is appended", () =>
  strictEqual(direct("mp4", { audioStreamIndex: 2 }), `${S}/Videos/abc/stream.mp4?Static=true&MediaSourceId=ms%201&api_key=TOK&AudioStreamIndex=2`));
check("audio stream index 0 is kept", () =>
  strictEqual(direct("mp4", { audioStreamIndex: 0 }).endsWith("&AudioStreamIndex=0"), true));
check("null audio stream index is left off", () =>
  strictEqual(direct("mp4", { audioStreamIndex: null }).includes("AudioStreamIndex"), false));

check("hand-built HLS gets ApiKey beside api_key", () =>
  strictEqual(JU.withApiKey(`${S}/Videos/abc/master.m3u8?MediaSourceId=abc&api_key=TOK`, "TOK"),
    `${S}/Videos/abc/master.m3u8?MediaSourceId=abc&api_key=TOK&ApiKey=TOK`));
check("TranscodingUrl that already has ApiKey gains api_key only", () =>
  strictEqual(JU.withApiKey(`${S}/videos/abc/master.m3u8?PlaySessionId=p&ApiKey=TOK`, "TOK"),
    `${S}/videos/abc/master.m3u8?PlaySessionId=p&ApiKey=TOK&api_key=TOK`));
check("both present: unchanged", () =>
  strictEqual(JU.withApiKey(`${S}/x?api_key=A&ApiKey=A`, "TOK"), `${S}/x?api_key=A&ApiKey=A`));
check("no query string yet", () =>
  strictEqual(JU.withApiKey(`${S}/x`, "TOK"), `${S}/x?api_key=TOK&ApiKey=TOK`));
check("a param that merely ends in api_key does not count", () =>
  strictEqual(JU.withApiKey(`${S}/x?not_api_key=1`, "TOK"), `${S}/x?not_api_key=1&api_key=TOK&ApiKey=TOK`));

// Hand-built HLS fallback. Emby 4.10.1.0 puts only `PlaySessionId=<id>` on each segment
// URL, taken from the master; a master without one gave `PlaySessionId=` and a 400 on
// every segment.
const fb = (extra = {}) =>
  JU.fallbackHlsUrl({ serverUrl: S, itemId: "abc", mediaSourceId: "ms 1", token: "TOK", deviceId: "dev", ...extra });
const sessionOf = (url) => new URL(url).searchParams.getAll("PlaySessionId");

check("fallback HLS URL shape, with the session it was given", () =>
  strictEqual(fb({ playSessionId: "ps-1" }),
    `${S}/Videos/abc/master.m3u8?MediaSourceId=ms%201&api_key=TOK&VideoCodec=h264&AudioCodec=aac`
    + `&MaxWidth=3840&SegmentContainer=ts&DeviceId=dev&PlaySessionId=ps-1&ApiKey=TOK`));
check("fallback mints a session when none is given", () => {
  const ids = sessionOf(fb());
  strictEqual(ids.length, 1);
  strictEqual(ids[0].length > 0, true);
});
check("fallback never carries an empty PlaySessionId", () =>
  strictEqual(/[?&]PlaySessionId=(&|$)/.test(fb({ playSessionId: "" })), false));
check("each fallback is its own session", () =>
  strictEqual(sessionOf(fb())[0] === sessionOf(fb())[0], false));
check("fallback keeps api_key and ApiKey, once each", () => {
  const p = new URL(fb()).searchParams;
  strictEqual(p.getAll("api_key").join(), "TOK");
  strictEqual(p.getAll("ApiKey").join(), "TOK");
});
check("fallback carries no StartTimeTicks (Jellyfin refuses it on segments)", () =>
  strictEqual(fb().includes("StartTimeTicks"), false));
check("session id is escaped", () =>
  strictEqual(sessionOf(fb({ playSessionId: "a&b" }))[0], "a&b"));
check("no secure context (plain-http LAN tuner): still a 32-hex id", () => {
  const desc = Object.getOwnPropertyDescriptor(globalThis, "crypto");
  Object.defineProperty(globalThis, "crypto", { value: undefined, configurable: true, writable: true });
  try {
    const id = JU.newPlaySessionId();
    strictEqual(/^[0-9a-f]{32}$/.test(id), true, id);
    strictEqual(/^[0-9a-f]{32}$/.test(sessionOf(fb())[0]), true);
  } finally {
    Object.defineProperty(globalThis, "crypto", desc);
  }
});

// ── Emby, where it differs from Jellyfin (EmbyAPIService.swift), and Jellyfin unchanged ──
// Shapes captured 2026-10-16 from Jellyfin 12.2.0 and Emby 4.8.11.0, 4.9.5.0 and 4.10.1.0
// (/System/Info/Public), with names and ids replaced.
const JELLYFIN_12_2 = { LocalAddress: "http://127.0.0.1:8096", ServerName: "lab", Version: "12.2.0",
  ProductName: "Jellyfin Server", OperatingSystem: "", Id: "0123456789abcdef0123456789abcdef", StartupWizardCompleted: true };
const EMBY = (Version) => ({ LocalAddresses: [], RemoteAddresses: [], ServerName: "lab", Version, Id: "fedcba9876543210fedcba9876543210" });

check("Jellyfin libraries stay at /UserViews?userId= (unchanged)", () =>
  strictEqual(JU.userViewsPath("jellyfin", "user 1"), "/UserViews?userId=user%201"));
check("Emby libraries are /Users/{id}/Views (/UserViews is 404 on Emby)", () =>
  strictEqual(JU.userViewsPath("emby", "user 1"), "/Users/user%201/Views"));
check("Emby user id is path-escaped", () =>
  strictEqual(JU.userViewsPath("emby", "a/b?c"), "/Users/a%2Fb%3Fc/Views"));
check("Jellyfin PlaybackInfo body gains nothing on the retry (unchanged)", () =>
  strictEqual(JSON.stringify(JU.serverStreamOnlyFields("jellyfin", true)), "{}"));
check("Jellyfin PlaybackInfo body gains nothing on the first attempt (unchanged)", () =>
  strictEqual(JSON.stringify(JU.serverStreamOnlyFields("jellyfin", false)), "{}"));
check("Emby retry after a failed direct play turns off direct play AND direct stream", () =>
  strictEqual(JSON.stringify(JU.serverStreamOnlyFields("emby", true)), '{"EnableDirectPlay":false,"EnableDirectStream":false}'));
check("Emby first attempt lets the server decide", () =>
  strictEqual(JSON.stringify(JU.serverStreamOnlyFields("emby", false)), "{}"));
check("Plex never gets MediaBrowser fields", () =>
  strictEqual(JSON.stringify(JU.serverStreamOnlyFields("plex", true)), "{}"));
check("isMediaBrowser: Jellyfin and Emby, nothing else", () => {
  strictEqual(JU.isMediaBrowser("jellyfin"), true);
  strictEqual(JU.isMediaBrowser("emby"), true);
  strictEqual(JU.isMediaBrowser("plex"), false);
  strictEqual(JU.isMediaBrowser(undefined), false);
});
check("public info: Jellyfin 12.2 reads as Jellyfin", () =>
  strictEqual(JU.serverKindFromPublicInfo(JELLYFIN_12_2), "jellyfin"));
for (const v of ["4.8.11.0", "4.9.5.0", "4.10.1.0"]) {
  check(`public info: Emby ${v} reads as Emby`, () => strictEqual(JU.serverKindFromPublicInfo(EMBY(v)), "emby"));
}
check("public info: anything unclear keeps the person's choice (null)", () => {
  for (const x of [null, undefined, "", 42, [], {}, { ServerName: "x" }, { ProductName: "Emby Server" },
    { LocalAddresses: "no", Version: "4.10.1.0", Id: "x" }, { LocalAddresses: [], Version: 4, Id: "x" }]) {
    strictEqual(JU.serverKindFromPublicInfo(x), null, JSON.stringify(x));
  }
});
check("stream URLs carry no backend switch: Emby and Jellyfin get the same direct and fallback URLs", () => {
  strictEqual(direct("mp4"), `${S}/Videos/abc/stream.mp4?Static=true&MediaSourceId=ms%201&api_key=TOK`);
  strictEqual(new URL(fb({ playSessionId: "p" })).pathname, "/Videos/abc/master.m3u8");
});

// ── Which views a scan reads, and what it keeps (point 12; scripts/jellyfin-library-golden.json) ──
const libraryGolden = JSON.parse(readFileSync(new URL("./jellyfin-library-golden.json", import.meta.url), "utf8"));
for (const c of libraryGolden.sections) {
  check(`library view ${JSON.stringify(c.collectionType)} is a ${c.sectionType} section`, () => {
    strictEqual(JU.sectionType(c.collectionType), c.sectionType);
    strictEqual(JU.itemTypes(JU.sectionType(c.collectionType)), c.itemTypes);
  });
}
check("a view with no CollectionType key at all is a film view", () => strictEqual(JU.sectionType(undefined), "movie"));
for (const c of libraryGolden.types) {
  check(`a ${JSON.stringify(c.item.Type)} row asked for ${c.asked} is ${c.kept ? "kept" : "dropped"}`, () =>
    strictEqual(JU.hasAskedType(c.item, c.asked), c.kept));
}
check("hasAskedType tolerates no item", () => strictEqual(JU.hasAskedType(null, "Movie"), true));

if (failures.length) {
  console.error(`jellyfin-urls: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}
console.log(`jellyfin-urls: ${passed} passed`);
