// Shared by the live tools: read and write PLEX_* keys in the repo's .env
// (git-ignored, mode 600), and make HTTPS-only Plex requests. Nothing here
// prints a token.
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ENV_PATH = join(dirname(fileURLToPath(import.meta.url)), "..", "..", ".env");

export function readEnv() {
  const env = {};
  if (!existsSync(ENV_PATH)) return env;
  for (const line of readFileSync(ENV_PATH, "utf8").split("\n")) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) env[m[1]] = m[2].replace(/^"(.*)"$/, "$1");
  }
  return env;
}

export function writeEnvKey(key, value) {
  const lines = existsSync(ENV_PATH) ? readFileSync(ENV_PATH, "utf8").split("\n") : [];
  const kept = lines.filter((l) => !l.startsWith(`${key}=`) && l !== "");
  kept.push(`${key}=${value}`);
  writeFileSync(ENV_PATH, kept.join("\n") + "\n", { mode: 0o600 });
  chmodSync(ENV_PATH, 0o600);
}

export function clientId() {
  const env = readEnv();
  if (env.PLEX_CLIENT_ID) return env.PLEX_CLIENT_ID;
  const id = randomUUID();
  writeEnvKey("PLEX_CLIENT_ID", id);
  return id;
}

export function plexHeaders(token) {
  const h = {
    Accept: "application/json",
    "X-Plex-Product": "nostalgex-roku devtools",
    "X-Plex-Version": "0.1",
    "X-Plex-Platform": "Linux",
    "X-Plex-Client-Identifier": clientId(),
  };
  if (token) h["X-Plex-Token"] = token;
  return h;
}

export async function https(url, { method = "GET", token = "", timeoutMs = 15000 } = {}) {
  if (!url.startsWith("https://")) throw new Error("refusing a non-HTTPS URL");
  const res = await fetch(url, { method, headers: plexHeaders(token), signal: AbortSignal.timeout(timeoutMs) });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: res.status, json };
}

// The account's servers with a working HTTPS connection, ranked as the TV
// ranks them: direct before relay, local before remote.
export async function servers(token) {
  // Checked before any request: a request calls clientId(), which would write a
  // .env holding only PLEX_CLIENT_ID here, and plex.tv would answer a bare 401.
  if (!token) throw new Error(`no PLEX_TOKEN in ${ENV_PATH}: run tests/live/plex-link.mjs, or run from the checkout whose .env holds it`);
  const res = await https("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", { token });
  if (res.status !== 200 || !Array.isArray(res.json)) throw new Error(`plex.tv resources answered ${res.status}`);
  const out = [];
  for (const r of res.json.filter((r) => (r.provides || "").includes("server"))) {
    const ranked = (r.connections || [])
      .filter((c) => c.protocol === "https")
      .map((c) => ({ c, rank: (c.relay ? 2 : 0) + (c.local ? 0 : 1) }))
      .sort((a, b) => a.rank - b.rank);
    for (const { c } of ranked) {
      try {
        const id = await https(`${c.uri}/identity`, { token: r.accessToken, timeoutMs: 5000 });
        if (id.status === 200) {
          out.push({ name: r.name, machineIdentifier: r.clientIdentifier || "", url: c.uri, token: r.accessToken, connections: r.connections || [] });
          break;
        }
      } catch { /* next connection */ }
    }
  }
  return out;
}
