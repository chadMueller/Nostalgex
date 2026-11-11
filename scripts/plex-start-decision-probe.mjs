#!/usr/bin/env node
/**
 * Does Plex answer start.m3u8 with HTTP 400 on fast channel changes, and does a /decision call first stop it?
 *
 * The Apple TV measured (2026-09, a Mac probe mirroring the app's request) that Plex answers
 * /video/:/transcode/universal/start.m3u8 with 400 whenever the transcoder is not idle, unless
 * /video/:/transcode/universal/decision is asked first with the same session and query. The web tuner builds the
 * same start.m3u8 URL (plex-tuner.html, playCurrentItem) and has never asked /decision. This sends the web tuner's
 * request, the same query in the same order, the way a viewer pressing a channel every second or two does:
 * start a session, read the playlist, stop it (what stopActiveTranscode does), start the next at once.
 *
 *   PLEX_URL=http://127.0.0.1:32468 [PLEX_TOKEN=...] RATING_KEYS=1,2,3 node scripts/plex-start-decision-probe.mjs
 *   CHANGES=20 GAP_MS=1500 MODE=both|plain|decision STOP=0   (STOP=0 never stops the old session, as when a stop is lost)
 *
 * Prints, per mode, how many start.m3u8 answers were not 200 and the time to the playlist. Not part of `npm test`:
 * it needs a real Plex server.
 */
import { randomUUID } from "node:crypto";

const base = (process.env.PLEX_URL || "").replace(/\/$/, "");
const token = process.env.PLEX_TOKEN || "";
const keys = (process.env.RATING_KEYS || "").split(",").map((s) => s.trim()).filter(Boolean);
const changes = Number(process.env.CHANGES || 20);
const gap = Number(process.env.GAP_MS || 1500);
const modes = process.env.MODE === "plain" ? ["plain"] : process.env.MODE === "decision" ? ["decision"] : ["plain", "decision"];
if (!base || !keys.length) { console.error("Set PLEX_URL and RATING_KEYS (comma separated rating keys of films the server can transcode)."); process.exit(2); }
const clientId = "nx-probe-" + randomUUID().slice(0, 8);

/** The web tuner's request, from plex-tuner.html playCurrentItem (AUTO quality adds nothing). */
const query = (key, session) => `?path=${encodeURIComponent("/library/metadata/" + key)}`
  + `&mediaIndex=0&partIndex=0&protocol=hls&offset=0&copyts=1`
  + (token ? `&X-Plex-Token=${token}` : "")
  + `&session=${session}&X-Plex-Session-Identifier=${session}&X-Plex-Client-Identifier=${clientId}`
  + `&X-Plex-Product=Plex%2090&X-Plex-Platform=Web&X-Plex-Platform-Version=1.0&X-Plex-Device=Browser&X-Plex-Device-Name=Plex90`;

const stop = (session) => fetch(`${base}/video/:/transcode/universal/stop?session=${session}` + (token ? `&X-Plex-Token=${token}` : ""))
  .then((r) => r.arrayBuffer()).catch(() => {});

async function run(mode) {
  const statuses = []; const times = []; let previous = null;
  for (let i = 0; i < changes; i += 1) {
    const session = randomUUID();
    const q = query(keys[i % keys.length], session);
    const t0 = Date.now();
    if (mode === "decision") { try { const d = await fetch(`${base}/video/:/transcode/universal/decision${q}`); await d.arrayBuffer(); } catch (e) { /* the start answers for itself */ } }
    let status = 0;
    try { const r = await fetch(`${base}/video/:/transcode/universal/start.m3u8${q}`); status = r.status; await r.arrayBuffer(); } catch (e) { status = -1; }
    statuses.push(status); times.push(Date.now() - t0);
    if (previous && process.env.STOP !== "0") stop(previous);      // the web stops the old session as the new one starts (STOP=0: the stop is lost)
    previous = session;
    await new Promise((r) => setTimeout(r, gap));
  }
  if (previous) await stop(previous);
  const bad = statuses.filter((s) => s !== 200).length;
  const sorted = [...times].sort((a, b) => a - b);
  console.log(`${mode.padEnd(9)} ${changes} changes: ${bad} not 200 (${[...new Set(statuses)].join(",")}), median ${sorted[Math.floor(sorted.length / 2)]} ms to the playlist`);
  return { mode, bad, statuses };
}

const out = [];
for (const m of modes) { out.push(await run(m)); await new Promise((r) => setTimeout(r, 4000)); }
process.exit(out.some((o) => o.bad > 0 && o.mode === "decision") ? 1 : 0);
