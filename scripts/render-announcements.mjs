// Writes the announcement bar into the static marketing pages from
// content/announcements.json.
//
// Same arrangement as render-roku.mjs: the data lives in content/, each page keeps
// one marked region just above its nav, and this script rewrites what is between
// the markers. `npm run build` runs it before vite, and `npm test` runs it with
// --check, so the committed pages and the built pages never disagree.
//
//   <!-- ANNOUNCE:START (auto-generated) -->
//   ...the bar, or nothing when no message is on...
//   <!-- ANNOUNCE:END (auto-generated) -->
//
// Which pages get the bar:
//
//   The nine static pages below, each a Vite input with its own copy of the nav.
//   The blog and the channel guide are written by scripts/build-blog.mjs and
//   scripts/build-bundles.mjs through renderNav() in scripts/site-chrome.mjs, which
//   puts the bar in front of the nav, so they need no markers.
//   Not on privacy, terms and the 404 page (they have no nav), and never on the
//   web tuner pages: those are built on their own and this script does not open
//   them. A new marketing page with the site nav goes in PAGES and gets the two
//   marker lines above its <header class="nav">.
//
//   node scripts/render-announcements.mjs            rewrite the pages
//   node scripts/render-announcements.mjs --check    fail if a page is out of date

import { readFile, writeFile } from "node:fs/promises";
import { renderBar, loadEnabled, loadEnded, DISMISS_KEY } from "./announcements.mjs";
import { renderNav } from "./site-chrome.mjs";

const CHECK = process.argv.includes("--check");
const PAGES = [
  "index.html",
  "apple-tv.html",
  "how-channels-work.html",
  "plex.html",
  "jellyfin.html",
  "emby.html",
  "support.html",
  "self-host.html",
  "roku.html",
];

const START = "<!-- ANNOUNCE:START (auto-generated) -->";
const END = "<!-- ANNOUNCE:END (auto-generated) -->";

function region(text, page, bar) {
  const startIdx = text.indexOf(START);
  const endIdx = text.indexOf(END);
  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
    throw new Error(`${page}: the ANNOUNCE markers are missing or in the wrong order. Put them above <header class="nav">.`);
  }
  if (text.indexOf(START, startIdx + 1) !== -1) throw new Error(`${page}: more than one ANNOUNCE region.`);
  // Keep the bar at the marker's own indentation.
  const lineStart = text.lastIndexOf("\n", startIdx) + 1;
  const indent = text.slice(lineStart, startIdx);
  const body = bar
    ? "\n" + bar.split("\n").map((l) => indent + l).join("\n") + "\n" + indent
    : "\n" + indent;
  return text.slice(0, startIdx + START.length) + body + text.slice(endIdx);
}

const messages = loadEnabled(); // validates the file too
const bar = renderBar(messages);

const stale = [];
for (const page of PAGES) {
  const url = new URL(`../${page}`, import.meta.url);
  const before = await readFile(url, "utf8");
  const after = region(before, page, bar);
  if (after === before) continue;
  if (CHECK) stale.push(page);
  else await writeFile(url, after, "utf8");
}

// The generated pages take the bar from renderNav(). Make sure that hookup holds.
const flat = (html) => html.split("\n").map((l) => l.trim()).join("\n");
const nav = flat(renderNav());
if (bar && !nav.includes(flat(bar))) {
  console.error("announcements: renderNav() in scripts/site-chrome.mjs no longer includes the bar, so the blog and channel guide would lose it.");
  process.exit(1);
}
if (!bar && nav.includes('id="announce"')) {
  console.error("announcements: renderNav() renders a bar although no message is enabled.");
  process.exit(1);
}

// app.js keeps its own copy of the storage key (it cannot import this module).
if (!(await readFile(new URL("../app.js", import.meta.url), "utf8")).includes(`"${DISMISS_KEY}"`)) {
  console.error(`announcements: app.js does not use the storage key "${DISMISS_KEY}" from scripts/announcements.mjs.`);
  process.exit(1);
}

for (const m of loadEnded()) {
  console.log(`announcements: note, "${m.id}" ended ${m.endsAt}. The browser hides it; set enabled to false and re-render when you next touch the file.`);
}

if (CHECK) {
  if (stale.length) {
    console.error(`announcements: ${stale.join(", ")} out of date with content/announcements.json. Run \`npm run announce:render\`.`);
    process.exit(1);
  }
  console.log(`announcements: ${PAGES.length} pages match content/announcements.json (${messages.length} enabled)`);
} else {
  console.log(`announcements: rendered ${PAGES.length} pages, ${messages.length} message${messages.length === 1 ? "" : "s"} enabled`);
}
