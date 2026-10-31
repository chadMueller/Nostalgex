#!/usr/bin/env node
/**
 * Smoke test for scripts/nostalgex-collections.js (server collections as channels
 * on the web tuner). Mirrors AppState+Channels.swift `scanCollections` /
 * `materializeDynamicChannels` and CollectionCategory numbering. No network.
 * Run: `npm run test:collections`.
 */
import "./nostalgex-collections.js";
const C = globalThis.NostalgexCollections;

let pass = 0;
const failures = [];
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) pass++;
  else failures.push(`${name}: expected ${e}, got ${a}`);
}

// ---- Name cleaning and stock matching (Swift collectionClean / staticChannelLookup) ----
check("clean strips collection", C.cleanTitle("Batman Collection"), "batman");
check("clean possessive", C.cleanTitle("Spielberg's Collection"), "spielbergs");
check("clean curly possessive", C.cleanTitle("Nolan’s Films"), "nolans films");
check("decade 4 digit", C.decadeNormalized("best of 2000s"), "00s");
check("decade 2 digit", C.decadeNormalized("80s hits"), "80s");
check("no decade", C.decadeNormalized("batman"), null);

const stock = [
  { id: 2, number: 2, name: "ACTION" },
  { id: 88, number: 88, name: "THE 80S" },
  { id: 100, number: 100, name: "STAR WARS" },
  { id: 101, number: 101, name: "MARVEL" },
];
check("name match substring", C.matchStaticChannel("Star Wars Collection", stock), "CH 100 STAR WARS");
check("name match decade", C.matchStaticChannel("1980s Classics", stock), "CH 88 THE 80S");
check("no name match", C.matchStaticChannel("Tom Hanks", stock), null);
check("empty title never matches", C.matchStaticChannel("Collection", stock), null);

// ---- Manifest overlap (Swift computeContentOverlap, 60%) ----
const manifest = { items: {
  "movie:1": { channels: [101] }, "movie:2": { channels: [101] }, "movie:3": { channels: [101, 2] },
  "movie:4": { channels: [2] },
} };
const byID = new Map(stock.map((c) => [c.id, c]));
const mv = (k, tmdb) => ({ ratingKey: String(k), tmdbID: tmdb, type: "movie", duration: 100, title: `M${k}` });
{
  const o = C.contentOverlap([mv(1, 1), mv(2, 2), mv(3, 3), mv(4, 4)], manifest, byID);
  check("overlap 75% on CH 101", [o.channelID, o.percent, o.channelName], [101, 75, "CH 101 MARVEL"]);
  check("overlap under 60% is null", C.contentOverlap([mv(1, 1), mv(4, 4), mv(5, 5), mv(6, 6)], manifest, byID), null);
  check("overlap without manifest", C.contentOverlap([mv(1, 1)], null, byID), null);
}

// ---- Candidates: 3+ movies on that server, sorted by upper-cased title ----
const server = new Map([["srv", new Map([1, 2, 3, 4, 5, 6, 7, 8].map((k) => [String(k), mv(k, k)]))]]);
const raw = [
  { id: "srv:c1", title: "zombie set", childKeys: ["5", "6", "7"], serverKey: "srv" },
  { id: "srv:c2", title: "Marvel Collection", childKeys: ["1", "2", "3"], serverKey: "srv" },
  { id: "srv:c3", title: "Too Small", childKeys: ["1", "2", "99"], serverKey: "srv" },
  { id: "srv:c4", title: "Alpha", childKeys: ["4", "5", "6", "7", "7"], serverKey: "srv" },
  { id: "other:c5", title: "Other Server", childKeys: ["1", "2", "3"], serverKey: "other" },
  { id: "srv:c6", title: "action heroes", childKeys: ["4", "8", "6"], serverKey: "srv" },
];
const marvel = { id: 101, number: 101, name: "MARVEL", itemPool: [] };
{
  const list = C.buildCandidates(raw, server, {
    staticChannels: stock, manifest, franchiseChannels: [marvel], enabledKeys: new Set(["srv:c1", "srv:c2", "srv:c4"]),
  });
  check("candidates: <3 matched dropped, other server dropped", list.map((c) => c.id), ["srv:c6", "srv:c4", "srv:c2", "srv:c1"]);
  check("candidates: titles upper-cased", list.map((c) => c.title), ["ACTION HEROES", "ALPHA", "MARVEL COLLECTION", "ZOMBIE SET"]);
  check("candidates: duplicate child counted once", list[1].movieCount, 4);
  check("candidates: enabled from saved keys", list.map((c) => c.enabled), [false, true, true, true]);
  check("candidates: stock duplicate flagged", C.duplicateWarning(list[0]), "Exists: CH 2 ACTION");
  check("candidates: overlap outranks name", C.duplicateWarning(list[2]), "100% already on CH 101 MARVEL");
  check("candidates: plain row has no warning", C.duplicateWarning(list[3]), null);
  check("candidates: franchise duplicate folds", list[2].foldedInto, "CH 101 MARVEL");
  check("candidates: non-franchise duplicate does not fold", list[0].foldedInto, null);

  const { channels, overCap } = C.materialize(list);
  check("materialize: folded and disabled skipped", channels.map((c) => c.name), ["ALPHA", "ZOMBIE SET"]);
  check("materialize: numbers from 450", channels.map((c) => c.number), [450, 451]);
  check("materialize: ids from 1,020,000", channels.map((c) => c.id), [1020000, 1020001]);
  check("materialize: no rules, pool is the collection", [channels[0].rules, channels[0].itemPool.length], [null, 4]);
  check("materialize: flags", [channels[0].collection, channels[0].stock, channels[0].minItems, channels[0].enabled], [true, false, 3, true]);
  check("materialize: colors by slot", channels.map((c) => c.colorHex), ["#E74C3C", "#3498DB"]);
  check("materialize: overCap", overCap, 0);
}
{
  // Item overlap with a franchise pool folds a collection whose name says nothing.
  const pool = [1, 2, 3].map((k) => mv(k, k));
  const list = C.buildCandidates([{ id: "srv:x", title: "Phase One", childKeys: ["1", "2", "3"], serverKey: "srv" }], server, {
    staticChannels: [], franchiseChannels: [{ id: 101, number: 101, name: "MARVEL", itemPool: pool }],
  });
  check("item overlap folds", list[0].foldedInto, "CH 101 MARVEL");
}
{
  // Cap: 50 channels, CH 450-499, the rest counted, never built.
  const big = new Map([["s", new Map(Array.from({ length: 3 }, (_, i) => [String(i), mv(i, null)]))]]);
  const many = Array.from({ length: 55 }, (_, i) => ({
    id: `s:${i}`, title: `Set ${String(i).padStart(3, "0")}`, childKeys: ["0", "1", "2"], serverKey: "s",
  }));
  const list = C.buildCandidates(many, big, { enabledKeys: new Set(many.map((m) => m.id)) });
  const { channels, overCap } = C.materialize(list);
  check("cap: 50 built", channels.length, 50);
  check("cap: last number 499", channels[channels.length - 1].number, 499);
  check("cap: 5 over", overCap, 5);
}

// ---- Fetchers: the same calls the Swift services make ----
{
  const calls = [];
  const plex = {
    "/library/sections": { MediaContainer: { Directory: [{ key: "1", type: "movie" }, { key: "2", type: "show" }, { key: "3", type: "movie" }] } },
    "/library/sections/1/collections": { MediaContainer: { Metadata: [{ ratingKey: "10", title: "A" }, { ratingKey: "11", title: "B" }] } },
    "/library/sections/3/collections": { MediaContainer: { Metadata: [{ ratingKey: "10", title: "A" }] } },
    "/library/collections/10/children": { MediaContainer: { Metadata: [{ ratingKey: "1" }, { ratingKey: "2" }] } },
  };
  const getJSON = async (p) => {
    calls.push(p);
    if (!(p in plex)) throw new Error("404");
    return plex[p];
  };
  const out = await C.fetchPlexCollections("mid", getJSON);
  check("plex: movie and TV sections, deduped", calls.filter((c) => c.endsWith("/collections")),
    ["/library/sections/1/collections", "/library/sections/2/collections", "/library/sections/3/collections"]);
  check("plex: failed children dropped", out, [{ id: "mid:10", title: "A", childKeys: ["1", "2"], serverKey: "mid" }]);
}
{
  const calls = [];
  const getJSON = async (p) => {
    calls.push(p);
    if (p.includes("IncludeItemTypes=BoxSet")) return { Items: [{ Id: "b1", Name: "Box" }, { Id: "b1", Name: "Box" }] };
    const start = Number(p.match(/StartIndex=(\d+)/)[1]);
    return start === 0
      ? { Items: Array.from({ length: 200 }, (_, i) => ({ Id: `m${i}` })), TotalRecordCount: 201 }
      : { Items: [{ Id: "m200" }], TotalRecordCount: 201 };
  };
  const out = await C.fetchBoxSetCollections("jellyfin", "u 1", getJSON);
  check("boxset: listing call", calls[0], "/Items?userId=u%201&IncludeItemTypes=BoxSet&Recursive=true&Fields=ChildCount&SortBy=SortName");
  check("boxset: children call", calls[1], "/Items?userId=u%201&ParentId=b1&Recursive=true&IncludeItemTypes=Movie,Series&StartIndex=0&Limit=200&SortBy=SortName");
  check("boxset: deduped, paged", [out.length, out[0].childKeys.length, out[0].id], [1, 201, "jellyfin:b1"]);
}

// ---- Collections holding shows (CollectionShowsTests.swift) ----
{
  const ep = (k, show, showKey, se, server = "srv") => ({
    ratingKey: String(k), title: show, showKey, type: "episode", seTag: se, duration: 22, serverID: server,
  });
  const film = (k, title) => ({ ratingKey: String(k), title, type: "movie", duration: 100, serverID: "srv" });
  const alpha = [1, 2, 3, 4].map((n) => ep(`a${n}`, "Alpha Island", "s1", `S01E0${n}`));
  const bravo = [1, 2, 3, 4, 5].map((n) => ep(`b${n}`, "Bravo Kitchen", "s2", `S01E0${n}`));
  const lima = [1, 2].map((n) => ep(`l${n}`, "Hotel Lima", "s4", `S01E0${n}`));
  // Restored from a library cache written before showKey: Emby lists these by key.
  const charlie = [1, 2, 3].map((n) => ep(`c${n}`, "Charlie Court", undefined, `S01E0${n}`));
  const films = [film("m1", "Delta Run"), film("m2", "Echo Point"), film("m3", "Foxtrot Night")];
  const index = C.indexLibrary([...films, ...alpha, ...bravo, ...lima, ...charlie], (it) => it.serverID);

  check("index: one per server", [...index.keys()], ["srv"]);
  check("resolve: show keys expand to episodes", C.resolveMembers(["s1", "s2"], index.get("srv")).map((i) => i.ratingKey),
    [...alpha, ...bravo].map((i) => i.ratingKey));
  check("resolve: episode keys (Emby) match without showKey", C.resolveMembers(["c1", "c2", "c3"], index.get("srv")).length, 3);
  check("resolve: each item once, unknown keys ignored",
    C.resolveMembers(["m1", "m1", "s1", "a1", "zz"], index.get("srv")).map((i) => i.ratingKey), ["m1", "a1", "a2", "a3", "a4"]);
  check("representatives: one per show", C.titleRepresentatives([...films.slice(0, 1), ...alpha]).map((i) => i.ratingKey), ["m1", "a1"]);

  const raw = [
    { id: "srv:tv", title: "Reality TV", childKeys: ["s1", "s2"], serverKey: "srv" },
    { id: "srv:mix", title: "Mixed Bag", childKeys: ["m1", "m2", "s4"], serverKey: "srv" },
    { id: "srv:emby", title: "Courtroom", childKeys: ["c1", "c2", "c3"], serverKey: "srv" },
    { id: "srv:two", title: "Two Films", childKeys: ["m1", "m2"], serverKey: "srv" },
    { id: "srv:films", title: "Film Trio", childKeys: ["m1", "m2", "m3"], serverKey: "srv" },
  ];
  const list = C.buildCandidates(raw, index, { enabledKeys: new Set(raw.map((r) => r.id)) });
  check("shows: candidates (two films still too few)", list.map((c) => c.title), ["COURTROOM", "FILM TRIO", "MIXED BAG", "REALITY TV"]);
  check("shows: summaries", list.map((c) => C.memberSummary(c)),
    ["1 show · 3 episodes", "3 movies", "2 movies · 1 show", "2 shows · 9 episodes"]);
  check("shows: counts", list.map((c) => [c.movieCount, c.showCount, c.episodeCount]), [[0, 1, 3], [3, 0, 0], [2, 1, 2], [0, 2, 9]]);
  const { channels } = C.materialize(list);
  check("shows: channels from 450", channels.map((c) => [c.number, c.name, c.itemPool.length]),
    [[450, "COURTROOM", 3], [451, "FILM TRIO", 3], [452, "MIXED BAG", 4], [453, "REALITY TV", 9]]);
  check("shows: pool is episodes", channels[3].itemPool.every((i) => i.type === "episode"), true);
  check("summary wording", [
    C.memberSummary({ movieCount: 12, showCount: 0, episodeCount: 0 }),
    C.memberSummary({ movieCount: 0, showCount: 1, episodeCount: 1 }),
    C.memberSummary({ movieCount: 1, showCount: 2, episodeCount: 9 }),
  ], ["12 movies", "1 show · 1 episode", "1 movie · 2 shows"]);

  // Fold guard: a name match onto a films-only franchise channel folds the films but
  // never a mix whose show the channel does not air.
  const wick = { id: 104, number: 104, name: "JOHN WICK", itemPool: films };
  const key = (it) => `${it.serverID}|${it.ratingKey}`;
  const mixFold = C.buildCandidates([{ id: "srv:w", title: "John Wick", childKeys: ["m1", "m2", "m3", "s4"], serverKey: "srv" }], index,
    { staticChannels: [wick], franchiseChannels: [wick], itemKey: key });
  check("fold guard: mix with a show the channel lacks stays", mixFold[0].foldedInto, null);
  const filmFold = C.buildCandidates([{ id: "srv:f", title: "John Wick", childKeys: ["m1", "m2", "m3"], serverKey: "srv" }], index,
    { staticChannels: [wick], franchiseChannels: [wick], itemKey: key });
  check("fold guard: films-only still folds", filmFold[0].foldedInto, "CH 104 JOHN WICK");
  const wickWithShow = { ...wick, itemPool: [...films, lima[1]] };
  const mixFold2 = C.buildCandidates([{ id: "srv:w", title: "John Wick", childKeys: ["m1", "m2", "m3", "s4"], serverKey: "srv" }], index,
    { staticChannels: [wickWithShow], franchiseChannels: [wickWithShow], itemKey: key });
  check("fold guard: mix folds once the channel airs the show", mixFold2[0].foldedInto, "CH 104 JOHN WICK");
}

// ---- A collection channel of episodes through the shared scheduler ----
{
  await import("./nostalgex-daily-manifest.js");
  const DM = globalThis.NostalgexDailyManifest;
  if (DM && typeof DM.interleaveByShow === "function") {
    const eps = [];
    for (const [show, key, n] of [["Alpha Island", "s1", 8], ["Bravo Kitchen", "s2", 6], ["Charlie Court", "s3", 5]]) {
      for (let i = 1; i <= n; i++) eps.push({ ratingKey: `${key}-${i}`, title: show, showKey: key, type: "episode", duration: 22, seTag: `S01E${String(i).padStart(2, "0")}` });
    }
    const order = DM.interleaveByShow(eps, C.ID_BASE, 20375);
    let run = 1, maxRun = 1;
    for (let i = 1; i < order.length; i++) { run = order[i].title === order[i - 1].title ? run + 1 : 1; maxRun = Math.max(maxRun, run); }
    const alphaTags = order.filter((i) => i.title === "Alpha Island").map((i) => i.seTag);
    check("schedule: every episode once", new Set(order.map((i) => i.ratingKey)).size, 19);
    check("schedule: at most two of a show in a row", maxRun <= 2, true);
    check("schedule: shuffled, not S/E order", JSON.stringify(alphaTags) !== JSON.stringify([...alphaTags].sort()), true);
  } else {
    failures.push("daily manifest module did not expose interleaveByShow");
  }
}

if (failures.length) {
  console.error(`collections smoke: ${failures.length} failed, ${pass} passed`);
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`collections smoke: ${pass} passed`);
