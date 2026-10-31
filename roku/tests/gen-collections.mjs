// Server-collection vectors: upstream's own scripts/nostalgex-collections.js
// run over fixtures, so the port's name cleaning, stock matching, manifest
// overlap, member index, candidates, folds into stock franchise channels,
// numbering and Plex calls answer exactly as the web tuner's. The cases of
// upstream's scripts/nostalgex-collections-smoke.mjs are here, with their
// fixtures rebuilt as library items (the port only has the item index, not
// the older films-only map), plus edges: percentages JS rounds below the
// half (23/40 is 57.49999999999999), non-ASCII titles, empty and missing
// titles, and the cap.
//
// Fold targets here are stock franchise channels only, as the web tuner passes
// them. The port folds through FranchiseCollectionFold.swift, which also takes
// found franchises and dictionary signals; with no dictionary and stock
// targets it answers as upstream's foldTarget, and these vectors hold it to
// that. Called by tests/gen-vectors.mjs, which owns the output.
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export async function collectionsVectors(upstream) {
  // The module is a browser IIFE that sets globalThis.NostalgexCollections.
  await import(pathToFileURL(join(upstream, "scripts", "nostalgex-collections.js")).href);
  const C = globalThis.NostalgexCollections;
  if (!C) throw new Error("upstream collections module did not load");

  // ── Text ──
  const titles = [
    "Batman Collection", "Spielberg's Collection", "Nolan’s Films", "best of 2000s", "80s hits", "batman",
    "Collection", " collection", "COLLECTION", "Collections", "Recollection Box", "The Collection Collection",
    "Star Wars Collection", "1980s Classics", "Top 100", "007 Collection", "2000s & 2010s", "The 1990s",
    "Amélie's Collection", "ÉMILE COLLECTION", "Ålien set", "  Tom Hanks  ", "", "Marvel’s Universe",
    "Spielberg's's", "90's Kids", "1-9-8-0", "the 80s", "Y2K", "y2k comedy", "Harry Potter Collection",
    "Jurassic Park", "Mission: Impossible", "Disney Classics", "HBO", "Sci-Fi Collection",
  ];
  const text = titles.map((t) => ({ title: t, clean: C.cleanTitle(t), decade: C.decadeNormalized(C.cleanTitle(t)) }));

  // ── Stock matching, against the real lineup's names ──
  const channelsJson = JSON.parse(await (await import("node:fs")).promises.readFile(join(upstream, "channels.json"), "utf8"));
  const lineup = channelsJson.channels.map((c) => ({ id: c.id, number: c.number, name: c.name }));
  const matchTitles = [
    ...titles, "Action", "The 80s", "Star Wars", "Marvel Cinematic Universe", "Pixar", "Pixar Movies Collection",
    "Lord of the Rings Collection", "Bourne", "Westerns", "Holidaze", "1960s", "60s", "2020s", "Netflix Originals",
    "Christmas", "Santa's List", "Sitcoms of the 90s", "A", "Tom Hanks",
  ];
  const smokeStock = [
    { id: 2, number: 2, name: "ACTION" },
    { id: 88, number: 88, name: "THE 80S" },
    { id: 100, number: 100, name: "STAR WARS" },
    { id: 101, number: 101, name: "MARVEL" },
  ];
  const match = [
    ...matchTitles.map((t) => ({ title: t, stock: "lineup", label: C.matchStaticChannel(t, lineup) })),
    ...["Star Wars Collection", "1980s Classics", "Tom Hanks", "Collection"].map((t) => ({
      title: t, stock: "smoke", label: C.matchStaticChannel(t, smokeStock),
    })),
    // A channel with no name matches every title, as upstream's includes("") does.
    { title: "Anything", stock: "unnamed", label: C.matchStaticChannel("Anything", [{ id: 7, name: "" }]) },
  ];

  // ── Manifest overlap ──
  const mv = (k, tmdb, server = "srv") => ({
    ratingKey: String(k), tmdbID: tmdb, type: "movie", duration: 100, title: `M${k}`, serverID: server,
  });
  const ep = (k, show, showKey, tmdb = null, server = "srv") => ({
    ratingKey: String(k), title: show, showKey, type: "episode", duration: 22, tmdbID: tmdb, serverID: server,
  });
  const smokeManifest = { items: {
    "movie:1": { channels: [101] }, "movie:2": { channels: [101] }, "movie:3": { channels: [101, 2] },
    "movie:4": { channels: [2] },
  } };
  const byID = (list) => new Map(list.map((c) => [c.id, c]));
  const overlapCases = [];
  const overlap = (name, items, manifest, channels) => {
    const o = C.contentOverlap(items, manifest, byID(channels));
    overlapCases.push({ name, items, manifest, channels, overlap: o });
  };
  overlap("smoke: 75% on CH 101", [mv(1, 1), mv(2, 2), mv(3, 3), mv(4, 4)], smokeManifest, smokeStock);
  overlap("smoke: under 60%", [mv(1, 1), mv(4, 4), mv(5, 5), mv(6, 6)], smokeManifest, smokeStock);
  overlap("smoke: no manifest", [mv(1, 1)], null, smokeStock);
  overlap("no items", [], smokeManifest, smokeStock);
  overlap("manifest without items", [mv(1, 1)], {}, smokeStock);
  overlap("a channel not in the lineup is named by id", [mv(1, 1), mv(2, 2)], { items: {
    "movie:1": { channels: [777] }, "movie:2": { channels: [777] },
  } }, smokeStock);
  overlap("a tie goes to the channel seen first", [mv(1, 1), mv(2, 2), mv(3, 3)], { items: {
    "movie:1": { channels: [2, 101] }, "movie:2": { channels: [101, 2] }, "movie:3": { channels: [2, 101] },
  } }, smokeStock);
  overlap("episodes look up tv:", [ep("e1", "Show", "s1", 9), ep("e2", "Show", "s1", 9), mv(3, 9)], { items: {
    "tv:9": { channels: [2] }, "movie:9": { channels: [101] },
  } }, smokeStock);
  overlap("items with no TMDB id still count in the total", [mv(1, 1), mv(2, null), mv(3, null)], {
    items: { "movie:1": { channels: [101] } },
  }, smokeStock);
  overlap("a channel listed twice counts twice", [mv(1, 1), mv(2, null)], {
    items: { "movie:1": { channels: [101, 101] } },
  }, smokeStock);
  // Percentages at the half, where JS's (count / total) * 100 lands either side.
  for (const [k, n] of [[23, 40], [29, 200], [1, 8], [3, 8], [119, 200], [3, 5], [59, 99], [35, 58], [7, 12], [5, 8], [67, 100]]) {
    const items = Array.from({ length: n }, (_, i) => mv(i + 1, i + 1));
    const manifest = { items: {} };
    for (let i = 1; i <= k; i++) manifest.items[`movie:${i}`] = { channels: [101] };
    const o = C.contentOverlap(items, manifest, byID(smokeStock), 0);
    overlapCases.push({ name: `percent ${k}/${n}`, items, manifest, channels: smokeStock, threshold: 0, overlap: o });
  }

  // ── Candidates, folds and channels ──
  const keyOf = (it) => `${it.serverID}|${it.ratingKey}`;
  const ref = (it) => ({ serverID: it.serverID, ratingKey: it.ratingKey });
  const candidateCases = [];
  const run = (name, items, raw, ctx = {}) => {
    const index = C.indexLibrary(items, (it) => it.serverID);
    const franchiseChannels = (ctx.franchiseChannels || []).map((ch) => ({ ...ch, itemPool: ch.pool }));
    const list = C.buildCandidates(raw, index, {
      staticChannels: ctx.staticChannels || [],
      channelsByID: ctx.channels ? byID(ctx.channels) : undefined,
      franchiseChannels,
      itemKey: keyOf,
      enabledKeys: new Set(ctx.enabledKeys || []),
      manifest: ctx.manifest,
    });
    const { channels, overCap } = C.materialize(list);
    candidateCases.push({
      name,
      items,
      raw,
      staticChannels: ctx.staticChannels || [],
      channels: ctx.channels || null,
      franchiseChannels: (ctx.franchiseChannels || []).map((ch) => ({ ...ch, pool: ch.pool.map(ref) })),
      enabledKeys: ctx.enabledKeys || [],
      manifest: ctx.manifest || null,
      candidates: list.map((c) => ({
        id: c.id, title: c.title, movieCount: c.movieCount, showCount: c.showCount, episodeCount: c.episodeCount,
        items: c.items.map(keyOf), enabled: c.enabled, matchedChannel: c.matchedChannel,
        contentOverlap: c.contentOverlap, foldedInto: c.foldedInto,
        warning: C.duplicateWarning(c), summary: C.memberSummary(c),
      })),
      materialized: {
        overCap,
        channels: channels.map((ch) => ({
          id: ch.id, number: ch.number, name: ch.name, colorHex: ch.colorHex, minItems: ch.minItems,
          enabled: ch.enabled, collectionID: ch.collectionID, pool: ch.itemPool.map(keyOf),
        })),
      },
    });
  };

  // Smoke: 3+ movies on that server, sorted by upper-cased title.
  const smokeItems = [1, 2, 3, 4, 5, 6, 7, 8].map((k) => mv(k, k));
  const smokeRaw = [
    { id: "srv:c1", title: "zombie set", childKeys: ["5", "6", "7"], serverKey: "srv" },
    { id: "srv:c2", title: "Marvel Collection", childKeys: ["1", "2", "3"], serverKey: "srv" },
    { id: "srv:c3", title: "Too Small", childKeys: ["1", "2", "99"], serverKey: "srv" },
    { id: "srv:c4", title: "Alpha", childKeys: ["4", "5", "6", "7", "7"], serverKey: "srv" },
    { id: "other:c5", title: "Other Server", childKeys: ["1", "2", "3"], serverKey: "other" },
    { id: "srv:c6", title: "action heroes", childKeys: ["4", "8", "6"], serverKey: "srv" },
  ];
  run("smoke: candidates, warnings, fold, channels", smokeItems, smokeRaw, {
    staticChannels: smokeStock, manifest: smokeManifest,
    franchiseChannels: [{ id: 101, number: 101, name: "MARVEL", pool: [] }],
    enabledKeys: ["srv:c1", "srv:c2", "srv:c4"],
  });
  run("smoke: item overlap folds", smokeItems,
    [{ id: "srv:x", title: "Phase One", childKeys: ["1", "2", "3"], serverKey: "srv" }],
    { franchiseChannels: [{ id: 101, number: 101, name: "MARVEL", pool: smokeItems.slice(0, 3) }] });
  {
    const big = [0, 1, 2].map((i) => mv(i, null, "s"));
    const many = Array.from({ length: 55 }, (_, i) => ({
      id: `s:${i}`, title: `Set ${String(i).padStart(3, "0")}`, childKeys: ["0", "1", "2"], serverKey: "s",
    }));
    run("smoke: cap at CH 499", big, many, { enabledKeys: many.map((m) => m.id) });
  }

  // Smoke (CollectionShowsTests.swift): collections holding shows.
  const alpha = [1, 2, 3, 4].map((n) => ep(`a${n}`, "Alpha Island", "s1"));
  const bravo = [1, 2, 3, 4, 5].map((n) => ep(`b${n}`, "Bravo Kitchen", "s2"));
  const lima = [1, 2].map((n) => ep(`l${n}`, "Hotel Lima", "s4"));
  const charlie = [1, 2, 3].map((n) => ep(`c${n}`, "Charlie Court", undefined));
  const films = [mv("m1", null), mv("m2", null), mv("m3", null)];
  films[0].title = "Delta Run"; films[1].title = "Echo Point"; films[2].title = "Foxtrot Night";
  const showItems = [...films, ...alpha, ...bravo, ...lima, ...charlie];
  const showRaw = [
    { id: "srv:tv", title: "Reality TV", childKeys: ["s1", "s2"], serverKey: "srv" },
    { id: "srv:mix", title: "Mixed Bag", childKeys: ["m1", "m2", "s4"], serverKey: "srv" },
    { id: "srv:emby", title: "Courtroom", childKeys: ["c1", "c2", "c3"], serverKey: "srv" },
    { id: "srv:two", title: "Two Films", childKeys: ["m1", "m2"], serverKey: "srv" },
    { id: "srv:films", title: "Film Trio", childKeys: ["m1", "m2", "m3"], serverKey: "srv" },
    { id: "srv:dupes", title: "Dupes", childKeys: ["m1", "m1", "s1", "a1", "zz"], serverKey: "srv" },
  ];
  run("shows: candidates, summaries, channels", showItems, showRaw, { enabledKeys: showRaw.map((r) => r.id) });
  const wick = { id: 104, number: 104, name: "JOHN WICK", pool: films };
  run("fold guard: a show the channel lacks keeps the mix", showItems,
    [{ id: "srv:w", title: "John Wick", childKeys: ["m1", "m2", "m3", "s4"], serverKey: "srv" }],
    { staticChannels: [wick], franchiseChannels: [wick] });
  run("fold guard: films only still folds", showItems,
    [{ id: "srv:f", title: "John Wick", childKeys: ["m1", "m2", "m3"], serverKey: "srv" }],
    { staticChannels: [wick], franchiseChannels: [wick] });
  run("fold guard: the mix folds once the channel airs the show", showItems,
    [{ id: "srv:w", title: "John Wick", childKeys: ["m1", "m2", "m3", "s4"], serverKey: "srv" }],
    { staticChannels: [{ ...wick, pool: [...films, lima[1]] }], franchiseChannels: [{ ...wick, pool: [...films, lima[1]] }] });

  // Edges.
  {
    const items = Array.from({ length: 200 }, (_, i) => mv(i + 1, i + 1));
    const pool = items.slice(0, 119);
    run("fold by item overlap at 119/200", items,
      [{ id: "srv:x", title: "Untitled Box", childKeys: items.map((i) => i.ratingKey), serverKey: "srv" }],
      { franchiseChannels: [{ id: 102, number: 102, name: "HARRY POTTER", pool }] });
    run("no fold at 23/40, which JS rounds to 57", items.slice(0, 40),
      [{ id: "srv:y", title: "Box", childKeys: items.slice(0, 40).map((i) => i.ratingKey), serverKey: "srv" }],
      { franchiseChannels: [{ id: 102, number: 102, name: "HARRY POTTER", pool: items.slice(0, 23) }] });
    run("fold at 24/40", items.slice(0, 40),
      [{ id: "srv:y", title: "Box", childKeys: items.slice(0, 40).map((i) => i.ratingKey), serverKey: "srv" }],
      { franchiseChannels: [{ id: 102, number: 102, name: "HARRY POTTER", pool: items.slice(0, 24) }] });
  }
  {
    // The real lineup's names and a manifest: the name match points at a stock
    // channel that is not a franchise channel, so it warns but never folds;
    // overlap onto a franchise channel folds even with a name match elsewhere.
    const items = [1, 2, 3, 4, 5].map((k) => mv(k, 900 + k));
    const manifest = { items: {
      "movie:901": { channels: [102] }, "movie:902": { channels: [102] }, "movie:903": { channels: [102] },
      "movie:904": { channels: [12] },
    } };
    const potter = { id: 102, number: 102, name: "HARRY POTTER", pool: [] };
    run("real lineup: warnings and folds", items, [
      { id: "srv:a", title: "Action Adventure Collection", childKeys: ["1", "2", "3", "4"], serverKey: "srv" },
      { id: "srv:b", title: "Wizarding World", childKeys: ["1", "2", "3", "5"], serverKey: "srv" },
      { id: "srv:c", title: "Harry Potter Collection", childKeys: ["4", "5", "1"], serverKey: "srv" },
      { id: "srv:d", title: "The 1980s", childKeys: ["5", "4", "3"], serverKey: "srv" },
      { id: "srv:e", title: "", childKeys: ["1", "2", "3"], serverKey: "srv" },
      { id: "srv:f", childKeys: ["2", "3", "4"], serverKey: "srv" },
    ], {
      staticChannels: lineup, channels: lineup, manifest, franchiseChannels: [potter],
      enabledKeys: ["srv:a", "srv:b", "srv:c", "srv:d", "srv:e", "srv:f"],
    });
  }
  {
    // Sort: upper-cased, by UTF-16 code unit (É after Z), stable for equal titles.
    const items = [1, 2, 3].map((k) => mv(k, null));
    const raw = ["zebra", "Émile", "Zorro", "amélie", "ålien", "Zebra", "a", "B", "b"].map((t, i) => ({
      id: `srv:${i}`, title: t, childKeys: ["1", "2", "3"], serverKey: "srv",
    }));
    run("sort by code unit, stable", items, raw, { enabledKeys: raw.map((r) => r.id) });
  }
  {
    // Two servers with the same ratingKeys: each collection resolves on its own.
    const items = [mv(1, null, "a"), mv(2, null, "a"), mv(3, null, "a"), mv(1, null, "b"), mv(2, null, "b"),
      ep("e1", "Show", "s9", null, "b"), ep("e2", "Show", "s9", null, "b")];
    run("two servers", items, [
      { id: "a:1", title: "On A", childKeys: ["1", "2", "3"], serverKey: "a" },
      { id: "b:1", title: "On B", childKeys: ["1", "2", "s9"], serverKey: "b" },
      { id: "b:2", title: "B short", childKeys: ["1", "3"], serverKey: "b" },
    ], { enabledKeys: ["b:1"] });
  }

  // ── Plex calls ──
  const plexCases = [];
  const plex = async (name, docs) => {
    const calls = [];
    const getJSON = async (p) => {
      calls.push(p);
      if (!(p in docs)) throw new Error("404");
      return docs[p];
    };
    let out;
    // Upstream warns on the console for each section that fails; that is not output.
    const warn = console.warn;
    console.warn = () => {};
    try {
      out = await C.fetchPlexCollections("mid", getJSON);
    } catch (err) {
      out = "throws";
    } finally {
      console.warn = warn;
    }
    plexCases.push({ name, docs, calls, out });
  };
  await plex("smoke: movie and TV sections, deduped, failed children dropped", {
    "/library/sections": { MediaContainer: { Directory: [{ key: "1", type: "movie" }, { key: "2", type: "show" }, { key: "3", type: "movie" }] } },
    "/library/sections/1/collections": { MediaContainer: { Metadata: [{ ratingKey: "10", title: "A" }, { ratingKey: "11", title: "B" }] } },
    "/library/sections/3/collections": { MediaContainer: { Metadata: [{ ratingKey: "10", title: "A" }] } },
    "/library/collections/10/children": { MediaContainer: { Metadata: [{ ratingKey: "1" }, { ratingKey: "2" }] } },
  });
  await plex("no section list throws", {});
  await plex("music and photo sections are skipped; odd rows and titles", {
    "/library/sections": { MediaContainer: { Directory: [{ key: "4", type: "artist" }, { key: "5", type: "photo" }, { key: "6", type: "show" }] } },
    "/library/sections/6/collections": { MediaContainer: { Metadata: [
      { ratingKey: 20, title: "" }, { title: "no key" }, { ratingKey: "21" }, { ratingKey: "22", title: "Empty" },
    ] } },
    "/library/collections/20/children": { MediaContainer: { Metadata: [{ ratingKey: 7 }, { ratingKey: "8" }] } },
    "/library/collections/21/children": { MediaContainer: {} },
    "/library/collections/22/children": { MediaContainer: { size: 0 } },
  });
  await plex("no sections", { "/library/sections": { MediaContainer: {} } });

  // ── Jellyfin and Emby calls ──
  // Upstream reads four BoxSets at once, so its call order isn't the port's;
  // the calls are kept sorted and compared as a set.
  const boxSetCases = [];
  const boxSet = async (name, docs) => {
    const calls = [];
    const getJSON = async (p) => {
      calls.push(p);
      if (!(p in docs)) throw new Error("404");
      return docs[p];
    };
    let out;
    try {
      out = await C.fetchBoxSetCollections("srv", "u 1/2", getJSON);
    } catch (err) {
      out = "throws";
    }
    boxSetCases.push({ name, docs, calls: [...calls].sort(), out });
  };
  const uid = encodeURIComponent("u 1/2");
  const list = `/Items?userId=${uid}&IncludeItemTypes=BoxSet&Recursive=true&Fields=ChildCount&SortBy=SortName`;
  const page = (id, start) => `/Items?userId=${uid}&ParentId=${encodeURIComponent(id)}&Recursive=true`
    + `&IncludeItemTypes=Movie,Series&StartIndex=${start}&Limit=200&SortBy=SortName`;
  await boxSet("smoke: films and series ids, deduped, a failed BoxSet dropped", {
    [list]: { Items: [{ Id: "b1", Name: "Alien Collection" }, { Id: "b2", Name: "Shows" }, { Id: "b1", Name: "Again" }, { Id: "b3", Name: "Gone" }] },
    [page("b1", 0)]: { Items: [{ Id: "m1" }, { Id: "m2" }, { Id: "m3" }], TotalRecordCount: 3 },
    [page("b2", 0)]: { Items: [{ Id: "s1", Type: "Series" }, { Id: "m4" }], TotalRecordCount: 2 },
  });
  await boxSet("no BoxSet list throws", {});
  await boxSet("no BoxSets", { [list]: {} });
  await boxSet("pages until TotalRecordCount", {
    [list]: { Items: [{ Id: "big", Name: "Big Set" }] },
    [page("big", 0)]: { Items: [{ Id: "a" }, { Id: "b" }], TotalRecordCount: 5 },
    [page("big", 2)]: { Items: [{ Id: "c" }, { Id: "d" }], TotalRecordCount: 5 },
    [page("big", 4)]: { Items: [{ Id: "e" }], TotalRecordCount: 5 },
  });
  await boxSet("an empty page ends it; no TotalRecordCount ends after one page", {
    [list]: { Items: [{ Id: "short", Name: "Short" }, { Id: "open", Name: "Open" }, { Id: "none", Name: "None" }] },
    [page("short", 0)]: { Items: [{ Id: "a" }], TotalRecordCount: 4 },
    [page("short", 1)]: { Items: [], TotalRecordCount: 4 },
    [page("open", 0)]: { Items: [{ Id: "x" }, { Id: "y" }] },
    [page("none", 0)]: {},
  });
  await boxSet("a later page that fails drops the BoxSet", {
    [list]: { Items: [{ Id: "half", Name: "Half" }, { Id: "ok", Name: "Ok" }] },
    [page("half", 0)]: { Items: [{ Id: "a" }], TotalRecordCount: 2 },
    [page("ok", 0)]: { Items: [{ Id: "z" }], TotalRecordCount: 1 },
  });
  await boxSet("odd rows and titles", {
    [list]: { Items: [null, { Name: "No id" }, { Id: "", Name: "Empty id" }, { Id: 7, Name: "" }, { Id: "u", Name: null }, { Id: "w/ slash", Name: "Ünïcode Set" }] },
    [page("7", 0)]: { Items: [{ Id: 70 }, { Name: "no id" }], TotalRecordCount: 2 },
    [page("u", 0)]: { Items: [{ Id: "u1" }], TotalRecordCount: 1 },
    [page("w/ slash", 0)]: { Items: [{ Id: "w1" }], TotalRecordCount: 1 },
  });

  return {
    constants: {
      ID_BASE: C.ID_BASE, NUMBER_BASE: C.NUMBER_BASE, NUMBER_END: C.NUMBER_END, CAPACITY: C.CAPACITY,
    },
    text,
    lineup,
    smokeStock,
    match,
    overlap: overlapCases,
    candidates: candidateCases,
    plex: plexCases,
    boxSets: boxSetCases,
  };
}
