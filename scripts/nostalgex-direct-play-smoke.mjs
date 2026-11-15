#!/usr/bin/env node
/**
 * The Plex direct play decision reads the file's codecs (scripts/nostalgex-direct-play.js, GitHub #326), and the page uses it.
 * No network. Run: `npm run test:direct-play`.
 */
import { readFileSync } from "node:fs";
await import("./nostalgex-direct-play.js");
const D = globalThis.NostalgexDirectPlay;
let passed = 0;
const failures = [];
const eq = (label, got, want) => { if (got === want) passed += 1; else failures.push(`${label}: got ${got}, want ${want}`); };

const none = undefined;
const yes = (n) => ["hevc", "ac3", "eac3"].includes(n);   // a browser that decodes all three (Safari)
const no = () => false;                                   // one that decodes none (Chrome on most machines)
const item = (v, a) => ({ videoCodec: v, audioCodec: a });

eq("h264 and aac plays", D.codecsOK(item("h264", "aac"), no), true);
eq("avc1 and mp3 plays", D.codecsOK(item("avc1", "mp3"), no), true);
eq("vp9 and opus plays", D.codecsOK(item("vp9", "opus"), no), true);
eq("av1 and flac plays", D.codecsOK(item("av1", "flac"), no), true);
eq("HEVC does not play where the browser cannot decode it", D.codecsOK(item("hevc", "aac"), no), false);
eq("HEVC plays where the browser says it can", D.codecsOK(item("hevc", "aac"), yes), true);
eq("h265 is HEVC", D.codecsOK(item("h265", "aac"), no), false);
eq("with no probe, a codec only some browsers decode reads as unplayable", D.codecsOK(item("hevc", "aac"), none), false);
eq("AC-3 does not play where the browser cannot decode it", D.codecsOK(item("h264", "ac3"), no), false);
eq("AC-3 and E-AC-3 play where the browser says they do", D.codecsOK(item("h264", "eac3"), yes) && D.codecsOK(item("h264", "ac3"), yes), true);
eq("DTS never plays in a browser", D.codecsOK(item("h264", "dts"), yes), false);
eq("TrueHD never plays", D.codecsOK(item("h264", "truehd"), yes), false);
eq("mpeg2 video does not play", D.codecsOK(item("mpeg2video", "aac"), yes), false);
eq("a case difference does not matter", D.codecsOK(item("H264", "AAC"), no), true);
eq("no codecs at all (a library saved before they were kept): unknown, so the container decides as before", D.codecsOK(item(null, null), no), null);
eq("only a known good video codec: plays", D.codecsOK(item("h264", null), no), true);
eq("only a known bad audio codec: does not", D.codecsOK(item(null, "dts"), no), false);
eq("no item: unknown", D.codecsOK(undefined, no), null);

// Dolby Vision profile 5 (#324): only where the browser decodes Dolby Vision and the file is played as it is.
const dv = (n) => n === "dv5";
eq("DV5 in an MP4 plays in a browser that decodes Dolby Vision", D.dolbyVision5Plays("mp4", dv), true);
eq("DV5 in an MKV does not, even there: Plex will not convert it", D.dolbyVision5Plays("mkv", dv), false);
eq("DV5 does not play in a browser that does not decode Dolby Vision", D.dolbyVision5Plays("mp4", no), false);
eq("DV5 with no probe does not play", D.dolbyVision5Plays("mp4", none), false);

// browserProbe asks canPlayType once per codec.
let asked = 0;
const probe = D.browserProbe(() => ({ canPlayType: (t) => { asked++; return /hvc1/.test(t) ? "probably" : ""; } }));
eq("probe: HEVC yes", probe("hevc"), true);
eq("probe: AC-3 no", probe("ac3"), false);
probe("hevc"); probe("ac3");
eq("probe: asked once per codec", asked, 2);
const throwing = D.browserProbe(() => { throw new Error("no video element"); });
eq("probe: a browser that throws says no", throwing("hevc"), false);

// The page uses it for Plex: the container, the codecs and then the rest.
const html = readFileSync(new URL("../plex-tuner.html", import.meta.url), "utf8");
eq("a Dolby Vision profile 5 file is stopped with its reason before a stream is asked for", /plexStreams\.doviProfile === 5 && !NostalgexDirectPlay\.dolbyVision5Plays\(item\.container, directPlayProbe\)/.test(html) && /kind: 'dolbyVision5'/.test(html), true);
eq("the page loads the module", html.includes('<script src="scripts/nostalgex-direct-play.js"></script>'), true);
eq("the Plex path asks the codecs unless they are unknown", /canDirectPlay = !item\._forceTranscode && item\.partKey && \['mp4', 'webm', 'mov'\]\.includes\(item\.container\)\s*&& NostalgexDirectPlay\.codecsOK\(item, directPlayProbe\) !== false/.test(html), true);

if (failures.length) {
  console.error(`direct play: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`direct play: ${passed} checks passed`);
