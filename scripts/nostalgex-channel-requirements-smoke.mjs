#!/usr/bin/env node
// The plain-words lines of WHY ARE SOME CHANNELS MISSING?, from the Apple TV's ChannelRules.plainLanguageRequirements.
// Hand cases (written from the Swift) and every channel in channels.json against scripts/channel-requirements-golden.json.
// UPDATE_GOLDEN=1 rewrites the golden file after channels.json changes on purpose; a Roku or Android port compares against it.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
await import("./nostalgex-channel-requirements.js");
const { plainRequirements, needsLine } = globalThis.NostalgexChannelRequirements;
const here = (p) => fileURLToPath(new URL(p, import.meta.url));
let passed = 0; const failures = [];
const same = (label, got, want) => { if (JSON.stringify(got) === JSON.stringify(want)) passed += 1; else failures.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };

same("movie, years, ratings", plainRequirements({ type: "movie", yearRange: { min: 1980, max: 1989 }, contentRatings: ["PG", "PG-13"] }), ["Movies only", "Released 1980 to 1989", "Rated: PG, PG-13"]);
same("episode, genre or genre", plainRequirements({ type: "episode", genres: { include: ["Animation", "Kids"] } }), ["TV episodes only", "Genre: Animation or Kids"]);
same("all, exclude", plainRequirements({ genres: { requireAll: ["Comedy", "Romance"], exclude: ["Horror"] } }), ["Needs every one of these genres: Comedy, Romance", "Not genre: Horror"]);
same("year open ends", [plainRequirements({ yearRange: { min: 2000 } }), plainRequirements({ yearRange: { max: 1970 } })], [["Released 2000 or later"], ["Released before 1970"]]);
same("ratings and scores", plainRequirements({ ratingMin: 8, imdbRatingMin: 7.5, rtScoreMin: 90, metacriticMin: 80, wonOscar: true }),
  ["Plex star rating 8.0 or higher", "IMDb rating 7.5 or higher", "Rotten Tomatoes score 90 or higher", "Metacritic score 80 or higher", "Won an Oscar"]);
same("watched flags", plainRequirements({ watchedOnly: true, unwatchedOnly: true, rewatched: true }), ["Already watched titles only", "Unwatched titles only", "Watched three times or more"]);
same("keywords keep four", plainRequirements({ keywords: ["a", "b", "c", "d", "e"] }), ["About: a, b, c, d"]);
same("duration", [plainRequirements({ durationRange: { min: 60, max: 90 } }), plainRequirements({ durationRange: { min: 150 } }), plainRequirements({ durationRange: { max: 25 } })],
  [["Runs 60 to 90 minutes"], ["Runs 150 minutes or longer"], ["Runs 25 minutes or shorter"]]);
same("music video, studio, network", plainRequirements({ source: "musicVideo", studios: ["A24", "Pixar"], networks: ["HBO"] }), ["Music videos only", "Studio: A24 or Pixar", "Network: HBO"]);
same("nothing readable: one line", plainRequirements({ titleContains: ["x"] }), ["A specific, curated list of titles rather than a general rule"]);
same("needs line", [needsLine(15, 3), needsLine(1, 0), needsLine(50, null)], ["Needs 15 matching titles. You have 3.", "Needs 1 matching title. You have 0.", "Needs 50 matching titles. Counting yours…"]);

const channels = JSON.parse(readFileSync(here("../channels.json"), "utf8")).channels;
const now = {}; for (const c of channels) now[c.id] = plainRequirements(c.rules);
if (process.env.UPDATE_GOLDEN === "1") { writeFileSync(here("./channel-requirements-golden.json"), JSON.stringify({ note: "plain-words lines per channel id, from scripts/nostalgex-channel-requirements.js (a port of ChannelRules.plainLanguageRequirements)", channels: now }, null, 1) + "\n"); console.log("golden rewritten"); }
const golden = JSON.parse(readFileSync(here("./channel-requirements-golden.json"), "utf8")).channels;
for (const c of channels) same(`channel ${c.id} ${c.name}`, now[c.id], golden[c.id]);
same("the golden file has no stale channels", Object.keys(golden).length, channels.length);
if (failures.length) { console.error(`channel requirements smoke: ${failures.length} failed, ${passed} passed`); for (const f of failures.slice(0, 20)) console.error("  FAIL " + f); process.exit(1); }
console.log(`channel requirements smoke: ${passed} checks passed (${channels.length} channels)`);
