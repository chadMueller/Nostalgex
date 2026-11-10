#!/usr/bin/env node
/**
 * Every Plex list request carries X-Plex-Container-Size and is read to its end (Trello N-038).
 *
 * Found in a Plex server log during a Roku first load: "Missing X-Plex-Container-Size header,
 * will fail with status 400 in the future". The collection requests (/library/sections,
 * /library/sections/{key}/collections, /library/collections/{id}/children) and the per-show
 * episode list (/library/metadata/{id}/allLeaves) sent no size. The paged section fetch always did.
 *
 * A bare size is not the fix: Plex answers it with the first window only, so a collection of 650
 * films would come back as 300. This runs the engine's fetchers against a fake Plex that
 *   - answers 400 to a list request with no X-Plex-Container-Size (as Plex says it will),
 *   - returns only the window asked for, so a caller that does not page loses the rest,
 * in the shapes a real server can take: totalSize sent, totalSize left out, a window capped
 * below the size asked for, and a server that ignores the window altogether (which must end, not
 * loop). Then it reads plex-tuner.html and checks every Plex list getter sends the window.
 *
 * No browser, no network beyond 127.0.0.1. Run: `npm run test:plex-paging`.
 */
import http from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import "./nostalgex-collections.js";

const C = globalThis.NostalgexCollections;

let passed = 0;
const failures = [];
const check = (label, ok, detail = "") => {
  if (ok) passed += 1;
  else failures.push(`${label}${detail ? `: ${detail}` : ""}`);
};

// ── The library the fake server holds ────────────────────────────────────────

const keys = (prefix, n) => Array.from({ length: n }, (_, i) => `${prefix}${i + 1}`);
const children = {
  "10": keys("m", 650),   // three windows of 300
  "11": keys("e", 300),   // exactly one full window
  "12": keys("s", 3),
  "20": keys("t", 4),
};
const collections = {
  "1": [{ ratingKey: "10", title: "Big Set" }, { ratingKey: "11", title: "Exact Set" }, { ratingKey: "12", title: "Small Set" }],
  "2": [{ ratingKey: "20", title: "Shows Set" }],
};
const episodes = {
  "500": Array.from({ length: 750 }, (_, i) => ({ ratingKey: `ep${i + 1}`, title: `Episode ${i + 1}` })),
  "501": Array.from({ length: 3 }, (_, i) => ({ ratingKey: `sm${i + 1}`, title: `Small ${i + 1}` })),
};
const sections = [
  { key: "1", title: "Movies", type: "movie" },
  { key: "2", title: "TV", type: "show" },
  { key: "3", title: "Music", type: "artist" },
];

/**
 * A Plex-shaped server. `mode`: "total" sends totalSize; "nototal" leaves it out; "capped"
 * sends totalSize but never more than 100 entries; "ignores" answers every request with the
 * whole list, whatever the window says. `failChildrenAfterFirstPage` answers 500 to any later
 * window of the Big Set. `strict` answers 400 to a list request with no size.
 */
function startPlex(mode, { strict = true, failChildrenAfterFirstPage = false } = {}) {
  const log = [];
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    const path = url.pathname;
    // Plex reads the window from the query or from the header of the same name.
    const sizeText = url.searchParams.get("X-Plex-Container-Size") ?? req.headers["x-plex-container-size"];
    const startText = url.searchParams.get("X-Plex-Container-Start") ?? req.headers["x-plex-container-start"];
    const hasSize = sizeText != null && sizeText !== "";
    const start = Number(startText || 0);
    const entry = { path, start, size: hasSize ? Number(sizeText) : null, hasSize };
    log.push(entry);
    res.setHeader("Content-Type", "application/json");

    const listMatch =
      path === "/library/sections" ? { key: "Directory", list: sections }
      : path.match(/^\/library\/sections\/(\d+)\/collections$/) ? { key: "Metadata", list: collections[path.split("/")[3]] || [] }
      : path.match(/^\/library\/collections\/(\d+)\/children$/) ? { key: "Metadata", list: (children[path.split("/")[3]] || []).map((k) => ({ ratingKey: k })) }
      : path.match(/^\/library\/metadata\/(\d+)\/allLeaves$/) ? { key: "Metadata", list: episodes[path.split("/")[3]] || [] }
      : null;
    if (!listMatch) { res.writeHead(404); return res.end("{}"); }

    if (strict && !hasSize) {
      entry.refused = true;
      res.writeHead(400);
      return res.end(JSON.stringify({ error: "Missing X-Plex-Container-Size header" }));
    }
    if (failChildrenAfterFirstPage && path === "/library/collections/10/children" && start > 0) {
      res.writeHead(500);
      return res.end("{}");
    }

    let window;
    if (mode === "ignores") window = listMatch.list;
    else {
      const size = hasSize ? Math.min(Number(sizeText), mode === "capped" ? 100 : Infinity) : listMatch.list.length;
      window = listMatch.list.slice(start, start + size);
    }
    const container = { size: window.length, offset: start, [listMatch.key]: window };
    if (mode === "total" || mode === "capped") container.totalSize = listMatch.list.length;
    res.end(JSON.stringify({ MediaContainer: container }));
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => {
    resolve({ log, url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => server.close(r)) });
  }));
}

/**
 * The getter a caller hands the engine: one fetch of the path, with the window added the way
 * the tuner does (plexWindowPath). Written to run on a checkout that lacks plexWindowPath too,
 * where it sends the bare path and the strict server refuses it.
 */
const getterFor = (plex) => async (path, win) => {
  const withWindow = C.plexWindowPath ? C.plexWindowPath(path, win) : path;
  const res = await fetch(`${plex.url}${withWindow}`, { headers: { Accept: "application/json", "X-Plex-Token": "lab-token" } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
};

const readAll = async (mode, options) => {
  const plex = await startPlex(mode, options);
  const warn = console.warn;
  console.warn = () => {};
  let out = null;
  let error = null;
  try {
    out = await C.fetchPlexCollections("mid", getterFor(plex));
  } catch (err) {
    error = err && err.message;
  } finally {
    console.warn = warn;
    await plex.close();
  }
  return { out, error, log: plex.log };
};
const byTitle = (out) => Object.fromEntries((out || []).map((c) => [c.title, c.childKeys]));
const childrenRequests = (log, id) => log.filter((l) => l.path === `/library/collections/${id}/children`);

// ── 1. The server totals every list: sizes sent, every collection whole ──────
{
  const { out, error, log } = await readAll("total");
  const refused = log.filter((l) => l.refused);
  check("total: no list request went without a size", refused.length === 0 && error == null,
    `${refused.length} of ${log.length} requests refused (HTTP 400): ${[...new Set(refused.map((l) => l.path))].join(", ")}${error ? `; the scan threw ${error}` : ""}`);
  const t = byTitle(out);
  check("total: the 650-film collection is read whole, not cut at the first window", (t["Big Set"] || []).length === 650, `${(t["Big Set"] || []).length} of 650`);
  check("total: and in order", JSON.stringify(t["Big Set"]) === JSON.stringify(children["10"]));
  check("total: a collection of exactly one window needs no second request", (t["Exact Set"] || []).length === 300 && childrenRequests(log, 11).length === 1,
    `${(t["Exact Set"] || []).length} keys, ${childrenRequests(log, 11).length} requests`);
  check("total: small and TV collections come through", (t["Small Set"] || []).length === 3 && (t["Shows Set"] || []).length === 4);
  check("total: Big Set is asked for in three windows", JSON.stringify(childrenRequests(log, 10).map((l) => l.start)) === "[0,300,600]",
    JSON.stringify(childrenRequests(log, 10).map((l) => l.start)));
  check("total: every window asks for the page size", log.every((l) => l.size === C.PLEX_PAGE_SIZE), JSON.stringify([...new Set(log.map((l) => l.size))]));
  check("total: 9 requests (sections, two collection lists, then 3 + 1 + 1 + 1 windows)", log.length === 9, String(log.length));
  check("total: music sections are not asked for collections", !log.some((l) => l.path === "/library/sections/3/collections"));
}

// ── 2. No totalSize: the first short page ends the walk ──────────────────────
{
  const { out, error, log } = await readAll("nototal");
  const t = byTitle(out);
  check("nototal: nothing refused, nothing thrown", !log.some((l) => l.refused) && error == null, error || "");
  check("nototal: Big Set read whole", (t["Big Set"] || []).length === 650, `${(t["Big Set"] || []).length} of 650`);
  check("nototal: a full window with no total costs one more request, and the empty one ends it",
    JSON.stringify(childrenRequests(log, 11).map((l) => l.start)) === "[0,300]", JSON.stringify(childrenRequests(log, 11).map((l) => l.start)));
  check("nototal: a short list is one request", childrenRequests(log, 12).length === 1);
}

// ── 3. A server that caps the window below the size asked for ────────────────
{
  const { out, error, log } = await readAll("capped");
  const t = byTitle(out);
  check("capped: nothing thrown", error == null, error || "");
  check("capped: Big Set read whole although every window is 100", (t["Big Set"] || []).length === 650 && JSON.stringify(t["Big Set"]) === JSON.stringify(children["10"]),
    `${(t["Big Set"] || []).length} of 650`);
  check("capped: the next window starts where the last one ended, not 300 on",
    JSON.stringify(childrenRequests(log, 10).map((l) => l.start)) === "[0,100,200,300,400,500,600]", JSON.stringify(childrenRequests(log, 10).map((l) => l.start)));
}

// ── 4. A server that ignores the window: the walk ends, nothing is doubled ───
{
  const { out, error, log } = await readAll("ignores", { strict: false });
  const t = byTitle(out);
  check("ignores: nothing thrown", error == null, error || "");
  check("ignores: Big Set comes back once, not twice", (t["Big Set"] || []).length === 650, `${(t["Big Set"] || []).length}`);
  check("ignores: the walk of Big Set ends on the second window", childrenRequests(log, 10).length === 2, String(childrenRequests(log, 10).length));
}

// ── 5. A window that fails halfway drops that collection, not the scan ───────
{
  const { out, error, log } = await readAll("total", { failChildrenAfterFirstPage: true });
  const t = byTitle(out);
  check("failed window: the scan finishes", error == null, error || "");
  check("failed window: the half-read collection is dropped, never kept short", !("Big Set" in t), JSON.stringify(Object.keys(t)));
  check("failed window: the others are still there", (t["Exact Set"] || []).length === 300 && (t["Small Set"] || []).length === 3 && (t["Shows Set"] || []).length === 4);
  check("failed window: it was the second window that failed", childrenRequests(log, 10).length === 2, String(childrenRequests(log, 10).length));
}

// ── 6. A show's episodes (allLeaves): the same helper, a long show whole ─────
{
  const plex = await startPlex("total");
  const get = getterFor(plex);
  try {
    const long = await C.fetchPlexPaged(get, "/library/metadata/500/allLeaves", "Metadata");
    const short = await C.fetchPlexPaged(get, "/library/metadata/501/allLeaves", "Metadata");
    check("allLeaves: a 750-episode show is read whole", long.length === 750 && long[0].ratingKey === "ep1" && long[749].ratingKey === "ep750", String(long.length));
    check("allLeaves: no request went without a size", !plex.log.some((l) => l.refused), JSON.stringify(plex.log.filter((l) => l.refused)));
    check("allLeaves: a short show is one request", plex.log.filter((l) => l.path.endsWith("/501/allLeaves")).length === 1 && short.length === 3);
  } catch (err) {
    // A checkout without the paged helper has nothing to call: that is the failure.
    check("allLeaves: the shared paged reader exists and reads a show", false, err && err.message);
  }
  await plex.close();
}

// ── 7. plex-tuner.html: every Plex list getter sends the window ──────────────
{
  const tuner = readFileSync(fileURLToPath(new URL("../plex-tuner.html", import.meta.url)), "utf8");
  const calls = [...tuner.matchAll(/\b(fetchPlexPaged|fetchPlexCollections)\(/g)];
  // four: the collection scan, the scan's section list, the episode lists, and the CHOOSE YOUR LIBRARIES section list
  check("tuner: the collection scan, the section lists and the episode lists all page", calls.length === 4, `${calls.length} calls found`);
  for (const m of calls) {
    const nearby = tuner.slice(m.index, m.index + 400);
    check(`tuner: ${m[1]} at ${tuner.slice(0, m.index).split("\n").length} hands over a getter that sends the window`, nearby.includes("plexWindowPath("));
  }
  check("tuner: no bare /library/sections request is left", !/plexLibraryFetch(ForServer)?\(\s*['"`]\/library\/sections['"`]/.test(tuner));
  check("tuner: no bare allLeaves request is left", !/fetch\(`\$\{server\.url\}\/library\/metadata\/\$\{show\.ratingKey\}\/allLeaves/.test(tuner));
  check("tuner: the section pages still send their own size", /\/library\/sections\/\$\{section\.key\}\/all\?includeGuids=1[\s\S]{0,80}X-Plex-Container-Size/.test(tuner));
}

if (failures.length) {
  console.error(`plex-paging smoke: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error(`  FAIL ${f}`);
  process.exit(1);
}
console.log(`plex-paging smoke: ${passed} checks passed (sizes sent, 650-film collection and 750-episode show whole, four server shapes)`);
