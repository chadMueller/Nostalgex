// Usage: node --env-file=.env scripts/qa/plex-start-probe.mjs <ratingKey> <offsetSeconds> <auto|normal> [segments]
// Read-only timing of the requests the Apple TV app makes to start an HLS stream of one item.
// Port of PlexAPIService.transcodeQueryItems / clientProfileExtra / dolbyVisionRemuxURL / automaticOriginalVideoURL.
// Session is stopped afterwards. Never prints the token.
import { randomUUID } from "node:crypto";
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
const base = process.env.PLEX_URL.replace(/\/$/, ""), TOKEN = process.env.PLEX_TOKEN;
const [key, offsetStr, mode] = process.argv.slice(2).length >= 3 ? process.argv.slice(2) : process.argv.slice(2); // mode: auto | normal
const offset = Number(offsetStr);
const clientID = "nostalgex-qa-" + randomUUID();
const eac3Cap = "+add-limitation(scope=videoAudioCodec&scopeName=eac3&type=upperBound&name=audio.channels&value=6)";
function profileExtra() {
  const audio = "aac,ac3,eac3,mp3";
  return `add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264,mpeg4&audioCodec=${audio})`
    + `+add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=fmp4&videoCodec=h264,hevc,mpeg4&audioCodec=${audio})`
    + "+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width&value=3840&replace=true)"
    + "+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height&value=2160&replace=true)" + eac3Cap
    + "+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.width&value=3840&replace=true)"
    + "+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.height&value=2160&replace=true)"
    + "+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.bitDepth&value=10&replace=true)";
}
function genericProfile() {
  return "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3,mp3)"
    + "+add-limitation(scope=videoTranscodeTarget&scopeName=hevc&scopeType=videoCodec&context=all&protocol=hls&type=upperBound&name=video.bitDepth&value=10)" + eac3Cap;
}
function startParams(session, platform, extra, audioStreamID) {
  const p = new URLSearchParams();
  const add = (k, v) => p.append(k, v);
  add("path", `/library/metadata/${key}`); add("mediaIndex", "0"); add("partIndex", "0"); add("protocol", "hls"); add("session", session);
  add("offset", String(offset)); add("fastSeek", "1"); add("directPlay", "0"); add("directStream", "1"); add("directStreamAudio", "1"); add("copyts", "0");
  add("subtitles", "auto"); add("subtitleSize", "100"); add("audioBoost", "100"); add("hasMDE", "1"); add("location", "lan");
  add("maxVideoBitrate", "40000"); add("videoQuality", "100"); add("videoResolution", "3840x2160"); add("autoAdjustQuality", "0"); add("addDebugOverlay", "0");
  add("X-Plex-Client-Profile-Extra", extra); add("X-Plex-Session-Identifier", session); add("X-Plex-Token", TOKEN); add("X-Plex-Client-Identifier", clientID);
  add("X-Plex-Product", "Nostalgex"); add("X-Plex-Platform", platform); add("X-Plex-Device", "Apple TV"); add("X-Plex-Device-Name", "Nostalgex-QA");
  if (audioStreamID) add("audioStreamID", String(audioStreamID));
  return p;
}
const T = async (label, fn) => { const t = performance.now(); let r, err; try { r = await fn(); } catch (e) { err = e; } const ms = Math.round(performance.now() - t); console.log(`${label.padEnd(38)} ${String(ms).padStart(6)} ms ${err ? "ERR " + (err.cause?.code || err.message) : ""}`); return { r, ms, err }; };
const get = async (url, ms = 60000) => { const c = new AbortController(); const to = setTimeout(() => c.abort(), ms); try { return await fetch(url, { signal: c.signal, headers: { "X-Plex-Client-Identifier": clientID } }); } finally { clearTimeout(to); } };

const meta = await T("GET /library/metadata/" + key, async () => (await (await get(`${base}/library/metadata/${key}`, 5000)).text()));
const audioStreamID = (meta.r.match(/<Stream[^>]*streamType="2"[^>]*id="(\d+)"/) || meta.r.match(/<Stream[^>]*id="(\d+)"[^>]*streamType="2"/) || [])[1];
const session = randomUUID();
const platform = mode === "auto" ? "Generic" : "tvOS";
const extra = mode === "auto" ? genericProfile() : profileExtra();
const q = startParams(session, platform, extra, mode === "auto" ? audioStreamID : null);
const dec = await T(`decision (${mode}, offset ${offset}s)`, async () => { const r = await get(`${base}/video/:/transcode/universal/decision?${q}`, 15000); return { status: r.status, body: await r.text() }; });
const body = dec.r?.body || "";
const attr = (n) => (body.match(new RegExp(n + '="([^"]*)"')) || [])[1];
console.log("   decision HTTP", dec.r?.status, "code", attr("transcodeDecisionCode") || attr("generalDecisionCode"), "|", attr("transcodeDecisionText") || attr("generalDecisionText"));
const streams = [...body.matchAll(/<Stream [^>]*>/g)].map((m) => m[0]).filter((s) => /decision=/.test(s)).map((s) => `${/streamType="(\d)"/.exec(s)?.[1] === "1" ? "V" : "A"}:${/codec="(\w+)"/.exec(s)?.[1]}/${/decision="(\w+)"/.exec(s)?.[1]}`);
console.log("   streams:", streams.join(" "), "| part container", (body.match(/<Part [^>]*container="(\w+)"/) || [])[1]);
const startURL = `${base}/video/:/transcode/universal/start.m3u8?${q}`;
const master = await T("start.m3u8 (master playlist)", async () => { const r = await get(startURL, 120000); return { status: r.status, text: await r.text() }; });
console.log("   start HTTP", master.r?.status, "bytes", master.r?.text.length);
if (master.r?.status === 200) {
  const variant = master.r.text.split("\n").find((l) => l && !l.startsWith("#"));
  console.log("   variants:", master.r.text.split("\n").filter((l) => l.startsWith("#EXT-X-STREAM-INF")).map((l) => (/RESOLUTION=(\S+?)[,]/.exec(l) || [])[1] + "@" + (/BANDWIDTH=(\d+)/.exec(l) || [])[1]).join(" "), "| codecs", (master.r.text.match(/CODECS="([^"]+)"/) || [])[1]);
  const vurl = new URL(variant, startURL).href;
  const vp = await T("variant playlist", async () => { const r = await get(vurl, 120000); return { status: r.status, text: await r.text() }; });
  const lines = vp.r.text.split("\n"); const segs = lines.filter((l) => l && !l.startsWith("#"));
  console.log("   playlist HTTP", vp.r.status, "segments listed", segs.length, "target", (vp.r.text.match(/TARGETDURATION:(\d+)/) || [])[1], "map", (vp.r.text.match(/#EXT-X-MAP:URI="([^"]+)"/) || [])[1] ? "yes" : "no");
  const mapU = (vp.r.text.match(/#EXT-X-MAP:URI="([^"]+)"/) || [])[1];
  if (mapU) await T("init segment", async () => (await (await get(new URL(mapU, vurl).href, 120000)).arrayBuffer()).byteLength);
  const N = Number(process.argv[5] || 3);
  const times = []; const t0 = performance.now(); let bytes = 0;
  for (let i = 0; i < Math.min(N, segs.length); i++) {
    if (N > 3) { const t = performance.now(); const ab = await (await get(new URL(segs[i], vurl).href, 120000)).arrayBuffer(); times.push(Math.round(performance.now() - t)); bytes += ab.byteLength; continue; }
    const s = await T(`segment ${i}`, async () => (await (await get(new URL(segs[i], vurl).href, 120000)).arrayBuffer()).byteLength);
    console.log("   bytes", s.r);
  }
  if (times.length) { const sorted = [...times].sort((a, b) => a - b); const wall = Math.round(performance.now() - t0);
    console.log(`   ${times.length} segments back to back: wall ${wall} ms for ${times.length} s of video (${(times.length * 1000 / wall).toFixed(2)}x real time), per-segment ms min ${sorted[0]} median ${sorted[sorted.length >> 1]} p95 ${sorted[Math.floor(sorted.length * .95)]} max ${sorted.at(-1)}, ${(bytes * 8 / times.length / 1e6).toFixed(1)} Mbps avg`); }
}
const stop = new URLSearchParams({ session, "X-Plex-Token": TOKEN });
await T("stop session", async () => (await get(`${base}/video/:/transcode/universal/stop?${stop}`, 10000)).status);
